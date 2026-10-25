//
//  HummingbirdLoanReturns.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Foundation

/// Returns a Hummingbird book to its library when the user deletes the last copy of it here (fork),
/// so the loan doesn't sit on their bookshelf until it runs out. Told by `.mediaServerItemsDeleted`,
/// which only user deletes post. Fire and forget: the book is gone either way, and a return that
/// fails (offline, signed out) is logged and the loan runs out on the server's clock.
final class HummingbirdLoanReturns: BPLogger {
  private let connectionService: HummingbirdConnectionService
  private var observer: NSObjectProtocol?

  init(connectionService: HummingbirdConnectionService) {
    self.connectionService = connectionService

    observer = NotificationCenter.default.addObserver(
      forName: .mediaServerItemsDeleted,
      object: nil,
      queue: nil
    ) { [weak self] notification in
      let entries = notification.userInfo?[MediaServerDeletion.entriesKey] as? [MediaServerSourceInfo] ?? []
      Task { @MainActor [weak self] in
        await self?.returnLoans(for: entries)
      }
    }
  }

  deinit {
    if let observer {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  /// Returns the Hummingbird books among `entries`, each to the connection it was downloaded from
  @MainActor
  func returnLoans(for entries: [MediaServerSourceInfo]) async {
    for entry in entries where entry.kind == .hummingbird {
      do {
        try await connectionService.returnBook(bookId: entry.itemId, connectionId: entry.connectionId)
        Self.logger.info("returned Hummingbird book \(entry.itemId) after its delete")
      } catch {
        Self.logger.warning("couldn't return Hummingbird book \(entry.itemId): \(error.localizedDescription)")
      }
    }
  }
}
