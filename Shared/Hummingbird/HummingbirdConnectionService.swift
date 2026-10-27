//
//  HummingbirdConnectionService.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-05-18.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import Foundation

/// Talks to a Hummingbird server (cobdfamily/hummingbird) over its v1 REST surface (fork).
///
/// Hummingbird puts accessible libraries (NNELS today) behind one REST API through server plugins,
/// so one connection reaches whichever library the server's plugin serves.
///
/// Auth is HTTP Basic on every authenticated call: `/login` checks the credentials and the server
/// caches that for about 15 minutes. The password stays in the saved connection so the header can be
/// rebuilt for each request; the REST surface issues no tokens.
@MainActor
@Observable
public class HummingbirdConnectionService: BPLogger {
  /// `nonisolated` so the `nonisolated init` below can read it. The key the July 2026 builds used
  private nonisolated static let activeConnectionIDKey = "hummingbird_active_connection_id"

  /// Keychain persistence, de-duplication and the active choice, shared with Jellyfin and ABS
  private let store: IntegrationConnectionStore<HummingbirdConnectionData>

  public var connections: [HummingbirdConnectionData] { store.connections }
  public var connection: HummingbirdConnectionData? { store.active }
  public var activeConnectionID: String? { store.activeConnectionID }

  /// Every request goes through it, so tests can check what's sent
  private nonisolated let httpClient: IntegrationHTTPClient
  /// How the resource poll waits between tries, in nanoseconds; tests make it instant
  private nonisolated let waitBeforeRetry: @Sendable (UInt64) async throws -> Void
  /// The clock the resource poll's budget runs on; tests move it along with their waits
  private nonisolated let now: @Sendable () -> Date

  /// How long the resource poll keeps asking a server that is still preparing a book. NNELS DAISY
  /// archives of several GB over a slow link have taken 8 minutes and more server-side
  nonisolated static let resourcePollBudget: TimeInterval = 20 * 60

  public nonisolated init(
    keychainService: KeychainServiceProtocol = KeychainService(),
    httpClient: IntegrationHTTPClient = IntegrationURLSessionClient(),
    defaults: UserDefaults = .standard,
    waitBeforeRetry: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.store = IntegrationConnectionStore(
      keychainKey: .hummingbirdConnection,
      activeIDDefaultsKey: Self.activeConnectionIDKey,
      keychain: keychainService,
      defaults: defaults
    )
    self.httpClient = httpClient
    self.waitBeforeRetry = waitBeforeRetry
    self.now = now
  }

  public func setup() {
    store.reload()
  }

  // MARK: - Server probe

  /// Asks the server root whether it's a Hummingbird and returns a name for it (its host). A probe
  /// before signing in: a 401 here is never "your session expired".
  public func pingServer(
    at absolutePath: String,
    customHeaders: [String: String] = [:]
  ) async throws -> String {
    guard let url = URL(string: absolutePath) else {
      throw IntegrationError.urlMalformed(nil)
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 10
    applyCustomHeaders(to: &request, headers: customHeaders)

    let (data, response) = try await httpClient.data(for: request)
    guard (200...299).contains(response.statusCode) else {
      throw IntegrationError.unexpectedResponse(code: response.statusCode)
    }

    guard
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      json["service"] as? String == "hummingbird"
    else {
      throw IntegrationError.unexpectedResponse(code: nil)
    }
    return url.host ?? "Hummingbird"
  }

  // MARK: - Sign in

  /// Checks the credentials against `/protocols/hummingbird/v1/login` and saves the connection.
  /// Hummingbird answers `{"authenticated": true, "username": …}`; no token is issued, the password
  /// goes with every later request.
  ///
  /// - Parameter replacingID: the connection a re-authentication started from, so signing in to the
  ///   same account at an edited URL updates that row instead of leaving an orphan
  public func signIn(
    username: String,
    password: String,
    serverUrl: String,
    serverName: String,
    customHeaders: [String: String] = [:],
    replacingID: String? = nil
  ) async throws {
    guard let url = URL(string: serverUrl) else {
      throw IntegrationError.urlMalformed(nil)
    }

    // In the body, never the URL: hummingbird 0.3.1 dropped the query form because it put
    // passwords in every access log on the way (uvicorn, Traefik, any CDN, Console.app)
    let loginURL = url.appendingPathComponent("protocols/hummingbird/v1/login")
    var request = URLRequest(url: loginURL)
    request.httpMethod = "POST"
    applyCustomHeaders(to: &request, headers: customHeaders)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])

