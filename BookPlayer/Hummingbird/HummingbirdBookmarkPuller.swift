//
//  HummingbirdBookmarkPuller.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Foundation
import UIKit

/// Brings a Hummingbird book's saved position into the library (fork): a book downloaded from
/// Hummingbird that hasn't been played here starts where its bookmark on the server says, saved by
/// another device or a DODP player. Only for a book still at the start and not finished, and not loaded
/// in the player: once there's a position on this device, it wins. Upstream decided media servers'
/// positions are never pulled; the fork's Hummingbird bookmarks always were (DAISY libraries keep them).
@MainActor
final class HummingbirdBookmarkPuller: BPLogger {
  /// How a bookmark is asked for: `HummingbirdConnectionService.fetchBookmark` in the app
  typealias Fetch = @MainActor (_ bookId: String, _ connectionId: String) async throws -> HummingbirdBookmark?
  /// Whether the book at a path is the player's current book. Its position is the player's, and the
  /// library's saved copy lags it by a couple of seconds while it plays, so it's never pulled into
  typealias IsLoaded = @MainActor (_ relativePath: String) -> Bool

  private let sourceStore: MediaServerSourceStore
  private let libraryService: LibraryServiceProtocol
  private let fetch: Fetch
  private let isLoadedInPlayer: IsLoaded
  private let notificationCenter: NotificationCenter
  private var observers = [NSObjectProtocol]()
  /// The books asked about this launch (by library uuid and server item), so a shelf of unplayed books
  /// doesn't call the library on every foreground. One whose request failed is asked again next time
  private var asked = Set<String>()

  init(
    sourceStore: MediaServerSourceStore,
    libraryService: LibraryServiceProtocol,
    notificationCenter: NotificationCenter = .default,
    isLoadedInPlayer: @escaping IsLoaded,
    fetch: @escaping Fetch
  ) {
    self.sourceStore = sourceStore
    self.libraryService = libraryService
    self.notificationCenter = notificationCenter
    self.isLoadedInPlayer = isLoadedInPlayer
    self.fetch = fetch

    for name in [UIApplication.willEnterForegroundNotification, .importItemsInserted] {
      // A book imported since (entries resolve when the import runs), or bookmarks saved elsewhere
      observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.startPull() }
      })
    }
  }

  deinit {
    for observer in observers {
      notificationCenter.removeObserver(observer)
    }
  }

  /// Pulls without waiting: at launch, on foreground, after an import
  func startPull() {
    Task { [weak self] in
      await self?.pull()
    }
  }

  /// Asks the server of each unplayed Hummingbird book for its bookmark, one at a time, and applies a
  /// position to a book that's still unplayed when the answer arrives
  func pull() async {
    for (path, info) in sourceStore.allResolved where info.kind == .hummingbird {
      guard
        let item = libraryService.getSimpleItem(with: path),
        Self.isUnplayed(item),
        !isLoadedInPlayer(path)
      else { continue }
      let key = "\(item.uuid)|\(info.connectionId)|\(info.itemId)"
      guard asked.insert(key).inserted else { continue }

      let bookmark: HummingbirdBookmark?
      do {
        bookmark = try await fetch(info.itemId, info.connectionId)
      } catch {
        asked.remove(key)
        Self.logger.warning("Hummingbird bookmark not read: \(error.localizedDescription)")
        continue
      }
      guard let bookmark, bookmark.currentTime.isFinite, bookmark.currentTime > 0 else { continue }

      // The library may have moved on while the request was out: the user started listening (the
      // player has the book; its saved position may not show it yet), or the book was deleted, or
      // replaced by another (even the same title again, with a new uuid)
      guard
        !isLoadedInPlayer(path),
        let current = libraryService.getSimpleItem(with: path),
        current.uuid == item.uuid,
        Self.isUnplayed(current),
        let entry = sourceStore.source(for: path),
        entry.kind == info.kind,
        entry.connectionId == info.connectionId,
        entry.itemId == info.itemId
      else { continue }

      let time = current.duration > 0 ? min(bookmark.currentTime, current.duration) : bookmark.currentTime
      libraryService.updatePlaybackTime(relativePath: path, time: time, date: Date(), scheduleSave: true)
    }
  }

  private static func isUnplayed(_ item: SimpleLibraryItem) -> Bool {
    item.currentTime == 0 && !item.isFinished
  }
}
