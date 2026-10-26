//
//  SoundBoothAPIClient.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import Foundation

/// Client for the SoundBooth ("Soundbooth Theater") private API at `api.soundbooththeater.com`
/// (fork), the reverse-engineered contract its web player speaks:
///
/// - Every request carries the player's client key (`x-iglu-api-key`) and
///   `Accept: application/vnd.iglu.v2`; without the key the API answers `[724]`. It also wants the web
///   player's Origin and Referer, or it answers `[726]`.
/// - User calls add `Authorization: Token <jwt>` and the `iglu.sid` session cookie.
/// - Sign-in is passwordless: an emailed code is verified for a 30-day session.
/// - Audio is MP3 on CacheFly. `resources/play` redirects to it, and that redirect is the only working
///   URL: the path isn't guessable and carries CacheFly's token.
///
/// Every request goes through the injected `IntegrationHTTPClient`; the app's is the cookie-free
/// `SoundBoothHTTPClient`.
public struct SoundBoothAPIClient: Sendable {
  public struct Configuration: Sendable {
    public var baseURL: URL
    /// The `x-iglu-api-key` value, without its "Bearer " prefix
    public var clientKey: String

    public init(baseURL: URL, clientKey: String) {
      self.baseURL = baseURL
      self.clientKey = clientKey
    }

    /// The client key is SoundBooth's own public key, embedded in its web player and sent by every
    /// visitor's browser. It identifies the client, not an account, and grants nothing on its own (user
    /// calls also need the account's session), so it isn't a secret of ours: moving it to an xcconfig
    /// would protect nothing
    public static let production = Configuration(
      baseURL: URL(string: "https://api.soundbooththeater.com")!,
      clientKey: "UyvN1lWaohkcO0wtmLfHkQZmGZSBAC3I"
    )
  }

  /// List calls follow `hasNextPage` this far at most (SoundBooth answers everything in one page today)
  static let maxPages = 50

  /// The API checks requests come from its web player, so this client presents the same origin
  static let webOrigin = "https://player.soundbooth.app"

  /// The API's code for an invalid session, which it can send with a 200
  static let sessionInvalidCode = "50230"

  public let configuration: Configuration
  private let httpClient: IntegrationHTTPClient

  public init(configuration: Configuration = .production, httpClient: IntegrationHTTPClient = SoundBoothHTTPClient()) {
    self.configuration = configuration
    self.httpClient = httpClient
  }

  // MARK: - Sign in

  /// Asks SoundBooth to email a one-time code to `email`. No session needed.
  public func requestLoginCode(email: String) async throws {
    let request = try makeRequest(path: "/base/auth/login/code/link", jsonBody: ["email": email])
    let (data, response) = try await httpClient.data(for: request)
    try Self.validate(response, signedIn: false)
    let envelope = try Self.decode(SoundBoothStatusEnvelope.self, from: data)
    guard envelope.success else {
      throw Self.apiError(envelope.message, envelope.code, signedIn: false)
    }
  }

  /// Verifies the emailed `code` and returns the session: the 30-day JWT, and the `iglu.sid` cookie the
  /// same response sets. An answer without an account id or a JWT is refused, since nothing could be
  /// signed in with it and an empty id would let two accounts collapse into one saved connection.
  public func verifyLoginCode(email: String, code: String) async throws -> SoundBoothSession {
    let request = try makeRequest(path: "/base/auth/login/code/verify", jsonBody: ["email": email, "code": code])
    let (data, response) = try await httpClient.data(for: request)
    try Self.validate(response, signedIn: false)
    let envelope = try Self.decode(SoundBoothEnvelope<SoundBoothVerifyResponse>.self, from: data)
    guard envelope.success, let verified = envelope.data else {
      throw Self.apiError(envelope.message, envelope.code, signedIn: false)
    }
    guard !verified.id.isEmpty, !verified.jwt.isEmpty else {
      throw SoundBoothAPIError.decoding
    }

    return SoundBoothSession(
      jwt: verified.jwt,
      userId: verified.id,
      email: verified.email.isEmpty ? email : verified.email,
      sessionCookie: Self.sessionCookie(from: response, baseURL: configuration.baseURL)
    )
  }

