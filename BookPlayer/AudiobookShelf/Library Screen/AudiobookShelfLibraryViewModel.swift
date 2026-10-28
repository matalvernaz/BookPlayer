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
  let onImportConfirmed: ([SimpleExternalResource]) -> Void
  var accountService: AccountService
  
  /// The arguments of `AudiobookShelfConnectionService.fetchItems(in:limit:page:sortBy:desc:filter:)`
  /// for the Books tab, which has no filter
  struct BooksPageRequest: Equatable {
    let libraryID: String
    /// 0 asks for every book
    let limit: Int
    let page: Int
    let sortBy: String
    let desc: Bool?
  }

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
  @Published private(set) var isImporting = false
  @Published var pendingImportBatch: ExternalImportBatch?

  @Published var editMode: EditMode = .inactive
  @Published var selectedItems: Set<AudiobookShelfLibraryItem.ID> = []
  @Published var showingDownloadConfirmation = false
  /// While the books the pages haven't brought load, for select-all or a whole-level Stream or
  /// Download (fork)
  @Published private(set) var isLoadingAllItems = false
  
  var onTransition: BPTransition<Routes>?

  let connectionService: AudiobookShelfConnectionService
  private let singleFileDownloadService: SingleFileDownloadService
  /// The whole library's books, for the Folders tab to group by path (ABS has no folder endpoint).
  /// A seam so tests can hold a response back; the default is the service's limit-0 fetch
  var loadFolderItems: @MainActor (String) async throws -> [AudiobookShelfLibraryItem]
  /// A request for the Books tab's books, from the service. A seam, so tests can hold a response back
  var loadBooksPage: @MainActor (BooksPageRequest) async throws -> (items: [AudiobookShelfLibraryItem], total: Int)
  /// The Books tab's search (library id, query), from the service. A seam, so tests can hold a response back
  var loadSearchResults: @MainActor (String, String) async throws -> [AudiobookShelfLibraryItem]

  private var fetchTask: Task<(), any Error>?
  /// The load of every remaining book, while it runs. It holds the fetch slot too
  private var remainingItemsTask: Task<(), any Error>?
  /// Select-all, waiting for that load
  private var selectAllTask: Task<(), Never>?
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
    // A folder level shows the on-disk order; sorting would undo it
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

  /// `searchDebounce` is how long the search field settles before the list is fetched again; tests pass a
  /// long one, so a query they set never refetches behind their back
  init(
    source: AudiobookShelfLibraryViewSource,
    connectionService: AudiobookShelfConnectionService,
    singleFileDownloadService: SingleFileDownloadService,
    accountService: AccountService,
    onImportConfirmed: @escaping ([SimpleExternalResource]) -> Void,
    navigation: BPNavigation,
    navigationTitle: String,
    searchDebounce: RunLoop.SchedulerTimeType.Stride = .milliseconds(350)
  ) {
    self.source = source
    self.connectionService = connectionService
    self.singleFileDownloadService = singleFileDownloadService
    self.accountService = accountService
    self.onImportConfirmed = onImportConfirmed
    self.navigation = navigation
    self.navigationTitle = navigationTitle
    self.loadFolderItems = { [connectionService] libraryID in
      try await connectionService.fetchItems(
        in: libraryID,
        limit: 0,
        page: 0,
        sortBy: nil,
        desc: nil,
        filter: nil
      ).items
    }
    self.loadBooksPage = { [connectionService] request in
      try await connectionService.fetchItems(
        in: request.libraryID,
        limit: request.limit,
        page: request.page,
        sortBy: request.sortBy,
        desc: request.desc,
        filter: nil
      )
    }
    self.loadSearchResults = { [connectionService] libraryID, query in
      try await connectionService.searchItems(
        in: libraryID,
        query: query,
        limit: Self.searchResultLimit
      )
    }

    $searchQuery
      .debounce(for: searchDebounce, scheduler: RunLoop.main)
      .removeDuplicates()
      .dropFirst()
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
    cancelSelectAll()
    fetchTask?.cancel()
    fetchTask = nil
  }

  func destination(for item: AudiobookShelfLibraryItem) -> AudiobookShelfLibraryLevelData? {
    switch item.kind {
    case .audiobook:
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
      cancelSelectAll()
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

  /// Selects every item of the level, loading the Books tab's pages not loaded yet first (fork, upstream
  /// #1661: it selected the loaded pages only). A tap while that load runs stops it; with a selection, a
  /// tap clears it
  @MainActor
  func onSelectAllTapped() {
    guard allowsEditing else { return }

    if isLoadingAllItems {
      cancelSelectAll()
      return
    }
    guard selectedItems.isEmpty else {
      selectedItems.removeAll()
      return
    }
    guard canFetchMoreItems else {
      selectLoadedItems()
      return
    }

    selectAllTask = Task { @MainActor in
      do {
        try await loadRemainingItems()
      } catch {
        if !Self.isCancellation(error) {
          self.error = error
        }
        return
      }
      guard !Task.isCancelled else { return }

      selectLoadedItems()
      // The title shows the count, but VoiceOver doesn't read a title that changes
      UIAccessibility.post(
        notification: .announcement,
        argument: String(format: "integration_selection_count".localized, selectedItems.count, totalItems)
      )
    }
  }

  private func selectLoadedItems() {
    selectedItems = Set(items.filter { $0.isDownloadable }.map(\.id))
  }
  
  /// Stream never downloads: without the entitlement it sells the entitlement.
  @MainActor
  func onStreamTapped(useSelectedItems: Bool) {
    guard accountService.hasStreamingEnabled() else {
      goToSubscribe()
      return
    }
    Task { await virtualImportFolderAudiobooks(useSelectedItems: useSelectedItems) }
  }
  
  /// What a Stream acts on: the selection, in the order shown, or the whole level, whose pages not
  /// loaded yet are loaded first (fork, upstream #1661: it streamed only the pages scrolled into view).
  /// Both filter on isDownloadable so a selection can never carry something the whole-level branch
  /// would have skipped
  func importCandidates(useSelectedItems: Bool) async throws -> [AudiobookShelfLibraryItem] {
    if useSelectedItems {
      return items.filter { selectedItems.contains($0.id) && $0.isDownloadable }
    }
    try await loadRemainingItems()
    return items.filter { $0.isDownloadable }
  }

  @MainActor
  func virtualImportFolderAudiobooks(useSelectedItems: Bool) async {
    // Reentrancy guard: a double-tap mid-hydration (or mid-load) must not run two imports
    guard !isImporting else { return }
    isImporting = true
    defer { isImporting = false }

    let audiobooks: [AudiobookShelfLibraryItem]
    do {
      audiobooks = try await importCandidates(useSelectedItems: useSelectedItems)
    } catch {
      // Stopped: the screen closed, or a search or sort replaced the level
      if !Self.isCancellation(error) {
        self.error = error
      }
      return
    }

    guard !audiobooks.isEmpty else { return }

    do {
      let resources = try await VirtualImportPipeline.run(
        items: audiobooks,
        id: \.id,
        hydrate: { ids in
          // batch/get returns EXPANDED items (list endpoints are minified without
          // audioFiles); one round-trip for the whole selection
          let hydrated = try await self.connectionService.fetchItems(ids: ids)
          return hydrated.reduce(into: [:]) {
            $0[$1.id] = HydratedItem(
              fileExtension: $1.fileExtension,
              duration: $1.duration,
              chapters: $1.chapters,
              files: $1.streamFiles
            )
          }
        },
        buildResource: { item, hydrated in
          item.asVirtualImportResource(
            fileExtension: hydrated.fileExtension,
            duration: hydrated.duration,
            chapters: hydrated.chapters,
            files: hydrated.files,
            connectionService: self.connectionService,
            artworkSize: CGSize(width: 300, height: 300)
          )
        }
      )
      guard !resources.isEmpty else {
        self.error = BookPlayerError.runtimeError("import_no_audio_files_alert".localized)
        return
      }
      if resources.count < audiobooks.count {
        Self.logger.warning("Virtual import skipped \(audiobooks.count - resources.count) item(s) with no audio-file metadata or no server-measured length")
      }
      // Stage as a VALUE for this screen's own confirmation sheet — the browser
      // stays open beneath it; dismissal happens on confirm
      pendingImportBatch = ExternalImportBatch(resources: resources)
    } catch {
      self.error = error
    }
  }
  
  /// The dialog says how many books will download, so the Books tab's pages not loaded yet are loaded
  /// first, as the Jellyfin folder resolves its requests first (fork, upstream #1661: it counted and
  /// downloaded the loaded pages only)
  @MainActor
  func onDownloadFolderTapped() {
    guard canFetchMoreItems else {
      showingDownloadConfirmation = true
      return
    }

    Task { @MainActor in
      do {
        try await loadRemainingItems()
      } catch {
        if !Self.isCancellation(error) {
          self.error = error
        }
        return
      }
      self.showingDownloadConfirmation = true
    }
  }
  
  @MainActor
  func confirmDownloadFolder() {
   var requests = [URLRequest]()
    // Same filter as virtualImportFolderAudiobooks: folder/collection rows at this
    // level would each throw in createItemDownloadRequest (last error wins) while
    // the rest of the loop proceeds — a confusing partial download
    for item in self.items where item.isDownloadable {
      do {
        let request = try connectionService.createItemDownloadRequest(item)
        requests.append(request)
      } catch {
        self.error = error
      }
    }

    guard !requests.isEmpty else { return }
    singleFileDownloadService.handleDownload(requests)
    navigation.dismiss?()
  }

  @MainActor
  func onDownloadTapped() {
    let items = self.items.filter { selectedItems.contains($0.id) && $0.isDownloadable }

    var requests = [URLRequest]()
    for item in items {
      do {
        let request = try connectionService.createItemDownloadRequest(item)
        requests.append(request)
      } catch {
        self.error = error
      }
    }

    guard !requests.isEmpty else { return }
    singleFileDownloadService.handleDownload(requests)
    navigation.dismiss?()
  }
  
  @MainActor
  func goToSubscribe() {
    navigation.showingSubscribe = true
  }

  @MainActor
  func confirmExternalImport(_ resources: [SimpleExternalResource]) {
    // Bulk imports land you in the library (today's destination): send the batch on
    // the import bus, then close the browser
    onImportConfirmed(resources)
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

  /// Unlike the other fetches here, a superseded folder fetch must stay silent and keep its hands off
  /// the handle: a cancelled task can still get its response, and its cleanup would otherwise
  /// clear its replacement's handle
  private func fetchFolderItems(libraryID: String, path: String) {
    fetchTask?.cancel()
    fetchTask = Task { @MainActor in
      defer {
        if !Task.isCancelled { self.fetchTask = nil }
      }

      do {
        let fetched = try await loadFolderItems(libraryID)
        guard !Task.isCancelled else { return }

        loadLocalItems(Self.folderLevelItems(from: fetched, at: path, libraryId: libraryID))
      } catch {
        guard !Task.isCancelled, !Self.isCancellation(error) else { return }
        self.error = error
      }
    }
  }

  /// URLSession cancels with `URLError.cancelled`, not `CancellationError`
  private static func isCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
  }

  /// One level of the library's folder tree from its whole book list: the subfolders of `path`
  /// (with how many books each holds, at any depth) and then the books directly in it, both in
  /// name order. Books without a `relPath` under `path` aren't on this level; the Books tab still
  /// lists them.
  nonisolated static func folderLevelItems(
    from books: [AudiobookShelfLibraryItem],
    at path: String,
    libraryId: String
  ) -> [AudiobookShelfLibraryItem] {
    let prefix = path.isEmpty ? "" : path + "/"
    var folderBookCounts: [String: Int] = [:]
    var levelBooks: [(name: String, item: AudiobookShelfLibraryItem)] = []

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

    let books = levelBooks
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      .map(\.item)

    return folders + books
  }

  private func fetchLibraries() {
    fetchTask?.cancel()
    fetchTask = Task { @MainActor in
      defer { self.fetchTask = nil }

      do {
        let libraries = try await connectionService.fetchLibraries()
        let libraryItems = libraries
          .filter { $0.mediaType == "book" }
          .map(AudiobookShelfLibraryItem.init(library:))
        loadLocalItems(libraryItems)
      } catch is CancellationError {
        // ignore
      } catch {
        self.error = error
      }
    }
  }

  private func fetchEntityItems(libraryID: String, category: AudiobookShelfBrowseCategory) {
    fetchTask?.cancel()
    fetchTask = Task { @MainActor in
      defer { self.fetchTask = nil }

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
      } catch is CancellationError {
        // ignore
      } catch {
        self.error = error
      }
    }
  }

  private func fetchCollectionItems(collectionID: String) {
    fetchTask?.cancel()
    fetchTask = Task { @MainActor in
      defer { self.fetchTask = nil }

      do {
        let collection = try await connectionService.fetchCollection(id: collectionID)
        let books = collection.books.compactMap(AudiobookShelfLibraryItem.init(apiItem:))
        loadLocalItems(books)
      } catch is CancellationError {
        // ignore
      } catch {
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

  /// Like the folder fetch, a superseded page (by select-all's load, a search or a sort) stays silent and
  /// keeps its hands off the handle: whoever cancels it clears the slot
  private func fetchBooksPage() {
    guard case .books(let libraryID, let filter) = source else { return }
    guard filter == nil, fetchTask == nil, canFetchMoreItems else { return }

    fetchTask = Task { @MainActor in
      defer {
        if !Task.isCancelled { self.fetchTask = nil }
      }

      do {
        let (items, totalItems) = try await loadBooksPage(BooksPageRequest(
          libraryID: libraryID,
          limit: Self.itemBatchSize,
          page: nextPage,
          sortBy: sortParameter,
          desc: sortDescending
        ))
        guard !Task.isCancelled else { return }

        self.nextPage += 1
        self.totalItems = totalItems
        self.items.append(contentsOf: items)
      } catch {
        guard !Task.isCancelled, !Self.isCancellation(error) else { return }
        self.error = error
      }
    }
  }

  /// Loads every book of the Books tab the pages haven't brought, in one request in the tab's sort
  /// (fork, upstream #1661: select-all and the whole-level Stream and Download acted on the loaded
  /// pages only). The other levels arrive whole. It takes the fetch slot, stopping a page in flight,
  /// and is stopped as a page is: the screen closing, a new search or sort. Cancelling the caller stops
  /// it too
  func loadRemainingItems() async throws {
    guard case .books(let libraryID, .none) = source, canFetchMoreItems else { return }

    cancelRemainingItemsLoad()
    fetchTask?.cancel()
    let capturedQuery = searchQuery
    // Everything (limit 0, as the Folders tab and the filtered levels ask), in the pages' sort
    let request = BooksPageRequest(
      libraryID: libraryID,
      limit: 0,
      page: 0,
      sortBy: sortParameter,
      desc: sortDescending
    )
    let task = Task { @MainActor in
      let books = try await self.loadBooksPage(request).items
      // Stopped, or a search started: whatever replaced it owns the list
      guard !Task.isCancelled, self.searchQuery == capturedQuery else {
        throw CancellationError()
      }
      // The whole tab replaces the pages. Its own count is the total, not the server's: rows the app
      // can't read are dropped, and paging would go on looking for them
      self.items = books
      self.totalItems = books.count
    }
    fetchTask = task
    remainingItemsTask = task
    isLoadingAllItems = true
    UIAccessibility.post(notification: .announcement, argument: "integration_loading_all_items".localized)
    defer {
      if remainingItemsTask == task {
        remainingItemsTask = nil
        isLoadingAllItems = false
      }
      if fetchTask == task {
        fetchTask = nil
      }
    }

    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  /// Stops the load of every remaining book, if one runs
  private func cancelRemainingItemsLoad() {
    guard let task = remainingItemsTask else { return }
    task.cancel()
    remainingItemsTask = nil
    isLoadingAllItems = false
    if fetchTask == task {
      fetchTask = nil
    }
  }

  /// Stops select-all and the load it waits for (or a whole-level Stream's or Download's)
  private func cancelSelectAll() {
    selectAllTask?.cancel()
    selectAllTask = nil
    cancelRemainingItemsLoad()
  }

  private func fetchAllFilteredBooks(libraryID: String, filter: AudiobookShelfItemFilter?) {
    fetchTask?.cancel()
    fetchTask = Task { @MainActor in
      defer { self.fetchTask = nil }

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
      } catch is CancellationError {
        // ignore
      } catch {
        self.error = error
      }
    }
  }

  /// Like the pages, a superseded search (the query cleared or changed, select-all's load after it) stays
  /// silent and keeps its hands off the handle: its late answer would otherwise put its results back over
  /// whatever replaced them
  private func searchLibraryItems(libraryID: String, query: String) {
    fetchTask?.cancel()
    fetchTask = Task { @MainActor in
      defer {
        if !Task.isCancelled { self.fetchTask = nil }
      }

      do {
        let items = try await loadSearchResults(libraryID, query)
        guard !Task.isCancelled, self.searchQuery == query else { return }

        self.totalItems = items.count
        self.items = sortItems(items)
      } catch {
        guard !Task.isCancelled, !Self.isCancellation(error) else { return }
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
    // A folder level arrives in disk order (folders, then books, by name), searched or not
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
    cancelSelectAll()
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
