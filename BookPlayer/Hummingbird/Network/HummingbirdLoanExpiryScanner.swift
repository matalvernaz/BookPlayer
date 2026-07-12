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

/// Sweeps locally-imported Hummingbird books for expired loans and
/// auto-returns them: deletes the local file, removes the library entry,
/// drops the source-store mapping, and POSTs `/bookshelf/remove/{id}` to
/// the originating server.
///
/// NNELS has no loan period so its books always have ``dueDate == nil``
/// and this scanner is a no-op for them. The CELA / Bookshare / OverDrive
/// case is the motivation -- those libraries enforce loan periods and we
/// want the local copy to disappear cleanly when the loan runs out
/// instead of the user playing a book that's already "returned"
/// upstream.
///
/// Scan is cheap (one UserDefaults read + a date comparison per imported
/// item) so it runs on every launch and every scenePhase = .active
/// transition, plus a manual entry point for tests.
final class HummingbirdLoanExpiryScanner: BPLogger {
  private let connectionService: HummingbirdConnectionService
  private let sourceStore: MediaServerSourceStore
  private let libraryService: LibraryService
  /// Injectable clock so tests can fast-forward. Production always uses
  /// `Date()`.
  private let now: () -> Date

  private var foregroundObserver: NSObjectProtocol?

  init(
    connectionService: HummingbirdConnectionService,
    sourceStore: MediaServerSourceStore,
    libraryService: LibraryService,
    now: @escaping () -> Date = Date.init
  ) {
    self.connectionService = connectionService
    self.sourceStore = sourceStore
    self.libraryService = libraryService
    self.now = now
    // Re-sweep on every foreground transition. A user can borrow a book on
    // another device, listen on this one until the loan expires, and we
    // want it gone the next time they open the app. The launch-time
    // sweep is triggered from MainCoordinator after this init returns
    // (see MainCoordinator's super.init follow-up Task).
    self.foregroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      Task { [weak self] in await self?.scan() }
    }
  }

  deinit {
    if let foregroundObserver {
      NotificationCenter.default.removeObserver(foregroundObserver)
    }
  }

  /// Iterates the source-store's resolved entries, finds expired
  /// Hummingbird loans, and returns + deletes each one. Failures are
  /// logged and skipped; the scanner re-runs on the next trigger.
  func scan() async {
    let currentTime = now()
    for (relativePath, info) in expiredHummingbirdEntries(at: currentTime) {
      await processExpired(relativePath: relativePath, info: info)
    }
  }

  /// Visible for testing: which entries the next scan would act on.
  func expiredHummingbirdEntries(at currentTime: Date) -> [(String, MediaServerSourceInfo)] {
    sourceStore.allResolved
      .filter { _, info in
        info.kind == .hummingbird
          && (info.dueDate.map { $0 < currentTime } ?? false)
      }
  }

  private func processExpired(relativePath: String, info: MediaServerSourceInfo) async {
    // 1. Tell the server we're done with the book. If the network fails
    // we still proceed with the local cleanup -- the server will notice
    // the loan expired on its own timetable, and leaving stale local
    // copies after the date passed is worse than a missing remove call.
    do {
      try await connectionService.returnBook(
        bookId: info.itemId,
        connectionId: info.connectionId
      )
    } catch {
      Self.logger.warning(
        "Hummingbird auto-return of \(info.itemId) failed: \(error.localizedDescription)"
      )
    }

    // 2. Delete the local library item (and its files). `.deep` matters for
    // bound books: `.shallow` would promote every chapter file to a loose
    // library item instead of removing the expired audio — the opposite of a
    // loan return. If the delete fails, keep the source mapping so the next
    // scan retries the cleanup; dropping it would strand the expired copy on
    // disk forever with no further attempts.
    if let item = libraryService.getSimpleItem(with: relativePath) {
      do {
        try libraryService.delete([item], mode: .deep)
      } catch {
        Self.logger.warning(
          "Loan-expiry delete of \(relativePath) failed: \(error.localizedDescription)"
        )
        return
      }
    }

    // 3. Drop the source mapping so completed cleanups aren't re-scanned.
    sourceStore.removeSource(for: relativePath)
  }
}
