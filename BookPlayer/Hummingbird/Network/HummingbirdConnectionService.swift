//
//  HummingbirdConnectionService.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-05-18.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Foundation

/// Talks to a Hummingbird server (cobdfamily/hummingbird) over the v1 REST surface.
///
/// Hummingbird is a generic accessible-library aggregator that exposes a uniform
/// REST API across multiple library backends via its plugin layer (NNELS, future:
/// Bookshare/RNIB/etc.). One BookPlayer integration is therefore a client of N
/// libraries simultaneously, depending on which plugin the server is running.
///
/// Auth model: HTTP Basic on every authenticated endpoint. `/login` validates
/// the credentials and the server caches the validation for ~15 min so per-
/// request plugin checks aren't repeated. We keep the password in the
/// connection data so we can attach the Basic header on every call without
/// forcing the user to sign in every cold start -- Hummingbird itself
/// doesn't issue session tokens at the REST surface (that's the KADOS
/// surface's job, which DAISY-Online clients use).
@Observable
class HummingbirdConnectionService: BPLogger {
  private static let activeConnectionIDKey = "hummingbird_active_connection_id"

  private let keychainService: KeychainServiceProtocol

  var connections: [HummingbirdConnectionData] = []
  var connection: HummingbirdConnectionData? {
    if let activeConnectionID,
       let active = connections.first(where: { $0.id == activeConnectionID }) {
      return active
    }
    return connections.first
  }
  private var urlSession: URLSession

  private(set) var activeConnectionID: String? {
    get { UserDefaults.standard.string(forKey: Self.activeConnectionIDKey) }
    set { UserDefaults.standard.set(newValue, forKey: Self.activeConnectionIDKey) }
  }

  /// Optional source-tracking store wired in by `MainCoordinator`. When present,
  /// every call to `createItemDownloadRequest` records (connection, item) so
  /// playback progress for the resulting local copy gets reported back here.
  var mediaServerSourceStore: MediaServerSourceStore?

  init(keychainService: KeychainServiceProtocol = KeychainService()) {
    self.keychainService = keychainService
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 15
    self.urlSession = URLSession(configuration: configuration)
  }

  func setup() {
    reloadConnections()
  }

  // MARK: - Server probe

  /// Hits the root `/` endpoint (liveness probe) to confirm the server exists and
  /// is a Hummingbird. Returns the server-reported service name on success.
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

