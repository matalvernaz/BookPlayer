//
//  HummingbirdLoanTests.swift
//  BookPlayerTests
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

@testable import BookPlayer
@testable import BookPlayerKit
import XCTest

/// A library with media-server provenance, on a throwaway Core Data store and a suite of defaults
@MainActor
class HummingbirdLibraryTestCase: XCTestCase {
  var suiteName: String!
  var defaults: UserDefaults!
  var store: MediaServerSourceStore!
  var libraryService: LibraryService!
  /// Files made immutable to make a delete fail; made mutable again before cleanup
  private var lockedFiles = [URL]()

  override func setUp() {
    super.setUp()
    DataTestUtils.clearFolderContents(url: DataManager.getProcessedFolderURL())
    suiteName = "\(type(of: self)).\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    store = MediaServerSourceStore(userDefaults: defaults)
    libraryService = LibraryService()
    libraryService.setup(
      dataManager: DataManager(coreDataStack: CoreDataStack(testPath: "/dev/null")),
      audioMetadataService: AudioMetadataService()
    )
    libraryService.mediaServerSourceStore = store
    _ = libraryService.getLibrary()
  }

  override func tearDown() {
    for url in lockedFiles {
      setImmutable(url, false)
    }
    lockedFiles = []
    DataTestUtils.clearFolderContents(url: DataManager.getProcessedFolderURL())
    defaults.removePersistentDomain(forName: suiteName)
    libraryService = nil
    store = nil
    defaults = nil
    super.tearDown()
  }

  func loan(_ itemId: String, connection: String = "home", due: Date? = nil) -> MediaServerSourceInfo {
    MediaServerSourceInfo(kind: .hummingbird, connectionId: connection, itemId: itemId, dueDate: due)
  }

  func rootBook(_ title: String) -> Book {
    let book = StubFactory.book(dataManager: libraryService.dataManager, title: title, duration: 100)
    libraryService.getLibraryReference().addToItems(book)
    libraryService.dataManager.saveContext()
    return book
  }

  /// A folder at the root holding a book per title
  func folder(_ title: String, books: [String]) throws -> Folder {
    let folder = try StubFactory.folder(dataManager: libraryService.dataManager, title: title)
    libraryService.getLibraryReference().addToItems(folder)
    let made = books.map { rootBook($0) }
    try libraryService.moveItems(
      made.map { LibraryItemRef(relativePath: $0.relativePath, uuid: $0.uuid) },
      inside: folder.relativePath
    )
    return folder
  }

  func simple(_ relativePath: String) throws -> SimpleLibraryItem {
    try XCTUnwrap(libraryService.getSimpleItem(with: relativePath))
  }

  private func setImmutable(_ url: URL, _ immutable: Bool) {
    var url = url
    var values = URLResourceValues()
    values.isUserImmutable = immutable
    try? url.setResourceValues(values)
  }

  /// Makes the item's file refuse to be deleted
  func lock(_ relativePath: String) {
    let url = DataManager.getProcessedFolderURL().appendingPathComponent(relativePath)
    setImmutable(url, true)
    lockedFiles.append(url)
  }
}

// MARK: - What a delete took

/// The two reads around a user's delete: what it could take, then which server items it left no
/// copy of. Identities, not paths: a "folder only" delete moves books, a failed batch keeps some
final class MediaServerDeletionTests: HummingbirdLibraryTestCase {
  private func deleteAndCollect(_ items: [SimpleLibraryItem], mode: DeleteMode) -> (gone: [MediaServerSourceInfo], error: Error?) {
    let snapshot = MediaServerDeletion.snapshot(of: items, mode: mode, store: store)
    var thrown: Error?
    do {
      try libraryService.delete(items, mode: mode)
    } catch {
      thrown = error
    }
    return (MediaServerDeletion.gone(from: snapshot, store: store), thrown)
  }

  /// A plain folder has no entry of its own; its loans are under it
  func testDeletingAFolderReturnsTheLoansInIt() throws {
    _ = try folder("Shelf", books: ["a", "b"])
    store.setSource(loan("1"), for: "Shelf/a.txt")
    store.setSource(loan("2"), for: "Shelf/b.txt")

    let result = deleteAndCollect([try simple("Shelf")], mode: .deep)

    XCTAssertNil(result.error)
    XCTAssertEqual(Set(result.gone.map(\.itemId)), ["1", "2"])
  }

