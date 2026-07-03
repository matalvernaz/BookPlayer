//
//  SoundBoothAPIClient.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import Foundation

/// Dependency-free client for the SoundBooth ("Soundbooth Theater") private API at
/// `api.soundbooththeater.com`. Encodes the reverse-engineered contract:
///
/// - Every request carries a static client key: `x-iglu-api-key: Bearer <clientKey>` plus
///   `Accept: application/vnd.iglu.v2`. Without the key the API returns error `[724]`.
/// - User-scoped calls additionally send `Authorization: Token <jwt>` (and the `iglu.sid`
///   cookie) from a `SoundBoothSession`. Without a session they return error `[722]`.
/// - Auth is passwordless: request an email code, then verify it for a 30-day JWT. (Firebase
///   email/password and anonymous auth are both disabled server-side.)
/// - Audio is plain MP3 on a public CacheFly CDN; `resources/play` 302-redirects to it. No DRM.
///
/// This type intentionally imports nothing beyond Foundation so it can be lifted into a
/// standalone SoundBooth app unchanged.
public struct SoundBoothAPIClient {
  public struct Configuration: Sendable {
    public var baseURL: URL
    /// Static app key extracted from the web player (`x-iglu-api-key` value, sans "Bearer ").
    public var clientKey: String

    public init(baseURL: URL, clientKey: String) {
      self.baseURL = baseURL
      self.clientKey = clientKey
    }

    public static let production = Configuration(
      baseURL: URL(string: "https://api.soundbooththeater.com")!,
      clientKey: "UyvN1lWaohkcO0wtmLfHkQZmGZSBAC3I"
    )
  }

  /// Public MP3 CDN that `resources/play` redirects to. Path is deterministic:
  /// `/soundbooth/resources/<resourceId>/<quality>/file.mp3`.
  static let cdnBaseURL = URL(string: "https://soundbooth.cachefly.net")!

  private let config: Configuration
  private let session: URLSession
  private let noRedirectSession: URLSession
  private let redirectBlocker: RedirectBlocker

  public init(configuration: Configuration = .production) {
    self.config = configuration
    let sessionConfig = URLSessionConfiguration.default
    sessionConfig.timeoutIntervalForRequest = 20
    self.session = URLSession(configuration: sessionConfig)
    let blocker = RedirectBlocker()
    self.redirectBlocker = blocker
    self.noRedirectSession = URLSession(configuration: sessionConfig, delegate: blocker, delegateQueue: nil)
  }

  // MARK: - Auth

  /// Requests a one-time login code be emailed to `email`. No session required (client key only).
  public func requestLoginCode(email: String) async throws {
    let request = try makeRequest(
      path: "/base/auth/login/code/link",
      method: "POST",
      jsonBody: ["email": email]
    )
    let (data, response) = try await session.data(for: request)
    try validate(response)
    let envelope = try decode(SoundBoothStatusEnvelope.self, from: data)
    guard envelope.success else {
      throw SoundBoothAPIError.api(message: envelope.message, code: envelope.code)
    }
  }

  /// Verifies the emailed `code` and returns an authenticated session. The 30-day JWT is the
  /// primary credential; the `iglu.sid` cookie (if present) is captured as a fallback.
  public func verifyLoginCode(email: String, code: String) async throws -> SoundBoothSession {
    let request = try makeRequest(
      path: "/base/auth/login/code/verify",
      method: "POST",
      jsonBody: ["email": email, "code": code]
    )
    let (data, response) = try await session.data(for: request)
    try validate(response)
    let envelope = try decode(SoundBoothEnvelope<SoundBoothVerifyResponse>.self, from: data)
    guard envelope.success, let verified = envelope.data else {
      throw SoundBoothAPIError.api(message: envelope.message, code: envelope.code)
    }
    let cookie = Self.sessionCookie(from: response, baseURL: config.baseURL)
    return SoundBoothSession(
      jwt: verified.jwt,
      userId: verified.id,
      email: verified.email,
      sessionCookie: cookie
    )
  }

