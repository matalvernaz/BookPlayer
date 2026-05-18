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
  /// Surface to the user when a tap-to-download fails for any reason
  /// (network, malformed manifest, plugin error, etc). Cleared when
  /// the user dismisses the alert. Replaces a silent
  /// ``Self.logger.warning`` that the user could never see.
  @Published var downloadError: String?
  /// "Preparing download…" -> "Downloading N files…" so the user gets
  /// SOMETHING visible after a tap, instead of the previous behavior
  /// where the tap returned no UI feedback at all.
  @Published var downloadStatus: String?

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

  /// One-tap download into BookPlayer's library. Fetches the DODP-shaped
  /// resource manifest first, then either does a single-file download (for
  /// libraries that ship single MP3s) or fans out into a multi-file
  /// download landing into a bound-book folder (for DAISY 2.02 archives).
  ///
  /// The two paths converge: bound-book folder with audio + .m3u, or single
  /// audio file at library root. BookPlayer's existing library import picks
  /// up either shape.
  func downloadItem(_ item: HummingbirdLibraryItem) {
    Task { [weak self] in await self?._downloadItem(item) }
  }

  private func _downloadItem(_ item: HummingbirdLibraryItem) async {
    downloadStatus = "preparing_download_status".localized
    do {
      let resources = try await connectionService.fetchResources(item)
      // Audio-only filter -- BookPlayer doesn't navigate SMIL or NCC, and
      // dragging those files into the library just clutters it. The
      // server emits the full list so DAISY-aware clients (eg. a future
      // BookPlayer-with-SMIL or Dolphin EasyReader hitting our KADOS
      // surface) can still build full navigation; we just don't use it.
      let audio = resources.filter { $0.mimeType.hasPrefix("audio/") }

      if audio.count == 1 {
        // Single-file flow: drop the one file at the library root.
        let request = try connectionService.createResourceDownloadRequest(
          audio[0], bookId: item.bookId, folderName: "", dueDate: item.dueDate
        )
        singleFileDownloadService.handleDownload(request)
        downloadStatus = String.localizedStringWithFormat(
          "downloading_file_title".localized, 1
        )
        return
      }

      // Bound-book flow: fan out into a folder named after the book.
      // Folder name is the book title sanitised to filesystem-safe.
      let folderName = Self.sanitisedBookFolderName(item.title)
      let requests = try audio.map { res in
        try connectionService.createResourceDownloadRequest(
          res, bookId: item.bookId, folderName: folderName, dueDate: item.dueDate
        )
      }
      singleFileDownloadService.handleDownload(requests, folderName: folderName)
      downloadStatus = String.localizedStringWithFormat(
        "downloading_file_title".localized, audio.count
      )

      // Write a .m3u playlist into the folder so BookPlayer (or anything
      // else inspecting the folder) has an explicit playback order.
      // Audio resources arrive over time; the playlist references them
      // by the local filenames that SingleFileDownloadService will use
      // when each task completes (lastPathComponent of the URL).
      Self.writePlaylist(
        folderName: folderName,
        bookTitle: item.title,
        audioResources: audio
      )

      // Register the bound folder as a media-server source so the
      // progress dispatcher can route bookmarks back to the server when
      // BookPlayer plays this bound book. The per-file source mappings
      // registered inside createResourceDownloadRequest cover progress
      // on individual chapters; this one covers the bound book itself.
      guard let connection = connectionService.connection,
            let sourceStore = connectionService.mediaServerSourceStore else { return }
      sourceStore.setSource(
        MediaServerSourceInfo(
          kind: .hummingbird,
          connectionId: connection.id,
          itemId: "\(item.bookId)",
          dueDate: item.dueDate,
          // Explicit intent: this folder represents a DAISY archive
          // that should become a bound book once all chapters land.
          // The bound-book completer's sweep keys off this flag --
          // future code paths can register Hummingbird-sourced folders
          // *without* setting this and they'll stay as folders.
          shouldBindFolder: true
        ),
        for: folderName
      )
    } catch let error as IntegrationError where error.isSessionExpired {
      sessionExpiredError = error
      downloadStatus = nil
    } catch {
      // Surface the real failure to the user instead of dropping it
      // into oslog where they'd never see it. Previous behavior: a
      // silent ``Self.logger.warning`` with no visible feedback.
      Self.logger.warning("Hummingbird download dispatch failed: \(error.localizedDescription)")
      downloadError = error.localizedDescription
      downloadStatus = nil
    }
  }

  /// Called when the user dismisses an in-progress download status (the
  /// "Downloading N files" banner). Doesn't actually cancel the
  /// downloads -- they keep running via the background URLSession --
  /// just hides the banner.
  func dismissDownloadStatus() {
    downloadStatus = nil
  }

  // MARK: - Bound-book helpers

  /// Strips characters that filesystems and BookPlayer's import pipeline
  /// dislike, caps the length, and falls back to a stable default if the
  /// title sanitises to empty. Doesn't try to deduplicate across existing
  /// folders -- BookPlayer's library importer handles renaming on collision.
  private static func sanitisedBookFolderName(_ title: String) -> String {
    let stripped = title
      .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r"))
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let capped = String(stripped.prefix(120))
    return capped.isEmpty ? "Hummingbird Book" : capped
  }

  /// Writes a simple m3u playlist into the bound-book folder listing the
  /// expected audio filenames in their server-provided order. Fire-and-
  /// forget: best-effort so a failure here doesn't block the downloads.
  private static func writePlaylist(
    folderName: String,
    bookTitle: String,
    audioResources: [DODPResource]
  ) {
    let folderURL = DataManager.getDocumentsFolderURL().appendingPathComponent(folderName)
    do {
      try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    } catch {
      return
    }
    var lines = ["#EXTM3U", "#PLAYLIST:\(bookTitle)"]
    for res in audioResources {
      // SingleFileDownloadService strips paths and keeps only
      // lastPathComponent when saving (eg. "audio/01.mp3" -> "01.mp3").
      let filename = (res.localURI as NSString).lastPathComponent
      lines.append(filename)
    }
    let content = lines.joined(separator: "\n") + "\n"
    let playlistURL = folderURL.appendingPathComponent("playlist.m3u")
    try? content.write(to: playlistURL, atomically: true, encoding: .utf8)
  }
}
