//
//  IntegrationSelectAllTests.swift
//  BookPlayerTests
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

@testable import BookPlayer
@testable import BookPlayerKit
import XCTest

/// Requests a view model's seam has made, each answered (or failed) by the test
@MainActor
final class HeldRequests<Request, Response> {
  private(set) var requests: [Request] = []
  private var continuations: [CheckedContinuation<Response, Error>?] = []

  var count: Int { requests.count }

  func hold(_ request: Request) async throws -> Response {
    try await withCheckedThrowingContinuation { continuation in
      requests.append(request)
      continuations.append(continuation)
    }
  }

  func answer(_ index: Int, with response: Response) {
    continuations[index]?.resume(returning: response)
    continuations[index] = nil
  }

  func fail(_ index: Int, with error: Error) {
    continuations[index]?.resume(throwing: error)
    continuations[index] = nil
  }

  /// Answers whatever is still held, so no continuation leaks
  func drain(with response: Response) {
    for index in continuations.indices {
      answer(index, with: response)
    }
  }
}

@MainActor
private func makeAccountService() -> AccountService {
  let accountService = AccountService()
  accountService.setup(
    dataManager: DataManager(coreDataStack: CoreDataStack(testPath: "/dev/null")),
    client: NetworkClientMock(mockedResponse: Empty()),
    keychain: KeychainServiceMock()
  )
  return accountService
}

/// A request a test waited for didn't come
private struct MissingRequests: Error {}

/// Lets the view model's tasks run up to their next wait
@MainActor
private func settle() async {
  for _ in 0..<5 {
    await Task.yield()
  }
  try? await Task.sleep(nanoseconds: 50_000_000)
}

// MARK: - Jellyfin

/// Select-all and the whole-level Stream act on the whole level, not the pages loaded (fork, upstream
/// #1661). A folder of 45 books, paged 20 at a time
@MainActor
final class JellyfinSelectAllTests: XCTestCase {
  private typealias ViewModel = JellyfinLibraryViewModel

  private var viewModel: ViewModel!
  private var held: HeldRequests<ViewModel.PageRequest, ViewModel.Page>!

  override func setUp() {
    super.setUp()
    let held = HeldRequests<ViewModel.PageRequest, ViewModel.Page>()
    self.held = held
    viewModel = ViewModel(
      folderID: "folder",
      connectionService: JellyfinConnectionService(keychainService: KeychainServiceMock()),
      singleFileDownloadService: SingleFileDownloadService(networkClient: NetworkClientMock(mockedResponse: Empty())),
      onImportConfirmed: { _ in },
      accountService: makeAccountService(),
      navigation: BPNavigation(),
      navigationTitle: "Folder"
    )
    viewModel.loadPage = { request in
      try await held.hold(request)
    }
  }

  override func tearDown() {
    held.drain(with: ([], 0, 0))
    viewModel = nil
    held = nil
    super.tearDown()
  }

  private func books(_ range: Range<Int>) -> [JellyfinLibraryItem] {
    range.map { JellyfinLibraryItem(id: "b\($0)", name: "Book \($0)", kind: .audiobook) }
  }

  /// Waits for `count` requests. Fewer fail the test and stop it, so it never reads one that didn't come
  private func waitForRequests(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
    for _ in 0..<100 where held.count < count {
      await settle()
    }
    XCTAssertEqual(held.count, count, file: file, line: line)
    guard held.count >= count else { throw MissingRequests() }
  }

  /// The first page, 20 of the folder's 45 (or of an unknown number when the server leaves its count out)
  private func loadFirstPage(serverTotal: Int = 45) async throws {
    viewModel.fetchInitialItems()
    try await waitForRequests(1)
    held.answer(0, with: (books(0..<20), 20, serverTotal))
    await settle()
    XCTAssertEqual(viewModel.items.count, 20)
  }

  private func startSelecting() {
    viewModel.onEditToggleSelectTapped()
    XCTAssertTrue(viewModel.editMode.isEditing)
  }

