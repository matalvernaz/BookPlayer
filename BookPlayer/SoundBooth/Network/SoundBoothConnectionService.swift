//
//  SoundBoothConnectionService.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Foundation

/// BookPlayer-side glue around the standalone `SoundBoothAPIClient`: owns the observable
/// connection state, persists sessions to the Keychain, and maps API errors onto the shared
/// `IntegrationError` so the common connection/library UI can present them.
///
/// Auth is a two-step passwordless flow: `requestLoginCode(email:)` emails a code, then
/// `signIn(email:code:)` verifies it and stores the resulting session. There's no server URL to
/// enter — the backend is fixed — so the connection screen only needs an email then a code.
@MainActor
@Observable
class SoundBoothConnectionService: BPLogger {
  private static let activeConnectionIDKey = "soundbooth_active_connection_id"

  private nonisolated let keychainService: KeychainServiceProtocol
  private let apiClient: SoundBoothAPIClient

  /// Bitrate used for playback/download. SoundBooth exposes 96k and 192k; default to the higher
  /// tier. (A user-facing quality setting can flow into here later.)
  var preferredQuality: SoundBoothQuality = .high

  var connections: [SoundBoothConnectionData] = []
  var connection: SoundBoothConnectionData? {
    if let activeConnectionID,
      let active = connections.first(where: { $0.id == activeConnectionID }) {
      return active
    }
    return connections.first
  }

  /// Wired by `MainCoordinator` for download-flow provenance tracking, mirroring the other clients.
  var mediaServerSourceStore: MediaServerSourceStore?

  private(set) var activeConnectionID: String? {
    get { UserDefaults.standard.string(forKey: Self.activeConnectionIDKey) }
    set { UserDefaults.standard.set(newValue, forKey: Self.activeConnectionIDKey) }
  }

  nonisolated init(
    keychainService: KeychainServiceProtocol = KeychainService(),
    apiClient: SoundBoothAPIClient = SoundBoothAPIClient()
  ) {
    self.keychainService = keychainService
    self.apiClient = apiClient
  }

  func setup() {
    reloadConnections()
  }

  // MARK: - Auth

  /// Ask SoundBooth to email a one-time login code to `email`. No session required.
  func requestLoginCode(email: String) async throws {
    do {
      try await apiClient.requestLoginCode(email: email)
    } catch {
      throw mapError(error)
    }
  }

  /// Verify the emailed `code` and persist the resulting session as the active connection.
  func signIn(email: String, code: String) async throws {
    let session: SoundBoothSession
    do {
      session = try await apiClient.verifyLoginCode(email: email, code: code)
    } catch {
      throw mapError(error)
    }
    // Bail before persisting if the caller cancelled mid-flight (e.g. sheet dismissed).
    try Task.checkCancellation()

    // Preserve the existing connection's id on re-auth so imported items keep resolving.
    let existing = connections.first { $0.userId == session.userId }
    let data = SoundBoothConnectionData(session: session, id: existing?.id ?? UUID().uuidString)

    connections.removeAll { $0.userId == session.userId }
    connections.append(data)
    activeConnectionID = data.id
    saveConnections()
  }

  // MARK: - Library

  func fetchLibraryElements() async throws -> [SoundBoothLibraryElement] {
    let session = try requireSession()
    do {
      return try await apiClient.libraryElements(session: session)
    } catch {
      throw mapError(error)
    }
  }

  func fetchItemResources(itemIds: [String]) async throws -> [SoundBoothItemResource] {
    let session = try requireSession()
    do {
      return try await apiClient.itemResources(session: session, itemIds: itemIds)
    } catch {
      throw mapError(error)
    }
  }

  func fetchProgresses() async throws -> [SoundBoothProgress] {
    let session = try requireSession()
    do {
      return try await apiClient.progresses(session: session)
    } catch {
      throw mapError(error)
    }
  }

  func fetchSeries() async throws -> [SoundBoothSeries] {
    let session = try requireSession()
    do {
      return try await apiClient.series(session: session)
    } catch {
      throw mapError(error)
    }
  }

  // MARK: - Streaming / download

  /// Resolve a resource to its playable CDN URL (via the authenticated `resources/play` gate).
  func resolvePlaybackURL(resourceId: String, quality: SoundBoothQuality? = nil) async throws -> URL {
    let session = try requireSession()
    do {
      return try await apiClient.resolvePlaybackURL(
        resourceId: resourceId,
        quality: quality ?? preferredQuality,
        session: session
      )
    } catch {
      throw mapError(error)
    }
  }

  /// A download request for a resource. Resolves the entitlement-gated URL, then downloads the
  /// resulting public CDN MP3 directly (no auth header needed on the CDN).
  func createDownloadRequest(resourceId: String, quality: SoundBoothQuality? = nil) async throws -> URLRequest {
    let url = try await resolvePlaybackURL(resourceId: resourceId, quality: quality)
    return URLRequest(url: url)
  }

  // MARK: - Connection management

  func activateConnection(id: String) {
    guard connections.contains(where: { $0.id == id }) else { return }
    activeConnectionID = id
  }

  func deleteConnection(id: String) {
    connections.removeAll { $0.id == id }
    if activeConnectionID == id {
      activeConnectionID = connections.first?.id
    }
    if connections.isEmpty {
      do {
        try keychainService.remove(.soundboothConnection)
      } catch {
        Self.logger.warning("failed to remove SoundBooth connection from keychain: \(error)")
      }
    } else {
      saveConnections()
    }
  }

  func deleteConnection() {
    if let id = connection?.id {
      deleteConnection(id: id)
    }
  }

  // MARK: - Persistence

  private func reloadConnections() {
    if let stored: [SoundBoothConnectionData] = try? keychainService.get(.soundboothConnection) {
      connections = stored.filter { isConnectionValid($0) }
      if connections.count != stored.count {
        saveConnections()
      }
    } else {
      Self.logger.warning("no SoundBooth connection data in keychain")
      return
    }

    if connections.isEmpty {
      activeConnectionID = nil
    } else if let activeID = activeConnectionID,
      !connections.contains(where: { $0.id == activeID }) {
      activeConnectionID = connections.first?.id
    } else if activeConnectionID == nil {
      activeConnectionID = connections.first?.id
    }
  }

  private func saveConnections() {
    try? keychainService.set(connections, key: .soundboothConnection)
  }

  private func isConnectionValid(_ data: SoundBoothConnectionData) -> Bool {
    !data.userId.isEmpty && !data.jwt.isEmpty
  }

  // MARK: - Helpers

  private func requireSession() throws -> SoundBoothSession {
    guard let session = connection?.session else {
      throw URLError(.userAuthenticationRequired)
    }
    return session
  }

  /// Map the standalone client's errors onto the shared `IntegrationError` (plus the
  /// `userAuthenticationRequired` URLError the shared UI already understands).
  private func mapError(_ error: Error) -> Error {
    switch error {
    case let apiError as SoundBoothAPIError:
      switch apiError {
      case .sessionInvalid:
        return IntegrationError.sessionExpired(serverName: connection?.serverName ?? "SoundBooth")
      case .http(let status):
        return IntegrationError.unexpectedResponse(code: status)
      case .api, .decoding:
        return IntegrationError.unexpectedResponse(code: nil)
      case .malformedURL:
        return IntegrationError.urlMalformed(nil)
      }
    default:
      return error
    }
  }
}
