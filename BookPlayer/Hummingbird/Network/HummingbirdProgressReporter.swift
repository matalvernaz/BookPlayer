//
//  HummingbirdProgressReporter.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-05-18.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Foundation

/// Pushes BookPlayer playback state to a Hummingbird server's bookmark endpoint so
/// the same book resumes in the right spot on another device pointed at the same
/// server.
///
/// Hummingbird treats the bookmark payload as opaque JSON -- the plugin layer or
/// the default JSON storage round-trip whatever shape we send. We send a
/// BookPlayer-flavored shape (currentTime/duration/progress/isFinished) so other
/// BookPlayer instances pick up exactly what they wrote.
final class HummingbirdProgressReporter: MediaServerProgressReporter, BPLogger {
  let kind: MediaServerKind = .hummingbird

  private let connectionService: HummingbirdConnectionService
  private let urlSession: URLSession

  init(
    connectionService: HummingbirdConnectionService,
    urlSession: URLSession = .shared
  ) {
    self.connectionService = connectionService
    self.urlSession = urlSession
  }

  /// Pending report chain. Each send awaits the previous one, so an older
  /// in-progress request can't land after — and overwrite — a newer pause or
  /// finish report on the server. Guarded by `chainLock` because the protocol
  /// entry points are nonisolated.
  private var sendChain: Task<Void, Never>?
  private let chainLock = NSLock()

  func reportInProgress(_ update: MediaServerProgressUpdate) {
    enqueue(update)
  }

  func reportFinal(_ update: MediaServerProgressUpdate) {
    enqueue(update)
  }

  private func enqueue(_ update: MediaServerProgressUpdate) {
    chainLock.withLock {
      let previous = sendChain
      sendChain = Task { @MainActor [weak self] in
        await previous?.value
        await self?.postBookmark(update)
      }
    }
  }

  /// `POST /protocols/hummingbird/v1/bookshelf/bookmark/{id}` -- the REST surface
  /// that mirrors KADOS's `setBookmarks` method but is easier to call from a
  /// native client. Failures are logged and dropped; the next tick overwrites.
  @MainActor
  private func postBookmark(_ update: MediaServerProgressUpdate) async {
    guard let connection = connectionService.connections.first(
      where: { $0.id == update.info.connectionId }
    ) else {
      // Connection was deleted since this item was imported.
      return
    }

    let url = connection.url
      .appendingPathComponent("protocols/hummingbird/v1/bookshelf/bookmark")
      .appendingPathComponent(update.info.itemId)
      .appending(queryItems: [URLQueryItem(name: "username", value: connection.userName)])

    let progress: Double = update.duration > 0 ? (update.currentTime / update.duration) : 0
    let body: [String: Any] = [
      "bookmark": [
        "currentTime": update.currentTime,
        "duration": update.duration,
        "progress": progress,
        "isFinished": update.isFinished,
      ]
    ]
    guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return }

    var request = connectionService.wrapWithCustomHeaders(url, connection: connection)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let basic = "\(connection.userName):\(connection.password)"
    if let encoded = basic.data(using: .utf8)?.base64EncodedString() {
      request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = payload

    do {
      let (_, response) = try await urlSession.data(for: request)
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        Self.logger.warning("Hummingbird bookmark POST non-2xx for \(update.info.itemId): \(http.statusCode)")
      }
    } catch {
      Self.logger.warning("Hummingbird bookmark POST failed for \(update.info.itemId): \(error.localizedDescription)")
    }
  }
}