  /// What the load asks for: the page's request from where the pages stopped, without a limit
  private func assertLoadsTheRest(_ request: ViewModel.PageRequest, from startIndex: Int, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(
      request,
      ViewModel.PageRequest(
        folderID: "folder",
        startIndex: startIndex,
        limit: nil,
        sortBy: viewModel.sortBy,
        searchTerm: nil,
        recursive: false
      ),
      file: file,
      line: line
    )
  }

  func testSelectAllLoadsTheRestThenSelectsEveryBook() async throws {
    try await loadFirstPage()
    startSelecting()

    viewModel.onSelectAllTapped()
    try await waitForRequests(2)
    assertLoadsTheRest(held.requests[1], from: 20)
    XCTAssertTrue(viewModel.isLoadingAllItems)
    XCTAssertTrue(viewModel.selectedItems.isEmpty, "nothing is selected until everything is here")

    held.answer(1, with: (books(20..<45), 45, 45))
    await settle()

    XCTAssertEqual(viewModel.items.map(\.id), books(0..<45).map(\.id))
    XCTAssertEqual(viewModel.selectedItems, Set(books(0..<45).map(\.id)))
    XCTAssertEqual(viewModel.totalItems, 45)
    XCTAssertFalse(viewModel.canFetchMoreItems)
    XCTAssertFalse(viewModel.isLoadingAllItems)
    XCTAssertNil(viewModel.error)
    XCTAssertEqual(held.count, 2, "asked once")
  }

  /// Without the server's count, paging publishes a placeholder a page past what's loaded; the load
  /// ends it at the real count
  func testWithoutAServerCountTheTotalEndsAtTheRealCount() async throws {
    try await loadFirstPage(serverTotal: Int.max)
    XCTAssertEqual(viewModel.totalItems, 40)
    startSelecting()

    viewModel.onSelectAllTapped()
    try await waitForRequests(2)
    assertLoadsTheRest(held.requests[1], from: 20)
    held.answer(1, with: (books(20..<45), 45, Int.max))
    await settle()

    XCTAssertEqual(viewModel.selectedItems.count, 45)
    XCTAssertEqual(viewModel.totalItems, 45)
    XCTAssertFalse(viewModel.canFetchMoreItems)
  }

  func testWithEverythingLoadedSelectAllAsksNothing() async throws {
    viewModel.fetchInitialItems()
    try await waitForRequests(1)
    held.answer(0, with: (books(0..<15), 15, 15))
    await settle()
    startSelecting()

    viewModel.onSelectAllTapped()

    XCTAssertEqual(viewModel.selectedItems.count, 15)
    await settle()
    XCTAssertEqual(held.count, 1)
  }

  func testASecondTapStopsTheLoadAndPagingCarriesOn() async throws {
    try await loadFirstPage()
    startSelecting()
    viewModel.onSelectAllTapped()
    try await waitForRequests(2)

    viewModel.onSelectAllTapped()
    XCTAssertFalse(viewModel.isLoadingAllItems)

    held.answer(1, with: (books(20..<45), 45, 45))
    await settle()
    XCTAssertEqual(viewModel.items.count, 20, "the stopped load adds nothing")
    XCTAssertTrue(viewModel.selectedItems.isEmpty)
    XCTAssertNil(viewModel.error)

    viewModel.fetchMoreItemsIfNeeded(currentItem: viewModel.items[19])
    try await waitForRequests(3)
    XCTAssertEqual(held.requests[2].startIndex, 20)
    XCTAssertEqual(held.requests[2].limit, 20, "the next page, as before")
  }

  /// GPT: a page still on its way when select-all starts is stopped. When its answer comes it adds
  /// nothing and leaves the slot to the load, which a second tap can still stop
  func testAPageInFlightWhenSelectAllStartsIsDropped() async throws {
    viewModel.fetchInitialItems()
    try await waitForRequests(1)
    startSelecting()

    viewModel.onSelectAllTapped()
    try await waitForRequests(2)
    assertLoadsTheRest(held.requests[1], from: 0)

    held.answer(0, with: (books(0..<20), 20, 45))
    await settle()
    XCTAssertTrue(viewModel.items.isEmpty, "the stopped page adds nothing")
    XCTAssertTrue(viewModel.isLoadingAllItems)
    viewModel.fetchInitialItems()
    await settle()
    XCTAssertEqual(held.count, 2, "the load kept the slot, so no page started alongside it")

    viewModel.onSelectAllTapped()
    XCTAssertFalse(viewModel.isLoadingAllItems)
    held.answer(1, with: (books(0..<45), 45, 45))
    await settle()
    XCTAssertTrue(viewModel.items.isEmpty)
    XCTAssertTrue(viewModel.selectedItems.isEmpty)
    XCTAssertNil(viewModel.error)
  }

