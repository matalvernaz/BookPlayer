//
//  HummingbirdDownloadTests.swift
//  BookPlayerTests
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

@testable import BookPlayer
@testable import BookPlayerKit
import XCTest

/// Hummingbird downloads on the provenance model: one file is known by its request until it lands, a
/// DAISY book takes a folder of its own whose files are named to keep its reading order
@MainActor
final class HummingbirdDownloadTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var store: MediaServerSourceStore!
  private var keychain: KeychainServiceMock!
  private var http: HummingbirdHTTPStub!
  private var service: HummingbirdConnectionService!
  private var downloadService: SingleFileDownloadService!
  private var viewModel: HummingbirdLibraryViewModel!
  /// What the tests put in Processed or Documents, removed afterwards
  private var leftovers = [URL]()

  private let home = HummingbirdConnectionData(
    id: "home",
    url: URL(string: "https://hb.example.com")!,
    serverName: "hb.example.com",
    userName: "reader",
    password: "pw"
  )
  private let due = Date(timeIntervalSince1970: 1_793_491_200)

  override func setUpWithError() throws {
    try super.setUpWithError()
    suiteName = "HummingbirdDownloadTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    store = MediaServerSourceStore(userDefaults: defaults)
    keychain = KeychainServiceMock()
    try keychain.set([home], key: .hummingbirdConnection)
    http = HummingbirdHTTPStub()
    service = HummingbirdConnectionService(keychainService: keychain, httpClient: http, defaults: defaults)
    service.setup()
    downloadService = SingleFileDownloadService(networkClient: NetworkClientMock(mockedResponse: Empty()))
    viewModel = HummingbirdLibraryViewModel(
      connectionService: service,
      singleFileDownloadService: downloadService,
      sourceStore: store
    )
  }

  override func tearDown() {
    for url in leftovers {
      try? FileManager.default.removeItem(at: url)
    }
    leftovers = []
    defaults.removePersistentDomain(forName: suiteName)
    viewModel = nil
    downloadService = nil
    service = nil
    http = nil
    keychain = nil
    store = nil
    defaults = nil
    super.tearDown()
  }

  private func item(bookId: Int = 77, format: Int = 11, title: String) -> HummingbirdLibraryItem {
    HummingbirdLibraryItem(
      bookId: bookId,
      format: format,
      title: title,
      downloadURL: URL(string: "https://hb.example.com/protocols/hummingbird/v1/download/\(format)/\(bookId)/")!,
      dueDate: due
    )
  }

  private func resources(_ localURIs: [String], bookId: Int = 77) -> [DODPResource] {
    localURIs.map {
      DODPResource(
        uri: "https://hb.example.com/protocols/hummingbird/v1/download/11/\(bookId)/file/"
          + ($0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0),
        mimeType: "audio/mpeg",
        size: 1,
        localURI: $0
      )
    }
  }

  /// A folder name under Documents whatever an earlier run left there, cleared again afterwards
  private func clearDocuments(_ name: String) {
    let url = DataManager.getDocumentsFolderURL().appendingPathComponent(name)
    try? FileManager.default.removeItem(at: url)
    leftovers.append(url)
  }

  private func sortedByPath(_ paths: [String]) -> [String] {
    paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  // MARK: - The reading order

  /// The server lists a book's files in its zip's storage order; the plan follows their paths, with
  /// numbers compared as numbers
  func testTheReadingOrderIsTheBooksPathsInNumberOrder() {
    let plan = HummingbirdLibraryViewModel.downloadPlan(
      for: resources(["12.mp3", "1.mp3", "2.mp3", "Disc 10/01.mp3", "Disc 2/01.mp3"])
    )

    XCTAssertEqual(plan.map(\.resource.localURI), ["1.mp3", "2.mp3", "12.mp3", "Disc 2/01.mp3", "Disc 10/01.mp3"])
    XCTAssertEqual(
      plan.map(\.fileName),
      ["001 - 1.mp3", "002 - 2.mp3", "003 - 12.mp3", "004 - Disc 2 - 01.mp3", "005 - Disc 10 - 01.mp3"]
    )
  }

  /// Two discs that both start with 01.mp3 get two names (July saved both as 01.mp3)
  func testFilesAtTheSameNameInDifferentFoldersStaySeparate() {
    let plan = HummingbirdLibraryViewModel.downloadPlan(for: resources(["Disc 1/01.mp3", "Disc 2/01.mp3"]))

    XCTAssertEqual(Set(plan.map(\.fileName)).count, 2)
  }

  func testAFileListedTwiceIsDownloadedOnce() {
    let plan = HummingbirdLibraryViewModel.downloadPlan(for: resources(["01.mp3", "01.mp3", "02.mp3"]))

    XCTAssertEqual(plan.map(\.resource.localURI), ["01.mp3", "02.mp3"])
  }

  /// End to end: the files as they're named here, imported the way the library imports a folder and
  /// bound, play in the books' path order. The pair "A B.mp3" / "A/B.mp3" sorts the other way once
  /// flattened, so this only passes because the number decides
  func testTheBoundBookPlaysInReadingOrder() async throws {
    let localURIs = ["12.mp3", "1.mp3", "2.mp3", "Disc 10/01.mp3", "Disc 2/01.mp3", "A B.mp3", "A/B.mp3"]
    let expectedOrder = sortedByPath(localURIs)
    XCTAssertEqual(Array(expectedOrder.prefix(3)), ["1.mp3", "2.mp3", "12.mp3"])
    XCTAssertLessThan(
      try XCTUnwrap(expectedOrder.firstIndex(of: "Disc 2/01.mp3")),
      try XCTUnwrap(expectedOrder.firstIndex(of: "Disc 10/01.mp3"))
    )
    // Without the numbers, flattening would put "A/B.mp3" ("A - B.mp3") before "A B.mp3"
    let flattened = MediaServerFileNames.volumeChildFileNames(["A B.mp3", "A/B.mp3"])
    XCTAssertEqual(sortedByPath(["A B.mp3", "A/B.mp3"]), ["A B.mp3", "A/B.mp3"], "precondition: path order")
    XCTAssertEqual(sortedByPath(flattened), Array(flattened.reversed()), "precondition: flattened order flips")

    let plan = HummingbirdLibraryViewModel.downloadPlan(for: resources(localURIs))
    XCTAssertEqual(plan.map(\.resource.localURI), expectedOrder)

    DataTestUtils.clearFolderContents(url: DataManager.getProcessedFolderURL())
    let libraryService = LibraryService()
    libraryService.setup(
      dataManager: DataManager(coreDataStack: CoreDataStack(testPath: "/dev/null")),
      audioMetadataService: AudioMetadataService()
    )
    _ = libraryService.getLibrary()
    let folder = DataManager.getProcessedFolderURL().appendingPathComponent("Reading Order")
    leftovers.append(folder)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for entry in plan {
      try Data("audio".utf8).write(to: folder.appendingPathComponent(entry.fileName))
    }

    _ = await libraryService.insertItems(from: [folder])
    try libraryService.updateFolder(at: "Reading Order", type: .bound)

    let parts = try XCTUnwrap(libraryService.fetchContents(at: "Reading Order", limit: nil, offset: nil))
    let localURIByFileName = Dictionary(uniqueKeysWithValues: plan.map { ($0.fileName, $0.resource.localURI) })
    XCTAssertEqual(
      parts.map { localURIByFileName[($0.relativePath as NSString).lastPathComponent] ?? "?" },
      expectedOrder
    )
    DataTestUtils.clearFolderContents(url: DataManager.getProcessedFolderURL())
  }

  // MARK: - Queuing

  /// One file lands wherever the download service saves it, so its provenance waits on its request
  func testOneFileIsKnownByItsRequest() throws {
    let resource = resources(["book.mp3"], bookId: 88)

    try viewModel.startDownloads(of: resource, for: item(bookId: 88, format: 4, title: "Single"), connectionId: "home")

    XCTAssertEqual(downloadService.downloadQueue.count, 1)
    let queued = try XCTUnwrap(downloadService.downloadQueue.first)
    XCTAssertNil(queued.folderName)
    XCTAssertNil(queued.fileName)
    XCTAssertEqual(queued.request.url?.absoluteString, resource[0].uri)
    XCTAssertEqual(
      queued.request.value(forHTTPHeaderField: "Authorization"),
      "Basic " + Data("reader:pw".utf8).base64EncodedString()
    )

    let url = try XCTUnwrap(URL(string: resource[0].uri))
    store.landPendingDownload(url, at: "probe.mp3")
    XCTAssertEqual(
      store.takeLandedSource(at: "probe.mp3"),
      MediaServerSourceInfo(kind: .hummingbird, connectionId: "home", itemId: "88", dueDate: due)
    )
  }

  /// A DAISY book takes a folder named after it, its files named in reading order, and the folder's
  /// provenance marks it to be bound into one book. Nothing is written before the files arrive: July
  /// wrote a playlist.m3u first, which the import made a part of the book
  func testSeveralFilesGoToAFolderOfTheirOwn() throws {
    let title = "Dune: Messiah"
    let folderName = MediaServerDownloadFolders.folderName(title: title, fallback: "Hummingbird 77")
    XCTAssertEqual(folderName, "Dune_ Messiah")
    clearDocuments(folderName)
    clearDocuments(folderName + " 2")

    try viewModel.startDownloads(
      of: resources(["12.mp3", "1.mp3", "2.mp3"]),
      for: item(title: title),
      connectionId: "home"
    )

    let queue = downloadService.downloadQueue
    XCTAssertEqual(queue.map(\.folderName), [folderName, folderName, folderName])
    XCTAssertEqual(queue.map(\.fileName), ["001 - 1.mp3", "002 - 2.mp3", "003 - 12.mp3"])
    XCTAssertEqual(
      queue.map { $0.request.url?.lastPathComponent },
      ["1.mp3", "2.mp3", "12.mp3"]
    )
    XCTAssertEqual(
      store.takeLandedSource(at: folderName),
      MediaServerSourceInfo(kind: .hummingbird, connectionId: "home", itemId: "77", dueDate: due, shouldBindFolder: true)
    )
    let folderURL = DataManager.getDocumentsFolderURL().appendingPathComponent(folderName)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL.appendingPathComponent("playlist.m3u").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL.path))
  }

  /// July added " (bookId)" to every folder, which became the book's title and was read aloud
  func testASecondBookWithTheSameTitleGetsTheNextNumber() throws {
    clearDocuments("Same Title")
    clearDocuments("Same Title 2")

    try viewModel.startDownloads(of: resources(["1.mp3", "2.mp3"], bookId: 1), for: item(bookId: 1, title: "Same Title"), connectionId: "home")
    try viewModel.startDownloads(of: resources(["1.mp3", "2.mp3"], bookId: 2), for: item(bookId: 2, title: "Same Title"), connectionId: "home")

    XCTAssertEqual(Set(downloadService.downloadQueue.compactMap(\.folderName)), ["Same Title", "Same Title 2"])
    XCTAssertEqual(store.takeLandedSource(at: "Same Title")?.itemId, "1")
    XCTAssertEqual(store.takeLandedSource(at: "Same Title 2")?.itemId, "2")
  }

  /// A connection signed out while the server prepared the book queues nothing
  func testARemovedConnectionQueuesNothing() {
    XCTAssertThrowsError(
      try viewModel.startDownloads(of: resources(["1.mp3", "2.mp3"]), for: item(title: "Gone"), connectionId: "gone")
    )
    XCTAssertTrue(downloadService.downloadQueue.isEmpty)
    XCTAssertFalse(store.hasLandedSource(at: "Gone"))
  }

  // MARK: - Due dates on the list

  func testTheDueDateReadsAsACountdown() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 1_793_534_400)  // 2026-11-01 12:00 UTC

    XCTAssertEqual(
      HummingbirdLibraryListItemView.dueDateLabel(for: now.addingTimeInterval(3600 * 11), now: now, calendar: calendar),
      "hummingbird_due_today".localized
    )
    XCTAssertEqual(
      HummingbirdLibraryListItemView.dueDateLabel(for: now.addingTimeInterval(86_400 * 3), now: now, calendar: calendar),
      String(format: "hummingbird_due_format".localized, Self.relative(now.addingTimeInterval(86_400 * 3), now))
    )
    XCTAssertEqual(
      HummingbirdLibraryListItemView.dueDateLabel(for: now.addingTimeInterval(-86_400 * 2), now: now, calendar: calendar),
      String(format: "hummingbird_overdue_format".localized, Self.relative(now.addingTimeInterval(-86_400 * 2), now))
    )
    // Every key exists: a missing one reads aloud as its name
    for key in ["hummingbird_due_today", "hummingbird_due_format", "hummingbird_overdue_format"] {
      XCTAssertNotEqual(key.localized, key)
    }
  }

  private static func relative(_ date: Date, _ now: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    formatter.dateTimeStyle = .named
    return formatter.localizedString(for: date, relativeTo: now)
  }

  /// Every key the Hummingbird screens use is in the strings table (July's six weren't)
  func testEveryHummingbirdStringExists() {
    for key in [
      "hummingbird_preparing_download", "hummingbird_no_audio", "hummingbird_bookshelf_empty",
      "hummingbird_search_no_results", "hummingbird_due_today", "hummingbird_due_format",
      "hummingbird_overdue_format", "voiceover_close_button", "download_title",
    ] {
      XCTAssertNotEqual(key.localized, key, key)
    }
  }
}
