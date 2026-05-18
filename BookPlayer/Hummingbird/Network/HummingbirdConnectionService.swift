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
/// Auth model: every authenticated endpoint takes `?username=` as a query param.
/// `/login` validates credentials. We keep the password in the connection data so
/// we can re-validate without forcing the user to sign in every cold start --
/// Hummingbird itself doesn't issue session tokens at the REST surface.
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

    let loginURL = url
      .appendingPathComponent("protocols/hummingbird/v1/login")
      .appending(queryItems: [
        URLQueryItem(name: "username", value: username),
        URLQueryItem(name: "password", value: password),
      ])
    var request = URLRequest(url: loginURL)
    request.httpMethod = "POST"
    applyCustomHeaders(to: &request, headers: customHeaders)

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
    return HummingbirdLibraryItem(bookId: bookId, format: format, title: api.title, downloadURL: downloadURL)
  }

  // MARK: - Download

  /// Returns a URLRequest for downloading the bookshelf item, registering the
  /// source mapping so the progress dispatcher can route bookmarks back to this
  /// server once the file is imported.
  public func createItemDownloadRequest(_ item: HummingbirdLibraryItem) throws -> URLRequest {
    guard let connection else { throw URLError(.userAuthenticationRequired) }
    mediaServerSourceStore?.registerPendingDownload(
      item.downloadURL,
      info: MediaServerSourceInfo(
        kind: .hummingbird,
        connectionId: connection.id,
        // We sync progress against the book id (which is what Hummingbird's
        // bookmark endpoint keys on); format is implicit.
        itemId: "\(item.bookId)"
      )
    )
    return wrapWithCustomHeaders(item.downloadURL)
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
    // Hummingbird's REST surface doesn't actually verify credentials per-request --
    // it gates on the username being valid. We still send Basic auth so reverse
    // proxies in front of Hummingbird (cobd's homelab uses Traefik + SSO) can
    // optionally enforce on it.
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