  /// URLSession, under Get, ends a cancelled request with `URLError.cancelled`: no error to show
  func testAStoppedPagesCancellationIsNoError() async throws {
    viewModel.fetchInitialItems()
    try await waitForRequests(1)
    startSelecting()
    viewModel.onSelectAllTapped()
    try await waitForRequests(2)

    held.fail(0, with: URLError(.cancelled))
    await settle()

    XCTAssertNil(viewModel.error)
  }

  func testClosingTheScreenStopsTheLoad() async throws {
    try await loadFirstPage()
    startSelecting()
    viewModel.onSelectAllTapped()
    try await waitForRequests(2)

    viewModel.cancelFetchItems()
    XCTAssertFalse(viewModel.isLoadingAllItems)
    held.fail(1, with: URLError(.cancelled))
    await settle()

    XCTAssertEqual(viewModel.items.count, 20)
    XCTAssertTrue(viewModel.selectedItems.isEmpty)
    XCTAssertNil(viewModel.error)
  }

  func testLeavingSelectionStopsTheLoad() async throws {
    try await loadFirstPage()
    startSelecting()
    viewModel.onSelectAllTapped()
    try await waitForRequests(2)

    viewModel.onEditToggleSelectTapped()
    XCTAssertFalse(viewModel.isLoadingAllItems)
    held.answer(1, with: (books(20..<45), 45, 45))
    await settle()

    XCTAssertTrue(viewModel.selectedItems.isEmpty, "nothing selected outside selection")
    XCTAssertEqual(viewModel.items.count, 20)
  }

  /// The search changed while the load ran: its answer belongs to the old search
  func testALoadAnsweredAfterTheSearchChangedIsDropped() async throws {
    try await loadFirstPage()
    startSelecting()
    viewModel.onSelectAllTapped()
    try await waitForRequests(2)

    viewModel.searchQuery = "dune"
    held.answer(1, with: (books(20..<45), 45, 45))
    await settle()

    XCTAssertEqual(viewModel.items.count, 20)
    XCTAssertTrue(viewModel.selectedItems.isEmpty)
    XCTAssertFalse(viewModel.isLoadingAllItems)
    XCTAssertNil(viewModel.error)
  }

  func testAFailedLoadIsShownAndSelectsNothing() async throws {
    try await loadFirstPage()
    startSelecting()
    viewModel.onSelectAllTapped()
    try await waitForRequests(2)

    held.fail(1, with: URLError(.badServerResponse))
    await settle()

    XCTAssertEqual((viewModel.error as? URLError)?.code, .badServerResponse)
    XCTAssertTrue(viewModel.selectedItems.isEmpty)
    XCTAssertFalse(viewModel.isLoadingAllItems)
  }

  func testTheWholeLevelsStreamTakesEveryBook() async throws {
    try await loadFirstPage()

    let candidates = Task { try await self.viewModel.importCandidates(useSelectedItems: false) }
    try await waitForRequests(2)
    assertLoadsTheRest(held.requests[1], from: 20)
    held.answer(1, with: (books(20..<45), 45, 45))

    let streamed = try await candidates.value
    XCTAssertEqual(streamed.map(\.id), books(0..<45).map(\.id))
  }

  /// Through the Stream's own entry: the load runs before the import (whose hydration then fails here,
  /// with no server to ask)
  func testTheWholeLevelsStreamLoadsTheRestFirst() async throws {
    try await loadFirstPage()

    let streaming = Task { await self.viewModel.virtualImportFolderAudiobooks(useSelectedItems: false) }
    try await waitForRequests(2)
    assertLoadsTheRest(held.requests[1], from: 20)
    held.answer(1, with: (books(20..<45), 45, 45))
    await streaming.value

    XCTAssertEqual(viewModel.items.count, 45)
  }