  // MARK: - Library

  /// The account's owned library: books, episodes and season bundles it bought
  public func libraryElements(session: SoundBoothSession) async throws -> [SoundBoothLibraryElement] {
    try await list("/functions/u/library-elements/list", body: [:], session: session)
  }

  /// Series records, which name the series the owned items point at
  public func series(session: SoundBoothSession) async throws -> [SoundBoothSeries] {
    try await list("/functions/u/series/list", body: [:], session: session)
  }

  /// Season (`Group`) records, which name and order seasons, including ones owned episode by episode
  public func groups(session: SoundBoothSession) async throws -> [SoundBoothGroup] {
    try await list("/functions/u/groups/list", body: [:], session: session)
  }

  /// The whole item catalog. Its items carry their series and season as full objects, names included,
  /// so it names the series `series/list` leaves out (free previews and the like)
  public func items(session: SoundBoothSession) async throws -> [SoundBoothElement] {
    try await list("/functions/u/items/list", body: [:], session: session)
  }

  /// The episodes of one season. How a season bought as a bundle lists them: a bundle has no episode
  /// entries of its own in the library, and the account is entitled to each through it
  public func items(inGroup groupId: String, session: SoundBoothSession) async throws -> [SoundBoothElement] {
    try await list("/functions/u/items/list", body: ["groupId": groupId], session: session)
  }

  /// Every saved playback position, one per (item, chapter). Entries that don't decode are skipped.
  public func progresses(session: SoundBoothSession) async throws -> [SoundBoothProgress] {
    let request = try makeRequest(path: "/functions/user/progresses", jsonBody: [:], session: session)
    let (data, response) = try await httpClient.data(for: request)
    try Self.validate(response)
    // A plain array in `data`, not a page
    let envelope = try Self.decode(SoundBoothEnvelope<[SoundBoothFailable<SoundBoothProgress>]>.self, from: data)
    guard envelope.success, let list = envelope.data else {
      throw Self.apiError(envelope.message, envelope.code)
    }
    return list.compactMap(\.value)
  }

  /// The chapters (resources) of one or more items
  public func itemResources(itemIds: [String], session: SoundBoothSession) async throws -> [SoundBoothItemResource] {
    let request = try makeRequest(path: "/functions/playlist/item-resources", jsonBody: ["itemIds": itemIds], session: session)
    let (data, response) = try await httpClient.data(for: request)
    try Self.validate(response)
    let envelope = try Self.decode(SoundBoothEnvelope<SoundBoothItemResourcesResponse>.self, from: data)
    guard envelope.success, let payload = envelope.data else {
      throw Self.apiError(envelope.message, envelope.code)
    }
    return payload.itemResources
  }

  // MARK: - Audio

  /// `resources/play` for one chapter, which checks the account owns it and redirects to the audio
  public func playbackEndpointURL(resourceId: String, quality: SoundBoothQuality) throws -> URL {
    guard
      var components = URLComponents(
        url: configuration.baseURL.appendingPathComponent("functions/resources/play"),
        resolvingAgainstBaseURL: false
      )
    else {
      throw SoundBoothAPIError.malformedURL
    }
    components.queryItems = [
      URLQueryItem(name: "id", value: resourceId),
      URLQueryItem(name: "quality", value: quality.rawValue),
    ]
    guard let url = components.url else { throw SoundBoothAPIError.malformedURL }
    return url
  }

  /// The chapter's audio URL: where `resources/play` redirects. Any other answer throws. Never a URL
  /// built here: CacheFly serves the guessable form for some chapters and an HTML 404 for others, which
  /// used to be saved as the chapter's MP3.
  public func resolvePlaybackURL(
    resourceId: String,
    quality: SoundBoothQuality,
    session: SoundBoothSession
  ) async throws -> URL {
    var request = URLRequest(url: try playbackEndpointURL(resourceId: resourceId, quality: quality))
    request.httpMethod = "GET"
    applyStandardHeaders(to: &request, session: session)
    return try await httpClient.redirectLocation(for: request)
  }

