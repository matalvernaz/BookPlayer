//
//  HummingbirdProgressTests.swift
//  BookPlayerTests
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

@testable import BookPlayer
@testable import BookPlayerKit
import Combine
import XCTest

// MARK: - The bookmark calls

/// Hummingbird's bookmark endpoint (server v0.6.2): the user comes from the sign-in, the bookmark is
/// kept as sent, and each book's goes to the connection its provenance names
@MainActor
final class HummingbirdBookmarkServiceTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var keychain: KeychainServiceMock!
  private var http: HummingbirdHTTPStub!
  private var service: HummingbirdConnectionService!

  private let home = HummingbirdConnectionData(
    id: "home",
    url: URL(string: "https://hb.example.com")!,
    serverName: "hb.example.com",
    userName: "reader",
    password: "pw"
  )
  private let other = HummingbirdConnectionData(
    id: "other",
    url: URL(string: "https://other.example.com:8000")!,
    serverName: "other.example.com",
    userName: "second",
    password: "other-pass",
    customHeaders: ["X-Proxy": "1", "Authorization": "Bearer proxy"]
  )

  override func setUpWithError() throws {
    try super.setUpWithError()
    suiteName = "HummingbirdBookmarkServiceTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    keychain = KeychainServiceMock()
    try keychain.set([home, other], key: .hummingbirdConnection)
    http = HummingbirdHTTPStub()
    service = HummingbirdConnectionService(keychainService: keychain, httpClient: http, defaults: defaults)
    service.setup()
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    service = nil
    http = nil
    keychain = nil
    defaults = nil
    super.tearDown()
  }

  private func basic(_ user: String, _ password: String) -> String {
    "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
  }

  func testABookmarkGoesToItsBookOnItsOwnServer() async throws {
    let bookmark = HummingbirdBookmark(currentTime: 30, duration: 120, isFinished: false)

    try await service.reportBookmark(bookmark, bookId: "77", connectionId: "other")

    let request = try XCTUnwrap(http.requests.first)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.absoluteString, "https://other.example.com:8000/protocols/hummingbird/v1/bookshelf/bookmark/77")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Proxy"), "1")
    // A custom header named Authorization never replaces the sign-in
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), basic("second", "other-pass"))
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: [String: Any]])
    let sent = try XCTUnwrap(body["bookmark"])
    XCTAssertEqual(sent["currentTime"] as? Double, 30)
    XCTAssertEqual(sent["duration"] as? Double, 120)
    XCTAssertEqual(sent["progress"] as? Double, 0.25)
    XCTAssertEqual(sent["isFinished"] as? Bool, false)
  }

  func testASavedBookmarkReadsBack() async throws {
    http.replies = [.init(status: 200, body: #"{"username": "reader", "node_id": 77, "bookmark": {"currentTime": 42.5, "duration": 100, "progress": 0.425, "isFinished": false}}"#)]

    let bookmark = try await service.fetchBookmark(bookId: "77", connectionId: "home")

    XCTAssertEqual(bookmark?.currentTime, 42.5)
    XCTAssertEqual(bookmark?.isFinished, false)
    let request = try XCTUnwrap(http.requests.first)
    XCTAssertEqual(request.httpMethod ?? "GET", "GET")
    XCTAssertEqual(request.url?.absoluteString, "https://hb.example.com/protocols/hummingbird/v1/bookshelf/bookmark/77")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), basic("reader", "pw"))
  }

  /// Only `currentTime` is needed; nothing saved, or a DODP client's bookmark, is no bookmark
  func testWhatCountsAsABookmark() async throws {
    http.replies = [.init(status: 200, body: #"{"bookmark": {"currentTime": 12}}"#)]
    let positionOnly = try await service.fetchBookmark(bookId: "77", connectionId: "home")
    XCTAssertEqual(positionOnly?.currentTime, 12)
    XCTAssertEqual(positionOnly?.isFinished, false)

    http.replies = [.init(status: 200, body: #"{"username": "reader", "node_id": 77, "bookmark": {}}"#)]
    let nothingSaved = try await service.fetchBookmark(bookId: "77", connectionId: "home")
    XCTAssertNil(nothingSaved)

    http.replies = [.init(status: 200, body: #"{"bookmark": {"position": "chapter-3#00:12:00"}}"#)]
    let dodp = try await service.fetchBookmark(bookId: "77", connectionId: "home")
    XCTAssertNil(dodp)
  }

  func testAnAnswerThatIsntJSONIsAnError() async {
    http.replies = [.init(status: 200, body: "<html>")]

    do {
      _ = try await service.fetchBookmark(bookId: "77", connectionId: "home")
      XCTFail("expected an error")
    } catch {
      XCTAssertEqual(error as? IntegrationError, .unexpectedResponse(code: nil))
    }
  }

  /// A connection signed out since the book was downloaded asks nothing, rather than another
  /// server's account going out instead
  func testARemovedConnectionAsksNothing() async {
    let bookmark = HummingbirdBookmark(currentTime: 30, duration: 120, isFinished: false)

    await assertSignInRequired { try await self.service.reportBookmark(bookmark, bookId: "77", connectionId: "gone") }
    await assertSignInRequired { _ = try await self.service.fetchBookmark(bookId: "77", connectionId: "gone") }
    XCTAssertTrue(http.requests.isEmpty)
  }

  func testARejectedSessionIsASessionToRenew() async {
    http.replies = [.init(status: 401, body: "")]

    do {
      _ = try await service.fetchBookmark(bookId: "77", connectionId: "home")
      XCTFail("expected an error")
    } catch {
      XCTAssertEqual(error as? IntegrationError, .sessionExpired(serverName: "hb.example.com"))
    }
  }

  private func assertSignInRequired(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Void
  ) async {
    do {
      try await body()
      XCTFail("expected a sign-in to be required", file: file, line: line)
    } catch {
      XCTAssertEqual((error as? URLError)?.code, .userAuthenticationRequired, file: file, line: line)
    }
  }
}

// MARK: - The reporter

/// Collects what the reporter sends; can hold the first send until released, as a slow server would
@MainActor
final class HummingbirdBookmarkRecorder {
  struct Sent: Equatable {
    let bookmark: HummingbirdBookmark
    let bookId: String
    let connectionId: String
  }

  private(set) var sent = [Sent]()
  var holdsFirst = false
  private var held: CheckedContinuation<Void, Never>?
  var isHolding: Bool { held != nil }

  func record(_ bookmark: HummingbirdBookmark, _ bookId: String, _ connectionId: String) async {
    sent.append(Sent(bookmark: bookmark, bookId: bookId, connectionId: connectionId))
    if holdsFirst {
      holdsFirst = false
      await withCheckedContinuation { held = $0 }
    }
  }

  func release() {
    let continuation = held
    held = nil
    continuation?.resume()
  }
}

/// Hummingbird books' positions go back to their servers: ticks at most every 15 seconds, pauses at
/// once, and the end of the book that ended, once
@MainActor
final class HummingbirdProgressReporterTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var store: MediaServerSourceStore!
  private var player: PlayerManagerProtocolMock!
  private var currentItems: PassthroughSubject<PlayableItem?, Never>!
  private var center: NotificationCenter!
  private var recorder: HummingbirdBookmarkRecorder!
  private var clock = Date(timeIntervalSince1970: 1_800_000_000)
  private var reporter: HummingbirdProgressReporter!

  override func setUp() {
    super.setUp()
    suiteName = "HummingbirdProgressReporterTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    store = MediaServerSourceStore(userDefaults: defaults)
    store.setSource(MediaServerSourceInfo(kind: .hummingbird, connectionId: "hb-1", itemId: "11"), for: "Daisy A")
    store.setSource(MediaServerSourceInfo(kind: .hummingbird, connectionId: "hb-1", itemId: "22"), for: "Daisy B")
    store.setSource(
      MediaServerSourceInfo(kind: .audiobookshelf, connectionId: "abs-1", itemId: "li_1", hostId: "https://abs.example.com"),
      for: "Dune.m4b"
    )
    player = PlayerManagerProtocolMock()
    currentItems = PassthroughSubject()
    player.currentItemPublisherReturnValue = currentItems.eraseToAnyPublisher()
    center = NotificationCenter()
    recorder = HummingbirdBookmarkRecorder()
    makeReporter()
  }

  override func tearDown() {
    reporter = nil
    defaults.removePersistentDomain(forName: suiteName)
    recorder = nil
    center = nil
    currentItems = nil
    player = nil
    store = nil
    defaults = nil
    super.tearDown()
  }

  private func makeReporter(send: HummingbirdProgressReporter.Send? = nil) {
    let recorder = self.recorder!
    reporter = HummingbirdProgressReporter(
      playerManager: player,
      sourceStore: store,
      notificationCenter: center,
      now: { [unowned self] in self.clock }
    ) { bookmark, bookId, connectionId in
      if let send {
        try await send(bookmark, bookId, connectionId)
      } else {
        await recorder.record(bookmark, bookId, connectionId)
      }
    }
  }

  /// A book of one chapter: `PlayableItem` needs at least one
  private func item(_ relativePath: String, at currentTime: Double = 10, duration: Double = 100) -> PlayableItem {
    let chapter = PlayableChapter(
      title: relativePath,
      author: "",
      start: 0,
      duration: duration,
      relativePath: relativePath,
      remoteURL: nil,
      externalURL: nil,
      index: 1
    )
    return PlayableItem(
      title: relativePath,
      author: "",
      chapters: [chapter],
      currentTime: currentTime,
      duration: duration,
      relativePath: relativePath,
      uuid: UUID().uuidString,
      parentFolder: nil,
      percentCompleted: 0,
      lastPlayDate: nil,
      isFinished: false,
      isBoundBook: false
    )
  }

  /// The player loads another book: the property and the publisher, as `PlayerManager` does
  private func load(_ item: PlayableItem?) {
    player.currentItem = item
    currentItems.send(item)
  }

  private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
    for _ in 0..<200 where !condition() {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertTrue(condition(), file: file, line: line)
  }

  /// Lets anything already started run, before checking nothing more was sent
  private func settle() async throws {
    try await Task.sleep(nanoseconds: 50_000_000)
  }

  func testTicksGoAtMostEvery15Seconds() async throws {
    let book = item("Daisy A")
    load(book)

    reporter.reportTick()
    try await waitUntil { recorder.sent.count == 1 }
    clock.addTimeInterval(5)
    book.currentTime = 15
    reporter.reportTick()
    try await settle()
    XCTAssertEqual(recorder.sent.count, 1)

    clock.addTimeInterval(11)
    book.currentTime = 26
    reporter.reportTick()
    try await waitUntil { recorder.sent.count == 2 }
    XCTAssertEqual(recorder.sent.map(\.bookmark.currentTime), [10, 26])
    XCTAssertEqual(recorder.sent.first, .init(bookmark: HummingbirdBookmark(currentTime: 10, duration: 100, isFinished: false), bookId: "11", connectionId: "hb-1"))
  }

  func testAPauseGoesAtOnce() async throws {
    let book = item("Daisy A")
    load(book)
    reporter.reportTick()
    try await waitUntil { recorder.sent.count == 1 }

    clock.addTimeInterval(2)
    book.currentTime = 12
    reporter.reportPause()

    try await waitUntil { recorder.sent.count == 2 }
    XCTAssertEqual(recorder.sent.last?.bookmark.currentTime, 12)
  }

  /// `PlayerManager` posts `.bookEnd`, loads the next book, and posts it again: the book that ended is
  /// reported finished once, and the next one isn't
  func testTheBookThatEndedIsReportedFinishedOnce() async throws {
    let first = item("Daisy A", at: 95)
    load(first)
    reporter.reportTick()
    try await waitUntil { recorder.sent.count == 1 }

    first.isFinished = true
    reporter.reportEnd()
    load(item("Daisy B", at: 0))
    try await settle()
    reporter.reportEnd()

    try await waitUntil { recorder.sent.count == 2 }
    try await settle()
    XCTAssertEqual(recorder.sent.count, 2)
    XCTAssertEqual(recorder.sent.last, .init(bookmark: HummingbirdBookmark(currentTime: 100, duration: 100, isFinished: true), bookId: "11", connectionId: "hb-1"))
  }

  /// The last book in the queue: nothing loads after it, and the second `.bookEnd` still reports nothing
  func testTheLastBookEndingIsReportedOnce() async throws {
    let last = item("Daisy A", at: 95)
    load(last)
    reporter.reportTick()
    try await waitUntil { recorder.sent.count == 1 }

    last.isFinished = true
    reporter.reportEnd()
    reporter.reportEnd()

    try await waitUntil { recorder.sent.count == 2 }
    try await settle()
    XCTAssertEqual(recorder.sent.count, 2)
  }

  /// Another book loaded since the Hummingbird one was reported: its end isn't the Hummingbird book's
  func testFinishingAnotherBookReportsNothingForTheHummingbirdOne() async throws {
    load(item("Daisy A"))
    reporter.reportTick()
    try await waitUntil { recorder.sent.count == 1 }

    let local = item("Local.m4b")
    load(local)
    try await settle()
    local.isFinished = true
    reporter.reportEnd()

    try await settle()
    XCTAssertEqual(recorder.sent.count, 1)
  }

  /// Marking a book unfinished posts `.bookEnd` too: it reports the position, not finished
  func testMarkingABookUnfinishedReportsItsPosition() async throws {
    let book = item("Daisy A", at: 40)
    load(book)
    reporter.reportTick()
    try await waitUntil { recorder.sent.count == 1 }

    reporter.reportEnd()

    try await waitUntil { recorder.sent.count == 2 }
    XCTAssertEqual(recorder.sent.last?.bookmark, HummingbirdBookmark(currentTime: 40, duration: 100, isFinished: false))
  }

  /// Audiobookshelf downloads go through upstream's push, and local books nowhere
  func testNothingForOtherBooks() async throws {
    for path in ["Dune.m4b", "Local.m4b"] {
      let book = item(path)
      load(book)
      reporter.reportTick()
      reporter.reportPause()
      book.isFinished = true
      reporter.reportEnd()
    }

    try await settle()
    XCTAssertTrue(recorder.sent.isEmpty)
  }

  /// One bookmark on its way per book: what came meanwhile waits, the newest replacing the rest
  func testOneBookmarkOnItsWayPerBook() async throws {
    recorder.holdsFirst = true
    let book = item("Daisy A", at: 10)
    load(book)
    reporter.reportTick()
    try await waitUntil { recorder.isHolding }

    book.currentTime = 20
    reporter.reportPause()
    book.currentTime = 30
    reporter.reportPause()
    try await settle()
    XCTAssertEqual(recorder.sent.count, 1)

    recorder.release()
    try await waitUntil { recorder.sent.count == 2 }
    try await settle()
    XCTAssertEqual(recorder.sent.map(\.bookmark.currentTime), [10, 30])
  }

  /// The player's notifications drive it
  func testThePlayersNotificationsDriveIt() async throws {
    let book = item("Daisy A")
    load(book)

    center.post(name: .bookPlaying, object: nil)
    try await waitUntil { recorder.sent.count == 1 }
    book.currentTime = 11
    center.post(name: .bookPaused, object: nil)
    try await waitUntil { recorder.sent.count == 2 }
    book.isFinished = true
    center.post(name: .bookEnd, object: nil)
    try await waitUntil { recorder.sent.count == 3 }
    XCTAssertEqual(recorder.sent.last?.bookmark.isFinished, true)
  }

  /// Through the real service: a book whose connection was removed sends no request
  func testARemovedConnectionSendsNoRequest() async throws {
    let keychain = KeychainServiceMock()
    let http = HummingbirdHTTPStub()
    let service = HummingbirdConnectionService(keychainService: keychain, httpClient: http, defaults: defaults)
    service.setup()
    makeReporter { bookmark, bookId, connectionId in
      try await service.reportBookmark(bookmark, bookId: bookId, connectionId: connectionId)
    }
    load(item("Daisy A"))

    reporter.reportTick()
    reporter.reportPause()

    try await settle()
    XCTAssertTrue(http.requests.isEmpty)
  }
}

// MARK: - The puller

/// Answers bookmark requests from a table; can hold the next one until released, as a slow server
/// would
@MainActor
final class HummingbirdBookmarkSource {
  var bookmarks = [String: HummingbirdBookmark]()
  var failsNext = false
  var holdsNext = false
  private(set) var asked = [String]()
  private var held: CheckedContinuation<Void, Never>?
  var isHolding: Bool { held != nil }

  func fetch(_ bookId: String, _ connectionId: String) async throws -> HummingbirdBookmark? {
    asked.append(bookId)
    if holdsNext {
      holdsNext = false
      await withCheckedContinuation { held = $0 }
    }
    if failsNext {
      failsNext = false
      throw URLError(.notConnectedToInternet)
    }
    return bookmarks[bookId]
  }

  func release() {
    let continuation = held
    held = nil
    continuation?.resume()
  }
}

/// An unplayed Hummingbird book starts at its server bookmark; once the book has a position here, or
/// the library moved on while the bookmark was on its way, it's left alone
@MainActor
final class HummingbirdBookmarkPullerTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var store: MediaServerSourceStore!
  private var libraryService: LibraryService!
  private var source: HummingbirdBookmarkSource!
  private var center: NotificationCenter!
  private var puller: HummingbirdBookmarkPuller!
  private var path: String!
  /// The book the player has loaded, if any
  private var loadedPath: String?

  private let entry = MediaServerSourceInfo(kind: .hummingbird, connectionId: "hb-1", itemId: "77")

  override func setUp() {
    super.setUp()
    DataTestUtils.clearFolderContents(url: DataManager.getProcessedFolderURL())
    suiteName = "HummingbirdBookmarkPullerTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    store = MediaServerSourceStore(userDefaults: defaults)
    libraryService = LibraryService()
    libraryService.setup(dataManager: DataManager(coreDataStack: CoreDataStack(testPath: "/dev/null")), audioMetadataService: AudioMetadataService())
    libraryService.mediaServerSourceStore = store
    _ = libraryService.getLibrary()
    path = rootBook("Daisy").relativePath
    store.setSource(entry, for: path)
    source = HummingbirdBookmarkSource()
    source.bookmarks["77"] = HummingbirdBookmark(currentTime: 42, duration: 100, isFinished: false)
    center = NotificationCenter()
    let source = self.source!
    puller = HummingbirdBookmarkPuller(
      sourceStore: store,
      libraryService: libraryService,
      notificationCenter: center,
      isLoadedInPlayer: { [unowned self] in self.loadedPath == $0 }
    ) { bookId, connectionId in
      try await source.fetch(bookId, connectionId)
    }
  }

  override func tearDown() {
    puller = nil
    DataTestUtils.clearFolderContents(url: DataManager.getProcessedFolderURL())
    defaults.removePersistentDomain(forName: suiteName)
    center = nil
    source = nil
    libraryService = nil
    store = nil
    defaults = nil
    super.tearDown()
  }

  @discardableResult
  private func rootBook(_ title: String) -> Book {
    let book = StubFactory.book(dataManager: libraryService.dataManager, title: title, duration: 100)
    libraryService.getLibraryReference().addToItems(book)
    libraryService.dataManager.saveContext()
    return book
  }

  /// A book of several files as its download leaves it: a folder of parts with one entry, the folder's,
  /// asking to be bound (the parts have none)
  private func multiFileBook(_ title: String, parts: [String], itemId: String) throws {
    let folder = try StubFactory.folder(dataManager: libraryService.dataManager, title: title)
    libraryService.getLibraryReference().addToItems(folder)
    let books = parts.map { rootBook($0) }
    try libraryService.moveItems(
      books.map { LibraryItemRef(relativePath: $0.relativePath, uuid: $0.uuid) },
      inside: folder.relativePath
    )
    store.setSource(
      MediaServerSourceInfo(kind: .hummingbird, connectionId: "hb-1", itemId: itemId, shouldBindFolder: true),
      for: title
    )
  }

  /// A book's saved position: what the puller writes is saved on the library's short delay, so it's
  /// saved first
  private func position(of relativePath: String) -> Double? {
    libraryService.dataManager.saveContext()
    return libraryService.getSimpleItem(with: relativePath)?.currentTime
  }

  private func currentTime() -> Double? {
    position(of: path)
  }

  private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
    for _ in 0..<200 where !condition() {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertTrue(condition(), file: file, line: line)
  }

  func testAnUnplayedBookStartsAtItsBookmark() async {
    await puller.pull()

    XCTAssertEqual(source.asked, ["77"])
    XCTAssertEqual(currentTime(), 42)
  }

  /// The bookmark is a position in the whole book, so it goes on the bound book, asked once, and the
  /// parts stay at their start
  func testABoundBookStartsAtItsBookmark() async throws {
    try multiFileBook("Volume", parts: ["Part 1", "Part 2"], itemId: "55")
    try libraryService.updateFolder(at: "Volume", type: .bound)
    XCTAssertEqual(libraryService.getSimpleItem(with: "Volume")?.duration, 200, "precondition: two 100 s parts")
    source.bookmarks["55"] = HummingbirdBookmark(currentTime: 150, duration: 200, isFinished: false)

    await puller.pull()

    XCTAssertEqual(source.asked.filter { $0 == "55" }.count, 1)
    XCTAssertEqual(position(of: "Volume"), 150)
    XCTAssertEqual(position(of: "Volume/Part 1.txt"), 0)
    XCTAssertEqual(position(of: "Volume/Part 2.txt"), 0)
  }

  /// The import's post reaches the puller and the binder together, and the binder runs a turn later, so
  /// an answer can land on the folder before it's bound: binding keeps the position
  func testABookmarkPulledBeforeTheBindStaysWithTheBook() async throws {
    try multiFileBook("Volume", parts: ["Part 1", "Part 2"], itemId: "55")
    XCTAssertEqual(libraryService.getSimpleItem(with: "Volume")?.duration, 200, "precondition: two 100 s parts")
    source.bookmarks["55"] = HummingbirdBookmark(currentTime: 150, duration: 200, isFinished: false)

    await puller.pull()
    XCTAssertEqual(position(of: "Volume"), 150)

    try libraryService.updateFolder(at: "Volume", type: .bound)

    XCTAssertEqual(libraryService.getSimpleItem(with: "Volume")?.type, .bound)
    XCTAssertEqual(position(of: "Volume"), 150)
  }

  func testABookmarkPastTheEndIsHeldToTheBook() async {
    source.bookmarks["77"] = HummingbirdBookmark(currentTime: 500, duration: 500, isFinished: false)

    await puller.pull()

    XCTAssertEqual(currentTime(), 100)
  }

  func testAPlayedOrFinishedBookIsntAsked() async {
    libraryService.updatePlaybackTime(relativePath: path, time: 10, date: Date(), scheduleSave: false)
    await puller.pull()
    XCTAssertTrue(source.asked.isEmpty)
    XCTAssertEqual(currentTime(), 10)

    let finished = rootBook("Finished")
    store.setSource(MediaServerSourceInfo(kind: .hummingbird, connectionId: "hb-1", itemId: "88"), for: finished.relativePath)
    libraryService.markAsFinished(flag: true, relativePath: finished.relativePath)
    await puller.pull()
    XCTAssertTrue(source.asked.isEmpty)
  }

  /// No bookmark, or one at the start, leaves the book where it is
  func testNoBookmarkLeavesTheStart() async {
    source.bookmarks["77"] = nil
    await puller.pull()
    XCTAssertEqual(currentTime(), 0)

    let other = rootBook("Other")
    store.setSource(MediaServerSourceInfo(kind: .hummingbird, connectionId: "hb-1", itemId: "99"), for: other.relativePath)
    source.bookmarks["99"] = HummingbirdBookmark(currentTime: 0, duration: 100, isFinished: false)
    await puller.pull()
    XCTAssertEqual(position(of: other.relativePath), 0)
  }

  func testEachBookIsAskedOncePerLaunch() async {
    source.bookmarks["77"] = nil
    await puller.pull()
    await puller.pull()

    XCTAssertEqual(source.asked, ["77"])
  }

  func testAFailedRequestIsAskedAgain() async {
    source.failsNext = true
    await puller.pull()
    XCTAssertEqual(currentTime(), 0)

    await puller.pull()

    XCTAssertEqual(source.asked, ["77", "77"])
    XCTAssertEqual(currentTime(), 42)
  }

  /// Entries resolve when the import runs: an import starts a pull
  func testAnImportStartsAPull() async throws {
    center.post(name: .importItemsInserted, object: nil)

    try await waitUntil { currentTime() == 42 }
  }

  /// The player's book is the player's: it isn't even asked
  func testABookLoadedInThePlayerIsLeftAlone() async {
    loadedPath = path

    await puller.pull()

    XCTAssertTrue(source.asked.isEmpty)
    XCTAssertEqual(currentTime(), 0)
  }

  /// The user loaded and started the book while its bookmark was on its way. Playback saves its position
  /// a couple of seconds late, so the library still reads 0 when the answer arrives: the player having
  /// the book is what keeps the bookmark out
  func testLoadingTheBookWhileItsBookmarkIsOnItsWayWins() async throws {
    source.holdsNext = true
    let puller = self.puller!
    let pull = Task { await puller.pull() }
    try await waitUntil { source.isHolding }

    loadedPath = path
    libraryService.updatePlaybackTime(relativePath: path, time: 5, date: Date(), scheduleSave: true)
    source.release()
    await pull.value

    XCTAssertEqual(currentTime(), 5)
  }

  /// The user started listening while the bookmark was on its way: their position stays
  func testListeningWhileTheBookmarkIsOnItsWayWins() async throws {
    source.holdsNext = true
    let puller = self.puller!
    let pull = Task { await puller.pull() }
    try await waitUntil { source.isHolding }

    libraryService.updatePlaybackTime(relativePath: path, time: 15, date: Date(), scheduleSave: false)
    source.release()
    await pull.value

    XCTAssertEqual(currentTime(), 15)
  }

  func testABookDeletedWhileTheBookmarkIsOnItsWayGetsNothing() async throws {
    source.holdsNext = true
    let puller = self.puller!
    let pull = Task { await puller.pull() }
    try await waitUntil { source.isHolding }

    let item = try XCTUnwrap(libraryService.getSimpleItem(with: path))
    try libraryService.delete([item], mode: .deep)
    source.release()
    await pull.value

    XCTAssertNil(libraryService.getSimpleItem(with: path))
  }

  /// The same title again at the same path, with the same provenance, is another book: the bookmark
  /// asked for the first isn't applied to it
  func testABookReplacedWhileTheBookmarkIsOnItsWayGetsNothing() async throws {
    source.holdsNext = true
    let puller = self.puller!
    let pull = Task { await puller.pull() }
    try await waitUntil { source.isHolding }

    let item = try XCTUnwrap(libraryService.getSimpleItem(with: path))
    try libraryService.delete([item], mode: .deep)
    let replacement = rootBook("Daisy")
    XCTAssertEqual(replacement.relativePath, path, "precondition: the same path")
    store.setSource(entry, for: path)
    source.release()
    await pull.value

    XCTAssertEqual(currentTime(), 0)
  }
}
