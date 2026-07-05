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

/// One list section at a level of the drill-down. `title` is a visible header ("Cinematic Audio")
/// when the level mixes production formats, nil for untitled groupings (series/season rows).
struct SoundBoothLibrarySection: Identifiable {
  let id: String
  let title: String?
  let rows: [SoundBoothLibraryItem]
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
  /// Season (`Group`) records keyed by id, from `groups/list` — supplies season names + order even
  /// for seasons the user owns only as individual episodes (not as the season bundle object).
  private var groupInfo: [String: SoundBoothGroup] = [:]
  /// Season name + index recovered from the full item catalog for orphan seasons `groups/list`
  /// omits (their `groupId` comes back populated in `u/items/list`). Consulted by `seasonInfo`
  /// after `groupInfo`.
  private var orphanSeasonInfo: [String: (name: String, index: Int)] = [:]
  /// Episode lists fetched per owned season bundle (their episodes aren't in `library-elements`),
  /// keyed by groupId. Cleared on library reload.
  @Published private var seasonItems: [String: [SoundBoothElement]] = [:]
  @Published private var seasonFetchesInFlight = Set<String>()
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
      let groupList = (try? await connectionService.fetchGroups()) ?? []
      var names = Dictionary(series.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
      let groupDict = Dictionary(groupList.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

      // Some owned items reference a series `series/list` omits (free-preview/orphan series), which
      // would strand them nameless at the top level. The full item catalog carries those items with
      // populated series/season names, so when any owned series is still unresolved, fetch it once
      // and backfill. Best-effort — a failure just leaves those items in the "Other Titles" fallback.
      var orphanSeasons: [String: (name: String, index: Int)] = [:]
      let hasUnresolvedSeries = elements.contains { element in
        guard !element.isGroup, let seriesId = element.element.seriesId else { return false }
        return names[seriesId] == nil
      }
      if hasUnresolvedSeries, let catalog = try? await connectionService.fetchCatalog() {
        for item in catalog {
          if let seriesId = item.seriesId, let name = item.seriesName, names[seriesId] == nil {
            names[seriesId] = name
          }
          if let groupId = item.groupId, let name = item.groupName, orphanSeasons[groupId] == nil {
            orphanSeasons[groupId] = (name: name, index: item.groupIndex ?? Int.max)
          }
        }
      }

      self.seriesNames = names
      self.groupInfo = groupDict
      self.orphanSeasonInfo = orphanSeasons
      self.elements = elements
      self.seasonItems = [:]
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

  /// Sections to show at a given level of the drill-down. Leaves are grouped into titled sections
  /// by production format when a level mixes formats (cinematic vs audiobook vs immersion).
  func sections(for node: SoundBoothNode) -> [SoundBoothLibrarySection] {
    switch node {
    case .root: return rootSections()
    case .series(let id, _): return sections(inSeries: id)
    case .season(let id, _): return sections(inSeason: id)
    }
  }

  private var groups: [SoundBoothLibraryElement] { elements.filter { $0.isGroup } }
  private var items: [SoundBoothLibraryElement] { elements.filter { !$0.isGroup } }

  /// Top level: one row per owned series — via owned items *or* an owned season bundle — then any
  /// standalone/unnamed titles.
  private func rootSections() -> [SoundBoothLibrarySection] {
    var seriesRows: [SoundBoothLibraryItem] = []
    var seen = Set<String>()
    for element in elements {
      guard let seriesId = element.element.seriesId,
        let name = seriesNames[seriesId],
        !seen.contains(seriesId)
      else { continue }
      seen.insert(seriesId)
      seriesRows.append(SoundBoothLibraryItem(id: seriesId, displayName: name, kind: .series))
    }

    // Owned season bundles whose series we can't name still need a row — navigate straight in.
    let looseSeasons = groups
      .filter { $0.element.seriesId.flatMap { seriesNames[$0] } == nil }
      .map { SoundBoothLibraryItem(id: $0.element.id, displayName: $0.element.name, kind: .group) }

    // Items whose series isn't in SoundBooth's series catalog (an orphan/unlisted seriesId that
    // `u/series/list` never returns) can't nest under a series row.
    let looseItems = items.filter { $0.element.seriesId.flatMap { seriesNames[$0] } == nil }

    let containers = sortedByName(seriesRows) + sortedByName(looseSeasons)
    var sections = [SoundBoothLibrarySection]()
    if !containers.isEmpty {
      sections.append(SoundBoothLibrarySection(id: "top", title: nil, rows: containers))
    }

    // Sitting bare among the named series above, an orphan title reads as broken — a tap-to-download
    // title masquerading as a drill-in series row. Gather them under an explicit header to set them
    // apart, but only when there are named series to set them apart *from*; an all-orphan library
    // just shows them as its plain contents.
    let looseRows = sortedByRelease(looseItems.map(\.element)).map {
      SoundBoothLibraryItem(raw: $0, seriesName: nil)
    }
    if !looseRows.isEmpty {
      let title = containers.isEmpty ? nil : "soundbooth_other_titles_title".localized
      sections.append(SoundBoothLibrarySection(id: "loose", title: title, rows: looseRows))
    }
    return sections
  }

  /// Inside a series: its seasons (owned bundles and seasons inferred from owned episodes, ordered
  /// by season index), then standalone titles that don't belong to a nameable season.
  private func sections(inSeries seriesId: String) -> [SoundBoothLibrarySection] {
    let seriesItems = items.filter { $0.element.seriesId == seriesId }

    var seasons: [(id: String, name: String, index: Int)] = []
    var seenSeasons = Set<String>()
    // Season bundles the user owns outright.
    for group in groups where group.element.seriesId == seriesId {
      seenSeasons.insert(group.element.id)
      let index = seasonInfo(forGroupId: group.element.id)?.index ?? Int.max
      seasons.append((group.element.id, group.element.name, index))
    }
    // Seasons inferred from owned episodes' groupIds (named via groups/list) — covers seasons
    // owned episode-by-episode with no bundle object.
    for item in seriesItems {
      guard let groupId = item.element.groupId, !seenSeasons.contains(groupId),
        let info = seasonInfo(forGroupId: groupId)
      else { continue }
      seenSeasons.insert(groupId)
      seasons.append((groupId, info.name, info.index))
    }
    let seasonRows = seasons
      .sorted { ($0.index, $0.name.localizedLowercase) < ($1.index, $1.name.localizedLowercase) }
      .map { SoundBoothLibraryItem(id: $0.id, displayName: $0.name, kind: .group) }

    // Standalone titles: no season, or a season we couldn't name.
    let directItems = seriesItems.filter { item in
      guard let groupId = item.element.groupId else { return true }
      return seasonInfo(forGroupId: groupId) == nil
    }

    var sections = [SoundBoothLibrarySection]()
    if !seasonRows.isEmpty {
      sections.append(SoundBoothLibrarySection(id: "seasons", title: nil, rows: seasonRows))
    }
    sections += leafSections(directItems.map(\.element), seriesName: seriesNames[seriesId])
    return sections
  }

  /// A season's display name + sort index for a `groupId`, from `groups/list` first, then an owned
  /// Group element. Nil when we can't name it (so its episodes surface as standalone titles).
  private func seasonInfo(forGroupId groupId: String) -> (name: String, index: Int)? {
    if let group = groupInfo[groupId] {
      return (group.name, group.index ?? Int.max)
    }
    if let owned = groups.first(where: { $0.element.id == groupId }) {
      return (owned.element.name, owned.element.displayOptions?.index ?? Int.max)
    }
    if let orphan = orphanSeasonInfo[groupId] {
      return orphan
    }
    return nil
  }

  /// Whether the user owns this season as a whole bundle (a `Group` doc in `library-elements`), as
  /// opposed to owning only individual episodes of it à-la-carte.
  private func ownsBundle(_ groupId: String) -> Bool {
    groups.contains { $0.element.id == groupId }
  }

  /// The episodes to show for a season. When the user owns the bundle, that's the full fetched
  /// episode list (`u/items/list {groupId}`) — any individually-owned episode docs are a redundant
  /// subset since entitlement flows through the bundle, so showing only them would mask the rest of
  /// the season. When the user owns no bundle, it's exactly the episodes they bought à-la-carte.
  private func episodes(inSeason groupId: String) -> [SoundBoothElement] {
    if ownsBundle(groupId) { return seasonItems[groupId] ?? [] }
    return items.filter { $0.element.groupId == groupId }.map(\.element)
  }

  /// Inside a season: its episodes — the owned bundle's full list, or the à-la-carte episodes owned.
  private func sections(inSeason groupId: String) -> [SoundBoothLibrarySection] {
    let seasonEpisodes = episodes(inSeason: groupId)
    let seriesName = seasonEpisodes.first?.seriesId.flatMap { seriesNames[$0] }
    return leafSections(seasonEpisodes, seriesName: seriesName)
  }

  /// Owned-bundle seasons list their episodes via `u/items/list {groupId}`, not `library-elements`;
  /// fetch that list on first visit. No-op unless the user owns the bundle (à-la-carte seasons read
  /// their episodes straight from the library), or when a fetch is cached or already in flight.
  func loadSeasonIfNeeded(_ node: SoundBoothNode) async {
    guard case .season(let groupId, _) = node,
      ownsBundle(groupId),
      seasonItems[groupId] == nil,
      !seasonFetchesInFlight.contains(groupId)
    else { return }
    seasonFetchesInFlight.insert(groupId)
    defer { seasonFetchesInFlight.remove(groupId) }
    do {
      seasonItems[groupId] = try await connectionService.fetchSeasonItems(groupId: groupId)
    } catch let error as IntegrationError where error.isSessionExpired {
      sessionExpiredError = error
    } catch is CancellationError {
      // Leave the cache empty; the next visit retries.
    } catch {
      Self.logger.warning("SoundBooth season fetch failed: \(error.localizedDescription)")
      downloadError = error.localizedDescription
    }
  }

  func isFetchingSeason(_ node: SoundBoothNode) -> Bool {
    guard case .season(let groupId, _) = node else { return false }
    return seasonFetchesInFlight.contains(groupId)
  }

  /// Pull-to-refresh: the root refetches the whole library; a season refetches its episode list.
  func refresh(_ node: SoundBoothNode) async {
    if case .season(let groupId, _) = node, ownsBundle(groupId) {
      seasonItems[groupId] = nil
      await loadSeasonIfNeeded(node)
    } else {
      await loadLibrary()
    }
  }

  /// Preferred order of format sections when a level mixes formats.
  private static let formatSectionOrder = ["Audiobook", "Cinematic Audio", "Immersion", "Bonus"]

  /// Leaf rows in release order — split into titled per-format sections when formats mix, so
  /// cinematic and regular editions of a story don't interleave indistinguishably.
  private func leafSections(
    _ elements: [SoundBoothElement],
    seriesName: String?
  ) -> [SoundBoothLibrarySection] {
    let rows = sortedByRelease(elements).map { element in
      SoundBoothLibraryItem(
        raw: element,
        seriesName: seriesName ?? element.seriesId.flatMap { seriesNames[$0] }
      )
    }
    guard !rows.isEmpty else { return [] }

    let formats = Set(rows.compactMap(\.formatLabel))
    guard formats.count > 1 else {
      return [SoundBoothLibrarySection(id: "leaves", title: nil, rows: rows)]
    }
    var buckets = [String: [SoundBoothLibraryItem]]()
    for row in rows {
      buckets[row.formatLabel ?? "Other", default: []].append(row)
    }
    let order = Self.formatSectionOrder
    return buckets.keys
      .sorted { lhs, rhs in
        let li = order.firstIndex(of: lhs) ?? order.count
        let ri = order.firstIndex(of: rhs) ?? order.count
        return li == ri ? lhs < rhs : li < ri
      }
      .map { SoundBoothLibrarySection(id: "format-\($0)", title: $0, rows: buckets[$0]!) }
  }

  private func sortedByName(_ rows: [SoundBoothLibraryItem]) -> [SoundBoothLibraryItem] {
    rows.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
  }

  /// Order elements chronologically by release date, falling back to name when dates match or are
  /// absent. Used for episodes within a season and standalone titles within a series.
  private func sortedByRelease(_ elements: [SoundBoothElement]) -> [SoundBoothElement] {
    elements.sorted {
      if $0.releaseSortKey != $1.releaseSortKey { return $0.releaseSortKey < $1.releaseSortKey }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
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
      let ordered = resources.sorted { ($0.number, $0.id) < ($1.number, $1.id) }
      guard !ordered.isEmpty else {
        downloadStatus = nil
        return
      }

      let fileNames = ordered.map { Self.chapterFileName(number: $0.number, name: $0.name) }
      let folderName = Self.folderName(title: item.displayName, seriesName: item.seriesName)
      let seedTime = try await resumeSeed(itemIds: [item.id], fullOrdered: ordered, kept: ordered)
      try await dispatchDownload(
        resources: ordered,
        fileNames: fileNames,
        folderName: folderName,
        sourceItemId: item.id,
        seedTime: seedTime
      )
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

  // MARK: - Season download

  /// Released episodes of a season, in play order. Empty for non-season nodes.
  private func releasedEpisodes(inSeason node: SoundBoothNode) -> [SoundBoothElement] {
    guard case .season(let groupId, _) = node else { return [] }
    return sortedByRelease(episodes(inSeason: groupId)).filter(\.isReleased)
  }

  func canDownloadSeason(_ node: SoundBoothNode) -> Bool {
    !releasedEpisodes(inSeason: node).isEmpty
  }

  func releasedEpisodeCount(_ node: SoundBoothNode) -> Int {
    releasedEpisodes(inSeason: node).count
  }

  func downloadSeason(_ node: SoundBoothNode, trimCredits: Bool) {
    inflightDownloadPrep?.cancel()
    inflightDownloadPrep = Task { [weak self] in
      await self?._downloadSeason(node, trimCredits: trimCredits)
    }
  }

  /// Download a whole season as one bound book. Every episode's chapters concatenate in release
  /// order. When `trimCredits` is on, repeated credits chapters are dropped so only the season's
  /// first opening credits and final ending credits remain and the story plays straight through
  /// episode boundaries; when off, every chapter is kept verbatim.
  private func _downloadSeason(_ node: SoundBoothNode, trimCredits: Bool) async {
    guard case .season(let groupId, let seasonName) = node else { return }
    let episodes = releasedEpisodes(inSeason: node)
    guard !episodes.isEmpty else { return }
    downloadStatus = "preparing_download_status".localized
    do {
      let allResources = try await connectionService.fetchItemResources(itemIds: episodes.map(\.id))
      try Task.checkCancellation()
      let byEpisode = Dictionary(grouping: allResources, by: \.itemId)
      // Episodes that actually returned chapters, in play order. Filtering here keeps the credits
      // selection and episode numbering from being thrown off by an episode that returned nothing.
      let playable = episodes.filter { !(byEpisode[$0.id] ?? []).isEmpty }

      // Flatten to (episode, chapter) in play order. Credits chapters are named inconsistently
      // ("Credits" serves as both opening and closing), so classify by position within the
      // episode: a credits chapter in the first half is opening-side, the second half closing-side.
      typealias Flat = (resource: SoundBoothItemResource, episodeNumber: Int, isCredits: Bool, isOpeningSide: Bool)
      var flat = [Flat]()
      for (episodeIndex, episode) in playable.enumerated() {
        let chapters = (byEpisode[episode.id] ?? [])
          .sorted { ($0.number, $0.id) < ($1.number, $1.id) }
        for (chapterIndex, resource) in chapters.enumerated() {
          flat.append((
            resource: resource,
            episodeNumber: episodeIndex + 1,
            // With trimming off nothing is flagged credits, so the keep/drop pass below is a no-op
            // and every chapter downloads.
            isCredits: trimCredits && Self.isCreditsChapter(resource.name) && chapters.count > 1,
            isOpeningSide: chapterIndex < chapters.count / 2
          ))
        }
      }

      // Keep exactly the season's FIRST opening-side credits and LAST ending-side credits; drop
      // every other credits chapter. Keying on actual occurrence (not episode index) is robust to
      // a first/last episode that has no credits of its own.
      let openingCreditsIndex = flat.firstIndex { $0.isCredits && $0.isOpeningSide }
      let endingCreditsIndex = flat.lastIndex { $0.isCredits && !$0.isOpeningSide }

      // `fullOrdered` is every chapter (the coordinate system server progress points into);
      // `kept` is what we download.
      var fullOrdered = [SoundBoothItemResource]()
      var kept = [SoundBoothItemResource]()
      var fileNames = [String]()
      for (index, chapter) in flat.enumerated() {
        fullOrdered.append(chapter.resource)
        if chapter.isCredits, index != openingCreditsIndex, index != endingCreditsIndex {
          continue
        }
        kept.append(chapter.resource)
        fileNames.append(
          Self.seasonChapterFileName(
            episode: chapter.episodeNumber,
            number: chapter.resource.number,
            name: chapter.resource.name
          )
        )
      }
      guard !kept.isEmpty else {
        downloadStatus = nil
        return
      }

      let seriesName = episodes.first?.seriesId.flatMap { seriesNames[$0] }
      let folderName = Self.folderName(title: seasonName, seriesName: seriesName)
      let seedTime = try await resumeSeed(
        itemIds: Set(episodes.map(\.id)),
        fullOrdered: fullOrdered,
        kept: kept
      )
      try await dispatchDownload(
        resources: kept,
        fileNames: fileNames,
        folderName: folderName,
        sourceItemId: groupId,
        seedTime: seedTime
      )
    } catch let error as IntegrationError where error.isSessionExpired {
      sessionExpiredError = error
      downloadStatus = nil
    } catch is CancellationError {
      downloadStatus = nil
    } catch {
      Self.logger.warning("SoundBooth season download dispatch failed: \(error.localizedDescription)")
      downloadError = error.localizedDescription
      downloadStatus = nil
    }
  }

  /// Resolve each chapter to its CDN URL (the CDN path ends in the same `file.mp3` for every
  /// chapter, hence explicit per-file names), hand the batch to the download service, and record
  /// provenance flagged for auto-binding — with the server-side resume position to seed, if any.
  private func dispatchDownload(
    resources: [SoundBoothItemResource],
    fileNames: [String],
    folderName: String,
    sourceItemId: String,
    seedTime: Double?
  ) async throws {
    var requests = [URLRequest]()
    for resource in resources {
      let url = try await connectionService.resolvePlaybackURL(resourceId: resource.id)
      try Task.checkCancellation()
      requests.append(URLRequest(url: url))
    }

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
          itemId: sourceItemId,
          shouldBindFolder: true,
          seedTime: seedTime
        ),
        for: folderName
      )
    }
  }

  // MARK: - Resume seeding

  /// Absolute resume offset (seconds) into the downloaded chapter sequence, from the account's
  /// per-chapter progress records — so a title in progress on SoundBooth's own apps picks up in
  /// the same spot here. Best-effort: any failure just means starting from the beginning.
  ///
  /// The most recently updated progress record is the anchor. The offset sums the durations of
  /// the *kept* chapters that precede it in `fullOrdered` (server records can point at trimmed
  /// credits chapters, which occupy no time in the downloaded book).
  private func resumeSeed(
    itemIds: Set<String>,
    fullOrdered: [SoundBoothItemResource],
    kept: [SoundBoothItemResource]
  ) async throws -> Double? {
    let progresses: [SoundBoothProgress]
    do {
      progresses = try await connectionService.fetchProgresses()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return nil  // best-effort: no resume rather than aborting the download
    }

    let orderIndex = Dictionary(
      fullOrdered.enumerated().map { ($1.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    // Consider only progress records we can place in the downloaded sequence, THEN take the most
    // recent — so a newest record pointing at an undownloaded/removed resource doesn't wipe out a
    // slightly older record we could have used.
    let anchorable = progresses.filter { itemIds.contains($0.item) && orderIndex[$0.resource] != nil }
    guard
      let latest = anchorable.max(by: { ($0.updatedAt ?? "") < ($1.updatedAt ?? "") }),
      let anchorIndex = orderIndex[latest.resource]
    else { return nil }

    let keptIds = Set(kept.map(\.id))
    // Sum durations of kept chapters before the anchor. A missing/NaN duration would make the
    // offset silently too small; a wrong resume point is worse than none, so fail closed to start.
    var offset = 0.0
    for resource in fullOrdered[..<anchorIndex] where keptIds.contains(resource.id) {
      guard let duration = resource.duration, duration.isFinite else { return nil }
      offset += duration
    }
    let anchor = fullOrdered[anchorIndex]
    if keptIds.contains(anchor.id) {
      guard let duration = anchor.duration, duration.isFinite else { return nil }
      if latest.finished {
        offset += duration
      } else {
        guard latest.position.isFinite else { return nil }
        offset += min(max(0, latest.position), duration)
      }
    }
    return offset > 1 ? offset : nil
  }

  /// A chapter whose name marks it as credits ("Credits", "Opening Credits", "Closing Credits",
  /// "Ending Credits" — naming varies per production).
  private static func isCreditsChapter(_ name: String?) -> Bool {
    name?.localizedCaseInsensitiveContains("credit") == true
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

  /// Chapter filename inside a whole-season bound book: the episode ordinal prefixes the chapter
  /// number so the concatenated season stays in play order (bound files sort by name). Zero-padded
  /// to three digits so lexical order stays correct past 99 episodes.
  private static func seasonChapterFileName(episode: Int, number: Int, name: String?) -> String {
    String(format: "E%03d %@", episode, chapterFileName(number: number, name: name))
  }

  /// Filesystem-safe folder name for a title, prefixed with its series when known. This becomes
  /// the bound book's displayed title, and the series prefix keeps different products that share
  /// a display name (SoundBooth reuses titles across series) from colliding into one folder.
  private static func folderName(title: String, seriesName: String?) -> String {
    let joined = [seriesName, title].compactMap { $0 }.joined(separator: " - ")
    let stripped = joined
      .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r"))
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !stripped.isEmpty else { return "SoundBooth Title" }
    return String(stripped.prefix(120))
  }
}
