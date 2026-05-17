//
//  AudiobookShelfProgressReporter.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-05-17.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Foundation

/// Reports BookPlayer playback state back to an Audiobookshelf server so the same book continues
/// from the right spot in the ABS web UI, the official ABS apps, or another BookPlayer device.
///
/// Resolves the connection lazily on every report so a user editing a server URL, rotating an API
/// token, or deleting a connection while a previously-imported book is mid-playback stops the
/// reports cleanly rather than failing forever with a stale token.
final class AudiobookShelfProgressReporter: MediaServerProgressReporter, BPLogger {
  let kind: MediaServerKind = .audiobookshelf

  private let connectionService: AudiobookShelfConnectionService
  private let urlSession: URLSession

  init(
    connectionService: AudiobookShelfConnectionService,
    urlSession: URLSession = .shared
  ) {
    self.connectionService = connectionService
    self.urlSession = urlSession
  }

  func reportInProgress(_ update: MediaServerProgressUpdate) {
    patchProgress(update)
  }

  func reportFinal(_ update: MediaServerProgressUpdate) {
    patchProgress(update)
  }

  /// `PATCH /api/me/progress/<libraryItemId>` — the endpoint the ABS web client and official
  /// apps use for periodic + boundary progress updates. Fire-and-forget by design; on transient
  /// failure the next tick will re-send and overwrite anyway.
  private func patchProgress(_ update: MediaServerProgressUpdate) {
    guard let connection = connectionService.connections.first(where: { $0.id == update.info.connectionId }) else {
      // Connection was deleted since this item was imported — nothing to do.
      return
    }

    let url = connection.url
      .appendingPathComponent("api")
      .appendingPathComponent("me")
      .appendingPathComponent("progress")
      .appendingPathComponent(update.info.itemId)

    let progress: Double = update.duration > 0 ? (update.currentTime / update.duration) : 0

    let body: [String: Any] = [
      "currentTime": update.currentTime,
      "duration": update.duration,
      "progress": progress,
      "isFinished": update.isFinished
    ]

    guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return }

    var request = connectionService.wrapWithCustomHeaders(url)
    request.httpMethod = "PATCH"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(connection.apiToken)", forHTTPHeaderField: "Authorization")
    request.httpBody = payload

    urlSession.dataTask(with: request) { _, response, error in
      if let error {
        Self.logger.warning("ABS progress PATCH failed for \(update.info.itemId): \(error.localizedDescription)")
        return
      }
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        Self.logger.warning("ABS progress PATCH non-2xx for \(update.info.itemId): \(http.statusCode)")
      }
    }.resume()
  }
}