  /// A selection streams in the order shown, not the set's
  func testASelectionStreamsInTheOrderShown() async throws {
    viewModel.fetchInitialItems()
    try await waitForRequests(1)
    held.answer(0, with: (books(0..<15), 15, 15))
    await settle()
    startSelecting()
    for index in [12, 3, 9, 0, 14, 6, 1, 11, 7, 4] {
      viewModel.onSelectTapped(for: viewModel.items[index])
    }

    let streamed = try await viewModel.importCandidates(useSelectedItems: true)

    XCTAssertEqual(streamed.map(\.id), ["b0", "b1", "b3", "b4", "b6", "b7", "b9", "b11", "b12", "b14"])
    XCTAssertEqual(held.count, 1, "a selection loads nothing")
  }
}

// MARK: - Audiobookshelf

/// The same on Audiobookshelf's Books tab, the one paged level there, plus the whole-level Download,
/// whose dialog says how many books will download
@MainActor
final class AudiobookShelfSelectAllTests: XCTestCase {
  private typealias ViewModel = AudiobookShelfLibraryViewModel
  private typealias Answer = (items: [AudiobookShelfLibraryItem], total: Int)

  private var viewModel: ViewModel!
  private var held: HeldRequests<ViewModel.BooksPageRequest, Answer>!
  /// The searches, by query
  private var searches: HeldRequests<String, [AudiobookShelfLibraryItem]>!

  override func setUp() {
    super.setUp()
    let held = HeldRequests<ViewModel.BooksPageRequest, Answer>()
    let searches = HeldRequests<String, [AudiobookShelfLibraryItem]>()
    self.held = held
    self.searches = searches
    viewModel = ViewModel(
      source: .books(libraryID: "lib", filter: nil),
      connectionService: AudiobookShelfConnectionService(keychainService: KeychainServiceMock()),
      singleFileDownloadService: SingleFileDownloadService(networkClient: NetworkClientMock(mockedResponse: Empty())),
      accountService: makeAccountService(),
      onImportConfirmed: { _ in },
      navigation: BPNavigation(),
      navigationTitle: "Books",
      // A query a test sets never refetches on its own: the test drives every fetch
      searchDebounce: .seconds(3600)
    )
    viewModel.loadBooksPage = { request in
      try await held.hold(request)
    }
    viewModel.loadSearchResults = { _, query in
      try await searches.hold(query)
    }
  }

  override func tearDown() {
    held.drain(with: ([], 0))
    searches.drain(with: [])
    viewModel = nil
    held = nil
    searches = nil
    super.tearDown()
  }

  private func books(_ range: Range<Int>) -> [AudiobookShelfLibraryItem] {
    range.map { AudiobookShelfLibraryItem(id: "b\($0)", title: "Book \($0)", kind: .audiobook, libraryId: "lib") }
  }

  /// Waits for `count` requests. Fewer fail the test and stop it, so it never reads one that didn't come
  private func waitForRequests(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
    for _ in 0..<100 where held.count < count {
      await settle()
    }
    XCTAssertEqual(held.count, count, file: file, line: line)
    guard held.count >= count else { throw MissingRequests() }
  }

  /// Waits for `count` searches, as `waitForRequests` does for pages
  private func waitForSearches(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
    for _ in 0..<100 where searches.count < count {
      await settle()
    }
    XCTAssertEqual(searches.count, count, file: file, line: line)
    guard searches.count >= count else { throw MissingRequests() }
  }

  /// A search for "dune" on the Books tab, its answer held
  private func startSearch() async throws {
    viewModel.searchQuery = "dune"
    viewModel.fetchInitialItems()
    try await waitForSearches(1)
    XCTAssertEqual(searches.requests[0], "dune")
  }

  private func loadFirstPage() async throws {
    viewModel.fetchInitialItems()
    try await waitForRequests(1)
    XCTAssertEqual(held.requests[0].limit, 20)
    held.answer(0, with: (books(0..<20), 45))
    await settle()
    XCTAssertEqual(viewModel.items.count, 20)
  }

  private func startSelecting() {
    viewModel.onEditToggleSelectTapped()
    XCTAssertTrue(viewModel.editMode.isEditing)
  }

