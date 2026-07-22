//
//  AudiobookShelfLibraryViewModel.swift
//  BookPlayer
//
//  Created by Gianni Carlo on 11/14/25.
//  Copyright © 2025 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Combine
import Foundation
import SwiftUI

enum AudiobookShelfLayout {
  enum SortBy: String {
    case recent, title
  }
}

@MainActor
final class AudiobookShelfLibraryViewModel: IntegrationLibraryViewModelProtocol, BPLogger {
  enum Routes {
    case done
  }

  var navigation: BPNavigation
  let navigationTitle: String
  let source: AudiobookShelfLibraryViewSource

  @AppStorage(Constants.UserDefaults.audiobookshelfLibraryLayout)
  var layout: IntegrationLayout.Options = .grid

  @AppStorage(Constants.UserDefaults.audiobookshelfLibraryLayoutSortBy)
  var sortBy: AudiobookShelfLayout.SortBy = .recent {
    didSet {
      handleSortChanged()
    }
  }

  @Published var searchQuery = ""
  @Published var items: [AudiobookShelfLibraryItem] = []
  @Published var totalItems = Int.max
  @Published var error: Error?

  @Published var editMode: EditMode = .inactive
  @Published var selectedItems: Set<AudiobookShelfLibraryItem.ID> = []

  var onTransition: BPTransition<Routes>?

  let connectionService: AudiobookShelfConnectionService
  private let singleFileDownloadService: SingleFileDownloadService

  private var fetchTask: Task<(), any Error>?
  private var nextPage = 0
  private var allItems: [AudiobookShelfLibraryItem] = []

  private static let itemBatchSize = 20
  private static let itemFetchMargin = 3
  private static let searchResultLimit = 500

  private var disposeBag = Set<AnyCancellable>()

  var isSearchable: Bool {
    switch source {
    case .books(_, .none):
      true
    case .books(_, _), .entities(_, _), .collection(_), .folders(_, _):
      true
    case .libraries:
      false
    }
  }

  var isGridEnabled: Bool {
    switch source {
    case .libraries, .books(_, _), .collection(_), .entities(_, _), .folders(_, _):
      true
    }
  }

  var showsLayoutPreferences: Bool {
    isGridEnabled
  }

  var showsSortPreferences: Bool {
    switch source {
    case .books(_, _), .collection(_):
      true
    // Folder levels mirror the on-disk layout; sorting would break that.
    case .libraries, .entities(_, _), .folders(_, _):
      false
    }
  }

  var allowsEditing: Bool {
    switch source {
    case .books(_, _), .collection(_), .folders(_, _):
      true
    case .libraries, .entities(_, _):
      false
    }
  }

  var isAlphabeticallySectioned: Bool {
    switch source {
    case .entities(_, .authors), .entities(_, .narrators):
      true
    case .libraries, .books(_, _), .collection(_), .entities(_, _), .folders(_, _):
      false
    }
  }

  private var usesRemoteBookSearch: Bool {
    if case .books(_, .none) = source {
      return true
    }
    return false
  }

  private var usesPagedFetching: Bool {
    if case .books(_, .none) = source, searchQuery.isEmpty {
      return true
    }
    return false
  }

  private var canFetchMoreItems: Bool {
    usesPagedFetching && items.count < totalItems
  }

  init(
    source: AudiobookShelfLibraryViewSource,
    connectionService: AudiobookShelfConnectionService,
    singleFileDownloadService: SingleFileDownloadService,
    navigation: BPNavigation,
    navigationTitle: String
  ) {
    self.source = source
    self.connectionService = connectionService
    self.singleFileDownloadService = singleFileDownloadService
    self.navigation = navigation
    self.navigationTitle = navigationTitle

    // `dropFirst()` must precede `debounce` — it exists to swallow the
    // subscription seed (`""`), and downstream of the debounce it would
    // swallow the user's first real query instead whenever they start
    // typing before the seed's debounce window elapses.
    $searchQuery
      .dropFirst()
      .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
      .removeDuplicates()
      .sink { [weak self] _ in
        self?.onSearchQueryChanged()
      }
      .store(in: &disposeBag)
  }

  func fetchInitialItems() {
    guard items.isEmpty, fetchTask == nil else { return }
    // Don't fetch if source has an empty library ID (library not yet resolved)
    guard !source.libraryID.isEmpty else { return }
    fetchSourceItems()
  }