  // MARK: - Library

  /// The user's owned library (books, episodes, and season groups they've purchased).
  public func libraryElements(session sbSession: SoundBoothSession) async throws -> [SoundBoothLibraryElement] {
    let request = try makeRequest(
      path: "/functions/u/library-elements/list",
      method: "POST",
      jsonBody: [:],
      session: sbSession
    )
    let (data, response) = try await session.data(for: request)
    try validate(response)
    let envelope = try decode(SoundBoothEnvelope<SoundBoothPage<SoundBoothLibraryElement>>.self, from: data)
    guard envelope.success, let page = envelope.data else {
      throw Self.apiError(envelope.message, envelope.code)
    }
    return page.docs
  }

  /// All saved playback positions, keyed by `(item, resource)`.
  public func progresses(session sbSession: SoundBoothSession) async throws -> [SoundBoothProgress] {
    let request = try makeRequest(
      path: "/functions/user/progresses",
      method: "POST",
      jsonBody: [:],
      session: sbSession
    )
    let (data, response) = try await session.data(for: request)
    try validate(response)
    // `progresses` returns a bare array in `data`, not a paginated page.
    let envelope = try decode(SoundBoothEnvelope<[SoundBoothProgress]>.self, from: data)
    guard envelope.success, let list = envelope.data else {
      throw Self.apiError(envelope.message, envelope.code)
    }
    return list
  }

  /// The chapter list (resources) for one or more items.
  public func itemResources(
    session sbSession: SoundBoothSession,
    itemIds: [String]
  ) async throws -> [SoundBoothItemResource] {
    let request = try makeRequest(
      path: "/functions/playlist/item-resources",
      method: "POST",
      jsonBody: ["itemIds": itemIds],
      session: sbSession
    )
    let (data, response) = try await session.data(for: request)
    try validate(response)
    let envelope = try decode(SoundBoothEnvelope<SoundBoothItemResourcesResponse>.self, from: data)
    guard envelope.success, let payload = envelope.data else {
      throw Self.apiError(envelope.message, envelope.code)
    }
    return payload.itemResources
  }

  // MARK: - Streaming

