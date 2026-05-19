//
//  HummingbirdBookmarkPuller.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-05-19.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Combine
import Foundation
import UIKit

/// Pulls server-side bookmarks for freshly-imported Hummingbird books
/// and applies them to the local library, so a resume position set on
/// device A is honoured when the same book is downloaded on device B.
///
/// `HummingbirdProgressReporter` already pushes BookPlayer's playback
/// state up to the server on every tick. This is the symmetric pull:
/// without it, cross-device sync is one-directional and the user has
/// to re-find their place after every reinstall / new-device migration.
///
/// Why "freshly imported": once the user starts listening locally,
/// their position becomes authoritative — the reporter will push it
/// up on the next tick and overwrite any server value anyway. The
/// puller therefore only acts on items whose ``currentTime`` is still
/// 0, which is the post-import state before playback has touched them.
///
/// Triggers:
/// - At init: a one-shot sweep so books imported in a prior process
///   lifetime (whose mapping is still in `MediaServerSourceStore`)
///   get their bookmark pulled the first time the puller is built.
/// - On every `SingleFileDownloadService` `.finished` / `.error`
///   event: catches newly-landed books in the current session.
/// - On every `willEnterForeground`: catches the case where the
///   download finished while the app was backgrounded and the user
///   is opening BookPlayer to listen.
///
/// The sweep is idempotent and cheap (one disk read of the source
/// store + one HTTP GET per fresh-untouched Hummingbird item), so
/// running it multiple times is safe.
final class HummingbirdBookmarkPuller: BPLogger {
  private let connectionService: HummingbirdConnectionService
  private let sourceStore: MediaServerSourceStore
  private let libraryService: LibraryService

  private var subscription: AnyCancellable?
  private var foregroundObserver: NSObjectProtocol?

  init(
    connectionService: HummingbirdConnectionService,
    sourceStore: MediaServerSourceStore,
    libraryService: LibraryService,
    downloadService: SingleFileDownloadService
  ) {
    self.connectionService = connectionService
    self.sourceStore = sourceStore
    self.libraryService = libraryService

    // Initial sweep for any items imported in a prior process lifetime.
    Task { [weak self] in await self?.sweep() }

    self.subscription = downloadService.eventsPublisher.sink { [weak self] event in
      switch event {
      case .finished, .error:
        Task { [weak self] in await self?.sweep() }
      default:
        break
      }
    }

    self.foregroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      Task { [weak self] in await self?.sweep() }
    }
  }

  deinit {
    if let foregroundObserver {
      NotificationCenter.default.removeObserver(foregroundObserver)
    }
  }

  /// Visible for testing + manual triggers. Walks the source store,
  /// pulls a server bookmark for each fresh Hummingbird item, and
  /// applies it via `LibraryService.updatePlaybackTime`.
  func sweep() async {
    let candidates = sourceStore.allResolved.filter { _, info in
      info.kind == .hummingbird
    }
    guard !candidates.isEmpty else { return }

    for (relativePath, info) in candidates {
      await applyRemoteBookmarkIfFresh(relativePath: relativePath, info: info)
    }
  }

  private func applyRemoteBookmarkIfFresh(
    relativePath: String, info: MediaServerSourceInfo
  ) async {
    guard let item = libraryService.getSimpleItem(with: relativePath) else {
      // Item hasn't been imported yet (download not finalized) or was
      // deleted. Either way, nothing to apply to.
      return
    }
    // Fresh-import gate: if the user has already started listening,
    // local is authoritative and the reporter will push that up on
    // the next tick. Overwriting it here would silently rewind them.
    guard item.currentTime == 0 else { return }

    let bookmark: [String: Any]?
    do {
      bookmark = try await connectionService.fetchBookmark(bookId: info.itemId)
    } catch {
      Self.logger.warning(
        "Hummingbird bookmark pull failed for \(info.itemId): \(error.localizedDescription)"
      )
      return
    }
    guard
      let bookmark,
      let remoteTime = bookmark["currentTime"] as? Double,
      remoteTime > 0
    else {
      // No remote bookmark, or remote currentTime is 0 (server has
      // never seen the book actively played). Nothing to merge.
      return
    }

    libraryService.updatePlaybackTime(
      relativePath: relativePath,
      time: remoteTime,
      date: Date(),
      scheduleSave: true
    )
    Self.logger.info(
      "applied remote bookmark for \(info.itemId): currentTime=\(remoteTime)"
    )
  }
}