  func fetchMoreItemsIfNeeded(currentItem: AudiobookShelfLibraryItem) {
    guard canFetchMoreItems,
          items.count >= Self.itemFetchMargin,
          let idx = items.firstIndex(where: { $0.id == currentItem.id })
    else { return }
    let thresholdIndex = items.count - Self.itemFetchMargin
    if idx >= thresholdIndex {
      fetchBooksPage()
    }
  }

  func cancelFetchItems() {
    fetchTask?.cancel()
    fetchTask = nil
  }

  func destination(for item: AudiobookShelfLibraryItem) -> AudiobookShelfLibraryLevelData? {
    switch item.kind {
    case .audiobook, .podcast:
      return .details(data: item)
    case .library:
      return nil
    case .browseCategory:
      return nil
    case .collection:
      return .library(source: .collection(id: item.id), title: item.title)
    case .author, .series, .narrator:
      guard let filter = item.filter else { return nil }
      return .library(source: .books(libraryID: item.libraryId, filter: filter), title: item.title)
    case .folder:
      guard let path = item.relPath else { return nil }
      return .library(source: .folders(libraryID: item.libraryId, path: path), title: item.title)
    }
  }

  @MainActor
  func handleDoneAction() {
    onTransition?(.done)
  }

  @MainActor
  func onEditToggleSelectTapped() {
    guard allowsEditing else { return }

    withAnimation {
      editMode = editMode.isEditing ? .inactive : .active
    }

    if !editMode.isEditing {
      selectedItems.removeAll()
    }
  }

  @MainActor
  func onSelectTapped(for item: AudiobookShelfLibraryItem) {
    guard item.isDownloadable else { return }

    if let index = selectedItems.firstIndex(of: item.id) {
      selectedItems.remove(at: index)
    } else {
      selectedItems.insert(item.id)
    }
  }

  @MainActor
  func onSelectAllTapped() {
    guard allowsEditing else { return }

    if selectedItems.isEmpty {
      let ids = items.compactMap { item in
        item.isDownloadable ? item.id : nil
      }
      selectedItems = Set(ids)
    } else {
      selectedItems.removeAll()
    }
  }

  @MainActor
  func onDownloadTapped() {
    let items = selectedItems.compactMap { id in
      self.items.first(where: { $0.id == id && $0.isDownloadable })
    }

    var requests = [URLRequest]()
    for item in items {
      do {
        let request = try connectionService.createItemDownloadRequest(item)
        connectionService.registerItemDownloadProvenance(request, itemId: item.id)
        requests.append(request)
      } catch {
        self.error = error
      }
    }

    guard !requests.isEmpty else { return }
    singleFileDownloadService.handleDownload(requests)
    navigation.dismiss?()
  }

  private func handleSortChanged() {
    guard !items.isEmpty else { return }

    switch source {
    case .books(let libraryID, .none):
      resetForFreshFetch()
      fetchBookItems(libraryID: libraryID, filter: nil)
    default:
      applyLocalSearchAndSort()
    }
  }

  private func fetchSourceItems() {
    switch source {
    case .libraries:
      fetchLibraries()
    case .books(let libraryID, let filter):
      fetchBookItems(libraryID: libraryID, filter: filter)
    case .entities(let libraryID, let category):
      fetchEntityItems(libraryID: libraryID, category: category)
    case .collection(let id):
      fetchCollectionItems(collectionID: id)
    case .folders(let libraryID, let path):
      fetchFolderItems(libraryID: libraryID, path: path)
    }
  }

  private func fetchLibraries() {
    fetchTask?.cancel()
    fetchTask = Task { @MainActor in
      defer { if !Task.isCancelled { self.fetchTask = nil } }

      do {
        let libraries = try await connectionService.fetchLibraries()
        let libraryItems = libraries
          .filter { $0.mediaType == "book" }
          .map(AudiobookShelfLibraryItem.init(library:))
        loadLocalItems(libraryItems)
      } catch let error where error.isCancellation {
        // ignore
      } catch {
        guard !Task.isCancelled else { return }
        self.error = error
      }
    }
  }