  // MARK: - Requests

  /// A list call's docs across its pages: the first request as the web player sends it, then
  /// `"page": n` while the answer says there's more, `maxPages` at most
  private func list<Doc: Decodable>(
    _ path: String,
    body: [String: String],
    session: SoundBoothSession
  ) async throws -> [Doc] {
    var docs = [Doc]()
    var page = 1
    while page <= Self.maxPages {
      var requestBody: [String: Any] = body
      if page > 1 {
        requestBody["page"] = page
      }
      let request = try makeRequest(path: path, jsonBody: requestBody, session: session)
      let (data, response) = try await httpClient.data(for: request)
      try Self.validate(response)
      let envelope = try Self.decode(SoundBoothEnvelope<SoundBoothPage<Doc>>.self, from: data)
      guard envelope.success, let pageData = envelope.data else {
        throw Self.apiError(envelope.message, envelope.code)
      }
      docs += pageData.docs
      guard pageData.hasNextPage == true else { break }
      page += 1
    }
    return docs
  }

  private func makeRequest(path: String, jsonBody: [String: Any], session: SoundBoothSession? = nil) throws -> URLRequest {
    guard let url = URL(string: path, relativeTo: configuration.baseURL)?.absoluteURL else {
      throw SoundBoothAPIError.malformedURL
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    applyStandardHeaders(to: &request, session: session)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
    return request
  }

  /// The headers every call needs, and the session's when there is one
  private func applyStandardHeaders(to request: inout URLRequest, session: SoundBoothSession?) {
    request.setValue("application/vnd.iglu.v2", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(configuration.clientKey)", forHTTPHeaderField: "x-iglu-api-key")
    request.setValue("\(TimeZone.current.secondsFromGMT() / 3600)", forHTTPHeaderField: "x-iglu-time-zone-offset")
    request.setValue(Self.webOrigin, forHTTPHeaderField: "Origin")
    request.setValue(Self.webOrigin + "/", forHTTPHeaderField: "Referer")
    guard let session else { return }

    request.setValue("Token \(session.jwt)", forHTTPHeaderField: "Authorization")
    if let cookie = session.sessionCookie {
      request.setValue("iglu.sid=\(cookie)", forHTTPHeaderField: "Cookie")
    }
  }

  // MARK: - Answers

  /// A non-2xx answer as an error. Only a call made with a session can find it rejected: before signing
  /// in, a 401 or 403 is a refusal like any other, never "your session expired"
  static func validate(_ response: HTTPURLResponse, signedIn: Bool = true) throws {
    if signedIn, response.statusCode == 401 || response.statusCode == 403 {
      throw SoundBoothAPIError.sessionInvalid
    }
    guard (200...299).contains(response.statusCode) else {
      throw SoundBoothAPIError.http(status: response.statusCode)
    }
  }

  static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw SoundBoothAPIError.decoding
    }
  }

  /// An API-level failure, with the invalid-session code made `sessionInvalid` so callers can offer to
  /// sign in again (only once signed in, as for `validate`)
  static func apiError(_ message: String?, _ code: String?, signedIn: Bool = true) -> SoundBoothAPIError {
    if signedIn, code == sessionInvalidCode {
      return .sessionInvalid
    }
    return .api(message: message, code: code)
  }

  /// The `iglu.sid` cookie from the response's `Set-Cookie`, the credential the data calls check (a JWT
  /// alone is refused with `[706]`). Only from this response: the transport keeps no cookies, so any
  /// `iglu.sid` found elsewhere would be stale or someone else's.
  static func sessionCookie(from response: HTTPURLResponse, baseURL: URL) -> String? {
    var fields = [String: String]()
    for (key, value) in response.allHeaderFields {
      if let key = key as? String, let value = value as? String {
        fields[key] = value
      }
    }
    return HTTPCookie.cookies(withResponseHeaderFields: fields, for: baseURL)
      .first(where: { $0.name == "iglu.sid" })?.value
  }
}
