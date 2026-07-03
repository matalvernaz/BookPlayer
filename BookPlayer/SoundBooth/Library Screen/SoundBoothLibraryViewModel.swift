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

/// A level in the owned-library hierarchy. `library-elements` carries the season (`groupId`) and
/// series (`seriesId`) links; `SoundBoothSeries` supplies series names, and the season Groups
/// supply season names.
enum SoundBoothNode: Hashable {
  case root
  case series(id: String, name: String)
  case season(id: String, name: String)

  var title: String {
    switch self {
    case .root: return "SoundBooth"
    case .series(_, let name): return name
    case .season(_, let name): return name
    }
  }
}

/// Backs the SoundBooth owned-library browser as a drill-down: Series → Season → Episode, with
/// standalone books surfaced directly. The whole owned set is fetched once (library-elements +
/// series names); each level's rows are computed from it via `rows(for:)`.
///
/// A SoundBooth title is multi-chapter, so a download fans its chapters into a bound-book folder.
/// Every chapter's CDN URL ends in the same `file.mp3`, so each download gets an explicit ordered
/// filename via `SingleFileDownloadService`'s `fileName` parameter.
@MainActor
final class SoundBoothLibraryViewModel: ObservableObject, BPLogger {
  enum LoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(message: String)
  }

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

  /// The full owned set (both season Groups and Item leaves), fetched once. `@Published` so the
  /// views recompute their level's rows when it lands.
  @Published private var elements: [SoundBoothLibraryElement] = []
  private var seriesNames: [String: String] = [:]
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
      // Series names are best-effort: if that call fails, items just fall back to loose rows
      // rather than blocking the whole library.
      let series = (try? await connectionService.fetchSeries()) ?? []
      self.seriesNames = Dictionary(series.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
      self.elements = elements
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

  // MARK: - Hierarchy

  /// Rows to show at a given level of the drill-down.
  func rows(for node: SoundBoothNode) -> [SoundBoothLibraryItem] {
    switch node {
    case .root: return rootRows()
    case .series(let id, _): return rows(inSeries: id)
    case .season(let id, _): return rows(inSeason: id)
    }
  }

  private var groups: [SoundBoothLibraryElement] { elements.filter { $0.isGroup } }
  private var items: [SoundBoothLibraryElement] { elements.filter { !$0.isGroup } }
  private var ownedGroupIds: Set<String> { Set(groups.map { $0.element.id }) }

  /// Top level: one row per owned series (that we can name), then any standalone/unnamed titles.
  private func rootRows() -> [SoundBoothLibraryItem] {
    var seriesRows: [SoundBoothLibraryItem] = []
    var seen = Set<String>()
    for item in items {
      guard let seriesId = item.element.seriesId,
        let name = seriesNames[seriesId],
        !seen.contains(seriesId)
      else { continue }
      seen.insert(seriesId)
      seriesRows.append(SoundBoothLibraryItem(id: seriesId, displayName: name, kind: .series))
    }

    // Items with no series (or a series we couldn't name) show directly at the top level.
    let looseRows = items
      .filter { item in
        guard let seriesId = item.element.seriesId else { return true }
        return seriesNames[seriesId] == nil
      }
      .map(SoundBoothLibraryItem.init(element:))

    return sortedByName(seriesRows) + sortedByName(looseRows)
  }

  /// Inside a series: its seasons, then any titles in the series not tucked under a season.
  private func rows(inSeries seriesId: String) -> [SoundBoothLibraryItem] {
    let seasonRows = groups
      .filter { $0.element.seriesId == seriesId }
      .map { SoundBoothLibraryItem(id: $0.element.id, displayName: $0.element.name, kind: .group) }

    let directRows = items
      .filter { item in
        guard item.element.seriesId == seriesId else { return false }
        // Exclude items that belong to one of this series' owned seasons — they live under it.
        if let groupId = item.element.groupId, ownedGroupIds.contains(groupId) { return false }
        return true
      }
      .map(SoundBoothLibraryItem.init(element:))

    return sortedByName(seasonRows) + sortedByName(directRows)
  }

  /// Inside a season: its episodes.
  private func rows(inSeason groupId: String) -> [SoundBoothLibraryItem] {
    sortedByName(
      items
        .filter { $0.element.groupId == groupId }
        .map(SoundBoothLibraryItem.init(element:))
    )
  }

  private func sortedByName(_ rows: [SoundBoothLibraryItem]) -> [SoundBoothLibraryItem] {
    rows.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
  }

  // MARK: - Download

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
