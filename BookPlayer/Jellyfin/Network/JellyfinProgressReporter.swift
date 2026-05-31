//
//  JellyfinProgressReporter.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-05-17.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Foundation
import UIKit

/// Reports BookPlayer playback state back to a Jellyfin server so the same audiobook continues
/// from the right spot in the Jellyfin web UI, Finamp, or another BookPlayer device.
///
/// Resolves the connection lazily so a user editing a server URL or rotating an access token
/// while a previously-imported book is mid-playback stops the reports cleanly rather than failing
/// forever against a stale token.
final class JellyfinProgressReporter: MediaServerProgressReporter, BPLogger {
  let kind: MediaServerKind = .jellyfin

  /// Jellyfin's `PositionTicks` field is 100-nanosecond units (10M per second).
  private static let ticksPerSecond: Double = 10_000_000

  /// Reused for a given playback session so the server can recognize successive updates as the
  /// same session rather than starting + stopping repeatedly. Keyed by `relativePath` so
  /// switching books generates a fresh session id.
  private var playSessionIds: [String: String] = [:]
  private let playSessionLock = NSLock()

  private let connectionService: JellyfinConnectionService
  private let urlSession: URLSession

  init(
    connectionService: JellyfinConnectionService,
    urlSession: URLSession = .shared
  ) {
    self.connectionService = connectionService
    self.urlSession = urlSession
  }

  func reportInProgress(_ update: MediaServerProgressUpdate) {
    Task { @MainActor [weak self] in
      self?.post(update, endpoint: "Sessions/Playing/Progress", eventName: "timeupdate", isFinal: false)
    }
  }

  func reportFinal(_ update: MediaServerProgressUpdate) {
    let endpoint = update.isFinished ? "Sessions/Playing/Stopped" : "Sessions/Playing/Progress"
    let eventName = update.isFinished ? "stopped" : "pause"
    Task { @MainActor [weak self] in
      self?.post(update, endpoint: endpoint, eventName: eventName, isFinal: true)
    }
    if update.isFinished {
      // Clear the session id so the next playback of this item is a fresh session on the server.
      playSessionLock.withLock { _ = playSessionIds.removeValue(forKey: relativePathKey(for: update)) }
    }
  }

  // MARK: - HTTP

  /// MainActor-isolated because `connectionService.connections` is `@MainActor`
  /// (post-multi-server-merge upstream rework). Callers hop via `Task @MainActor`.
  @MainActor
  private func post(
    _ update: MediaServerProgressUpdate,
    endpoint: String,
    eventName: String,
    isFinal: Bool
  ) {
    guard let connection = connectionService.connections.first(where: { $0.id == update.info.connectionId }) else {
      return
    }

    let url = connection.url.appendingPathComponent(endpoint)
    let ticks = Int64(update.currentTime * Self.ticksPerSecond)
    let sessionId = playSessionId(for: update)

    let body: [String: Any] = [
      "ItemId": update.info.itemId,
      "PositionTicks": ticks,
      "IsPaused": isFinal && !update.isFinished,
      "PlaySessionId": sessionId,
      "EventName": eventName
    ]

    guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return }

    var request = wrapWithCustomHeaders(url, customHeaders: connection.customHeaders)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(Self.authorizationHeader(token: connection.accessToken), forHTTPHeaderField: "Authorization")
    request.httpBody = payload

    urlSession.dataTask(with: request) { _, response, error in
      if let error {
        Self.logger.warning("Jellyfin progress POST failed for \(update.info.itemId): \(error.localizedDescription)")
        return
      }
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        Self.logger.warning("Jellyfin progress POST non-2xx for \(update.info.itemId): \(http.statusCode)")
      }
    }.resume()
  }

  /// Jellyfin auth header for arbitrary `POST` calls. Mirrors the format the Jellyfin SDK uses
  /// internally for `/Sessions/Playing*` so the server attributes the activity to BookPlayer.
  private static func authorizationHeader(token: String) -> String {
    let device = UIDevice.current.name.replacingOccurrences(of: "\"", with: "")
    let deviceID = (UIDevice.current.identifierForVendor?.uuidString ?? "BookPlayer")
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    return
      "MediaBrowser Token=\"\(token)\", Client=\"BookPlayer\", Device=\"\(device)\", DeviceId=\"\(deviceID)\", Version=\"\(version)\""
  }

  /// Apply per-connection custom headers, skipping `Authorization` so our token isn't overwritten.
  private func wrapWithCustomHeaders(_ url: URL, customHeaders: [String: String]) -> URLRequest {
    var request = URLRequest(url: url)
    for (key, value) in customHeaders
    where key.caseInsensitiveCompare("Authorization") != .orderedSame {
      request.setValue(value, forHTTPHeaderField: key)
    }
    return request
  }

  // MARK: - Play session id management

  private func relativePathKey(for update: MediaServerProgressUpdate) -> String {
    // Items are scoped by (connectionId, itemId) — combine so two different connections playing
    // the same library don't collide on session ids.
    "\(update.info.connectionId)/\(update.info.itemId)"
  }

  private func playSessionId(for update: MediaServerProgressUpdate) -> String {
    let key = relativePathKey(for: update)
    return playSessionLock.withLock {
      if let existing = playSessionIds[key] { return existing }
      let new = UUID().uuidString
      playSessionIds[key] = new
      return new
    }
  }
}
