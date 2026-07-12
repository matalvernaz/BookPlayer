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
        await self?.patchProgress(update)
      }
    }
  }

  /// `PATCH /api/me/progress/<libraryItemId>` — the endpoint the ABS web client and official
  /// apps use for periodic + boundary progress updates. Fire-and-forget by design; on transient
  /// failure the next tick will re-send and overwrite anyway.
  ///
  /// MainActor-isolated because `connectionService.connections` and `.wrapWithCustomHeaders(_:)`
  /// are `@MainActor` post-multi-server-merge upstream rework.
  @MainActor
  private func patchProgress(_ update: MediaServerProgressUpdate) async {
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

    var request = connectionService.wrapWithCustomHeaders(url, connection: connection)
    request.httpMethod = "PATCH"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(connection.apiToken)", forHTTPHeaderField: "Authorization")
    request.httpBody = payload

    do {
      let (_, response) = try await urlSession.data(for: request)
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        Self.logger.warning("ABS progress PATCH non-2xx for \(update.info.itemId): \(http.statusCode)")
      }
    } catch {
      Self.logger.warning("ABS progress PATCH failed for \(update.info.itemId): \(error.localizedDescription)")
    }
  }
}
