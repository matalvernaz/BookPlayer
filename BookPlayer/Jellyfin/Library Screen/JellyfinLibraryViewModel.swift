//
//  JellyfinLibraryViewModel.swift
//  BookPlayer
//
//  Created by Lysann Tranvouez on 2024-10-27.
//  Copyright © 2024 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Combine
import Foundation
import Get
import JellyfinAPI
import SwiftUI

enum JellyfinLibraryLevelData: Equatable, Hashable {
  case topLevel(libraryName: String)
  case folder(data: JellyfinLibraryItem)
  case authorBooks(authorID: String, authorName: String, parentID: String?)
  case narratorBooks(personID: String, personName: String, parentID: String?)
  case details(data: JellyfinLibraryItem)
}

/// The author/narrator browse screens are the same VM with a different fetch +
/// destination — parameterized by role instead of duplicated per class.
enum JellyfinPersonRole {
  case author
  case narrator
}

// MARK: - Shared folder-import flow

/// The two Jellyfin book-listing VMs share the identical import flow verbatim; the
/// persons-list VM never imports and deliberately does not conform. onStreamTapped
/// and confirmExternalImport are witnessed by the extension defaults below;
/// virtualImportFolderAudiobooks stays a per-VM wrapper so the isImporting reentrancy
/// guard keeps its @Published private(set) access.
@MainActor
protocol JellyfinFolderImporting: AnyObject, BPLogger {
  var items: [JellyfinLibraryItem] { get }
  var selectedItems: Set<JellyfinLibraryItem.ID> { get }
  var connectionService: JellyfinConnectionService { get }
  var accountService: AccountService { get }
  var navigation: BPNavigation { get }
  var onImportConfirmed: ([SimpleExternalResource]) -> Void { get }
  var error: Error? { get set }
  var pendingImportBatch: ExternalImportBatch? { get set }

  func virtualImportFolderAudiobooks(useSelectedItems: Bool) async
  /// Loads whatever of the level the pages haven't brought yet. A requirement, not only an
  /// extension member, so `importCandidates` reaches each screen's own
  func loadRemainingItems() async throws
  func onDownloadTapped()
  func confirmDownloadFolder()
  func goToSubscribe()
}

/// URLSession (and Get, over it) cancels with `URLError.cancelled`, not `CancellationError`
private func isCancellation(_ error: Error) -> Bool {
  error is CancellationError || (error as? URLError)?.code == .cancelled
}

extension JellyfinFolderImporting {
  /// Stream never downloads: without the entitlement it sells the entitlement.
  @MainActor
  func onStreamTapped(useSelectedItems: Bool) {
    guard accountService.hasStreamingEnabled() else {
      goToSubscribe()
      return
    }
    Task { await virtualImportFolderAudiobooks(useSelectedItems: useSelectedItems) }
  }

  @MainActor
  func confirmExternalImport(_ resources: [SimpleExternalResource]) {
    // Bulk imports land you in the library (today's destination): send the batch on
    // the import bus, then close the browser
    onImportConfirmed(resources)
    navigation.dismiss?()
  }

  /// What a Stream acts on: the selection, in the order shown, or the whole level, whose pages not
  /// yet loaded are loaded first (fork, upstream #1661: it streamed only the pages scrolled into view).
  /// Both filter on isDownloadable so a selection can never carry something the whole-level branch
  /// would have skipped
  func importCandidates(useSelectedItems: Bool) async throws -> [JellyfinLibraryItem] {
    if useSelectedItems {
      return items.filter { selectedItems.contains($0.id) && $0.isDownloadable }
    }
    try await loadRemainingItems()
    return items.filter { $0.isDownloadable }
  }