  private func fetchEntityItems(libraryID: String, category: AudiobookShelfBrowseCategory) {
    fetchTask?.cancel()
    fetchTask = Task { @MainActor in
      defer { if !Task.isCancelled { self.fetchTask = nil } }

      do {
        switch category {
        case .books:
          loadLocalItems([])
        case .authors:
          let filterData = try await connectionService.fetchFilterData(in: libraryID)
          loadLocalItems(filterData.authors.map { AudiobookShelfLibraryItem(author: $0, libraryId: libraryID) })
        case .series:
          let filterData = try await connectionService.fetchFilterData(in: libraryID)
          loadLocalItems(filterData.series.map { AudiobookShelfLibraryItem(series: $0, libraryId: libraryID) })
        case .narrators:
          let filterData = try await connectionService.fetchFilterData(in: libraryID)
          loadLocalItems(filterData.narrators.map { AudiobookShelfLibraryItem(narrator: $0, libraryId: libraryID) })
        case .collections:
          let collections = try await connectionService.fetchCollections(in: libraryID)
          loadLocalItems(collections.map(AudiobookShelfLibraryItem.init(collection:)))
        }
      } catch let error where error.isCancellation {
        // ignore
      } catch {
        guard !Task.isCancelled else { return }
        self.error = error
      }
    }
  }

  private func fetchFolderItems(libraryID: String, path: String) {
    fetchTask?.cancel()
    fetchTask = Task { @MainActor in
      defer { if !Task.isCancelled { self.fetchTask = nil } }

      do {
        let (fetched, _) = try await connectionService.fetchItems(
          in: libraryID,
          limit: 0,
          page: 0,
          sortBy: nil,
          desc: nil,
          filter: nil
        )

        loadLocalItems(Self.folderLevelItems(from: fetched, at: path, libraryId: libraryID))
      } catch let error where error.isCancellation {
        // ignore
      } catch {
        guard !Task.isCancelled else { return }
        self.error = error
      }
    }
  }

  /// Reduces the library's full book list to one folder level: subfolders of
  /// `path` (with recursive book counts) followed by the books sitting
  /// directly in it, both in name order. Books without a `relPath` under
  /// `path` are left out here but remain reachable from the Books tab.
  private static func folderLevelItems(
    from books: [AudiobookShelfLibraryItem],
    at path: String,
    libraryId: String
  ) -> [AudiobookShelfLibraryItem] {
    let prefix = path.isEmpty ? "" : path + "/"
    var folderBookCounts: [String: Int] = [:]
    var levelBooks: [(folderName: String, item: AudiobookShelfLibraryItem)] = []

    for book in books {
      guard let relPath = book.relPath, relPath.hasPrefix(prefix) else { continue }
      let remainder = relPath.dropFirst(prefix.count)
      guard !remainder.isEmpty else { continue }

      if let slash = remainder.firstIndex(of: "/") {
        folderBookCounts[String(remainder[..<slash]), default: 0] += 1
      } else {
        levelBooks.append((String(remainder), book))
      }
    }

    let folders = folderBookCounts
      .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
      .map { name, count in
        AudiobookShelfLibraryItem(
          folderName: name,
          path: prefix + name,
          libraryId: libraryId,
          bookCount: count
        )
      }

    let sortedBooks = levelBooks
      .sorted { $0.folderName.localizedStandardCompare($1.folderName) == .orderedAscending }
      .map(\.item)

    return folders + sortedBooks
  }

  private func fetchCollectionItems(collectionID: String) {
    fetchTask?.cancel()
    fetchTask = Task { @MainActor in
      defer { if !Task.isCancelled { self.fetchTask = nil } }

      do {
        let collection = try await connectionService.fetchCollection(id: collectionID)
        let books = collection.books.compactMap(AudiobookShelfLibraryItem.init(apiItem:))
        loadLocalItems(books)
      } catch let error where error.isCancellation {
        // ignore
      } catch {
        guard !Task.isCancelled else { return }
        self.error = error
      }
    }
  }

  private func fetchBookItems(libraryID: String, filter: AudiobookShelfItemFilter?) {
    resetSelectionState()

    if filter == nil, usesRemoteBookSearch, searchQuery.isEmpty {
      fetchBooksPage()
    } else if filter == nil, usesRemoteBookSearch {
      searchLibraryItems(libraryID: libraryID, query: searchQuery)
    } else {
      fetchAllFilteredBooks(libraryID: libraryID, filter: filter)
    }
  }