  /// "Delete folder only" keeps the books, moved up with their entries
  func testDeletingOnlyAFolderReturnsNothing() throws {
    _ = try folder("Shelf", books: ["a"])
    store.setSource(loan("1"), for: "Shelf/a.txt")

    let result = deleteAndCollect([try simple("Shelf")], mode: .shallow)

    XCTAssertNil(result.error)
    XCTAssertTrue(result.gone.isEmpty)
    XCTAssertEqual(store.source(for: "a.txt"), loan("1"))
  }

  /// A downloaded DAISY book is a bound folder whose own entry is its provenance: deleted with its
  /// audio it's returned once, however many of its entries name the book. "Folder only" keeps the
  /// audio, so it isn't a return (the delete dialog only offers that for plain folders anyway)
  func testABoundBookIsReturnedOnlyWithItsAudio() throws {
    _ = try folder("Kept", books: ["k1", "k2"])
    try libraryService.updateFolder(at: "Kept", type: .bound)
    store.setSource(MediaServerSourceInfo(kind: .hummingbird, connectionId: "home", itemId: "8", shouldBindFolder: true), for: "Kept")
    _ = try folder("Deleted", books: ["d1", "d2"])
    try libraryService.updateFolder(at: "Deleted", type: .bound)
    store.setSource(MediaServerSourceInfo(kind: .hummingbird, connectionId: "home", itemId: "9", shouldBindFolder: true), for: "Deleted")
    store.setSource(loan("9"), for: "Deleted/d1.txt")

    let shallow = deleteAndCollect([try simple("Kept")], mode: .shallow)
    let deep = deleteAndCollect([try simple("Deleted")], mode: .deep)

    XCTAssertNil(shallow.error)
    XCTAssertTrue(shallow.gone.isEmpty)
    XCTAssertNil(deep.error)
    XCTAssertEqual(deep.gone.map(\.itemId), ["9"])
  }

  /// A delete that fails on its second book has still deleted the first
  func testABatchThatFailsPartwayReturnsWhatItDeleted() throws {
    let first = rootBook("first")
    let second = rootBook("second")
    store.setSource(loan("1"), for: first.relativePath)
    store.setSource(loan("2"), for: second.relativePath)
    lock(second.relativePath)

    let result = deleteAndCollect([try simple(first.relativePath), try simple(second.relativePath)], mode: .deep)

    XCTAssertNotNil(result.error)
    XCTAssertEqual(result.gone.map(\.itemId), ["1"])
  }

  func testAnotherCopyOfTheBookKeepsTheLoan() throws {
    let copy = rootBook("copy")
    let other = rootBook("other-copy")
    store.setSource(loan("5"), for: copy.relativePath)
    store.setSource(loan("5"), for: other.relativePath)

    let result = deleteAndCollect([try simple(copy.relativePath)], mode: .deep)

    XCTAssertTrue(result.gone.isEmpty)
  }

  /// The same number on another server is another book
  func testACopyFromAnotherServerIsAnotherLoan() throws {
    let copy = rootBook("copy")
    let other = rootBook("other-server")
    store.setSource(loan("5"), for: copy.relativePath)
    store.setSource(loan("5", connection: "elsewhere"), for: other.relativePath)

    let result = deleteAndCollect([try simple(copy.relativePath)], mode: .deep)

    XCTAssertEqual(result.gone, [loan("5")])
  }

  func testTheGoneItemsArePostedForWhoeverReturnsThem() throws {
    let book = rootBook("posted")
    store.setSource(loan("6"), for: book.relativePath)
    let items = [try simple(book.relativePath)]
    let snapshot = MediaServerDeletion.snapshot(of: items, mode: .deep, store: store)
    try libraryService.delete(items, mode: .deep)
    let expected = [loan("6")]
    let posted = expectation(forNotification: .mediaServerItemsDeleted, object: nil) { notification in
      (notification.userInfo?[MediaServerDeletion.entriesKey] as? [MediaServerSourceInfo]) == expected
    }

    MediaServerDeletion.postGone(from: snapshot, store: store)

    wait(for: [posted], timeout: 1)
  }

  func testNothingIsPostedWhenNothingWentAway() throws {
    let book = rootBook("plain")
    let items = [try simple(book.relativePath)]
    let snapshot = MediaServerDeletion.snapshot(of: items, mode: .deep, store: store)
    try libraryService.delete(items, mode: .deep)
    let posted = expectation(forNotification: .mediaServerItemsDeleted, object: nil)
    posted.isInverted = true

    MediaServerDeletion.postGone(from: snapshot, store: store)

    wait(for: [posted], timeout: 0.3)
  }
}

// MARK: - Returning loans on delete

