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
import UIKit

/// The Hummingbird library screen (fork): the user's bookshelf, the library's search, and
/// downloads into BookPlayer. Hummingbird's REST surface is flat (no libraries, series or
/// collections), so this is much simpler than the Audiobookshelf screen.
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
  /// A download that couldn't start, shown until the user dismisses it
  @Published var downloadError: String?
  /// "Preparing download…", then "Downloading N files", in a banner on this screen. Every change is
  /// announced: the banner appears without focus moving to it, so VoiceOver wouldn't say it.
  @Published var downloadStatus: String? {
    didSet {
      guard let status = downloadStatus, status != oldValue else { return }
      UIAccessibility.post(notification: .announcement, argument: status)
    }
  }

  let connectionService: HummingbirdConnectionService
  let singleFileDownloadService: SingleFileDownloadService
  let sourceStore: MediaServerSourceStore

  /// The bookshelf as last loaded, so clearing the search needs no request
  private var bookshelfItems: [HummingbirdLibraryItem] = []
  private var inflightSearch: Task<Void, Never>?
  /// The wait for the server to prepare a book, which the banner's close button cancels
  private var inflightDownloadPrep: Task<Void, Never>?

  init(
    connectionService: HummingbirdConnectionService,
    singleFileDownloadService: SingleFileDownloadService,
    sourceStore: MediaServerSourceStore
  ) {
    self.connectionService = connectionService
    self.singleFileDownloadService = singleFileDownloadService
    self.sourceStore = sourceStore
  }

  private var trimmedQuery: String {
    searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func loadBookshelf() async {
    if trimmedQuery.isEmpty {
      loadState = .loading
    }
    do {
      let fetched = try await connectionService.fetchBookshelf()
      bookshelfItems = fetched
      // A search on screen keeps it: the bookshelf comes back when the search is cleared
      guard trimmedQuery.isEmpty else { return }
      items = fetched
      loadState = .loaded
    } catch {
      handleLoadError(error, isOnScreen: trimmedQuery.isEmpty)
    }
  }

  /// Pull to refresh: the bookshelf, or the search on screen
  func refresh() async {
    if trimmedQuery.isEmpty {
      await loadBookshelf()
    } else {
      await search(trimmedQuery)
    }
  }

  /// Searches as the user types, after a short pause. An empty query shows the bookshelf again.
  func applySearch(query: String) {
    inflightSearch?.cancel()

    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      items = bookshelfItems
      loadState = .loaded
      return
    }

    inflightSearch = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 300_000_000)
      guard !Task.isCancelled else { return }
      await self?.search(trimmed)
    }
  }

  private func search(_ query: String) async {
    loadState = .loading
    do {
      let results = try await connectionService.search(query: query)
      // A search that was replaced while it ran leaves the screen to its replacement
      guard !Task.isCancelled else { return }
      items = results
      loadState = .loaded
    } catch {
      guard !Task.isCancelled else { return }
      handleLoadError(error, isOnScreen: true)
    }
  }

  /// An expired session always asks to sign in again; other failures replace what's on screen only
  /// when the failed list is the one shown
  private func handleLoadError(_ error: Error, isOnScreen: Bool) {
    if let integrationError = error as? IntegrationError, integrationError.isSessionExpired {
      sessionExpiredError = integrationError
      if isOnScreen {
        loadState = .failed(message: integrationError.localizedDescription)
      }
    } else if isOnScreen, !Self.isCancellation(error) {
      loadState = .failed(message: error.localizedDescription)
    }
  }

  /// URLSession cancels with `URLError.cancelled`, not `CancellationError`
  private static func isCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
  }

  // MARK: - Downloads

  /// Downloads `item` into BookPlayer: one file lands at the root of Documents, several land in a
  /// folder of their own that becomes a bound book. A second tap before the first is ready replaces it.
  func downloadItem(_ item: HummingbirdLibraryItem) {
    inflightDownloadPrep?.cancel()
    inflightDownloadPrep = Task { [weak self] in
      await self?.prepareDownload(item)
    }
  }

  private func prepareDownload(_ item: HummingbirdLibraryItem) async {
    guard let connection = connectionService.connection else { return }

    // Cleared first so the same words for another book are announced again
    downloadStatus = nil
    downloadStatus = "hummingbird_preparing_download".localized
    do {
      let resources = try await connectionService.fetchResources(item, connectionId: connection.id)
      // A cancel while the server prepared the book (a long wait) mustn't still queue it
      try Task.checkCancellation()
      // BookPlayer plays the audio and doesn't navigate DAISY's text and SMIL files
      let audio = resources.filter { $0.mimeType.hasPrefix("audio/") }
      guard !audio.isEmpty else {
        downloadStatus = nil
        downloadError = "hummingbird_no_audio".localized
        return
      }

      try startDownloads(of: audio, for: item, connectionId: connection.id)
      downloadStatus = String.localizedStringWithFormat("downloading_file_title".localized, audio.count)
    } catch let error as IntegrationError where error.isSessionExpired {
      sessionExpiredError = error
      downloadStatus = nil
    } catch let error where Self.isCancellation(error) {
      // Whoever cancelled owns the banner now: closing it cleared it, and a tap on another book
      // replaced it
    } catch {
      Self.logger.warning("Hummingbird download couldn't start: \(error.localizedDescription)")
      downloadStatus = nil
      downloadError = error.localizedDescription
    }
  }

  /// Queues the downloads and records where they come from, so the books they make know their
  /// server item (loans, returns)
  func startDownloads(
    of audio: [DODPResource],
    for item: HummingbirdLibraryItem,
    connectionId: String
  ) throws {
    let source = MediaServerSourceInfo(
      kind: .hummingbird,
      connectionId: connectionId,
      itemId: "\(item.bookId)",
      dueDate: item.dueDate
    )

    if audio.count == 1 {
      // Keyed by the request URL until the file is saved, wherever it's saved
      let request = try connectionService.createResourceDownloadRequest(audio[0], connectionId: connectionId)
      if let url = request.url {
        sourceStore.registerPendingDownload(url, info: source)
      }
      singleFileDownloadService.handleDownload(request)
      return
    }

    let plan = Self.downloadPlan(for: audio)
    let requests = try plan.map {
      try connectionService.createResourceDownloadRequest($0.resource, connectionId: connectionId)
    }
    let folderName = MediaServerDownloadFolders.reserveFolder(
      named: MediaServerDownloadFolders.folderName(title: item.title, fallback: "Hummingbird \(item.bookId)"),
      info: MediaServerSourceInfo(
        kind: .hummingbird,
        connectionId: connectionId,
        itemId: "\(item.bookId)",
        dueDate: item.dueDate,
        shouldBindFolder: true
      ),
      store: sourceStore,
      folderInUse: { [singleFileDownloadService] in singleFileDownloadService.hasQueuedDownloads(inFolder: $0) }
    )
    singleFileDownloadService.handleDownload(requests, folderName: folderName, fileNames: plan.map(\.fileName))
  }

  /// A book's audio in the order it plays, each with the name it's saved under. The server lists a
  /// book's files in its zip's storage order, which DAISY doesn't make the reading order (seen:
  /// 12.mp3, 1.mp3, 2.mp3), so they're ordered by their paths in the book, numbers compared as
  /// numbers. The import orders a folder by name, and the number each name starts with keeps it in
  /// this order. Two files at the same path are one file listed twice.
  static func downloadPlan(for audio: [DODPResource]) -> [(resource: DODPResource, fileName: String)] {
    var byPath = [String: DODPResource]()
    for resource in audio where byPath[resource.localURI] == nil {
      byPath[resource.localURI] = resource
    }

    return MediaServerDownloadFolders.numberedFileNames(forPaths: Array(byPath.keys)).compactMap { entry in
      byPath[entry.path].map { (resource: $0, fileName: entry.fileName) }
    }
  }

  /// The banner's close button. While the server is still preparing the book this cancels the
  /// download; once the files are queued it only hides the banner, and they carry on.
  func dismissDownloadStatus() {
    inflightDownloadPrep?.cancel()
    inflightDownloadPrep = nil
    downloadStatus = nil
  }
}
