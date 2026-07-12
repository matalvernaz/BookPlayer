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
import UIKit

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
  ///
  /// `didSet` mirrors every change into a VoiceOver announcement.
  /// Without it the banner appears but VO focus stays on the download
  /// button, so a blind user has no idea the tap registered. Posting
  /// an ``.announcement`` makes the screen reader speak the new status
  /// without moving focus.
  @Published var downloadStatus: String? {
    didSet {
      guard let status = downloadStatus, status != oldValue else { return }
      UIAccessibility.post(notification: .announcement, argument: status)
    }
  }

  let connectionService: HummingbirdConnectionService
  let singleFileDownloadService: SingleFileDownloadService

  /// Cached "what the bookshelf looks like with no search applied" so the
  /// search bar can be cleared without a network round-trip.
  private var bookshelfItems: [HummingbirdLibraryItem] = []
  private var inflightSearch: Task<Void, Never>?
  /// Tracks the in-flight "prepare download" task (the 503 /
  /// Retry-After polling loop). Stored so the dismiss button on the
  /// "Preparing download..." banner can cancel it -- previously the
  /// banner only hid itself while the polling kept running for up to
  /// the 5-minute budget.
  private var inflightDownloadPrep: Task<Void, Never>?

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
    } catch let error where error.isCancellation {
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
      } catch let error where error.isCancellation {
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
    // Replace any prior prep task. A second tap before the first
    // completes is treated as "cancel that one, start this one."
    inflightDownloadPrep?.cancel()
    inflightDownloadPrep = Task { [weak self] in
      await self?._downloadItem(item)
    }
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
      // A cancel during the (potentially long, 503-polling) fetch above must
      // not still queue the files.
      try Task.checkCancellation()

      if audio.count == 1 {
        // Single-file flow: drop the one file at the library root. Root-landed
        // files can use the pending-download machinery — the tracker's
        // predicted relativePath is the bare filename, exactly where this file
        // lands. Without this the book gets no provenance: progress never
        // syncs and its loan can never expire.
        let request = try connectionService.createResourceDownloadRequest(
          audio[0], bookId: item.bookId, folderName: "", dueDate: item.dueDate
        )
        if let url = request.url,
          let connection = connectionService.connection,
          let sourceStore = connectionService.mediaServerSourceStore
        {
          sourceStore.registerPendingDownload(
            url,
            info: MediaServerSourceInfo(
              kind: .hummingbird,
              connectionId: connection.id,
              itemId: "\(item.bookId)",
              dueDate: item.dueDate
            )
          )
        }
        singleFileDownloadService.handleDownload(request)
        downloadStatus = String.localizedStringWithFormat(
          "downloading_file_title".localized, 1
        )
        return
      }

      // Bound-book flow: fan out into a folder named after the book.
      // Folder name is the book title sanitised to filesystem-safe,
      // then suffixed with the book id so two books that happen to
      // share a title (or both sanitise to "Hummingbird Book"
      // because the title was entirely punctuation) don't collide
      // on the same MediaServerSourceStore key.
      let folderName = Self.sanitisedBookFolderName(item.title, bookId: item.bookId)
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
      // BookPlayer plays this bound book. The bound book is the
      // progress-tracking granularity -- per-file registrations are
      // intentionally skipped (createResourceDownloadRequest) because
      // task `suggestedFilename`s collide across DAISY archives.
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
    } catch let error where error.isCancellation {
      // User dismissed the "Preparing download..." banner mid-prep.
      // Hide the banner; no error toast -- the cancel was deliberate.
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

  /// Called when the user dismisses the download status banner.
  ///
  /// Two phases the banner straddles:
  /// 1. "Preparing download..." -- the connection service is polling
  ///    the server's 503/Retry-After loop. Cancelling the tracked
  ///    Task aborts the loop (the inner ``Task.checkCancellation``
  ///    propagates), the catch in ``_downloadItem`` handles
  ///    CancellationError, and the banner hides cleanly.
  /// 2. "Downloading N files..." -- the URLSession dataTask is in
  ///    flight via SingleFileDownloadService. Cancellation here only
  ///    hides the banner; the dataTask runs to completion in the
  ///    background and the file lands in the library as usual. (A
  ///    full cancel-during-download would need to thread through
  ///    SingleFileDownloadService, which is out of scope.)
  func dismissDownloadStatus() {
    inflightDownloadPrep?.cancel()
    inflightDownloadPrep = nil
    downloadStatus = nil
  }

  // MARK: - Bound-book helpers

  /// Strips characters that filesystems and BookPlayer's import
  /// pipeline dislike, caps the length, and suffixes the Hummingbird
  /// book id so two downloads with the same (or empty) title don't
  /// collide on the same folder name. Without the suffix, two
  /// distinct NNELS books that share a title would both register the
  /// same key in `MediaServerSourceStore`, and the second download
  /// would overwrite the first's progress-sync mapping.
  private static func sanitisedBookFolderName(_ title: String, bookId: Int) -> String {
    let stripped = title
      .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r"))
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    // Cap to leave room for the " (id)" suffix without blowing past 120 chars.
    let suffix = " (\(bookId))"
    let titleBudget = max(0, 120 - suffix.count)
    let base = stripped.isEmpty
      ? "Hummingbird Book"
      : String(stripped.prefix(titleBudget))
    return base + suffix
  }

  /// Writes a simple m3u playlist into the bound-book folder listing
  /// the audio filenames in deterministic order. Fire-and-forget:
  /// best-effort so a failure here doesn't block the downloads.
  ///
  /// Sort order is the localised case-insensitive lex of ``localURI``
  /// (the path the file would have inside the original DAISY zip).
  /// The server emits resources in zip storage order, which for most
  /// real-world DAISY archives is also lexicographic -- but the spec
  /// does NOT guarantee that, and we've seen archives where the
  /// natural order produced ``[12.mp3, 1.mp3, 2.mp3, ...]``. Sorting
  /// the playlist locks playback order to something predictable;
  /// DAISY-aware navigation through NCC is a separate concern that
  /// BookPlayer doesn't use today.
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
    let ordered = audioResources.sorted { lhs, rhs in
      lhs.localURI.localizedStandardCompare(rhs.localURI) == .orderedAscending
    }
    var lines = ["#EXTM3U", "#PLAYLIST:\(bookTitle)"]
    for res in ordered {
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
