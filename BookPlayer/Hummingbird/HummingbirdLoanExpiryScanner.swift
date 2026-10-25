//
//  HummingbirdLoanExpiryScanner.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-05-18.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Foundation
import UIKit

/// Takes Hummingbird books whose loan has run out out of the library (fork): returns each to the
/// connection it was downloaded from, then deletes it the way a user's delete does. Runs at launch
/// and every time the app comes to the foreground: one provenance read and a date comparison per
/// downloaded book.
///
/// Only books with a due date are touched. NNELS has no loan periods, so there it does nothing; the
/// libraries that end loans (CELA, Bookshare) are why it exists, so a returned book doesn't keep
/// playing here.
@MainActor
final class HummingbirdLoanExpiryScanner: BPLogger {
  private let connectionService: HummingbirdConnectionService
  private let sourceStore: MediaServerSourceStore
  private let libraryService: LibraryServiceProtocol
  private let playerManager: PlayerManagerProtocol
  private let syncService: SyncServiceProtocol
  /// The clock, so tests can move it
  private let now: () -> Date

  private var foregroundObserver: NSObjectProtocol?
  /// A launch scan and a foreground scan can overlap; the second waits for the next trigger
  private var isScanning = false

  init(
    connectionService: HummingbirdConnectionService,
    sourceStore: MediaServerSourceStore,
    libraryService: LibraryServiceProtocol,
    playerManager: PlayerManagerProtocol,
    syncService: SyncServiceProtocol,
    now: @escaping () -> Date = Date.init
  ) {
    self.connectionService = connectionService
    self.sourceStore = sourceStore
    self.libraryService = libraryService
    self.playerManager = playerManager
    self.syncService = syncService
    self.now = now

    // A loan can run out while the app is in the background
    foregroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        await self?.scan()
      }
    }
  }

  deinit {
    if let foregroundObserver {
      NotificationCenter.default.removeObserver(foregroundObserver)
    }
  }

  /// Returns and deletes every expired Hummingbird book. A failure is logged and its book left for
  /// the next scan.
  func scan() async {
    guard !isScanning else { return }
    isScanning = true
    defer { isScanning = false }

    let currentTime = now()
    var removedAny = false
    for entry in expiredEntries(at: currentTime) {
      if await processExpired(relativePath: entry.relativePath, info: entry.info, at: currentTime) {
        removedAny = true
      }
    }

    if removedAny {
      NotificationCenter.default.post(name: .libraryItemsRemoved, object: nil)
    }
  }

  /// The library items the next scan acts on: Hummingbird downloads whose due date has passed
  func expiredEntries(at currentTime: Date) -> [(relativePath: String, info: MediaServerSourceInfo)] {
    sourceStore.allResolved
      .filter { _, info in
        info.kind == .hummingbird && (info.dueDate.map { $0 < currentTime } ?? false)
      }
      .map { (relativePath: $0.key, info: $0.value) }
      .sorted { $0.relativePath < $1.relativePath }
  }

  /// Whether the item was deleted
  private func processExpired(
    relativePath: String,
    info: MediaServerSourceInfo,
    at currentTime: Date
  ) async -> Bool {
    // Earlier returns in this scan took time: only an entry that's still this one is acted on
    guard sourceStore.source(for: relativePath) == info else { return false }

    // The return goes first and its failure doesn't stop the delete: the server ends the loan on
    // its own schedule, while a copy left playing here after its date is the thing to avoid. Not
    // when another copy of the book is still on loan (borrowed again): a return ends the server's
    // loan of the book, that one's included
    if anotherCopyIsOnLoan(info, besides: relativePath, at: currentTime) {
      Self.logger.info("expired Hummingbird \(info.itemId) not returned: another copy is still on loan")
    } else {
      do {
        try await connectionService.returnBook(bookId: info.itemId, connectionId: info.connectionId)
      } catch {
        Self.logger.warning("Hummingbird return of expired \(info.itemId) failed: \(error.localizedDescription)")
      }
    }

    // The library may have changed while the return was out: the book moved away (its entry went
    // with it), another item took this path, or the entry was replaced. Only the same entry at the
    // same path is still this book; anything else is looked at afresh by the next scan. Nothing
    // below waits, so this holds until the delete
    guard sourceStore.source(for: relativePath) == info else { return false }

    guard let item = libraryService.getSimpleItem(with: relativePath) else {
      // Already gone from the library: only its entry was left
      sourceStore.removeSources(under: relativePath)
      return false
    }

    if playerManager.currentItem?.relativePath == item.relativePath {
      playerManager.stop()
    }

    // `.deep`: "folder only" would leave a bound book's audio in the library as loose files, the
    // opposite of a return. A failed delete keeps the item's provenance, so the next scan tries again
    do {
      try libraryService.delete([item], mode: .deep)
    } catch {
      Self.logger.warning("Loan-expiry delete of \(relativePath) failed: \(error.localizedDescription)")
      return false
    }

    if let parentFolder = item.parentFolder {
      libraryService.rebuildFolderDetails(parentFolder)
    }
    syncService.scheduleDelete([item], mode: .deep)
    return true
  }

  /// Whether another library item comes from the same server item and its loan hasn't run out
  private func anotherCopyIsOnLoan(
    _ info: MediaServerSourceInfo,
    besides relativePath: String,
    at currentTime: Date
  ) -> Bool {
    sourceStore.allResolved.contains { path, other in
      path != relativePath
        && other.kind == info.kind
        && other.connectionId == info.connectionId
        && other.itemId == info.itemId
        && (other.dueDate.map { $0 >= currentTime } ?? true)
    }
  }
}