  /// What the load asks for: every book (limit 0) in the pages' sort
  private func assertLoadsEverything(_ request: ViewModel.BooksPageRequest, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(request.libraryID, "lib", file: file, line: line)
    XCTAssertEqual(request.limit, 0, file: file, line: line)
    XCTAssertEqual(request.page, 0, file: file, line: line)
    XCTAssertEqual(request.sortBy, held.requests[0].sortBy, "the pages' sort", file: file, line: line)
    XCTAssertEqual(request.desc, held.requests[0].desc, file: file, line: line)
  }

  func testSelectAllLoadsTheRestThenSelectsEveryBook() async throws {
    try await loadFirstPage()
    startSelecting()

    viewModel.onSelectAllTapped()
    try await waitForRequests(2)
    assertLoadsEverything(held.requests[1])
    XCTAssertTrue(viewModel.isLoadingAllItems)
    XCTAssertTrue(viewModel.selectedItems.isEmpty)

    held.answer(1, with: (books(0..<45), 45))
    await settle()

    XCTAssertEqual(viewModel.items.map(\.id), books(0..<45).map(\.id), "the whole tab replaces the pages")
    XCTAssertEqual(viewModel.selectedItems, Set(books(0..<45).map(\.id)))
    XCTAssertEqual(viewModel.totalItems, 45)
    XCTAssertFalse(viewModel.isLoadingAllItems)
    XCTAssertNil(viewModel.error)
    XCTAssertEqual(held.count, 2, "asked once")
  }

  /// The server counts rows the app can't read. The tab's own count is the total, so paging stops
  /// instead of asking for books that never come
  func testTheTotalIsTheBooksTheAppGot() async throws {
    try await loadFirstPage()
    startSelecting()
    viewModel.onSelectAllTapped()
    try await waitForRequests(2)

    held.answer(1, with: (books(0..<43), 45))
    await settle()

    XCTAssertEqual(viewModel.totalItems, 43)
    XCTAssertEqual(viewModel.selectedItems.count, 43)
    viewModel.fetchMoreItemsIfNeeded(currentItem: viewModel.items[42])
    await settle()
    XCTAssertEqual(held.count, 2, "no more pages")
  }

  func testASecondTapStopsTheLoadAndPagingCarriesOn() async throws {
    try await loadFirstPage()
    startSelecting()
    viewModel.onSelectAllTapped()
    try await waitForRequests(2)

    viewModel.onSelectAllTapped()
    XCTAssertFalse(viewModel.isLoadingAllItems)

    held.answer(1, with: (books(0..<45), 45))
    await settle()
    XCTAssertEqual(viewModel.items.count, 20, "the stopped load replaces nothing")
    XCTAssertTrue(viewModel.selectedItems.isEmpty)
    XCTAssertNil(viewModel.error)

    viewModel.fetchMoreItemsIfNeeded(currentItem: viewModel.items[19])
    try await waitForRequests(3)
    XCTAssertEqual(held.requests[2].page, 1)
    XCTAssertEqual(held.requests[2].limit, 20, "the next page, as before")
  }

  /// GPT: the first page still on its way when select-all starts is stopped. When its answer comes it
  /// adds nothing and leaves the slot to the load, which a second tap can still stop
  func testAPageInFlightWhenSelectAllStartsIsDropped() async throws {
    viewModel.fetchInitialItems()
    try await waitForRequests(1)
    startSelecting()

    viewModel.onSelectAllTapped()
    try await waitForRequests(2)
    assertLoadsEverything(held.requests[1])

    held.answer(0, with: (books(0..<20), 45))
    await settle()
    XCTAssertTrue(viewModel.items.isEmpty, "the stopped page adds nothing")
    XCTAssertTrue(viewModel.isLoadingAllItems)
    viewModel.fetchInitialItems()
    await settle()
    XCTAssertEqual(held.count, 2, "the load kept the slot, so no page started alongside it")
    XCTAssertTrue(viewModel.editMode.isEditing)

    viewModel.onSelectAllTapped()
    XCTAssertFalse(viewModel.isLoadingAllItems)
    held.answer(1, with: (books(0..<45), 45))
    await settle()
    XCTAssertTrue(viewModel.items.isEmpty)
    XCTAssertTrue(viewModel.selectedItems.isEmpty)
    XCTAssertNil(viewModel.error)
  }