@MainActor
final class HummingbirdLoanReturnsTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var http: HummingbirdHTTPStub!
  private var service: HummingbirdConnectionService!

  override func setUpWithError() throws {
    try super.setUpWithError()
    suiteName = "HummingbirdLoanReturnsTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    let keychain = KeychainServiceMock()
    try keychain.set(
      [
        HummingbirdConnectionData(id: "home", url: URL(string: "https://hb.example.com")!, serverName: "home", userName: "a", password: "1"),
        HummingbirdConnectionData(id: "other", url: URL(string: "https://other.example.com")!, serverName: "other", userName: "b", password: "2"),
      ],
      key: .hummingbirdConnection
    )
    http = HummingbirdHTTPStub()
    service = HummingbirdConnectionService(keychainService: keychain, httpClient: http, defaults: defaults)
    service.setup()
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    service = nil
    http = nil
    defaults = nil
    super.tearDown()
  }

  func testEachHummingbirdBookGoesBackToItsOwnServer() async {
    let returns = HummingbirdLoanReturns(connectionService: service)

    await returns.returnLoans(for: [
      MediaServerSourceInfo(kind: .hummingbird, connectionId: "other", itemId: "88"),
      // A number the Hummingbird server would accept, so only the kind keeps it from being sent
      MediaServerSourceInfo(kind: .audiobookshelf, connectionId: "home", itemId: "55"),
      MediaServerSourceInfo(kind: .hummingbird, connectionId: "gone", itemId: "99"),
      MediaServerSourceInfo(kind: .hummingbird, connectionId: "home", itemId: "77"),
    ])

    XCTAssertEqual(http.requests.map { $0.url?.absoluteString }, [
      "https://other.example.com/protocols/hummingbird/v1/bookshelf/remove/88",
      "https://hb.example.com/protocols/hummingbird/v1/bookshelf/remove/77",
    ])
  }

  func testAUserDeleteReachesIt() async throws {
    let returns = HummingbirdLoanReturns(connectionService: service)

    NotificationCenter.default.post(
      name: .mediaServerItemsDeleted,
      object: nil,
      userInfo: [MediaServerDeletion.entriesKey: [MediaServerSourceInfo(kind: .hummingbird, connectionId: "home", itemId: "77")]]
    )
    for _ in 0..<40 where http.requests.isEmpty {
      try await Task.sleep(nanoseconds: 50_000_000)
    }

    XCTAssertEqual(http.requests.map { $0.url?.lastPathComponent }, ["77"])
    withExtendedLifetime(returns) {}
  }
}

// MARK: - Loans that ran out

final class HummingbirdLoanExpiryScannerTests: HummingbirdLibraryTestCase {
  private var http: HummingbirdHTTPStub!
  private var service: HummingbirdConnectionService!
  private var player: PlayerManagerProtocolMock!
  private var sync: SyncServiceProtocolMock!
  private let now = Date(timeIntervalSince1970: 1_793_534_400)

  override func setUp() {
    super.setUp()
    let keychain = KeychainServiceMock()
    try? keychain.set(
      [HummingbirdConnectionData(id: "home", url: URL(string: "https://hb.example.com")!, serverName: "home", userName: "a", password: "1")],
      key: .hummingbirdConnection
    )
    http = HummingbirdHTTPStub()
    service = HummingbirdConnectionService(keychainService: keychain, httpClient: http, defaults: defaults)
    service.setup()
    player = PlayerManagerProtocolMock()
    sync = SyncServiceProtocolMock()
  }

  override func tearDown() {
    sync = nil
    player = nil
    service = nil
    http = nil
    super.tearDown()
  }

  private func makeScanner() -> HummingbirdLoanExpiryScanner {
    let now = self.now
    return HummingbirdLoanExpiryScanner(
      connectionService: service,
      sourceStore: store,
      libraryService: libraryService,
      playerManager: player,
      syncService: sync,
      now: { now }
    )
  }

  private func playable(_ relativePath: String) -> PlayableItem {
    PlayableItem(
      title: relativePath,
      author: "author",
      chapters: [
        PlayableChapter(
          title: relativePath,
          author: "author",
          start: 0,
          duration: 100,
          relativePath: relativePath,
          remoteURL: nil,
          externalURL: nil,
          index: 0
        )
      ],
      currentTime: 0,
      duration: 100,
      relativePath: relativePath,
      uuid: relativePath,
      parentFolder: nil,
      percentCompleted: 0,
      lastPlayDate: nil,
      isFinished: false,
      isBoundBook: false
    )
  }

  // A deleted book's managed object reads nil, so the tests keep its path from before the scan

