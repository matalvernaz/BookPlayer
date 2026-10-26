//
//  SoundBoothHTTPClient.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import Foundation

/// The HTTP transport for SoundBooth (fork): an `IntegrationHTTPClient` that keeps no cookies.
///
/// 6.0's `IntegrationURLSessionClient` keeps a cookie jar on purpose (Audiobookshelf's OIDC needs
/// it). SoundBooth's login calls fail with `[720]` when a stale `iglu.sid` cookie rides along, which
/// broke signing in again after a sign-out, so this session stores none, sends none and accepts
/// none. `SoundBoothAPIClient` reads the session cookie off the verify response and sends it by hand.
public final class SoundBoothHTTPClient: IntegrationHTTPClient {
  /// The redirects `redirectLocation` follows the `Location` of. 300 and 304 aren't a way to the
  /// audio, and 305/306 are deprecated
  static let redirectStatuses: Set<Int> = [301, 302, 303, 307, 308]

  private let session: URLSession

  /// The session's configuration, made cookie-free whatever was passed in
  var configuration: URLSessionConfiguration { session.configuration }

  /// - Parameter configuration: tests pass one carrying a stub `URLProtocol`. Copied, so the caller's
  ///   own configuration keeps its cookie settings
  public init(configuration: URLSessionConfiguration = .default, timeout: TimeInterval = 20) {
    let configuration = configuration.copy() as! URLSessionConfiguration
    configuration.timeoutIntervalForRequest = timeout
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    self.session = URLSession(configuration: configuration)
  }

  public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw SoundBoothAPIError.decoding
    }
    return (data, http)
  }

  /// `request` without following its redirect: where it redirects to. Only a redirect with a
  /// `Location` answers; anything else throws, 401 and 403 as an invalid session and other
  /// statuses as `noRedirect`, so a caller never ends up downloading an error page.
  public func redirectLocation(for request: URLRequest) async throws -> URL {
    let (_, response) = try await session.data(for: request, delegate: SoundBoothRedirectBlocker())
    guard let http = response as? HTTPURLResponse else {
      throw SoundBoothAPIError.decoding
    }

    if http.statusCode == 401 || http.statusCode == 403 {
      throw SoundBoothAPIError.sessionInvalid
    }
    guard
      Self.redirectStatuses.contains(http.statusCode),
      let location = http.value(forHTTPHeaderField: "Location"),
      let url = URL(string: location, relativeTo: request.url)?.absoluteURL
    else {
      throw SoundBoothAPIError.noRedirect(status: http.statusCode)
    }
    return url
  }
}

/// Declines every redirect, so `redirectLocation` reads the 3xx itself instead of downloading the
/// audio it points at
private final class SoundBoothRedirectBlocker: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    nil
  }
}