    let (data, response) = try await httpClient.data(for: request)
    // A sign-in cancelled while the request was out (the sheet swiped away) mustn't be saved
    try Task.checkCancellation()

    guard (200...299).contains(response.statusCode) else {
      if response.statusCode == 401 {
        throw URLError(.userAuthenticationRequired)
      }
      throw IntegrationError.unexpectedResponse(code: response.statusCode)
    }

    guard
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      json["authenticated"] as? Bool == true,
      let returnedUser = json["username"] as? String,
      !returnedUser.isEmpty
    else {
      throw IntegrationError.unexpectedResponse(code: nil)
    }

    // Re-authentication keeps the connection's id, which the provenance of downloaded books names
    store.upsert(url: url, userID: returnedUser, replacingID: replacingID) { existing in
      HummingbirdConnectionData(
        id: existing?.id ?? UUID().uuidString,
        url: url,
        serverName: serverName,
        userName: returnedUser,
        password: password,
        customHeaders: customHeaders
      )
    }
  }

  public func updateCustomHeaders(_ headers: [String: String]) {
    guard let activeID = connection?.id else { return }
    updateCustomHeaders(id: activeID, headers)
  }

  /// Saves `headers` on the connection with `id`, whichever is active
  public func updateCustomHeaders(id: String, _ headers: [String: String]) {
    store.updateCustomHeaders(id: id, headers)
  }

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

  // MARK: - Bookshelf and search

  /// The books on the user's shelf, audio editions only
  public func fetchBookshelf() async throws -> [HummingbirdLibraryItem] {
    guard let connection else { throw URLError(.userAuthenticationRequired) }

    let url = connection.url
      .appendingPathComponent("protocols/hummingbird/v1/bookshelf/list")
      .appending(queryItems: [URLQueryItem(name: "username", value: connection.userName)])
    var request = URLRequest(url: url)
    applyAuthenticatedHeaders(to: &request, connection: connection)

    let (data, response) = try await httpClient.data(for: request)
    try validateAuthenticatedResponse(response, connection: connection)

    let envelope = try JSONDecoder().decode(BookshelfListResponse.self, from: data)
    return envelope.items.compactMap(Self.makeItem(from:))
  }

  /// The library's matches for `query`, audio editions only
  public func search(query: String, page: Int = 0) async throws -> [HummingbirdLibraryItem] {
    guard let connection else { throw URLError(.userAuthenticationRequired) }
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    let url = connection.url
      .appendingPathComponent("protocols/hummingbird/v1/search")
      .appending(queryItems: [
        URLQueryItem(name: "q", value: trimmed),
        URLQueryItem(name: "page", value: "\(page)"),
        URLQueryItem(name: "username", value: connection.userName),
      ])
    var request = URLRequest(url: url)
    applyAuthenticatedHeaders(to: &request, connection: connection)

    let (data, response) = try await httpClient.data(for: request)
    try validateAuthenticatedResponse(response, connection: connection)

    let envelope = try JSONDecoder().decode(SearchResponse.self, from: data)
    return envelope.items.compactMap(Self.makeItem(from:))
  }

  /// Takes a book off the user's shelf on its server (the library's "return"): on a loan's expiry and
  /// when the user deletes the downloaded book. `bookId` is Hummingbird's node_id.
  ///
  /// Goes to the connection the book's provenance names and fails without a request when that's
  /// gone, since servers can reuse numeric ids. The active connection only when none is named.
  public func returnBook(bookId: String, connectionId: String?) async throws {
    let target = try connectionId.map(savedConnection) ?? connection
    guard let target else { throw URLError(.userAuthenticationRequired) }
    guard let id = Int(bookId) else { throw IntegrationError.unexpectedResponse(code: nil) }

    let url = target.url
      .appendingPathComponent("protocols/hummingbird/v1/bookshelf/remove")
      .appendingPathComponent("\(id)")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    applyAuthenticatedHeaders(to: &request, connection: target)

    let (_, response) = try await httpClient.data(for: request)
    try validateAuthenticatedResponse(response, connection: target)
  }

  // MARK: - Bookmarks

  /// Saves `bookmark` as the listening position of the book with `bookId` (Hummingbird's node_id) on
  /// the server of the connection with `connectionId`, the one the book's provenance names. The server
  /// keeps the bookmark as sent and takes the user from the sign-in. A connection that's gone fails
  /// before any request
  public func reportBookmark(_ bookmark: HummingbirdBookmark, bookId: String, connectionId: String) async throws {
    let target = try savedConnection(connectionId)
    var request = try bookmarkRequest(bookId: bookId, connection: target)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(BookmarkEnvelope(bookmark: bookmark))

    let (_, response) = try await httpClient.data(for: request)
    try validateAuthenticatedResponse(response, connection: target)
  }

  /// The listening position saved for the book with `bookId` on the server of the connection with
  /// `connectionId`, or nil when there's none BookPlayer can read (nothing saved, or a DODP client's
  /// bookmark, which keeps a `position` instead)
  public func fetchBookmark(bookId: String, connectionId: String) async throws -> HummingbirdBookmark? {
    let target = try savedConnection(connectionId)
    let request = try bookmarkRequest(bookId: bookId, connection: target)

    let (data, response) = try await httpClient.data(for: request)
    try validateAuthenticatedResponse(response, connection: target)
    guard let answer = try? JSONDecoder().decode(BookmarkAnswer.self, from: data) else {
      throw IntegrationError.unexpectedResponse(code: nil)
    }
    return answer.bookmark
  }

  private func bookmarkRequest(bookId: String, connection: HummingbirdConnectionData) throws -> URLRequest {
    guard let id = Int(bookId) else { throw IntegrationError.unexpectedResponse(code: nil) }
    let url = connection.url
      .appendingPathComponent("protocols/hummingbird/v1/bookshelf/bookmark")
      .appendingPathComponent("\(id)")
    var request = URLRequest(url: url)
    applyAuthenticatedHeaders(to: &request, connection: connection)
    return request
  }

  /// One audio edition from an API entry, or nil for text, braille and other editions BookPlayer
  /// can't play. The entry's URL ends `/download/{format}/{bookId}/`, the server's own statement of
  /// which copy this is.
  nonisolated static func makeItem(from api: HummingbirdLibraryItem.APIItem) -> HummingbirdLibraryItem? {
    guard let downloadURL = URL(string: api.url) else { return nil }
    let trailingNumbers = api.url.split(separator: "/").reversed().compactMap { Int($0) }
    guard trailingNumbers.count >= 2 else { return nil }

    let item = HummingbirdLibraryItem(
      bookId: trailingNumbers[0],
      format: trailingNumbers[1],
      title: api.title,
      downloadURL: downloadURL,
      dueDate: api.dueDate.flatMap(parseISO8601)
    )
    return item.isAudioFormat ? item : nil
  }

  /// ISO-8601 with or without fractional seconds: Python's `isoformat()` gives either
  nonisolated static func parseISO8601(_ raw: String) -> Date? {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: raw) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: raw)
  }

  // MARK: - Download

  /// The files a book is made of, from `/resources/{format}/{bookId}` on the saved connection with
  /// `connectionId` (the one the book was listed on).
  ///
  /// A book the server hasn't fetched yet answers 503 with Retry-After while it prepares the file
  /// (hummingbird 0.4.1 and later). This asks again until it's ready (200), missing (404), cancelled,
  /// or `resourcePollBudget` has passed. Retry-After is clamped to 1...30 seconds: a hostile or broken
  /// server sending -1 or a huge value would trap or stall the poll for months.
  public func fetchResources(_ item: HummingbirdLibraryItem, connectionId: String) async throws -> [DODPResource] {
    let connection = try savedConnection(connectionId)
    let url = connection.url
      .appendingPathComponent("protocols/hummingbird/v1/resources")
      .appendingPathComponent("\(item.format)")
      .appendingPathComponent("\(item.bookId)")

    let deadline = now().addingTimeInterval(Self.resourcePollBudget)
    while true {
      try Task.checkCancellation()
      var request = URLRequest(url: url)
      request.timeoutInterval = 30
      applyAuthenticatedHeaders(to: &request, connection: connection)

      let (data, response) = try await httpClient.data(for: request)
      if response.statusCode == 503 {
        guard now() <= deadline else { throw IntegrationError.unexpectedResponse(code: 503) }
        try await waitBeforeRetry(UInt64(Self.retryAfterSeconds(response)) * 1_000_000_000)
        continue
      }
      try validateAuthenticatedResponse(response, connection: connection)
      return try JSONDecoder().decode(ResourcesResponse.self, from: data).resources
    }
  }

  /// The wait a 503 asks for, in whole seconds within 1...30; 10 when the header is missing or isn't
  /// a number (the HTTP-date form isn't honoured)
  nonisolated static func retryAfterSeconds(_ response: HTTPURLResponse) -> Int {
    let requested = response.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) } ?? 10
    return max(1, min(requested, 30))
  }

  /// An authenticated request for one resource of a book, with the credentials of the connection its
  /// list came from: the active one may have changed during a long wait for the server to prepare it
  public func createResourceDownloadRequest(_ resource: DODPResource, connectionId: String) throws -> URLRequest {
    let connection = try savedConnection(connectionId)
    guard let url = URL(string: resource.uri) else {
      throw IntegrationError.urlMalformed(nil)
    }
    var request = URLRequest(url: url)
    applyAuthenticatedHeaders(to: &request, connection: connection)
    return request
  }

  // MARK: - Auth and validation

  /// The saved connection with `id`; signed out (removed) fails as a sign-in being needed, before
  /// any request is made
  private func savedConnection(_ id: String) throws -> HummingbirdConnectionData {
    guard let saved = connections.first(where: { $0.id == id }) else {
      throw URLError(.userAuthenticationRequired)
    }
    return saved
  }

  /// A 401 or 403 from a saved connection is an expired session (sign in again keeps the
  /// connection); anything else outside 2xx is an unexpected answer
  private func validateAuthenticatedResponse(
    _ response: HTTPURLResponse,
    connection: HummingbirdConnectionData
  ) throws {
    if response.statusCode == 401 || response.statusCode == 403 {
      throw IntegrationError.sessionExpired(serverName: connection.serverName)
    }
    guard (200...299).contains(response.statusCode) else {
      throw IntegrationError.unexpectedResponse(code: response.statusCode)
    }
  }

  private func applyCustomHeaders(to request: inout URLRequest, headers: [String: String]) {
    for (key, value) in headers {
      request.setValue(value, forHTTPHeaderField: key)
    }
  }

  /// Custom headers first, Basic auth last, so a custom header named Authorization can't replace it.
  /// The header also gets the request through a reverse proxy in front of Hummingbird
  private func applyAuthenticatedHeaders(to request: inout URLRequest, connection: HummingbirdConnectionData) {
    applyCustomHeaders(to: &request, headers: connection.customHeaders)
    let credentials = Data("\(connection.userName):\(connection.password)".utf8).base64EncodedString()
    request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
  }
}