  func testAnExpiredLoanIsReturnedThenDeleted() async throws {
    let path: String = rootBook("expired").relativePath
    store.setSource(loan("77", due: now.addingTimeInterval(-60)), for: path)
    let removed = expectation(forNotification: .libraryItemsRemoved, object: nil)

    await makeScanner().scan()

    XCTAssertEqual(http.requests.map { $0.url?.path }, ["/protocols/hummingbird/v1/bookshelf/remove/77"])
    XCTAssertNil(libraryService.getSimpleItem(with: path))
    XCTAssertNil(store.source(for: path))
    XCTAssertEqual(sync.scheduleDeleteModeReceivedArguments?.items.map(\.relativePath), [path])
    XCTAssertEqual(sync.scheduleDeleteModeReceivedArguments?.mode, .deep)
    XCTAssertFalse(player.stopCalled)
    await fulfillment(of: [removed], timeout: 1)
  }

  /// A book that's playing stops before its file goes
  func testTheLoadedBookStopsFirst() async {
    let path: String = rootBook("playing").relativePath
    store.setSource(loan("77", due: now.addingTimeInterval(-60)), for: path)
    player.currentItem = playable(path)

    await makeScanner().scan()

    XCTAssertTrue(player.stopCalled)
    XCTAssertNil(libraryService.getSimpleItem(with: path))
  }

  /// "Folder only" would leave a bound book's audio behind as loose files: the expired book goes with
  /// its parts, and is returned once, though a part carries the loan too (its entry went with the
  /// book's delete before the scan got to it)
  func testAnExpiredBoundBookGoesWithItsParts() async throws {
    _ = try folder("Daisy", books: ["p1", "p2"])
    try libraryService.updateFolder(at: "Daisy", type: .bound)
    store.setSource(
      MediaServerSourceInfo(kind: .hummingbird, connectionId: "home", itemId: "9", dueDate: now.addingTimeInterval(-1), shouldBindFolder: true),
      for: "Daisy"
    )
    store.setSource(loan("9", due: now.addingTimeInterval(-1)), for: "Daisy/p1.txt")

    await makeScanner().scan()

    XCTAssertNil(libraryService.getSimpleItem(with: "Daisy"))
    XCTAssertNil(libraryService.getSimpleItem(with: "p1.txt"))
    XCTAssertNil(libraryService.getSimpleItem(with: "Daisy/p1.txt"))
    XCTAssertNil(store.source(for: "Daisy/p1.txt"))
    XCTAssertEqual(http.requests.map { $0.url?.lastPathComponent }, ["9"])
  }

  /// The return failing doesn't keep the expired copy playing; a delete failing keeps the entry, so
  /// the next scan tries again
  func testAFailedDeleteIsTriedAgainNextTime() async throws {
    let path: String = rootBook("stuck").relativePath
    store.setSource(loan("77", due: now.addingTimeInterval(-60)), for: path)
    lock(path)
    http.replies = [.init(status: 500, body: "")]

    await makeScanner().scan()

    XCTAssertNotNil(libraryService.getSimpleItem(with: path))
    XCTAssertEqual(store.source(for: path), loan("77", due: now.addingTimeInterval(-60)))
    XCTAssertFalse(sync.scheduleDeleteModeCalled)
    XCTAssertEqual(http.requests.count, 1)
  }

  /// NNELS has no loan periods, and a loan that hasn't run out stays
  func testBooksWithoutAPassedDueDateStay() async {
    let open = rootBook("open")
    let later = rootBook("later")
    let other = rootBook("other-server")
    store.setSource(loan("1"), for: open.relativePath)
    store.setSource(loan("2", due: now.addingTimeInterval(60)), for: later.relativePath)
    store.setSource(
      MediaServerSourceInfo(kind: .audiobookshelf, connectionId: "abs", itemId: "li", dueDate: now.addingTimeInterval(-60)),
      for: other.relativePath
    )

    await makeScanner().scan()

    XCTAssertTrue(http.requests.isEmpty)
    XCTAssertNotNil(libraryService.getSimpleItem(with: open.relativePath))
    XCTAssertNotNil(libraryService.getSimpleItem(with: later.relativePath))
    XCTAssertNotNil(libraryService.getSimpleItem(with: other.relativePath))
  }

  /// An entry whose book is already gone is returned and dropped; nothing else is deleted
  func testAnEntryWithoutItsBookIsDropped() async {
    let bystander = rootBook("bystander")
    store.setSource(loan("3", due: now.addingTimeInterval(-60)), for: "vanished.mp3")

    await makeScanner().scan()

    XCTAssertNil(store.source(for: "vanished.mp3"))
    XCTAssertEqual(http.requests.map { $0.url?.lastPathComponent }, ["3"])
    XCTAssertFalse(sync.scheduleDeleteModeCalled)
    XCTAssertNotNil(libraryService.getSimpleItem(with: bystander.relativePath))
  }