  private func fetchBooksPage() {
    guard case .books(let libraryID, let filter) = source else { return }
    guard filter == nil, fetchTask == nil, canFetchMoreItems else { return }

    fetchTask = Task { @MainActor in
      defer { if !Task.isCancelled { self.fetchTask = nil } }

      do {
        let (items, totalItems) = try await connectionService.fetchItems(
          in: libraryID,
          limit: Self.itemBatchSize,
          page: nextPage,
          sortBy: sortParameter,
          desc: sortDescending,
          filter: nil
        )

        guard !Task.isCancelled else { return }
        self.nextPage += 1
        // An empty page is the end of the list even when the server-reported
        // total was never reached — records the app can't map into items
        // would otherwise keep `canFetchMoreItems` true forever, refetching
        // empty pages on every scroll.
        if items.isEmpty {
          self.totalItems = self.items.count
        } else {
          self.totalItems = totalItems
          self.items.append(contentsOf: items)
        }
      } catch let error where error.isCancellation {
        // ignore
      } catch {
        guard !Task.isCancelled else { return }
        self.error = error
      }
    }
  }

  private func fetchAllFilteredBooks(libraryID: String, filter: AudiobookShelfItemFilter?) {
    fetchTask?.cancel()
    fetchTask = Task { @MainActor in
      defer { if !Task.isCancelled { self.fetchTask = nil } }

      do {
        let items: [AudiobookShelfLibraryItem]
        if let filter, filter.group == .authors {
          // The items+filter endpoint joins through `bookAuthors`, which can
          // hold stale rows after ABS dedups authors on import. The dedicated
          // author endpoint hydrates books from the author record directly
          // and is what the official web client uses on the author-detail page.
          items = try await connectionService.fetchAuthorItems(authorID: filter.value)
        } else {
          let (fetched, _) = try await connectionService.fetchItems(
            in: libraryID,
            limit: 0,
            page: 0,
            sortBy: sortParameter,
            desc: sortDescending,
            filter: filter
          )
          items = fetched
        }

        loadLocalItems(items)
      } catch let error where error.isCancellation {
        // ignore
      } catch {
        guard !Task.isCancelled else { return }
        self.error = error
      }
    }
  }

  private func searchLibraryItems(libraryID: String, query: String) {
    fetchTask?.cancel()
    fetchTask = Task { @MainActor in
      defer { if !Task.isCancelled { self.fetchTask = nil } }

      do {
        let items = try await connectionService.searchItems(
          in: libraryID,
          query: query,
          limit: Self.searchResultLimit
        )

        guard !Task.isCancelled else { return }
        self.totalItems = items.count
        self.items = sortItems(items)
      } catch let error where error.isCancellation {
        // ignore
      } catch {
        guard !Task.isCancelled else { return }
        self.error = error
      }
    }
  }

  private func onSearchQueryChanged() {
    switch source {
    case .books(let libraryID, .none):
      resetForFreshFetch()

      if searchQuery.isEmpty {
        fetchBookItems(libraryID: libraryID, filter: nil)
      } else {
        searchLibraryItems(libraryID: libraryID, query: searchQuery)
      }
    default:
      applyLocalSearchAndSort()
    }
  }

  private func loadLocalItems(_ items: [AudiobookShelfLibraryItem]) {
    // Only ever called from fetch tasks; a cancelled task has been superseded
    // and must not overwrite the replacement's results.
    guard !Task.isCancelled else { return }
    allItems = items
    applyLocalSearchAndSort()
  }

  private func applyLocalSearchAndSort() {
    let normalizedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    let filteredItems = normalizedQuery.isEmpty
      ? allItems
      : allItems.filter { item in
        item.title.localizedCaseInsensitiveContains(normalizedQuery)
          || item.subtitle?.localizedCaseInsensitiveContains(normalizedQuery) == true
          || item.authorName?.localizedCaseInsensitiveContains(normalizedQuery) == true
          || item.narratorName?.localizedCaseInsensitiveContains(normalizedQuery) == true
      }

    let sortedItems = sortItems(filteredItems)
    totalItems = sortedItems.count
    items = sortedItems
  }