  /// URLSession ends a cancelled request with `URLError.cancelled`: no error to show
  func testAStoppedPagesCancellationIsNoError() async throws {
    viewModel.fetchInitialItems()
    try await waitForRequests(1)
    startSelecting()
    viewModel.onSelectAllTapped()
    try await waitForRequests(2)

    held.fail(0, with: URLError(.cancelled))
    await settle()

    XCTAssertNil(viewModel.error)
  }

  func testClosingTheScreenStopsTheLoad() async throws {
    try await loadFirstPage()
    startSelecting()
    viewModel.onSelectAllTapped()
    try await waitForRequests(2)

    viewModel.cancelFetchItems()
    XCTAssertFalse(viewModel.isLoadingAllItems)
    held.fail(1, with: URLError(.cancelled))
    await settle()

    XCTAssertEqual(viewModel.items.count, 20)
    XCTAssertTrue(viewModel.selectedItems.isEmpty)
    XCTAssertNil(viewModel.error)
  }

  func testLeavingSelectionStopsTheLoad() async throws {
    try await loadFirstPage()
    startSelecting()
    viewModel.onSelectAllTapped()
    try await waitForRequests(2)

    viewModel.onEditToggleSelectTapped()
    XCTAssertFalse(viewModel.isLoadingAllItems)
    held.answer(1, with: (books(0..<45), 45))
    await settle()

    XCTAssertTrue(viewModel.selectedItems.isEmpty, "nothing selected outside selection")
    XCTAssertEqual(viewModel.items.count, 20)
  }

  func testALoadAnsweredAfterASearchStartedIsDropped() async throws {
    try await loadFirstPage()
    startSelecting()
    viewModel.onSelectAllTapped()
    try await waitForRequests(2)

    viewModel.searchQuery = "dune"
    held.answer(1, with: (books(0..<45), 45))
    await settle()

    XCTAssertEqual(viewModel.items.count, 20)
    XCTAssertTrue(viewModel.selectedItems.isEmpty)
    XCTAssertFalse(viewModel.isLoadingAllItems)
    XCTAssertNil(viewModel.error)
  }

  func testAFailedLoadIsShownAndSelectsNothing() async throws {
    try await loadFirstPage()
    startSelecting()
    viewModel.onSelectAllTapped()
    try await waitForRequests(2)

    held.fail(1, with: URLError(.badServerResponse))
    await settle()

    XCTAssertEqual((viewModel.error as? URLError)?.code, .badServerResponse)
    XCTAssertTrue(viewModel.selectedItems.isEmpty)
    XCTAssertFalse(viewModel.isLoadingAllItems)
  }

  func testTheWholeLevelsStreamTakesEveryBook() async throws {
    try await loadFirstPage()

    let candidates = Task { try await self.viewModel.importCandidates(useSelectedItems: false) }
    try await waitForRequests(2)
    assertLoadsEverything(held.requests[1])
    held.answer(1, with: (books(0..<45), 45))

    let streamed = try await candidates.value
    XCTAssertEqual(streamed.map(\.id), books(0..<45).map(\.id))
  }

  /// Through the Stream's own entry: the load runs before the import (whose hydration then fails here,
  /// with no server to ask)
  func testTheWholeLevelsStreamLoadsTheRestFirst() async throws {
    try await loadFirstPage()

    let streaming = Task { await self.viewModel.virtualImportFolderAudiobooks(useSelectedItems: false) }
    try await waitForRequests(2)
    assertLoadsEverything(held.requests[1])
    held.answer(1, with: (books(0..<45), 45))
    await streaming.value

    XCTAssertEqual(viewModel.items.count, 45)
  }

  /// The dialog shows only once every book is here, and counts them all
  func testTheWholeLevelsDownloadCountsEveryBook() async throws {
    try await loadFirstPage()

    viewModel.onDownloadFolderTapped()
    try await waitForRequests(2)
    assertLoadsEverything(held.requests[1])
    XCTAssertFalse(viewModel.showingDownloadConfirmation, "not before the count is known")
    XCTAssertTrue(viewModel.isLoadingAllItems)

    held.answer(1, with: (books(0..<45), 45))
    await settle()

    XCTAssertTrue(viewModel.showingDownloadConfirmation)
    XCTAssertEqual(viewModel.downloadableItemCount, 45)
    XCTAssertFalse(viewModel.isLoadingAllItems)
  }