    let (data, response) = try await urlSession.data(for: request)
    _ = try validateAuthenticatedResponse(response)

    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let service = json["service"] as? String, service == "hummingbird" {
      return url.host ?? "Hummingbird"
    }
    // Not a Hummingbird (or didn't recognise the response shape).
    throw IntegrationError.unexpectedResponse(code: nil)
  }

  // MARK: - Sign in

  /// Validates credentials against `/protocols/hummingbird/v1/login` and persists
  /// the connection. Hummingbird responds with `{"authenticated": true, ...}` --
  /// no token is issued; the password rides every subsequent request.
  public func signIn(
    username: String,
    password: String,
    serverUrl: String,
    serverName: String,
    customHeaders: [String: String] = [:]
  ) async throws {
    guard let url = URL(string: serverUrl) else {
      throw IntegrationError.urlMalformed(nil)
    }

    // Credentials go in the request body, NOT the URL query string.
    // hummingbird@0.3.1 dropped the ?username=&password= shape because
    // it leaked plaintext credentials to every access log along the
    // path (uvicorn, Traefik, any CDN, the device's Console.app).
    let loginURL = url.appendingPathComponent("protocols/hummingbird/v1/login")
    var request = URLRequest(url: loginURL)
    request.httpMethod = "POST"
    applyCustomHeaders(to: &request, headers: customHeaders)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body: [String: Any] = ["username": username, "password": password]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await urlSession.data(for: request)
    try Task.checkCancellation()

    guard let httpResponse = response as? HTTPURLResponse else {
      throw IntegrationError.unexpectedResponse(code: nil)
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      if httpResponse.statusCode == 401 {
        throw URLError(.userAuthenticationRequired)
      }
      throw IntegrationError.unexpectedResponse(code: httpResponse.statusCode)
    }

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          (json["authenticated"] as? Bool) == true,
          let returnedUser = json["username"] as? String,
          !returnedUser.isEmpty
    else {
      throw IntegrationError.unexpectedResponse(code: nil)
    }

    // On re-auth, preserve the existing connection's id so any previously-imported
    // items keep their progress-sync linkage intact.
    let existing = connections.first {
      $0.url.canonicalDedupKey == url.canonicalDedupKey && $0.userName == returnedUser
    }
    let connectionData = HummingbirdConnectionData(
      id: existing?.id ?? UUID().uuidString,
      url: url,
      serverName: serverName,
      userName: returnedUser,
      password: password,
      customHeaders: customHeaders
    )

    connections.removeAll {
      $0.url.canonicalDedupKey == url.canonicalDedupKey && $0.userName == returnedUser
    }
    connections.append(connectionData)
    activeConnectionID = connectionData.id
    saveConnections()
  }

  func updateCustomHeaders(_ headers: [String: String]) {
    guard let activeID = connection?.id,
          let index = connections.firstIndex(where: { $0.id == activeID }) else { return }
    connections[index].customHeaders = headers
    saveConnections()
  }

  func activateConnection(id: String) {
    activeConnectionID = id
  }

  func deleteConnection(id: String) {
    connections.removeAll { $0.id == id }
    if activeConnectionID == id {
      activeConnectionID = connections.first?.id
    }
    if connections.isEmpty {
      do {
        try keychainService.remove(.hummingbirdConnection)
      } catch {
        Self.logger.warning("failed to remove connection data from keychain: \(error)")
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

  // MARK: - Bookshelf

  public func fetchBookshelf() async throws -> [HummingbirdLibraryItem] {
    guard let connection else { throw URLError(.userAuthenticationRequired) }

    let url = connection.url
      .appendingPathComponent("protocols/hummingbird/v1/bookshelf/list")
      .appending(queryItems: [URLQueryItem(name: "username", value: connection.userName)])

    var request = URLRequest(url: url)
    applyAuthenticatedHeaders(to: &request, connection: connection)

    let (data, response) = try await urlSession.data(for: request)
    _ = try validateAuthenticatedResponse(response)

    let decoder = JSONDecoder()
    let envelope = try decoder.decode(BookshelfListResponse.self, from: data)
    return envelope.items.compactMap(makeItem(from:))
  }

  /// Returns the book to the server (server-side equivalent of removing it
  /// from the user's bookshelf). Called by the loan-expiry scanner when a
  /// borrowed item's dueDate has passed, and could also be wired to a
  /// user-initiated "return book" affordance.
  ///
  /// ``bookId`` is the Hummingbird node_id (a stringified integer in our
  /// source-info representation).
  public func returnBook(bookId: String) async throws {
    guard let connection else { throw URLError(.userAuthenticationRequired) }
    guard let id = Int(bookId) else {
      throw IntegrationError.unexpectedResponse(code: nil)
    }
    let url = connection.url
      .appendingPathComponent("protocols/hummingbird/v1/bookshelf/remove")
      .appendingPathComponent("\(id)")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    applyAuthenticatedHeaders(to: &request, connection: connection)
    let (_, response) = try await urlSession.data(for: request)
    _ = try validateAuthenticatedResponse(response)
  }

  /// GET the server-side bookmark for ``bookId`` (the Hummingbird
  /// node_id). Returns the opaque bookmark dict the storage layer
  /// round-tripped, or `nil` if no bookmark has been set yet.
  ///
  /// HummingbirdProgressReporter pushes the BookPlayer-flavored shape
  /// `{currentTime, duration, progress, isFinished}` on every tick;
  /// this is the symmetric pull so a fresh download on a second
  /// device picks up the resume position from the first.
  public func fetchBookmark(bookId: String) async throws -> [String: Any]? {
    guard let connection else { throw URLError(.userAuthenticationRequired) }
    let url = connection.url
      .appendingPathComponent("protocols/hummingbird/v1/bookshelf/bookmark")
      .appendingPathComponent(bookId)
    var request = URLRequest(url: url)
    applyAuthenticatedHeaders(to: &request, connection: connection)
    let (data, response) = try await urlSession.data(for: request)
    _ = try validateAuthenticatedResponse(response)
    guard
      let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let bookmark = envelope["bookmark"] as? [String: Any],
      !bookmark.isEmpty
    else {
      return nil
    }
    return bookmark
  }

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

    let (data, response) = try await urlSession.data(for: request)
    _ = try validateAuthenticatedResponse(response)

    let envelope = try JSONDecoder().decode(SearchResponse.self, from: data)
    return envelope.items.compactMap(makeItem(from:))
  }

  private func makeItem(from api: HummingbirdLibraryItem.APIItem) -> HummingbirdLibraryItem? {
    guard let downloadURL = URL(string: api.url) else { return nil }
    // Hummingbird's BookItem.url has the path shape /protocols/hummingbird/v1/download/{fmt}/{id}/
    // Parse the trailing components to recover bookId + format. The server is
    // already authoritative about which (book, format) this represents.
    let trimmed = api.url.split(separator: "/").reversed().compactMap { Int($0) }
    guard trimmed.count >= 2 else { return nil }
    let bookId = trimmed[0]
    let format = trimmed[1]
    return HummingbirdLibraryItem(
      bookId: bookId,
      format: format,
      title: api.title,
      downloadURL: downloadURL,
      dueDate: api.dueDate.flatMap(Self.parseISO8601),
    )
  }

  /// Permissive ISO-8601 parser. Hummingbird emits dates in
  /// "2026-06-01T00:00:00+00:00" form; tolerate fractional seconds and
  /// trailing-Z variants too so plugins that lean on the stdlib's default
  /// `datetime.isoformat()` don't trip us up.
  static func parseISO8601(_ raw: String) -> Date? {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withFraction.date(from: raw) { return d }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: raw)
  }

  // MARK: - Download

  /// DODP-shaped resource manifest for a book: list of files (with mimeType,
  /// size, and the URL to fetch each). Hits Hummingbird's REST
  /// ``/resources/{fmt}/{node_id}`` endpoint, which is the same shape the
  /// KADOS ``getContentResources`` method returns; the request envelope
  /// differs (REST vs JSON-RPC) but the parser carries over.
  public func fetchResources(_ item: HummingbirdLibraryItem) async throws -> [DODPResource] {
    guard let connection else { throw URLError(.userAuthenticationRequired) }
    let url = connection.url
      .appendingPathComponent("protocols/hummingbird/v1/resources")
      .appendingPathComponent("\(item.format)")
      .appendingPathComponent("\(item.bookId)")

    // DODP-clean async pattern (hummingbird >= 0.4.1): cold-cache
    // requests get 503 + Retry-After while the server-side prefetch
    // task warms the cache. We poll until READY (200), MISSING (404),
    // user-cancelled, or we hit the budget. Each request is short
    // (just a status check); the slow work happens server-side in a
    // background task.
    //
    // 20 minutes is the hard upper bound. NNELS multi-GB DAISY
    // archives over a slow link have been seen to take 8+ minutes
    // server-side; the previous 5-minute cap aborted mid-prepare and
    // the user got a generic error right when the file was about to
    // land. Users who want to bail before the budget can tap the
    // dismiss button on the "Preparing download..." banner --
    // HummingbirdLibraryViewModel cancels the surrounding Task, the
    // Task.checkCancellation below propagates the cancel, and this
    // function throws CancellationError.
    let pollBudget: Date = Date().addingTimeInterval(20 * 60)
    while true {
      try Task.checkCancellation()
      var request = URLRequest(url: url)
      applyAuthenticatedHeaders(to: &request, connection: connection)
      request.timeoutInterval = 30
      let (data, response) = try await urlSession.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw IntegrationError.unexpectedResponse(code: nil)
      }
      if http.statusCode == 503 {
        if Date() > pollBudget {
          throw IntegrationError.unexpectedResponse(code: 503)
        }
        let retryAfter = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "10") ?? 10
        try await Task.sleep(nanoseconds: UInt64(retryAfter) * 1_000_000_000)
        try Task.checkCancellation()
        continue
      }
      _ = try validateAuthenticatedResponse(response)
      return try JSONDecoder().decode(ResourcesResponse.self, from: data).resources
    }
  }

  /// Builds an authenticated URLRequest for a single DODP resource (one
  /// audio file inside a DAISY archive, typically). The view model uses
  /// these in bulk with ``SingleFileDownloadService.handleDownload(_:folderName:)``
  /// to land them all into one bound-book folder.
  public func createResourceDownloadRequest(
    _ resource: DODPResource,
    bookId: Int,
    folderName: String,
    dueDate: Date?
  ) throws -> URLRequest {
    guard let connection,
          let url = URL(string: resource.uri) else {
      throw URLError(.userAuthenticationRequired)
    }
    mediaServerSourceStore?.registerPendingDownload(
      url,
      info: MediaServerSourceInfo(
        kind: .hummingbird,
        connectionId: connection.id,
        itemId: "\(bookId)",
        dueDate: dueDate
      )
    )
    var request = URLRequest(url: url)
    applyAuthenticatedHeaders(to: &request, connection: connection)
    return request
  }

  /// Returns a URLRequest for downloading the bookshelf item, registering the
  /// source mapping so the progress dispatcher can route bookmarks back to this
  /// server once the file is imported. ``dueDate`` (if set on the item) is
  /// persisted so the loan-expiry scanner can later auto-return the book.
  public func createItemDownloadRequest(_ item: HummingbirdLibraryItem) throws -> URLRequest {
    guard let connection else { throw URLError(.userAuthenticationRequired) }
    mediaServerSourceStore?.registerPendingDownload(
      item.downloadURL,
      info: MediaServerSourceInfo(
        kind: .hummingbird,
        connectionId: connection.id,
        // We sync progress against the book id (which is what Hummingbird's
        // bookmark endpoint keys on); format is implicit.
        itemId: "\(item.bookId)",
        dueDate: item.dueDate
      )
    )
    // /download is auth-gated since hummingbird@21e3dd7 (user is needed
    // so the NNELS plugin can fetch under the right Playwright session).
    // Without this header iOS sees 401 + WWW-Authenticate: Basic and the
    // URLSession retries silently in the background, which the user
    // perceives as an indefinite hang.
    var request = URLRequest(url: item.downloadURL)
    applyAuthenticatedHeaders(to: &request, connection: connection)
    return request
  }

  /// Wraps any URL in a URLRequest carrying the current connection's custom headers.
  public func wrapWithCustomHeaders(_ url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    applyCustomHeaders(to: &request, headers: connection?.customHeaders ?? [:])
    return request
  }

  // MARK: - Persistence

  private func reloadConnections() {
    if let stored: [HummingbirdConnectionData] = try? keychainService.get(.hummingbirdConnection) {
      connections = stored.filter { isConnectionValid($0) }
    } else if let single: HummingbirdConnectionData = try? keychainService.get(.hummingbirdConnection),
              isConnectionValid(single) {
      connections = [single]
      saveConnections()
    } else {
      Self.logger.warning("failed to load connection data from keychain")
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
    try? keychainService.set(connections, key: .hummingbirdConnection)
  }

  private func isConnectionValid(_ data: HummingbirdConnectionData) -> Bool {
    return !data.userName.isEmpty && !data.password.isEmpty
  }

  // MARK: - Auth + validation helpers

  private func validateAuthenticatedResponse(_ response: URLResponse) throws -> HTTPURLResponse {
    guard let http = response as? HTTPURLResponse else {
      throw IntegrationError.unexpectedResponse(code: nil)
    }
    if let serverName = connection?.serverName,
       http.statusCode == 401 || http.statusCode == 403 {
      throw IntegrationError.sessionExpired(serverName: serverName)
    }
    guard (200...299).contains(http.statusCode) else {
      throw IntegrationError.unexpectedResponse(code: http.statusCode)
    }
    return http
  }

  private func applyCustomHeaders(to request: inout URLRequest, headers: [String: String]) {
    for (key, value) in headers {
      request.setValue(value, forHTTPHeaderField: key)
    }
  }

  private func applyAuthenticatedHeaders(
    to request: inout URLRequest,
    connection: HummingbirdConnectionData
  ) {
    applyCustomHeaders(to: &request, headers: connection.customHeaders)
    // Hummingbird >= 0.2.0 validates Basic credentials per-request
    // (with a 15-min TTL cache to avoid Playwright per hit on NNELS).
    // The header also covers reverse proxies in front of Hummingbird
    // (cobd's homelab uses Traefik + SSO).
    let basic = "\(connection.userName):\(connection.password)"
    if let encoded = basic.data(using: .utf8)?.base64EncodedString() {
      request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
    }
  }
}

// MARK: - Wire models (Hummingbird REST envelopes)

private struct BookshelfListResponse: Codable {
  let username: String
  let items: [HummingbirdLibraryItem.APIItem]
  let count: Int
}

private struct SearchResponse: Codable {
  let username: String
  let query: String
  let page: Int
  let items: [HummingbirdLibraryItem.APIItem]
  let count: Int
}
