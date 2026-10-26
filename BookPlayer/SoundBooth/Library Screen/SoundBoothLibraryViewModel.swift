//
//  SoundBoothLibraryViewModel.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Combine
import Foundation
import UIKit

/// A level of the SoundBooth library. The owned items carry their season (`groupId`) and series
/// (`seriesId`); the series and season lists name them.
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

/// One section of a level. `title` is a header (a format's name) when the level mixes formats, nil
/// otherwise.
struct SoundBoothLibrarySection: Identifiable {
  let id: String
  let title: String?
  let rows: [SoundBoothLibraryItem]
}

/// The SoundBooth library (fork): Series, then Season, then Episode, with standalone books under their
/// series. The owned set is fetched once and every level is computed from it.
///
/// A title is several chapters, so a download is a folder of them that becomes one book. The library
/// was worked out against real accounts in July 2026 (a bundle-heavy one and an à-la-carte one), and
/// those rules are kept: season bundles list their episodes on demand, orphan series are named from the
/// catalog, a series owned in several formats is split by format.
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
  /// "Preparing download…", then "Downloading N files", in a banner. Announced on every change: the
  /// banner appears without focus moving to it
  @Published var downloadStatus: String? {
    didSet {
      guard let status = downloadStatus, status != oldValue else { return }
      UIAccessibility.post(notification: .announcement, argument: status)
    }
  }

  let connectionService: SoundBoothConnectionService
  let singleFileDownloadService: SingleFileDownloadService
  let sourceStore: MediaServerSourceStore

  /// The whole owned set, season bundles and titles alike
  @Published private var elements: [SoundBoothLibraryElement] = []
  /// Series names by id, from `series/list` and, for the series it leaves out, the catalog
  private var seriesNames: [String: String] = [:]
  /// Season records by id, from `groups/list`: names and order, including seasons owned episode by episode
  private var groupInfo: [String: SoundBoothGroup] = [:]
  /// Names and order of seasons `groups/list` leaves out, from the catalog
  private var orphanSeasonInfo: [String: (name: String, index: Int)] = [:]
  /// The episodes of each owned season bundle, fetched when the season is opened
  @Published private var seasonItems: [String: [SoundBoothElement]] = [:]
  @Published private var seasonFetchesInFlight = Set<String>()
  private var inflightDownloadPrep: Task<Void, Never>?
  /// The account the owned set on screen was listed for. Downloads and season fetches go out with it,
  /// whichever account is active by then (logging out of one account makes another active)
  private(set) var listedConnectionId: String?
  /// Counts library loads. Only the latest one's answer, or failure, is kept: a slow answer for the
  /// account before a switch mustn't land after the new account's library
  private var loadGeneration = 0
  /// Counts published listings. A season's episodes are kept only for the listing they were asked under
  private var listingGeneration = 0

  init(
    connectionService: SoundBoothConnectionService,
    singleFileDownloadService: SingleFileDownloadService,
    sourceStore: MediaServerSourceStore
  ) {
    self.connectionService = connectionService
    self.singleFileDownloadService = singleFileDownloadService
    self.sourceStore = sourceStore
  }

  func loadLibrary() async {
    loadGeneration += 1
    let generation = loadGeneration
    loadState = .loading
    // The library calls go out with the account active now
    let connectionId = connectionService.connection?.id
    do {
      // The owned set is required; series and season names are best-effort (a failure there only
      // leaves some titles unnested). The three don't depend on each other
      async let elementsFetch = connectionService.fetchLibraryElements()
      async let seriesFetch = connectionService.fetchSeries()
      async let groupsFetch = connectionService.fetchGroups()
      let elements = try await elementsFetch
      let series = (try? await seriesFetch) ?? []
      let groupList = (try? await groupsFetch) ?? []
      var names = Dictionary(series.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
      let groups = Dictionary(groupList.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

      // `series/list` leaves out some series owned titles belong to (free previews and the like). The
      // catalog has those titles with their series and season names, so ask it when a name is missing
      var orphanSeasons: [String: (name: String, index: Int)] = [:]
      let hasUnnamedSeries = elements.contains { element in
        guard !element.isGroup, let seriesId = element.element.seriesId else { return false }
        return names[seriesId] == nil
      }
      if hasUnnamedSeries, let catalog = try? await connectionService.fetchCatalog() {
        for item in catalog {
          if let seriesId = item.seriesId, let name = item.seriesName, names[seriesId] == nil {
            names[seriesId] = name
          }
          if let groupId = item.groupId, let name = item.groupName, orphanSeasons[groupId] == nil {
            orphanSeasons[groupId] = (name: name, index: item.groupIndex ?? Int.max)
          }
        }
      }

      guard generation == loadGeneration else { return }
      self.seriesNames = names
      self.groupInfo = groups
      self.orphanSeasonInfo = orphanSeasons
      self.elements = elements
      // Seasons fetched under the previous listing are dropped with it, and so are their answers
      self.seasonItems = [:]
      self.seasonFetchesInFlight = []
      self.listedConnectionId = connectionId
      self.listingGeneration += 1
      loadState = .loaded
    } catch let error as IntegrationError where error.isSessionExpired {
      guard generation == loadGeneration else { return }
      sessionExpiredError = error
      loadState = .failed(message: error.localizedDescription)
    } catch let error where Self.isCancellation(error) {
      guard generation == loadGeneration else { return }
      loadState = .idle
    } catch {
      guard generation == loadGeneration else { return }
      loadState = .failed(message: error.localizedDescription)
    }
  }

  // MARK: - Levels

  func sections(for node: SoundBoothNode) -> [SoundBoothLibrarySection] {
    switch node {
    case .root: return rootSections()
    case .series(let id, _): return sections(inSeries: id)
    case .season(let id, _): return sections(inSeason: id)
    }
  }

  private var groups: [SoundBoothLibraryElement] { elements.filter { $0.isGroup } }
  private var items: [SoundBoothLibraryElement] { elements.filter { !$0.isGroup } }

  /// One row per owned series (through a title or a season bundle), then season bundles of a series
  /// that couldn't be named, then titles without a nameable series under "Other Titles"
  private func rootSections() -> [SoundBoothLibrarySection] {
    var seriesRows: [SoundBoothLibraryItem] = []
    var seen = Set<String>()
    for element in elements {
      guard
        let seriesId = element.element.seriesId,
        let name = seriesNames[seriesId],
        !seen.contains(seriesId)
      else { continue }
      seen.insert(seriesId)
      seriesRows.append(SoundBoothLibraryItem(id: seriesId, displayName: name, kind: .series))
    }

    let looseSeasons = groups
      .filter { $0.element.seriesId.flatMap { seriesNames[$0] } == nil }
      .map { SoundBoothLibraryItem(id: $0.element.id, displayName: $0.element.name, kind: .group) }
    let looseItems = items.filter { $0.element.seriesId.flatMap { seriesNames[$0] } == nil }

    let containers = sortedByName(seriesRows) + sortedByName(looseSeasons)
    var sections = [SoundBoothLibrarySection]()
    if !containers.isEmpty {
      sections.append(SoundBoothLibrarySection(id: "top", title: nil, rows: containers))
    }

    // Among named series an orphan title would pass for a series to open; a header sets them apart.
    // A library of nothing but orphans just lists them
    let looseRows = sortedByRelease(looseItems.map(\.element)).map { SoundBoothLibraryItem(raw: $0) }
    if !looseRows.isEmpty {
      let title = containers.isEmpty ? nil : "soundbooth_other_titles_title".localized
      sections.append(SoundBoothLibrarySection(id: "loose", title: title, rows: looseRows))
    }
    return sections
  }

  /// A series: its seasons in order (owned bundles, and seasons owned episode by episode), then titles
  /// outside a nameable season. Split by format when it's owned in more than one
  private func sections(inSeries seriesId: String) -> [SoundBoothLibrarySection] {
    let seriesItems = items.filter { $0.element.seriesId == seriesId }
    let seriesName = seriesNames[seriesId]

    var seasons: [(id: String, name: String, index: Int)] = []
    var seenSeasons = Set<String>()
    for group in groups where group.element.seriesId == seriesId {
      seenSeasons.insert(group.element.id)
      let index = seasonInfo(forGroupId: group.element.id)?.index ?? Int.max
      seasons.append((group.element.id, group.element.name, index))
    }
    for item in seriesItems {
      guard
        let groupId = item.element.groupId,
        !seenSeasons.contains(groupId),
        let info = seasonInfo(forGroupId: groupId)
      else { continue }
      seenSeasons.insert(groupId)
      seasons.append((groupId, info.name, info.index))
    }

    let directItems = seriesItems.filter { item in
      guard let groupId = item.element.groupId else { return true }
      return seasonInfo(forGroupId: groupId) == nil
    }.map(\.element)

    // SoundBooth sells a story in several formats and tags them unevenly: one edition's episodes carry
    // a season, another's don't. Mixed together the editions scatter, so each format gets its section
    let ownedFormats = Set(seriesItems.compactMap { Self.formatKey($0.element.format) })
    if ownedFormats.count > 1 {
      return formatGroupedSections(seriesName: seriesName, seriesItems: seriesItems, seasons: seasons, directItems: directItems)
    }

    let seasonRows = seasons
      .sorted { ($0.index, $0.name.localizedLowercase) < ($1.index, $1.name.localizedLowercase) }
      .map { SoundBoothLibraryItem(id: $0.id, displayName: $0.name, kind: .group) }
    var sections = [SoundBoothLibrarySection]()
    if !seasonRows.isEmpty {
      sections.append(SoundBoothLibrarySection(id: "seasons", title: nil, rows: seasonRows))
    }
    sections += leafSections(directItems, seriesName: seriesName)
    return sections
  }

  /// A series owned in several formats, one section per format. A season's format is the one its owned
  /// episodes share; a season that can't be pinned to one (a bundle whose episodes aren't loaded yet, or
  /// a mixed one) and a title without a format go in a last section without a header
  private func formatGroupedSections(
    seriesName: String?,
    seriesItems: [SoundBoothLibraryElement],
    seasons: [(id: String, name: String, index: Int)],
    directItems: [SoundBoothElement]
  ) -> [SoundBoothLibrarySection] {
    func seasonFormat(_ groupId: String) -> String? {
      let formats = Set(
        seriesItems
          .filter { $0.element.groupId == groupId }
          .compactMap { Self.formatKey($0.element.format) }
      )
      return formats.count == 1 ? formats.first : nil
    }

    typealias SeasonEntry = (index: Int, name: String, row: SoundBoothLibraryItem)
    var seasonsByFormat = [String: [SeasonEntry]]()
    var looseSeasons = [SeasonEntry]()
    for season in seasons {
      let entry: SeasonEntry = (season.index, season.name, SoundBoothLibraryItem(id: season.id, displayName: season.name, kind: .group))
      if let format = seasonFormat(season.id) {
        seasonsByFormat[format, default: []].append(entry)
      } else {
        looseSeasons.append(entry)
      }
    }

    var leavesByFormat = [String: [SoundBoothElement]]()
    var looseLeaves = [SoundBoothElement]()
    for element in directItems {
      if let format = Self.formatKey(element.format) {
        leavesByFormat[format, default: []].append(element)
      } else {
        looseLeaves.append(element)
      }
    }

    func leafRow(_ element: SoundBoothElement) -> SoundBoothLibraryItem {
      SoundBoothLibraryItem(raw: element, seriesName: seriesName ?? element.seriesId.flatMap { seriesNames[$0] })
    }
    func sortedSeasonRows(_ entries: [SeasonEntry]) -> [SoundBoothLibraryItem] {
      entries
        .sorted { ($0.index, $0.name.localizedLowercase) < ($1.index, $1.name.localizedLowercase) }
        .map(\.row)
    }

    var sections = [SoundBoothLibrarySection]()
    for format in Self.orderedFormats(Set(seasonsByFormat.keys).union(leavesByFormat.keys)) {
      let rows = sortedSeasonRows(seasonsByFormat[format] ?? []) + sortedByRelease(leavesByFormat[format] ?? []).map(leafRow)
      guard !rows.isEmpty else { continue }
      sections.append(SoundBoothLibrarySection(id: "format-\(format)", title: SoundBoothLibraryItem.formatDisplayName(format), rows: rows))
    }

    let looseRows = sortedSeasonRows(looseSeasons) + sortedByRelease(looseLeaves).map(leafRow)
    if !looseRows.isEmpty {
      sections.append(SoundBoothLibrarySection(id: "format-none", title: nil, rows: looseRows))
    }
    return sections
  }

  /// A season's name and position, from `groups/list`, an owned bundle, or the catalog. Nil when it
  /// can't be named, so its episodes show as standalone titles
  private func seasonInfo(forGroupId groupId: String) -> (name: String, index: Int)? {
    if let group = groupInfo[groupId] {
      return (group.name, group.index ?? Int.max)
    }
    if let owned = groups.first(where: { $0.element.id == groupId }) {
      return (owned.element.name, owned.element.displayOptions?.index ?? Int.max)
    }
    return orphanSeasonInfo[groupId]
  }

  /// Whether the season is owned as a bundle, rather than episode by episode
  private func ownsBundle(_ groupId: String) -> Bool {
    groups.contains { $0.element.id == groupId }
  }

  /// A season's episodes: all of a bundle's (episodes also bought one by one are part of them), or the
  /// ones bought one by one
  private func episodes(inSeason groupId: String) -> [SoundBoothElement] {
    if ownsBundle(groupId) { return seasonItems[groupId] ?? [] }
    return items.filter { $0.element.groupId == groupId }.map(\.element)
  }

  private func sections(inSeason groupId: String) -> [SoundBoothLibrarySection] {
    let seasonEpisodes = episodes(inSeason: groupId)
    let seriesName = seasonEpisodes.first?.seriesId.flatMap { seriesNames[$0] }
    return leafSections(seasonEpisodes, seriesName: seriesName)
  }

  /// Fetches a bundle season's episodes the first time it's opened, with the account the library was
  /// listed for. Nothing to do for a season owned episode by episode, or one fetched already or being
  /// fetched. An answer that arrives after a newer listing (a reload, another account) is dropped
  func loadSeasonIfNeeded(_ node: SoundBoothNode) async {
    guard
      case .season(let groupId, _) = node,
      ownsBundle(groupId),
      seasonItems[groupId] == nil,
      !seasonFetchesInFlight.contains(groupId),
      let connectionId = listedConnectionId
    else { return }
    let listing = listingGeneration
    seasonFetchesInFlight.insert(groupId)
    defer {
      // A newer listing cleared the set already, and may have its own fetch of this season out
      if listing == listingGeneration {
        seasonFetchesInFlight.remove(groupId)
      }
    }
    do {
      let episodes = try await connectionService.fetchSeasonItems(groupId: groupId, connectionId: connectionId)
      guard listing == listingGeneration else { return }
      seasonItems[groupId] = episodes
    } catch let error as IntegrationError where error.isSessionExpired {
      guard listing == listingGeneration else { return }
      sessionExpiredError = error
    } catch let error where Self.isCancellation(error) {
      // Fetched again next time
    } catch {
      guard listing == listingGeneration else { return }
      Self.logger.warning("SoundBooth season fetch failed: \(error.localizedDescription)")
      downloadError = error.localizedDescription
    }
  }

  func isFetchingSeason(_ node: SoundBoothNode) -> Bool {
    guard case .season(let groupId, _) = node else { return false }
    return seasonFetchesInFlight.contains(groupId)
  }

  /// A bundle season fetches its episodes again; anywhere else the whole library loads again
  func refresh(_ node: SoundBoothNode) async {
    if case .season(let groupId, _) = node, ownsBundle(groupId) {
      seasonItems[groupId] = nil
      await loadSeasonIfNeeded(node)
    } else {
      await loadLibrary()
    }
  }

  /// SoundBooth's format values in the order sections show them
  static let formatOrder = ["audiobook", "cinematic", "immersion", "bonus"]

  /// The format value a title is grouped by, nil without one
  static func formatKey(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    return raw
  }

  /// Formats in section order: known ones first, others after in name order
  static func orderedFormats(_ formats: Set<String>) -> [String] {
    formats.sorted { lhs, rhs in
      let left = formatOrder.firstIndex(of: lhs) ?? formatOrder.count
      let right = formatOrder.firstIndex(of: rhs) ?? formatOrder.count
      return left == right ? lhs < rhs : left < right
    }
  }

  /// Titles in release order, in one section per format when formats mix
  private func leafSections(_ elements: [SoundBoothElement], seriesName: String?) -> [SoundBoothLibrarySection] {
    let ordered = sortedByRelease(elements)
    guard !ordered.isEmpty else { return [] }

    func row(_ element: SoundBoothElement) -> SoundBoothLibraryItem {
      SoundBoothLibraryItem(raw: element, seriesName: seriesName ?? element.seriesId.flatMap { seriesNames[$0] })
    }

    let formats = Set(ordered.compactMap { Self.formatKey($0.format) })
    guard formats.count > 1 else {
      return [SoundBoothLibrarySection(id: "leaves", title: nil, rows: ordered.map(row))]
    }

    var sections = [SoundBoothLibrarySection]()
    for format in Self.orderedFormats(formats) {
      let rows = ordered.filter { Self.formatKey($0.format) == format }.map(row)
      sections.append(SoundBoothLibrarySection(id: "format-\(format)", title: SoundBoothLibraryItem.formatDisplayName(format), rows: rows))
    }
    let unformatted = ordered.filter { Self.formatKey($0.format) == nil }.map(row)
    if !unformatted.isEmpty {
      sections.append(SoundBoothLibrarySection(id: "format-none", title: nil, rows: unformatted))
    }
    return sections
  }

  private func sortedByName(_ rows: [SoundBoothLibraryItem]) -> [SoundBoothLibraryItem] {
    rows.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
  }

  /// By release date, then name. Episodes of a season and titles of a series play in this order
  private func sortedByRelease(_ elements: [SoundBoothElement]) -> [SoundBoothElement] {
    elements.sorted {
      if $0.releaseSortKey != $1.releaseSortKey { return $0.releaseSortKey < $1.releaseSortKey }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  // MARK: - Season downloads

  /// A season's released episodes, in play order
  private func releasedEpisodes(inSeason node: SoundBoothNode, now: Date = Date()) -> [SoundBoothElement] {
    guard case .season(let groupId, _) = node else { return [] }
    return sortedByRelease(episodes(inSeason: groupId)).filter { element in
      guard let releaseDate = element.releaseDate else { return true }
      return releaseDate <= now
    }
  }

  func canDownloadSeason(_ node: SoundBoothNode) -> Bool {
    !releasedEpisodes(inSeason: node).isEmpty
  }

  func releasedEpisodeCount(_ node: SoundBoothNode) -> Int {
    releasedEpisodes(inSeason: node).count
  }

  // MARK: - Downloads

  /// Downloads a title as one book. A second tap before the first is ready replaces it
  func downloadItem(_ item: SoundBoothLibraryItem) {
    guard item.isDownloadable, let connectionId = listedConnectionId else { return }
    inflightDownloadPrep?.cancel()
    inflightDownloadPrep = Task { [weak self] in
      await self?.prepareDownload(of: item, connectionId: connectionId)
    }
  }

  /// Downloads a season's released episodes as one book, the repeated credits between them dropped
  /// when `trimCredits` is on
  func downloadSeason(_ node: SoundBoothNode, trimCredits: Bool) {
    guard
      case .season(let groupId, let seasonName) = node,
      let connectionId = listedConnectionId
    else { return }
    let episodes = releasedEpisodes(inSeason: node)
    guard !episodes.isEmpty else { return }
    let seriesName = episodes.first?.seriesId.flatMap { seriesNames[$0] }

    inflightDownloadPrep?.cancel()
    inflightDownloadPrep = Task { [weak self] in
      await self?.prepareSeasonDownload(
        groupId: groupId,
        seasonName: seasonName,
        seriesName: seriesName,
        episodes: episodes,
        trimCredits: trimCredits,
        connectionId: connectionId
      )
    }
  }

  private func prepareDownload(of item: SoundBoothLibraryItem, connectionId: String) async {
    await runPreparation {
      let resources = try await self.connectionService.fetchItemResources(itemIds: [item.id], connectionId: connectionId)
      let plan = Self.titlePlan(resources)
      try await self.queue(
        plan,
        folderTitle: item.displayName,
        seriesName: item.seriesName,
        fallbackName: "SoundBooth \(item.id)",
        sourceItemId: item.id,
        itemIds: [item.id],
        connectionId: connectionId
      )
    }
  }

  private func prepareSeasonDownload(
    groupId: String,
    seasonName: String,
    seriesName: String?,
    episodes: [SoundBoothElement],
    trimCredits: Bool,
    connectionId: String
  ) async {
    await runPreparation {
      let resources = try await self.connectionService.fetchItemResources(itemIds: episodes.map(\.id), connectionId: connectionId)
      let plan = Self.seasonPlan(episodes: episodes, resources: resources, trimCredits: trimCredits)
      try await self.queue(
        plan,
        folderTitle: seasonName,
        seriesName: seriesName,
        fallbackName: "SoundBooth \(groupId)",
        sourceItemId: groupId,
        itemIds: Set(episodes.map(\.id)),
        connectionId: connectionId
      )
    }
  }

  /// Runs a download's preparation with the banner and the error handling every download shares
  private func runPreparation(_ work: () async throws -> Void) async {
    // Cleared first so the same words for another title are announced again
    downloadStatus = nil
    downloadStatus = "soundbooth_preparing_download".localized
    do {
      try await work()
    } catch let error as IntegrationError where error.isSessionExpired {
      sessionExpiredError = error
      downloadStatus = nil
    } catch let error where Self.isCancellation(error) {
      // Whoever cancelled owns the banner now: closing it cleared it, another download replaced it
    } catch {
      Self.logger.warning("SoundBooth download couldn't start: \(error.localizedDescription)")
      downloadStatus = nil
      downloadError = error.localizedDescription
    }
  }

  /// Resolves every chapter's audio URL, then queues them into a folder of their own, recorded as
  /// landed with the bind flag and the resume point so the import brings it in as one book that starts
  /// where SoundBooth's own apps left off. Nothing is queued unless every chapter resolved.
  func queue(
    _ plan: SoundBoothDownloadPlan,
    folderTitle: String,
    seriesName: String?,
    fallbackName: String,
    sourceItemId: String,
    itemIds: Set<String>,
    connectionId: String
  ) async throws {
    guard !plan.kept.isEmpty else {
      downloadStatus = nil
      downloadError = "soundbooth_no_chapters".localized
      return
    }

    var requests = [URLRequest]()
    for chapter in plan.kept {
      let url = try await connectionService.resolvePlaybackURL(resourceId: chapter.resource.id, connectionId: connectionId)
      try Task.checkCancellation()
      // The CDN takes no credentials, so none go with the request
      requests.append(URLRequest(url: url))
    }
    let seedTime = try await resumeSeed(itemIds: itemIds, plan: plan, connectionId: connectionId)
    try Task.checkCancellation()
    // Logged out while the positions were read (a failed read only drops the seed): nothing is queued
    // for an account that's gone
    guard connectionService.connections.contains(where: { $0.id == connectionId }) else {
      throw URLError(.userAuthenticationRequired)
    }

    let title = [seriesName, folderTitle].compactMap { $0 }.joined(separator: " - ")
    let folderName = MediaServerDownloadFolders.reserveFolder(
      named: MediaServerDownloadFolders.folderName(title: title, fallback: fallbackName),
      info: MediaServerSourceInfo(
        kind: .soundbooth,
        connectionId: connectionId,
        itemId: sourceItemId,
        shouldBindFolder: true,
        seedTime: seedTime
      ),
      store: sourceStore,
      folderInUse: { [singleFileDownloadService] in singleFileDownloadService.hasQueuedDownloads(inFolder: $0) }
    )
    singleFileDownloadService.handleDownload(requests, folderName: folderName, fileNames: plan.kept.map(\.fileName))
    downloadStatus = String.localizedStringWithFormat("downloading_file_title".localized, requests.count)
  }

  /// Where the book should start, in seconds, from the account's saved positions: the newest one that
  /// falls on a chapter of the plan, plus the length of the downloaded chapters before it (a trimmed
  /// credits chapter takes no time in the book). Nil when there's nothing to resume or a length is
  /// missing: no resume beats a wrong one. A failure to read the positions only means no resume.
  private func resumeSeed(itemIds: Set<String>, plan: SoundBoothDownloadPlan, connectionId: String) async throws -> Double? {
    let progresses: [SoundBoothProgress]
    do {
      progresses = try await connectionService.fetchProgresses(connectionId: connectionId)
    } catch let error where Self.isCancellation(error) {
      throw CancellationError()
    } catch {
      return nil
    }
    return Self.resumeOffset(progresses: progresses, itemIds: itemIds, plan: plan)
  }

  func dismissDownloadStatus() {
    inflightDownloadPrep?.cancel()
    inflightDownloadPrep = nil
    downloadStatus = nil
  }

  /// URLSession cancels with `URLError.cancelled`, not `CancellationError`
  private static func isCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
  }
}

// MARK: - Download plans

/// The chapters a download takes, in play order: `all` every chapter the title has (the positions
/// SoundBooth's saved progress points into), `kept` the ones downloaded, each with its file name
struct SoundBoothDownloadPlan: Equatable {
  struct Chapter: Equatable {
    let resource: SoundBoothItemResource
    let fileName: String

    static func == (lhs: Chapter, rhs: Chapter) -> Bool {
      lhs.resource.id == rhs.resource.id && lhs.fileName == rhs.fileName
    }
  }

  let all: [SoundBoothItemResource]
  let kept: [Chapter]

  static func == (lhs: SoundBoothDownloadPlan, rhs: SoundBoothDownloadPlan) -> Bool {
    lhs.all.map(\.id) == rhs.all.map(\.id) && lhs.kept == rhs.kept
  }
}

extension SoundBoothLibraryViewModel {
  /// A title's chapters in play order, named "001 - Opening Credits.mp3". Numbered by position, not by
  /// SoundBooth's `number`, which can repeat: two chapters under one name would lose the second
  static func titlePlan(_ resources: [SoundBoothItemResource]) -> SoundBoothDownloadPlan {
    let ordered = resources.sorted { ($0.number, $0.id) < ($1.number, $1.id) }
    let chapters = ordered.enumerated().map { index, resource in
      SoundBoothDownloadPlan.Chapter(resource: resource, fileName: chapterFileName(position: index + 1, name: resource.name))
    }
    return SoundBoothDownloadPlan(all: ordered, kept: chapters)
  }

  /// A season's chapters in play order: each released episode in turn ("E001 001 - …mp3", the episodes
  /// numbered among those that have chapters, so the numbers have no gaps), with, when `trimCredits` is
  /// on, only the season's first opening credits and last closing credits kept. Credits are named
  /// unevenly ("Credits" serves for both), so a credits chapter in an episode's first half counts as
  /// opening and one in its second half as closing.
  static func seasonPlan(
    episodes: [SoundBoothElement],
    resources: [SoundBoothItemResource],
    trimCredits: Bool
  ) -> SoundBoothDownloadPlan {
    let byEpisode = Dictionary(grouping: resources, by: \.itemId)
    let playable = episodes.filter { !(byEpisode[$0.id] ?? []).isEmpty }

    typealias Flat = (resource: SoundBoothItemResource, episode: Int, position: Int, isCredits: Bool, isOpeningSide: Bool)
    var flat = [Flat]()
    for (episodeIndex, episode) in playable.enumerated() {
      let chapters = (byEpisode[episode.id] ?? []).sorted { ($0.number, $0.id) < ($1.number, $1.id) }
      for (chapterIndex, resource) in chapters.enumerated() {
        flat.append((
          resource: resource,
          episode: episodeIndex + 1,
          position: chapterIndex + 1,
          isCredits: trimCredits && isCreditsChapter(resource.name) && chapters.count > 1,
          isOpeningSide: chapterIndex < chapters.count / 2
        ))
      }
    }

    // The first opening-side and the last closing-side credits stay, wherever they fall: the first or
    // last episode may have none of its own
    let openingCredits = flat.firstIndex { $0.isCredits && $0.isOpeningSide }
    let closingCredits = flat.lastIndex { $0.isCredits && !$0.isOpeningSide }

    var kept = [SoundBoothDownloadPlan.Chapter]()
    for (index, chapter) in flat.enumerated() {
      if chapter.isCredits, index != openingCredits, index != closingCredits {
        continue
      }
      let name = String(format: "E%03d %@", chapter.episode, chapterFileName(position: chapter.position, name: chapter.resource.name))
      kept.append(SoundBoothDownloadPlan.Chapter(resource: chapter.resource, fileName: name))
    }
    return SoundBoothDownloadPlan(all: flat.map(\.resource), kept: kept)
  }

  /// The resume point for `plan` in seconds, from saved positions of `itemIds`; see `resumeSeed`
  static func resumeOffset(progresses: [SoundBoothProgress], itemIds: Set<String>, plan: SoundBoothDownloadPlan) -> Double? {
    let orderIndex = Dictionary(plan.all.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    // Only positions the plan can place, then the newest: a newer one on a chapter that isn't in the
    // plan mustn't hide an older one that is
    let placeable = progresses.filter { itemIds.contains($0.item) && orderIndex[$0.resource] != nil }
    guard
      let latest = placeable.max(by: { ($0.updatedAt ?? "") < ($1.updatedAt ?? "") }),
      let anchorIndex = orderIndex[latest.resource]
    else { return nil }

    let keptIds = Set(plan.kept.map(\.resource.id))
    var offset = 0.0
    for resource in plan.all[..<anchorIndex] where keptIds.contains(resource.id) {
      guard let duration = resource.duration, duration.isFinite else { return nil }
      offset += duration
    }
    let anchor = plan.all[anchorIndex]
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

  /// A credits chapter: "Credits", "Opening Credits", "Closing Credits"… (each production names them
  /// its own way)
  static func isCreditsChapter(_ name: String?) -> Bool {
    name?.localizedCaseInsensitiveContains("credit") == true
  }

  /// "001 - Opening Credits.mp3": the number keeps the book in play order (the import orders a folder by
  /// name), the chapter's name made safe as a file name, "Chapter 3" when it has none
  static func chapterFileName(position: Int, name: String?) -> String {
    let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let title = trimmed.isEmpty ? String(format: "chapter_number_title".localized, position) : trimmed
    let stem = MediaServerDownloadFolders.limited(MediaServerFileNames.sanitize(title))
    return String(format: "%03d - %@.mp3", position, stem)
  }
}