  func testAStoppedDownloadLoadShowsNoDialog() async throws {
    try await loadFirstPage()
    viewModel.onDownloadFolderTapped()
    try await waitForRequests(2)

    viewModel.cancelFetchItems()
    held.answer(1, with: (books(0..<45), 45))
    await settle()

    XCTAssertFalse(viewModel.showingDownloadConfirmation)
    XCTAssertNil(viewModel.error)
  }

  // MARK: - A superseded search (GPT, changes round 1)

  /// The screen closes while a search is on its way and opens again, asking again. The first search's late
  /// answer shows nothing and leaves the slot to the second, so no third search starts beside it
  func testAStoppedSearchStaysSilentAndKeepsItsReplacementsHandle() async throws {
    try await startSearch()
    viewModel.cancelFetchItems()
    viewModel.fetchInitialItems()
    try await waitForSearches(2)

    searches.answer(0, with: books(0..<5))
    await settle()
    XCTAssertTrue(viewModel.items.isEmpty, "the stopped search's answer shows nothing")
    viewModel.fetchInitialItems()
    await settle()
    XCTAssertEqual(searches.count, 2, "the second search kept the slot, so no third one started")

    searches.answer(1, with: books(0..<3))
    await settle()
    XCTAssertEqual(viewModel.items.count, 3)
  }

  /// GPT's sequence: a search on its way, the query cleared (the search stopped, the first page asked
  /// for), then select-all. The search's late answer, during the load or after it, never puts its results
  /// over the tab, and never frees the load's slot for a page beside it
  func testAStoppedSearchNeverTakesBackTheTab() async throws {
    try await startSearch()
    viewModel.searchQuery = ""
    viewModel.cancelFetchItems()
    try await loadFirstPage()
    startSelecting()
    viewModel.onSelectAllTapped()
    try await waitForRequests(2)

    searches.answer(0, with: books(0..<5))
    await settle()
    XCTAssertEqual(viewModel.items.count, 20, "the stopped search's answer replaces nothing")
    viewModel.fetchMoreItemsIfNeeded(currentItem: viewModel.items[19])
    await settle()
    XCTAssertEqual(held.count, 2, "the load kept the slot, so no page started beside it")

    held.answer(1, with: (books(0..<45), 45))
    await settle()
    XCTAssertEqual(viewModel.items.count, 45)
    XCTAssertEqual(viewModel.selectedItems.count, 45)
    XCTAssertEqual(viewModel.totalItems, 45)
  }

  /// The query changed while the search was on its way: its answer is for the old query
  func testASearchAnsweredAfterTheQueryChangedShowsNothing() async throws {
    try await startSearch()
    viewModel.searchQuery = "dune messiah"

    searches.answer(0, with: books(0..<5))
    await settle()

    XCTAssertTrue(viewModel.items.isEmpty)
    XCTAssertNil(viewModel.error)
  }

  /// URLSession ends a cancelled search with `URLError.cancelled`: no error to show
  func testAStoppedSearchsCancellationIsNoError() async throws {
    try await startSearch()
    viewModel.cancelFetchItems()

    searches.fail(0, with: URLError(.cancelled))
    await settle()

    XCTAssertNil(viewModel.error)
  }

  /// A selection streams in the order shown, not the set's
  func testASelectionStreamsInTheOrderShown() async throws {
    try await loadFirstPage()
    startSelecting()
    for index in [12, 3, 9, 0, 14, 6, 1, 11, 7, 4] {
      viewModel.onSelectTapped(for: viewModel.items[index])
    }

    let streamed = try await viewModel.importCandidates(useSelectedItems: true)

    XCTAssertEqual(streamed.map(\.id), ["b0", "b1", "b3", "b4", "b6", "b7", "b9", "b11", "b12", "b14"])
    XCTAssertEqual(held.count, 1, "a selection loads nothing")
  }
}
