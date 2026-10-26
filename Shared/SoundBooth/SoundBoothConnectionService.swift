//
//  SoundBoothConnectionService.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import Foundation

/// BookPlayer's side of SoundBooth (fork): the saved accounts, sign-in, and the API calls the screens
/// make, with the API's errors turned into the shared `IntegrationError`.
///
/// Sign-in is two steps without a password: `requestLoginCode(email:)` has SoundBooth email a code,
/// `signIn(email:code:replacingID:)` verifies it and saves the session. There's no server address: the
/// service is fixed.
@MainActor
@Observable
public class SoundBoothConnectionService: BPLogger {
  /// `nonisolated` so the `nonisolated init` can read it. The key the July 2026 builds used
  private nonisolated static let activeConnectionIDKey = "soundbooth_active_connection_id"

  /// Keychain persistence, de-duplication and the active choice, shared with the other integrations
  private let store: IntegrationConnectionStore<SoundBoothConnectionData>
  private nonisolated let apiClient: SoundBoothAPIClient

  public var connections: [SoundBoothConnectionData] { store.connections }
  public var connection: SoundBoothConnectionData? { store.active }
  public var activeConnectionID: String? { store.activeConnectionID }

  /// The rendition downloads use: the higher of the two SoundBooth serves (192k), the most its API has
  public var preferredQuality: SoundBoothQuality = .high

  public nonisolated init(
    keychainService: KeychainServiceProtocol = KeychainService(),
    apiClient: SoundBoothAPIClient = SoundBoothAPIClient(),
    defaults: UserDefaults = .standard
  ) {
    self.store = IntegrationConnectionStore(
      keychainKey: .soundboothConnection,
      activeIDDefaultsKey: Self.activeConnectionIDKey,
      keychain: keychainService,
      defaults: defaults
    )
    self.apiClient = apiClient
  }

  public func setup() {
    store.reload()
  }

  // MARK: - Sign in

  /// Has SoundBooth email a one-time code to `email`
  public func requestLoginCode(email: String) async throws {
    do {
      try await apiClient.requestLoginCode(email: email)
    } catch {
      throw mapError(error)
    }
  }

  /// Verifies the emailed `code` and saves the session as the active account.
  ///
  /// - Parameter replacingID: the connection a re-authentication started from. Signing in to the same
  ///   account keeps its id, which the provenance of downloaded books names; another account is a new
  ///   connection.
  public func signIn(email: String, code: String, replacingID: String? = nil) async throws {
    let session: SoundBoothSession
    do {
      session = try await apiClient.verifyLoginCode(email: email, code: code)
    } catch {
      throw mapError(error)
    }
    // A sign-in abandoned while the request was out (the sheet closed) mustn't be saved
    try Task.checkCancellation()

    store.upsert(url: apiClient.configuration.baseURL, userID: session.userId, replacingID: replacingID) { existing in
      SoundBoothConnectionData(session: session, id: existing?.id ?? UUID().uuidString)
    }
  }

  // MARK: - Library (the active account)

  public func fetchLibraryElements() async throws -> [SoundBoothLibraryElement] {
    try await call(on: activeSession()) { try await $0.libraryElements(session: $1) }
  }

  public func fetchSeries() async throws -> [SoundBoothSeries] {
    try await call(on: activeSession()) { try await $0.series(session: $1) }
  }

  public func fetchGroups() async throws -> [SoundBoothGroup] {
    try await call(on: activeSession()) { try await $0.groups(session: $1) }
  }

  /// The whole catalog, which names series and seasons the list calls leave out
  public func fetchCatalog() async throws -> [SoundBoothElement] {
    try await call(on: activeSession()) { try await $0.items(session: $1) }
  }

  // MARK: - The account the library was listed for

  /// The episodes of a season bought as a bundle, asked of the connection with `connectionId`
  public func fetchSeasonItems(groupId: String, connectionId: String) async throws -> [SoundBoothElement] {
    try await call(on: session(of: connectionId)) { try await $0.items(inGroup: groupId, session: $1) }
  }

  /// The chapters of `itemIds`, asked of the connection with `connectionId`
  public func fetchItemResources(itemIds: [String], connectionId: String) async throws -> [SoundBoothItemResource] {
    try await call(on: session(of: connectionId)) { try await $0.itemResources(itemIds: itemIds, session: $1) }
  }

  /// The saved positions of the connection with `connectionId`
  public func fetchProgresses(connectionId: String) async throws -> [SoundBoothProgress] {
    try await call(on: session(of: connectionId)) { try await $0.progresses(session: $1) }
  }

  /// A chapter's audio URL, through `resources/play` for the connection with `connectionId`
  public func resolvePlaybackURL(resourceId: String, connectionId: String) async throws -> URL {
    let quality = preferredQuality
    return try await call(on: session(of: connectionId)) {
      try await $0.resolvePlaybackURL(resourceId: resourceId, quality: quality, session: $1)
    }
  }

  // MARK: - Connections

  public func activateConnection(id: String) {
    store.setActive(id: id)
  }

  public func deleteConnection(id: String) {
    store.remove(id: id)
  }

  public func deleteConnection() {
    if let id = connection?.id {
      deleteConnection(id: id)
    }
  }

  // MARK: - Helpers

  private func activeSession() throws -> SoundBoothSession {
    guard let session = connection?.session else {
      throw URLError(.userAuthenticationRequired)
    }
    return session
  }

  /// The session of the saved connection with `id`. One that's gone (signed out) fails before any
  /// request, as for the other integrations: a title is never fetched with another account's session.
  private func session(of id: String) throws -> SoundBoothSession {
    guard let saved = connections.first(where: { $0.id == id }) else {
      throw URLError(.userAuthenticationRequired)
    }
    return saved.session
  }

  private func call<T>(
    on session: SoundBoothSession,
    _ body: (SoundBoothAPIClient, SoundBoothSession) async throws -> T
  ) async throws -> T {
    do {
      return try await body(apiClient, session)
    } catch {
      throw mapError(error)
    }
  }

  /// The API client's errors as the shared screens know them
  func mapError(_ error: Error) -> Error {
    guard let apiError = error as? SoundBoothAPIError else { return error }

    switch apiError {
    case .sessionInvalid:
      return IntegrationError.sessionExpired(serverName: "SoundBooth")
    case .http(let status):
      return IntegrationError.unexpectedResponse(code: status)
    case .noRedirect(let status):
      return IntegrationError.unexpectedResponse(code: status)
    case .api(let message, let code):
      // SoundBooth's own words say more than its code ("That code has expired"). The code is the
      // API's, not an HTTP status, so without words there's nothing better than the generic message
      guard let message, !message.isEmpty else {
        return IntegrationError.unexpectedResponse(code: nil)
      }
      return IntegrationError.serverMessage(code: code.flatMap { Int($0) } ?? 0, message: message)
    case .decoding:
      return IntegrationError.unexpectedResponse(code: nil)
    case .malformedURL:
      return IntegrationError.urlMalformed(nil)
    }
  }
}