  /// The shared import body — callers hold the isImporting guard.
  func runFolderImport(useSelectedItems: Bool) async {
    let audiobooks: [JellyfinLibraryItem]
    do {
      audiobooks = try await importCandidates(useSelectedItems: useSelectedItems)
    } catch {
      // Stopped: the screen closed, or a search or sort replaced the level
      if !isCancellation(error) {
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
          let hydrated = try await self.connectionService.fetchItems(ids: ids)
          return hydrated.reduce(into: [:]) {
            $0[$1.id] = HydratedItem(
              fileExtension: $1.details?.fileExtension,
              // `details.runtimeInSeconds` keeps "unmeasured" as nil and avoids the whole-second
              // truncation `durationSeconds` applies
              duration: $1.details?.runtimeInSeconds,
              chapters: $1.chapters
            )
          }
        },
        buildResource: { item, hydrated in
          item.asVirtualImportResource(
            fileExtension: hydrated.fileExtension,
            duration: hydrated.duration,
            chapters: hydrated.chapters,
            detailsOverride: nil,
            connectionService: self.connectionService,
            artworkSize: CGSize(width: 200, height: 200)
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
}

@MainActor
final class JellyfinLibraryViewModel: IntegrationLibraryViewModelProtocol, JellyfinFolderImporting, BPLogger {
  enum Routes {
    case done
  }

  /// The arguments of `JellyfinConnectionService.fetchItems(in:startIndex:limit:sortBy:searchTerm:recursive:)`
  struct PageRequest: Equatable {
    let folderID: String?
    let startIndex: Int
    /// nil asks for everything from `startIndex`
    let limit: Int?
    let sortBy: JellyfinLayout.SortBy
    let searchTerm: String?
    let recursive: Bool
  }

  typealias Page = (items: [JellyfinLibraryItem], nextStartIndex: Int, maxCountItems: Int)

  var navigation: BPNavigation
  let navigationTitle: String

  @AppStorage(Constants.UserDefaults.jellyfinLibraryLayout)
  var layout: IntegrationLayout.Options = .grid

  @AppStorage(Constants.UserDefaults.jellyfinLibraryLayoutSortBy)
  var sortBy: JellyfinLayout.SortBy = .smart {
    didSet {
      guard let folderID = folderID else { return }
      cancelSelectAll()
      fetchTask?.cancel()
      items = []
      nextStartItemIndex = 0
      totalItems = Int.max
      fetchFolderItems(folderID: folderID)
    }
  }

  @Published var searchQuery = ""
  @Published var items: [JellyfinLibraryItem] = []
  @Published var totalItems = Int.max
  @Published var error: Error?
  @Published private(set) var isImporting = false
  @Published var pendingImportBatch: ExternalImportBatch?

  @Published var editMode: EditMode = .inactive
  @Published var selectedItems: Set<JellyfinLibraryItem.ID> = []
  @Published var showingDownloadConfirmation = false
  @Published private(set) var isPreparingDownload = false
  /// While the items the pages haven't brought load, for select-all or the whole-level Stream (fork)
  @Published private(set) var isLoadingAllItems = false

  /// Resolved BEFORE the confirmation so the dialog can state the real figure: this
  /// folder's download reaches the complete level, which `items` alone can't count.
  /// Held only between `onDownloadFolderTapped` and `confirmDownloadFolder`.
  private var pendingDownloadRequests: [URLRequest] = []

  var isSearchable: Bool { true }

  var onTransition: BPTransition<Routes>?

  let folderID: String?
  let recursive: Bool
  let onImportConfirmed: ([SimpleExternalResource]) -> Void
  let connectionService: JellyfinConnectionService
  var accountService: AccountService
  private let singleFileDownloadService: SingleFileDownloadService
  /// A page of the folder or of the search, from the service. A seam, so tests can hold a response back
  var loadPage: @MainActor (PageRequest) async throws -> Page

  private var fetchTask: Task<(), any Error>?
  /// The load of every remaining item, while it runs. It holds the fetch slot too
  private var remainingItemsTask: Task<(), any Error>?
  /// Select-all, waiting for that load
  private var selectAllTask: Task<(), Never>?
  private var nextStartItemIndex = 0

  private static let itemBatchSize = 20
  private static let itemFetchMargin = 3

  private var disposeBag = Set<AnyCancellable>()

  var canFetchMoreItems: Bool {
    nextStartItemIndex < totalItems
  }

  /// A folder or a search with pages still to come (the top level is one request)
  private var hasUnloadedItems: Bool {
    (folderID != nil || !searchQuery.isEmpty) && canFetchMoreItems
  }

  /// While a confirmation is pending this is the exact number of requests about to run.
  /// `totalItems` is not usable here: a server that omits `totalRecordCount` makes
  /// `updatedTotal` publish `items.count + itemBatchSize` as a pagination probe.
  var downloadableItemCount: Int {
    showingDownloadConfirmation
      ? pendingDownloadRequests.count
      : items.filter { $0.isDownloadable }.count
  }

  init(
    folderID: String?,
    recursive: Bool = false,
    connectionService: JellyfinConnectionService,
    singleFileDownloadService: SingleFileDownloadService,
    onImportConfirmed: @escaping ([SimpleExternalResource]) -> Void,
    accountService: AccountService,
    navigation: BPNavigation,
    navigationTitle: String
  ) {
    self.folderID = folderID
    self.recursive = recursive
    self.connectionService = connectionService
    self.onImportConfirmed = onImportConfirmed
    self.singleFileDownloadService = singleFileDownloadService
    self.accountService = accountService
    self.navigation = navigation
    self.navigationTitle = navigationTitle
    self.loadPage = { [connectionService] request in
      try await connectionService.fetchItems(
        in: request.folderID,
        startIndex: request.startIndex,
        limit: request.limit,
        sortBy: request.sortBy,
        searchTerm: request.searchTerm,
        recursive: request.recursive
      )
    }

    $searchQuery
      .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in
        self?.onSearchQueryChanged()
      }
      .store(in: &disposeBag)
  }

  func fetchInitialItems() {
    // Don't fetch if no folder is set (library not yet resolved)
    guard folderID != nil || !searchQuery.isEmpty else { return }
    fetchMoreItems()
  }

  func fetchMoreItemsIfNeeded(currentItem: JellyfinLibraryItem) {
    guard items.count >= Self.itemFetchMargin,
          let idx = items.firstIndex(where: { $0.id == currentItem.id })
    else { return }
    let thresholdIndex = items.count - Self.itemFetchMargin
    if idx >= thresholdIndex {
      fetchMoreItems()
    }
  }

  func cancelFetchItems() {
    cancelSelectAll()
    fetchTask?.cancel()
    fetchTask = nil
  }

  func destination(for item: JellyfinLibraryItem) -> JellyfinLibraryLevelData? {
    switch item.kind {
    case .audiobook:
      return .details(data: item)
    case .userView, .folder:
      return .folder(data: item)
    case .author:
      return .authorBooks(authorID: item.id, authorName: item.name, parentID: folderID)
    case .narrator:
      return .narratorBooks(personID: item.id, personName: item.name, parentID: folderID)
    }
  }

  private func fetchMoreItems() {
    guard fetchTask == nil && canFetchMoreItems else {
      return
    }

    if let folderID {
      fetchFolderItems(folderID: folderID)
    } else if !searchQuery.isEmpty {
      fetchGlobalSearchItems()
    } else {
      fetchTopLevelItems()
    }
  }

  /// Like every fetch in the slot, a superseded one stays silent and keeps its hands off the handle: a
  /// cancelled task can still get its response, and its cleanup would otherwise clear its replacement's
  /// handle (whoever cancels it clears the slot)
  private func fetchTopLevelItems() {
    fetchTask?.cancel()
    fetchTask = Task { @MainActor in
      defer {
        if !Task.isCancelled { self.fetchTask = nil }
      }
      items = []

      do {
        let items = try await connectionService.fetchTopLevelItems()
        guard !Task.isCancelled else { return }

        self.totalItems = items.count
        self.items = items
      } catch {
        guard !Task.isCancelled, !isCancellation(error) else { return }
        self.error = error
      }
    }
  }

  private func onSearchQueryChanged() {
    cancelSelectAll()
    fetchTask?.cancel()
    fetchTask = nil
    editMode = .inactive
    items = []
    selectedItems.removeAll()
    nextStartItemIndex = 0
    totalItems = Int.max

    if let folderID {
      fetchFolderItems(folderID: folderID)
    } else if searchQuery.isEmpty {
      fetchTopLevelItems()
    } else {
      fetchGlobalSearchItems()
    }
  }

  private func fetchGlobalSearchItems() {
    fetchTask = Task { @MainActor in
      defer {
        if !Task.isCancelled { self.fetchTask = nil }
      }

      let capturedQuery = searchQuery
      let previousNextStart = nextStartItemIndex
      do {
        let (newItems, nextStart, maxNumItems) = try await loadPage(PageRequest(
          folderID: nil,
          startIndex: nextStartItemIndex,
          limit: Self.itemBatchSize,
          sortBy: sortBy,
          searchTerm: capturedQuery,
          recursive: false
        ))

        guard searchQuery == capturedQuery, !Task.isCancelled else { return }
        self.nextStartItemIndex = max(self.nextStartItemIndex, nextStart)
        self.items.append(contentsOf: newItems)
        let rawAdded = max(0, nextStart - previousNextStart)
        self.totalItems = updatedTotal(forRawAdded: rawAdded, serverTotal: maxNumItems)
      } catch {
        guard !Task.isCancelled, !isCancellation(error) else { return }
        self.error = error
      }
    }
  }

  private func fetchFolderItems(folderID: String) {
    fetchTask = Task { @MainActor in
      defer {
        if !Task.isCancelled { self.fetchTask = nil }
      }

      let capturedQuery = searchQuery
      let capturedFolderID = folderID
      let previousNextStart = nextStartItemIndex
      do {
        let searchParam: String? = capturedQuery.isEmpty ? nil : capturedQuery
        let (newItems, nextStart, maxNumItems) = try await loadPage(PageRequest(
          folderID: capturedFolderID,
          startIndex: nextStartItemIndex,
          limit: Self.itemBatchSize,
          sortBy: sortBy,
          searchTerm: searchParam,
          recursive: recursive
        ))

        guard searchQuery == capturedQuery, !Task.isCancelled else { return }
        self.nextStartItemIndex = max(self.nextStartItemIndex, nextStart)
        self.items.append(contentsOf: newItems)
        let rawAdded = max(0, nextStart - previousNextStart)
        self.totalItems = updatedTotal(forRawAdded: rawAdded, serverTotal: maxNumItems)
      } catch {
        guard !Task.isCancelled, !isCancellation(error) else { return }
        self.error = error
      }
    }
  }

  /// Loads every item of the level the pages haven't brought yet, in one request from where they
  /// stopped (fork, upstream #1661: select-all and the whole-level Stream acted on the loaded pages
  /// only). It takes the fetch slot, stopping a page in flight, and is stopped as a page is: the
  /// screen closing, a new search or sort. Cancelling the caller stops it too
  func loadRemainingItems() async throws {
    guard hasUnloadedItems else { return }

    cancelRemainingItemsLoad()
    fetchTask?.cancel()
    let capturedQuery = searchQuery
    // A page's request (`fetchFolderItems` / `fetchGlobalSearchItems`) without the limit
    let request = PageRequest(
      folderID: folderID,
      startIndex: nextStartItemIndex,
      limit: nil,
      sortBy: sortBy,
      searchTerm: capturedQuery.isEmpty ? nil : capturedQuery,
      recursive: folderID == nil ? false : recursive
    )
    let task = Task { @MainActor in
      let page = try await self.loadPage(request)
      // Stopped, or the search changed: whatever replaced it owns the list
      guard !Task.isCancelled, self.searchQuery == capturedQuery else {
        throw CancellationError()
      }
      self.nextStartItemIndex = max(self.nextStartItemIndex, page.nextStartIndex)
      self.items.append(contentsOf: page.items)
      // Everything is here. Not `updatedTotal`: without the server's count it publishes a page
      // past the end, which would keep paging on
      self.totalItems = self.items.count
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

  /// Stops the load of every remaining item, if one runs
  private func cancelRemainingItemsLoad() {
    guard let task = remainingItemsTask else { return }
    task.cancel()
    remainingItemsTask = nil
    isLoadingAllItems = false
    if fetchTask == task {
      fetchTask = nil
    }
  }

  /// Stops select-all and the load it waits for (or a whole-level Stream's)
  private func cancelSelectAll() {
    selectAllTask?.cancel()
    selectAllTask = nil
    cancelRemainingItemsLoad()
  }

  /// Resolves the value to publish for `totalItems` after a paginated fetch.
  /// A short page (the server returned fewer raw items than we asked for) means
  /// we've reached the end. Otherwise prefer the server's total when available,
  /// falling back to a sentinel that keeps pagination alive without exposing
  /// `Int.max` to the UI.
  ///
  /// `rawAdded` must be the count *as returned by the server*, before any
  /// client-side filtering — otherwise dropped items would be mistaken for the
  /// end of the list.
  private func updatedTotal(forRawAdded rawAdded: Int, serverTotal: Int) -> Int {
    if rawAdded < Self.itemBatchSize {
      return self.items.count
    }
    if serverTotal < Int.max {
      return max(serverTotal, self.items.count)
    }
    return self.items.count + Self.itemBatchSize
  }

  @MainActor
  func handleDoneAction() {
    onTransition?(.done)
  }

  @MainActor
  func onEditToggleSelectTapped() {
    withAnimation {
      editMode = editMode.isEditing ? .inactive : .active
    }

    if !editMode.isEditing {
      cancelSelectAll()
      selectedItems.removeAll()
    }
  }

  @MainActor
  func onSelectTapped(for item: JellyfinLibraryItem) {
    guard item.isDownloadable else { return }

    if let index = selectedItems.firstIndex(of: item.id) {
      selectedItems.remove(at: index)
    } else {
      selectedItems.insert(item.id)
    }
  }

  /// Selects every item of the level, loading the pages not loaded yet first (fork, upstream #1661: it
  /// selected the loaded pages only). A tap while that load runs stops it; with a selection, a tap
  /// clears it
  @MainActor
  func onSelectAllTapped() {
    if isLoadingAllItems {
      cancelSelectAll()
      return
    }
    guard selectedItems.isEmpty else {
      selectedItems.removeAll()
      return
    }
    guard hasUnloadedItems else {
      selectLoadedItems()
      return
    }

    selectAllTask = Task { @MainActor in
      do {
        try await loadRemainingItems()
      } catch {
        if !isCancellation(error) {
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
    // Every request failing must not read as success: surface the error already set
    // above and leave the browser open, matching the AudiobookShelf path
    guard !requests.isEmpty else { return }
    singleFileDownloadService.handleDownload(requests)
    navigation.dismiss?()
  }

  /// Resolves the request list BEFORE showing the confirmation, so the dialog states the
  /// number that will actually download rather than the number currently paged in. This is
  /// the same call the download used to make afterwards — moved, not duplicated — and
  /// `getAllAudiobookDownloadRequests` still short-circuits a fully loaded folder with no
  /// network at all.
  @MainActor
  func onDownloadFolderTapped() {
    guard let folderID, !isPreparingDownload else { return }

    isPreparingDownload = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.isPreparingDownload = false }

      do {
        let requests = try await self.getAllAudiobookDownloadRequests(for: folderID)
        // getAllAudiobookDownloadRequests swallows per-item failures with try?, so an
        // empty array means nothing could be built — say so instead of opening a
        // dialog that would download nothing.
        guard !requests.isEmpty else {
          self.error = BookPlayerError.runtimeError("download_prepare_error".localized)
          return
        }
        self.pendingDownloadRequests = requests
        self.showingDownloadConfirmation = true
      } catch {
        self.error = error
      }
    }
  }

  @MainActor
  func confirmDownloadFolder() {
    let requests = pendingDownloadRequests
    pendingDownloadRequests = []
    guard !requests.isEmpty else { return }

    singleFileDownloadService.handleDownload(requests, folderName: navigationTitle)
    navigation.dismiss?()
  }

  @MainActor
  private func getAllAudiobookDownloadRequests(for folderID: String) async throws -> [URLRequest] {
    if items.count == totalItems {
      let audiobooks = items.filter { $0.isDownloadable }
      return audiobooks.compactMap { audiobook in
        try? connectionService.createItemDownloadRequest(audiobook)
      }
    } else {
      return try await connectionService.fetchAudiobookDownloadRequests(for: folderID)
    }
  }
  
  @MainActor
  func virtualImportFolderAudiobooks(useSelectedItems: Bool) async {
    // Reentrancy guard stays per-VM (isImporting keeps private(set)); the shared
    // body lives in JellyfinFolderImporting.runFolderImport
    guard !isImporting else { return }
    isImporting = true
    defer { isImporting = false }
    await runFolderImport(useSelectedItems: useSelectedItems)
  }
  
  @MainActor
  func goToSubscribe() {
    navigation.showingSubscribe = true
  }

}

// MARK: - Author Books ViewModel

@MainActor
final class JellyfinPersonBooksViewModel: IntegrationLibraryViewModelProtocol, JellyfinFolderImporting, BPLogger {
  let role: JellyfinPersonRole
  let personID: String
  let parentID: String?

  var navigation: BPNavigation
  let navigationTitle: String

  @AppStorage(Constants.UserDefaults.jellyfinLibraryLayout)
  var layout: IntegrationLayout.Options = .grid

  @AppStorage(Constants.UserDefaults.jellyfinLibraryLayoutSortBy)
  var sortBy: JellyfinLayout.SortBy = .smart

  @Published var searchQuery = ""
  @Published var items: [JellyfinLibraryItem] = []
  @Published var totalItems = Int.max
  @Published var error: Error?
  @Published private(set) var isImporting = false
  @Published var pendingImportBatch: ExternalImportBatch?

  @Published var editMode: EditMode = .inactive
  @Published var selectedItems: Set<JellyfinLibraryItem.ID> = []
  @Published var showingDownloadConfirmation = false

  var isSearchable: Bool { true }
  /// Same reason as the persons list: `JellyfinLibraryView.sortPickerContent` only builds
  /// a picker for `JellyfinLibraryViewModel`, so leaving this on renders an empty section.
  /// Surfacing this screen's live `sortBy` would mean extending that picker — its own change.
  var showsSortPreferences: Bool { false }

  let onImportConfirmed: ([SimpleExternalResource]) -> Void
  let connectionService: JellyfinConnectionService
  var accountService: AccountService
  private let singleFileDownloadService: SingleFileDownloadService
  private var fetchTask: Task<(), any Error>?
  private var allItems: [JellyfinLibraryItem] = []
  private var disposeBag = Set<AnyCancellable>()

  init(
    role: JellyfinPersonRole,
    personID: String,
    parentID: String?,
    connectionService: JellyfinConnectionService,
    singleFileDownloadService: SingleFileDownloadService,
    onImportConfirmed: @escaping ([SimpleExternalResource]) -> Void,
    accountService: AccountService,
    navigation: BPNavigation,
    navigationTitle: String
  ) {
    self.role = role
    self.personID = personID
    self.parentID = parentID
    self.connectionService = connectionService
    self.singleFileDownloadService = singleFileDownloadService
    self.onImportConfirmed = onImportConfirmed
    self.accountService = accountService
    self.navigation = navigation
    self.navigationTitle = navigationTitle

    $searchQuery
      .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in self?.applySearch() }
      .store(in: &disposeBag)
  }

  func fetchInitialItems() {
    guard items.isEmpty, fetchTask == nil else { return }
    fetchTask = Task { @MainActor in
      defer { self.fetchTask = nil }
      do {
        let result: ([JellyfinLibraryItem], Int, Int)
        switch role {
        case .author:
          result = try await connectionService.fetchItemsByArtist(
            artistID: personID,
            parentID: parentID,
            startIndex: 0,
            limit: nil,
            sortBy: sortBy
          )
        case .narrator:
          result = try await connectionService.fetchItemsByPerson(
            personID: personID,
            personName: navigationTitle,
            parentID: parentID,
            startIndex: 0,
            limit: nil,
            sortBy: sortBy
          )
        }
        self.allItems = result.0
        applySearch()
      } catch is CancellationError {
        // ignore
      } catch {
        self.error = error
      }
    }
  }

  func fetchMoreItemsIfNeeded(currentItem: JellyfinLibraryItem) {}

  func cancelFetchItems() {
    fetchTask?.cancel()
    fetchTask = nil
  }

  func destination(for item: JellyfinLibraryItem) -> JellyfinLibraryLevelData? {
    switch item.kind {
    case .audiobook: .details(data: item)
    case .folder: .folder(data: item)
    default: nil
    }
  }

  @MainActor func handleDoneAction() {}

  @MainActor
  func onEditToggleSelectTapped() {
    withAnimation {
      editMode = editMode.isEditing ? .inactive : .active
    }
    if !editMode.isEditing { selectedItems.removeAll() }
  }

  @MainActor
  func onSelectTapped(for item: JellyfinLibraryItem) {
    guard item.isDownloadable else { return }
    if selectedItems.contains(item.id) {
      selectedItems.remove(item.id)
    } else {
      selectedItems.insert(item.id)
    }
  }

  @MainActor
  func onSelectAllTapped() {
    if selectedItems.isEmpty {
      selectedItems = Set(items.compactMap { $0.isDownloadable ? $0.id : nil })
    } else {
      selectedItems.removeAll()
    }
  }

  @MainActor
  func onDownloadTapped() {
    let downloadItems = items.filter { selectedItems.contains($0.id) && $0.isDownloadable }
    guard !downloadItems.isEmpty else { return }
    var requests = [URLRequest]()
    for item in downloadItems {
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
  func virtualImportFolderAudiobooks(useSelectedItems: Bool) async {
    // Reentrancy guard stays per-VM (isImporting keeps private(set)); the shared
    // body lives in JellyfinFolderImporting.runFolderImport
    guard !isImporting else { return }
    isImporting = true
    defer { isImporting = false }
    await runFolderImport(useSelectedItems: useSelectedItems)
  }

  /// Nothing to load: `fetchInitialItems` asks for `limit: nil`, so `items` is the whole level
  func loadRemainingItems() async throws {}

  @MainActor
  func onDownloadFolderTapped() {
    showingDownloadConfirmation = true
  }

  /// Unlike the folder VM there is no `folderID` to fetch against — this level is a query
  /// result. It doesn't need one: `fetchInitialItems` asks for `limit: nil` and
  /// `fetchMoreItemsIfNeeded` is a no-op, so `items` is always the complete level.
  @MainActor
  func confirmDownloadFolder() {
    let requests = items
      .filter { $0.isDownloadable }
      .compactMap { try? connectionService.createItemDownloadRequest($0) }

    guard !requests.isEmpty else {
      self.error = BookPlayerError.runtimeError("download_prepare_error".localized)
      return
    }

    singleFileDownloadService.handleDownload(requests, folderName: navigationTitle)
    navigation.dismiss?()
  }

  private func applySearch() {
    let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    if query.isEmpty {
      items = allItems
    } else {
      items = allItems.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
    totalItems = items.count
  }
  
  @MainActor
  func goToSubscribe() {
    navigation.showingSubscribe = true
  }

}

// MARK: - Persons List ViewModel (authors / narrators)

@MainActor
final class JellyfinPersonsListViewModel: IntegrationLibraryViewModelProtocol, BPLogger {
  let role: JellyfinPersonRole
  let parentID: String?

  var navigation: BPNavigation
  let navigationTitle: String

  @AppStorage(Constants.UserDefaults.jellyfinLibraryLayout)
  var layout: IntegrationLayout.Options = .list

  @AppStorage(Constants.UserDefaults.jellyfinLibraryLayoutSortBy)
  var sortBy: JellyfinLayout.SortBy = .name

  @Published var searchQuery = ""
  @Published var items: [JellyfinLibraryItem] = []
  @Published var totalItems = Int.max
  @Published var error: Error?

  @Published var editMode: EditMode = .inactive
  @Published var selectedItems: Set<JellyfinLibraryItem.ID> = []
  // showingDownloadConfirmation is deliberately NOT stored here — the protocol's no-op
  // default makes the confirmation structurally unpresentable on a list of people

  var isSearchable: Bool { true }
  /// People aren't importable: every editing action on this screen is a no-op, so the
  /// toolbar must not offer Select/Download over a list of authors (ABS opts out the
  /// same way for its `.entities` sources).
  var allowsEditing: Bool { false }
  /// `JellyfinLibraryView.sortPickerContent` only builds a picker for
  /// `JellyfinLibraryViewModel`, so leaving this on renders an empty section.
  var showsSortPreferences: Bool { false }

  let connectionService: JellyfinConnectionService
  var accountService: AccountService
  private let singleFileDownloadService: SingleFileDownloadService
  private var fetchTask: Task<(), any Error>?
  private var allItems: [JellyfinLibraryItem] = []
  private var disposeBag = Set<AnyCancellable>()

  init(
    role: JellyfinPersonRole,
    parentID: String?,
    connectionService: JellyfinConnectionService,
    singleFileDownloadService: SingleFileDownloadService,
    accountService: AccountService,
    navigation: BPNavigation,
    navigationTitle: String
  ) {
    self.role = role
    self.parentID = parentID
    self.connectionService = connectionService
    self.singleFileDownloadService = singleFileDownloadService
    self.accountService = accountService
    self.navigation = navigation
    self.navigationTitle = navigationTitle

    $searchQuery
      .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in self?.applyLocalSearch() }
      .store(in: &disposeBag)
  }

  func fetchInitialItems() {
    guard items.isEmpty, fetchTask == nil else { return }
    fetchTask = Task { @MainActor in
      defer { self.fetchTask = nil }
      do {
        let result: ([JellyfinLibraryItem], Int)
        switch role {
        case .author:
          result = try await connectionService.fetchAlbumArtists(parentID: parentID)
        case .narrator:
          result = try await connectionService.fetchNarrators(parentID: parentID)
        }
        let items = result.0
        self.allItems = items
        applyLocalSearch()
      } catch is CancellationError {
      } catch {
        self.error = error
      }
    }
  }

  func fetchMoreItemsIfNeeded(currentItem: JellyfinLibraryItem) {}
  func cancelFetchItems() { fetchTask?.cancel(); fetchTask = nil }

  func destination(for item: JellyfinLibraryItem) -> JellyfinLibraryLevelData? {
    switch (role, item.kind) {
    case (.author, .author):
      return .authorBooks(authorID: item.id, authorName: item.name, parentID: parentID)
    case (.narrator, .narrator):
      return .narratorBooks(personID: item.id, personName: item.name, parentID: parentID)
    default:
      return nil
    }
  }

  @MainActor func handleDoneAction() {}
  @MainActor func onEditToggleSelectTapped() {}
  @MainActor func onSelectTapped(for item: JellyfinLibraryItem) {}
  @MainActor func onSelectAllTapped() {}
  @MainActor func onDownloadTapped() {}
  @MainActor func onDownloadFolderTapped() {}
  @MainActor func confirmDownloadFolder() {}
  @Published var pendingImportBatch: ExternalImportBatch?
  @MainActor func onStreamTapped(useSelectedItems: Bool) {}
  @MainActor func confirmExternalImport(_ resources: [SimpleExternalResource]) {}

  private func applyLocalSearch() {
    let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    items = query.isEmpty ? allItems : allItems.filter { $0.name.localizedCaseInsensitiveContains(query) }
    totalItems = items.count
  }
  
  @MainActor
  func goToSubscribe() {
    navigation.showingSubscribe = true
  }
}
