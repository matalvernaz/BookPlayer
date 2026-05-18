//
//  HummingbirdLibraryViewModel.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-05-18.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Combine
import Foundation
import SwiftUI

/// Backs the Hummingbird library view. Owns the bookshelf list, the active search
/// query, and the download dispatch into BookPlayer's `SingleFileDownloadService`.
///
/// Hummingbird's REST surface is flat (no library hierarchy / no series / no
/// collections), so this model is intentionally much simpler than the ABS one.
@MainActor
final class HummingbirdLibraryViewModel: ObservableObject, BPLogger {
  enum LoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(message: String)
  }

  @Published var items: [HummingbirdLibraryItem] = []
  @Published var searchQuery: String = ""
  @Published var loadState: LoadState = .idle
  @Published var sessionExpiredError: IntegrationError?

  let connectionService: HummingbirdConnectionService
  let singleFileDownloadService: SingleFileDownloadService

  /// Cached "what the bookshelf looks like with no search applied" so the
  /// search bar can be cleared without a network round-trip.
  private var bookshelfItems: [HummingbirdLibraryItem] = []
  private var inflightSearch: Task<Void, Never>?

  init(
    connectionService: HummingbirdConnectionService,
    singleFileDownloadService: SingleFileDownloadService
  ) {
    self.connectionService = connectionService
    self.singleFileDownloadService = singleFileDownloadService
  }

  func loadBookshelf() async {
    loadState = .loading
    do {
      let fetched = try await connectionService.fetchBookshelf()
      bookshelfItems = fetched
      items = fetched
      loadState = .loaded
    } catch let error as IntegrationError where error.isSessionExpired {
      sessionExpiredError = error
      loadState = .failed(message: error.localizedDescription)
    } catch is CancellationError {
      loadState = .idle
    } catch {
      loadState = .failed(message: error.localizedDescription)
    }
  }

  /// Debounced search dispatch. Empty query restores the cached bookshelf list.
  func applySearch(query: String) {
    inflightSearch?.cancel()

    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      items = bookshelfItems
      loadState = .loaded
      return
    }

    inflightSearch = Task { [weak self] in
      guard let self else { return }
      // Quick debounce so a fast typist doesn't generate one request per
      // character. 300ms is the common "search-as-you-type" budget.
      try? await Task.sleep(nanoseconds: 300_000_000)
      if Task.isCancelled { return }

      loadState = .loading
      do {
        let results = try await self.connectionService.search(query: trimmed)
        if Task.isCancelled { return }
        items = results
        loadState = .loaded
      } catch let error as IntegrationError where error.isSessionExpired {
        sessionExpiredError = error
        loadState = .failed(message: error.localizedDescription)
      } catch is CancellationError {
        // user typed another character; the new task handles it
      } catch {
        loadState = .failed(message: error.localizedDescription)
      }
    }
  }

  /// One-tap download into BookPlayer's library. Source-tracking is registered
  /// inside `createItemDownloadRequest` so the eventual progress reports route
  /// back to this server.
  func downloadItem(_ item: HummingbirdLibraryItem) {
    do {
      let request = try connectionService.createItemDownloadRequest(item)
      singleFileDownloadService.handleDownload(request)
    } catch {
      Self.logger.warning("Hummingbird download dispatch failed: \(error.localizedDescription)")
    }
  }
}