  /// The authenticated endpoint that 302-redirects to the CDN audio. Passed to
  /// `resolvePlaybackURL`, or downloaded directly with `authorizedRequest(for:session:)`
  /// (URLSession follows the redirect; the CDN needs no auth).
  public func playbackEndpointURL(resourceId: String, quality: SoundBoothQuality) throws -> URL {
    guard
      var components = URLComponents(
        url: config.baseURL.appendingPathComponent("functions/resources/play"),
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

  /// Deterministic public CDN URL for a resource. Used as a fallback if `resolvePlaybackURL`
  /// can't reach the API; the CDN itself is unauthenticated.
  public func cacheFlyURL(resourceId: String, quality: SoundBoothQuality) -> URL {
    Self.cdnBaseURL
      .appendingPathComponent("soundbooth")
      .appendingPathComponent("resources")
      .appendingPathComponent(resourceId)
      .appendingPathComponent(quality.rawValue)
      .appendingPathComponent("file.mp3")
  }

  /// Resolves the final playable CDN URL by asking `resources/play` and reading its redirect
  /// `Location`, which respects SoundBooth's entitlement check. Falls back to the deterministic
  /// CDN URL if the response is a direct 200 rather than a redirect.
  public func resolvePlaybackURL(
    resourceId: String,
    quality: SoundBoothQuality,
    session sbSession: SoundBoothSession
  ) async throws -> URL {
    var request = URLRequest(url: try playbackEndpointURL(resourceId: resourceId, quality: quality))
    request.httpMethod = "GET"
    applyStandardHeaders(to: &request, session: sbSession)

    let (_, response) = try await noRedirectSession.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw SoundBoothAPIError.decoding
    }
    if (300...399).contains(http.statusCode),
      let location = http.value(forHTTPHeaderField: "Location"),
      let url = URL(string: location) {
      return url
    }
    if http.statusCode == 401 || http.statusCode == 403 {
      throw SoundBoothAPIError.sessionInvalid
    }
    // No redirect (or the server started streaming directly) — use the deterministic CDN URL.
    return cacheFlyURL(resourceId: resourceId, quality: quality)
  }

  /// Wraps a URL in a request carrying the client key + session auth, so BookPlayer's download
  /// service can fetch `playbackEndpointURL` directly (URLSession follows the 302 to the CDN).
  public func authorizedRequest(for url: URL, session sbSession: SoundBoothSession) -> URLRequest {
    var request = URLRequest(url: url)
    applyStandardHeaders(to: &request, session: sbSession)
    return request
  }

  // MARK: - Request building

  private func makeRequest(
    path: String,
    method: String,
    jsonBody: [String: Any],
    session sbSession: SoundBoothSession? = nil
  ) throws -> URLRequest {
    guard let url = URL(string: path, relativeTo: config.baseURL) else {
      throw SoundBoothAPIError.malformedURL
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    applyStandardHeaders(to: &request, session: sbSession)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
    return request
  }

  /// Origin the API gates on. Requests without it are rejected with `session is invalid [726]`
  /// regardless of the client key — the backend only trusts calls that look like they came from
  /// the web player, so this native client presents the same origin.
  private static let webOrigin = "https://player.soundbooth.app"

  /// Applies the always-required client-key headers, plus session auth when present.
  private func applyStandardHeaders(to request: inout URLRequest, session sbSession: SoundBoothSession?) {
    request.setValue("application/vnd.iglu.v2", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(config.clientKey)", forHTTPHeaderField: "x-iglu-api-key")
    request.setValue("\(TimeZone.current.secondsFromGMT() / 3600)", forHTTPHeaderField: "x-iglu-time-zone-offset")
    request.setValue(Self.webOrigin, forHTTPHeaderField: "Origin")
    request.setValue(Self.webOrigin + "/", forHTTPHeaderField: "Referer")
    if let sbSession {
      request.setValue("Token \(sbSession.jwt)", forHTTPHeaderField: "Authorization")
      if let cookie = sbSession.sessionCookie {
        request.setValue("iglu.sid=\(cookie)", forHTTPHeaderField: "Cookie")
      }
    }
  }

  // MARK: - Helpers

  private func validate(_ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse else {
      throw SoundBoothAPIError.decoding
    }
    if http.statusCode == 401 || http.statusCode == 403 {
      throw SoundBoothAPIError.sessionInvalid
    }
    guard (200...299).contains(http.statusCode) else {
      throw SoundBoothAPIError.http(status: http.statusCode)
    }
  }

  private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw SoundBoothAPIError.decoding
    }
  }

  /// Maps an API-level failure, promoting the invalid-session code (`50230`) so callers can
  /// trigger a re-login instead of showing a generic error.
  private static func apiError(_ message: String?, _ code: String?) -> SoundBoothAPIError {
    if code == "50230" {
      return .sessionInvalid
    }
    return .api(message: message, code: code)
  }

  /// Extracts the `iglu.sid` cookie value from a response's `Set-Cookie` header(s).
  private static func sessionCookie(from response: URLResponse, baseURL: URL) -> String? {
    guard
      let http = response as? HTTPURLResponse,
      let fields = http.allHeaderFields as? [String: String]
    else {
      return nil
    }
    let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: baseURL)
    return cookies.first(where: { $0.name == "iglu.sid" })?.value
  }
}

/// Blocks HTTP redirects so `resolvePlaybackURL` can read the 302 `Location` (the CDN URL)
/// without downloading the audio body that following the redirect would fetch.
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