// MARK: - Wire models

/// A listening position as BookPlayer keeps it on a Hummingbird server (fork): the July builds' shape.
/// The server stores whatever a client sends; only `currentTime` is required to read one back
public struct HummingbirdBookmark: Codable, Equatable, Sendable {
  public let currentTime: Double
  public let duration: Double
  /// `currentTime` as a share of `duration`, 0 to 1
  public let progress: Double
  public let isFinished: Bool

  enum CodingKeys: String, CodingKey {
    case currentTime, duration, progress, isFinished
  }

  public init(currentTime: Double, duration: Double, isFinished: Bool) {
    self.currentTime = currentTime
    self.duration = duration
    self.progress = duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
    self.isFinished = isFinished
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    currentTime = try container.decode(Double.self, forKey: .currentTime)
    duration = (try? container.decode(Double.self, forKey: .duration)) ?? 0
    progress = (try? container.decode(Double.self, forKey: .progress)) ?? 0
    isFinished = (try? container.decode(Bool.self, forKey: .isFinished)) ?? false
  }
}

private struct BookmarkEnvelope: Encodable {
  let bookmark: HummingbirdBookmark
}

/// `GET bookshelf/bookmark/{id}`: `{"username", "node_id", "bookmark": {...}}`, the bookmark `{}` when
/// nothing is saved. One BookPlayer can't read is no bookmark, not an error
private struct BookmarkAnswer: Decodable {
  let bookmark: HummingbirdBookmark?

  enum CodingKeys: String, CodingKey {
    case bookmark
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    bookmark = try? container.decode(HummingbirdBookmark.self, forKey: .bookmark)
  }
}

private struct BookshelfListResponse: Decodable {
  let items: [HummingbirdLibraryItem.APIItem]
}

private struct SearchResponse: Decodable {
  let items: [HummingbirdLibraryItem.APIItem]
}