  private func sortItems(_ items: [AudiobookShelfLibraryItem]) -> [AudiobookShelfLibraryItem] {
    // Folder levels arrive pre-ordered (folders first, then books, by disk
    // name); the global sortBy preference must not reshuffle them.
    if case .folders = source {
      return items
    }

    if let seriesID = activeSeriesID {
      return items.sorted { lhs, rhs in
        compareSeriesItems(lhs, rhs, seriesID: seriesID)
      }
    }

    switch sortBy {
    case .recent:
      return items.sorted { lhs, rhs in
        let lhsDate = lhs.updatedAt ?? lhs.addedAt ?? 0
        let rhsDate = rhs.updatedAt ?? rhs.addedAt ?? 0
        if lhsDate == rhsDate {
          return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        return lhsDate > rhsDate
      }
    case .title:
      return items.sorted {
        $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
      }
    }
  }

  private var activeSeriesID: String? {
    guard case .books(_, let filter?) = source,
          filter.group == .series
    else {
      return nil
    }

    return filter.value
  }

  private func compareSeriesItems(
    _ lhs: AudiobookShelfLibraryItem,
    _ rhs: AudiobookShelfLibraryItem,
    seriesID: String
  ) -> Bool {
    let lhsSortValue = seriesSortValue(lhs.seriesSequence(for: seriesID))
    let rhsSortValue = seriesSortValue(rhs.seriesSequence(for: seriesID))

    switch (lhsSortValue, rhsSortValue) {
    case let (.some(lhsValue), .some(rhsValue)):
      if lhsValue != rhsValue {
        return lhsValue < rhsValue
      }
    case (.some, .none):
      return true
    case (.none, .some):
      return false
    case (.none, .none):
      break
    }

    let lhsSequence = lhs.seriesSequence(for: seriesID) ?? lhs.title
    let rhsSequence = rhs.seriesSequence(for: seriesID) ?? rhs.title
    let fallbackComparison = lhsSequence.localizedStandardCompare(rhsSequence)
    if fallbackComparison != .orderedSame {
      return fallbackComparison == .orderedAscending
    }

    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
  }

  private func seriesSortValue(_ sequence: String?) -> Decimal? {
    guard let trimmedSequence = sequence?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmedSequence.isEmpty
    else {
      return nil
    }

    if let decimal = Decimal(string: trimmedSequence) {
      return decimal
    }

    if let wordValue = seriesWordSortValue(trimmedSequence) {
      return wordValue
    }

    let pattern = #"[-+]?\d+(?:\.\d+)?"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(
            in: trimmedSequence,
            range: NSRange(trimmedSequence.startIndex..., in: trimmedSequence)
          ),
          let range = Range(match.range, in: trimmedSequence)
    else {
      return nil
    }

    return Decimal(string: String(trimmedSequence[range]))
  }

  private static let seriesWordValues: [String: Decimal] = [
    "minus": -1,
    "negative": -1,
    "zero": 0,
    "one": 1,
    "first": 1,
    "two": 2,
    "second": 2,
    "three": 3,
    "third": 3,
    "four": 4,
    "fourth": 4,
    "five": 5,
    "fifth": 5,
    "six": 6,
    "sixth": 6,
    "seven": 7,
    "seventh": 7,
    "eight": 8,
    "eighth": 8,
    "nine": 9,
    "ninth": 9,
    "ten": 10,
    "tenth": 10,
    "eleven": 11,
    "eleventh": 11,
    "twelve": 12,
    "twelfth": 12,
    "thirteen": 13,
    "thirteenth": 13,
    "fourteen": 14,
    "fourteenth": 14,
    "fifteen": 15,
    "fifteenth": 15,
    "sixteen": 16,
    "sixteenth": 16,
    "seventeen": 17,
    "seventeenth": 17,
    "eighteen": 18,
    "eighteenth": 18,
    "nineteen": 19,
    "nineteenth": 19,
    "twenty": 20,
    "twentieth": 20,
    "half": Decimal(string: "0.5")!
  ]

  private func seriesWordSortValue(_ sequence: String) -> Decimal? {
    let normalized = sequence
      .lowercased()
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "_", with: " ")

    let tokens = normalized
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }

    for (index, token) in tokens.enumerated() {
      guard var value = Self.seriesWordValues[token] else { continue }

      if index > 0 {
        let previous = tokens[index - 1]
        if previous == "minus" || previous == "negative" {
          value *= -1
        }
      }

      return value
    }

    return nil
  }

  private func resetSelectionState() {
    editMode = .inactive
    selectedItems.removeAll()
  }

  private func resetForFreshFetch() {
    fetchTask?.cancel()
    fetchTask = nil
    resetSelectionState()
    items = []
    totalItems = Int.max
    nextPage = 0
  }

  private var sortParameter: String {
    switch sortBy {
    case .recent:
      "addedAt"
    case .title:
      "media.metadata.title"
    }
  }

  private var sortDescending: Bool? {
    switch sortBy {
    case .recent:
      true
    case .title:
      nil
    }
  }
}