  /// A book borrowed again and downloaded again: the expired copy goes, but returning it would end
  /// the new loan too (a return is by book), so the server isn't told
  func testAnExpiredCopyOfABookStillOnLoanIsDeletedWithoutAReturn() async {
    let oldPath: String = rootBook("old-copy").relativePath
    let newPath: String = rootBook("new-copy").relativePath
    store.setSource(loan("77", due: now.addingTimeInterval(-60)), for: oldPath)
    store.setSource(loan("77", due: now.addingTimeInterval(86_400 * 14)), for: newPath)

    await makeScanner().scan()

    XCTAssertTrue(http.requests.isEmpty)
    XCTAssertNil(libraryService.getSimpleItem(with: oldPath))
    XCTAssertNotNil(libraryService.getSimpleItem(with: newPath))
    XCTAssertEqual(store.source(for: newPath), loan("77", due: now.addingTimeInterval(86_400 * 14)))
  }

  /// The scan waits on the server between choosing a book and deleting it. If, meanwhile, the book
  /// moved and another took its old path, that scan deletes neither: the moved book keeps its entry
  /// and goes on the next scan, from where it is now
  func testABookMovedDuringTheReturnIsLeftForTheNextScan() async throws {
    let keychain = KeychainServiceMock()
    try keychain.set(
      [HummingbirdConnectionData(id: "home", url: URL(string: "https://hb.example.com")!, serverName: "home", userName: "a", password: "1")],
      key: .hummingbirdConnection
    )
    let gated = GatedHTTPStub()
    let gatedService = HummingbirdConnectionService(keychainService: keychain, httpClient: gated, defaults: defaults)
    gatedService.setup()
    let now = self.now
    let scanner = HummingbirdLoanExpiryScanner(
      connectionService: gatedService,
      sourceStore: store,
      libraryService: libraryService,
      playerManager: player,
      syncService: sync,
      now: { now }
    )
    let expired = rootBook("expired")
    let expiredPath: String = expired.relativePath
    let expiredUuid: String = expired.uuid
    let entry = loan("77", due: now.addingTimeInterval(-60))
    store.setSource(entry, for: expiredPath)
    let shelf = try StubFactory.folder(dataManager: libraryService.dataManager, title: "Shelf")
    libraryService.getLibraryReference().addToItems(shelf)
    libraryService.dataManager.saveContext()

    let staleScan = Task { await scanner.scan() }
    for _ in 0..<200 where gated.heldCount == 0 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(gated.heldCount, 1, "precondition: the return is out")

    try libraryService.moveItems([LibraryItemRef(relativePath: expiredPath, uuid: expiredUuid)], inside: "Shelf")
    let movedPath = "Shelf/" + expiredPath
    let bystanderPath: String = rootBook("expired").relativePath
    XCTAssertEqual(bystanderPath, expiredPath, "precondition: another book now has the old path")
    gated.release()
    await staleScan.value

    XCTAssertNotNil(libraryService.getSimpleItem(with: bystanderPath))
    XCTAssertNotNil(libraryService.getSimpleItem(with: movedPath))
    XCTAssertEqual(store.source(for: movedPath), entry)
    XCTAssertNil(store.source(for: bystanderPath))
    XCTAssertFalse(sync.scheduleDeleteModeCalled)

    await scanner.scan()

    XCTAssertNil(libraryService.getSimpleItem(with: movedPath))
    XCTAssertNil(store.source(for: movedPath))
    XCTAssertNotNil(libraryService.getSimpleItem(with: bystanderPath))
    XCTAssertEqual(sync.scheduleDeleteModeReceivedArguments?.items.map(\.relativePath), [movedPath])
  }
}

/// Holds each request until the test lets it go, so a test can change the library while one is out.
/// `@unchecked Sendable`: its state is behind a lock
final class GatedHTTPStub: IntegrationHTTPClient, @unchecked Sendable {
  private let lock = NSLock()
  private var held = [CheckedContinuation<Void, Never>]()
  private var holds = true

  /// Requests waiting to be let go
  var heldCount: Int { lock.withLock { held.count } }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    if lock.withLock({ holds }) {
      await withCheckedContinuation { continuation in
        lock.withLock { held.append(continuation) }
      }
    }
    return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }

  /// Lets every held request answer, and the ones after it answer straight away
  func release() {
    let waiting = lock.withLock {
      holds = false
      let waiting = held
      held = []
      return waiting
    }
    waiting.forEach { $0.resume() }
  }

  func redirectLocation(for request: URLRequest) async throws -> URL {
    throw URLError(.unsupportedURL)
  }
}
