//
//  SoundBoothLibraryViewModel.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Combine
import Foundation
import SwiftUI
import UIKit

/// Backs the SoundBooth owned-library browser. Mirrors the Hummingbird model (flat list, local
/// search, tap-to-download into `SingleFileDownloadService`) rather than the paginated ABS one,
/// because the SoundBooth library-elements endpoint returns the whole owned set at once.
///
/// A SoundBooth title is multi-chapter, so a download always fans its chapters into a bound-book
/// folder. Every chapter's CDN URL ends in the same `file.mp3`, so each download is given an
/// explicit ordered filename via `SingleFileDownloadService`'s `fileName` parameter.
@MainActor
final class SoundBoothLibraryViewModel: ObservableObject, BPLogger {
  enum LoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(message: String)
  }

  @Published var items: [SoundBoothLibraryItem] = []
  @Published var searchQuery: String = ""
  @Published var loadState: LoadState = .idle
  @Published var sessionExpiredError: IntegrationError?
  @Published var downloadError: String?
  /// Mirrors each change into a VoiceOver announcement so a blind user hears that a tap
  /// registered without focus moving off the download control (same pattern as Hummingbird).
  @Published var downloadStatus: String? {
    didSet {
      guard let status = downloadStatus, status != oldValue else { return }
      UIAccessibility.post(notification: .announcement, argument: status)
    }
  }

  let connectionService: SoundBoothConnectionService
  let singleFileDownloadService: SingleFileDownloadService

  private var allItems: [SoundBoothLibraryItem] = []
  private var inflightSearch: Task<Void, Never>?
  private var inflightDownloadPrep: Task<Void, Never>?

  init(
    connectionService: SoundBoothConnectionService,
    singleFileDownloadService: SingleFileDownloadService
  ) {
    self.connectionService = connectionService
    self.singleFileDownloadService = singleFileDownloadService
  }

  func loadLibrary() async {
    loadState = .loading
    do {
      let elements = try await connectionService.fetchLibraryElements()
      // Show the individually-owned books and episodes as downloadable rows. Groups (seasons)
      // are containers whose episodes already appear as their own Items, so they're omitted
      // from the flat v1 list rather than shown as dead-ends.
      let mapped = elements
        .filter { !$0.isGroup }
        .map(SoundBoothLibraryItem.init(element:))
      allItems = mapped
      applySearch(query: searchQuery)
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

  /// Local title filter over the already-fetched owned library. No network round-trip.
  func applySearch(query: String) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      items = allItems
    } else {
      items = allItems.filter { $0.displayName.localizedCaseInsensitiveContains(trimmed) }
    }
  }

  func downloadItem(_ item: SoundBoothLibraryItem) {
    guard item.isDownloadable else { return }
    inflightDownloadPrep?.cancel()
    inflightDownloadPrep = Task { [weak self] in
      await self?._downloadItem(item)
    }
  }

  private func _downloadItem(_ item: SoundBoothLibraryItem) async {
    downloadStatus = "preparing_download_status".localized
    do {
      let resources = try await connectionService.fetchItemResources(itemIds: [item.id])
      let ordered = resources.sorted { $0.number < $1.number }
      guard !ordered.isEmpty else {
        downloadStatus = nil
        return
      }

      // Resolve each chapter to its CDN URL and pair it with a distinct, order-preserving
      // filename (the CDN path is `.../<resourceId>/<quality>/file.mp3` for every chapter).
      var requests = [URLRequest]()
      var fileNames = [String]()
      for resource in ordered {
        let url = try await connectionService.resolvePlaybackURL(resourceId: resource.id)
        try Task.checkCancellation()
        requests.append(URLRequest(url: url))
        fileNames.append(Self.chapterFileName(number: resource.number, name: resource.name))
      }

      // Always a bound book: fan the chapters into a folder named after the title, then flag it
      // for auto-binding so BookPlayer promotes the folder to a single book once files land.
      let folderName = Self.folderName(for: item.displayName, id: item.id)
      singleFileDownloadService.handleDownload(requests, folderName: folderName, fileNames: fileNames)
      downloadStatus = String.localizedStringWithFormat(
        "downloading_file_title".localized, requests.count
      )

      if let connection = connectionService.connection,
        let sourceStore = connectionService.mediaServerSourceStore {
        sourceStore.setSource(
          MediaServerSourceInfo(
            kind: .soundbooth,
            connectionId: connection.id,
            itemId: item.id,
            shouldBindFolder: true
          ),
          for: folderName
        )
      }
    } catch let error as IntegrationError where error.isSessionExpired {
      sessionExpiredError = error
      downloadStatus = nil
    } catch is CancellationError {
      downloadStatus = nil
    } catch {
      Self.logger.warning("SoundBooth download dispatch failed: \(error.localizedDescription)")
      downloadError = error.localizedDescription
      downloadStatus = nil
    }
  }

  func dismissDownloadStatus() {
    inflightDownloadPrep?.cancel()
    inflightDownloadPrep = nil
    downloadStatus = nil
  }

  // MARK: - Naming helpers

  /// Distinct, order-preserving chapter filename, e.g. `000 - Opening Credits.mp3`. The numeric
  /// prefix keeps the bound book in chapter order (BookPlayer orders bound files by name).
  private static func chapterFileName(number: Int, name: String?) -> String {
    let title = (name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
      ?? "Chapter \(number)"
    let safeTitle = title
      .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r"))
      .joined(separator: " ")
    return String(format: "%03d - %@.mp3", number, safeTitle)
  }

  /// Filesystem-safe folder name for a title, suffixed with the item id so two titles that
  /// sanitise to the same string don't collide on one `MediaServerSourceStore` key.
  private static func folderName(for title: String, id: String) -> String {
    let stripped = title
      .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r"))
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let suffix = " (\(id))"
    let titleBudget = max(0, 120 - suffix.count)
    let base = stripped.isEmpty ? "SoundBooth Title" : String(stripped.prefix(titleBudget))
    return base + suffix
  }
}
