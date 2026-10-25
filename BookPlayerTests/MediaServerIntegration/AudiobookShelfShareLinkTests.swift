//
//  AudiobookShelfShareLinkTests.swift
//  BookPlayerTests
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

@testable import BookPlayer
@testable import BookPlayerKit
import XCTest
import ZipArchive

// MARK: - The Folders tab

final class AudiobookShelfFolderLevelTests: XCTestCase {
  private func book(_ id: String, _ relPath: String?) -> AudiobookShelfLibraryItem {
    AudiobookShelfLibraryItem(id: id, title: id, kind: .audiobook, libraryId: "lib", relPath: relPath)
  }

  private var library: [AudiobookShelfLibraryItem] {
    [
      book("b10", "Series/Book 10"),
      book("b2", "Series/Book 2"),
      book("deep", "Series/Extras/Deep"),
      book("loose10", "Loose 10"),
      book("loose2", "Loose 2"),
      book("alpha", "Alpha/One"),
      book("nopath", nil),
    ]
  }

  /// Subfolders first, then the books directly at the level, each in disk-name order (numbers as
  /// numbers); a book without a path isn't on any level
  func testTheTopLevelIsItsFoldersThenItsBooks() {
    let level = AudiobookShelfLibraryViewModel.folderLevelItems(from: library, at: "", libraryId: "lib")

    XCTAssertEqual(level.map(\.id), ["Alpha", "Series", "loose2", "loose10"])
    XCTAssertEqual(level.map(\.kind), [.folder, .folder, .audiobook, .audiobook])
    XCTAssertEqual(level[1].relPath, "Series")
    XCTAssertEqual(level[0].subtitle, "1 book")
    XCTAssertEqual(level[1].subtitle, "3 books", "books in subfolders count")
  }

  func testANestedLevelKeepsItsFullPath() {
    let level = AudiobookShelfLibraryViewModel.folderLevelItems(from: library, at: "Series", libraryId: "lib")

    XCTAssertEqual(level.map(\.id), ["Series/Extras", "b2", "b10"])
    XCTAssertEqual(level.first?.relPath, "Series/Extras")
    XCTAssertEqual(
      AudiobookShelfLibraryViewModel.folderLevelItems(from: library, at: "Series/Extras", libraryId: "lib").map(\.id),
      ["deep"]
    )
  }

  /// "Series" mustn't pick up "Series 2"
  func testASiblingWithTheSamePrefixIsntInside() {
    let books = [book("a", "Series/A"), book("b", "Series 2/B")]

    XCTAssertEqual(AudiobookShelfLibraryViewModel.folderLevelItems(from: books, at: "Series", libraryId: "lib").map(\.id), ["a"])
  }
}

@MainActor
final class AudiobookShelfFolderFetchTests: XCTestCase {
  private var viewModel: AudiobookShelfLibraryViewModel!
  private var navigation: BPNavigation!
  /// One per folder request, answered by the test
  private var pending = [CheckedContinuation<[AudiobookShelfLibraryItem], Error>]()

  override func setUp() {
    super.setUp()
    navigation = BPNavigation()
    pending = []
    let accountService = AccountService()
    accountService.setup(
      dataManager: DataManager(coreDataStack: CoreDataStack(testPath: "/dev/null")),
      client: NetworkClientMock(mockedResponse: Empty()),
      keychain: KeychainServiceMock()
    )
    viewModel = AudiobookShelfLibraryViewModel(
      source: .folders(libraryID: "lib", path: ""),
      connectionService: AudiobookShelfConnectionService(keychainService: KeychainServiceMock()),
      singleFileDownloadService: SingleFileDownloadService(networkClient: NetworkClientMock(mockedResponse: Empty())),
      accountService: accountService,
      onImportConfirmed: { _ in },
      navigation: navigation,
      navigationTitle: "Library"
    )
    viewModel.loadFolderItems = { [unowned self] _ in
      try await withCheckedThrowingContinuation { self.pending.append($0) }
    }
  }

  override func tearDown() {
    for continuation in pending {
      continuation.resume(returning: [])
    }
    pending = []
    viewModel = nil
    navigation = nil
    super.tearDown()
  }

  private func book(_ id: String) -> AudiobookShelfLibraryItem {
    AudiobookShelfLibraryItem(id: id, title: id, kind: .audiobook, libraryId: "lib", relPath: id)
  }

  /// Lets the view model's tasks run up to their next wait
  private func settle() async {
    for _ in 0..<5 {
      await Task.yield()
    }
    try? await Task.sleep(nanoseconds: 50_000_000)
  }

  private func waitForRequests(_ count: Int) async throws {
    for _ in 0..<100 where pending.count < count {
      await settle()
    }
    XCTAssertEqual(pending.count, count)
  }

  /// A fetch superseded while it waits mustn't show its answer or its error, nor clear the handle of the
  /// fetch that replaced it (which would let a second one start alongside)
  func testASupersededFetchStaysSilentAndKeepsItsReplacementsHandle() async throws {
    viewModel.fetchInitialItems()
    try await waitForRequests(1)
    viewModel.cancelFetchItems()
    viewModel.fetchInitialItems()
    try await waitForRequests(2)

    pending[0].resume(returning: [book("stale")])
    await settle()

    XCTAssertTrue(viewModel.items.isEmpty)
    XCTAssertNil(viewModel.error)
    viewModel.fetchInitialItems()
    await settle()
    XCTAssertEqual(pending.count, 2, "the replacement's handle survived, so no third request started")

    pending[1].resume(returning: [book("fresh")])
    await settle()
    XCTAssertEqual(viewModel.items.map(\.id), ["fresh"])
    pending = []
  }

  func testASupersededFetchsErrorIsDropped() async throws {
    viewModel.fetchInitialItems()
    try await waitForRequests(1)
    viewModel.cancelFetchItems()

    pending[0].resume(throwing: URLError(.badServerResponse))
    await settle()

    XCTAssertNil(viewModel.error)
    pending = []
  }

  /// URLSession cancels with `URLError.cancelled`, which is no error to show
  func testASessionCancellationIsNoError() async throws {
    viewModel.fetchInitialItems()
    try await waitForRequests(1)

    pending[0].resume(throwing: URLError(.cancelled))
    await settle()

    XCTAssertNil(viewModel.error)
    pending = []
  }

  func testAFailureIsShown() async throws {
    viewModel.fetchInitialItems()
    try await waitForRequests(1)

    pending[0].resume(throwing: URLError(.badServerResponse))
    await settle()

    XCTAssertEqual((viewModel.error as? URLError)?.code, .badServerResponse)
    pending = []
  }

  func testAFolderLevelKeepsDiskOrderAndCanBeSelected() {
    XCTAssertFalse(viewModel.showsSortPreferences)
    XCTAssertTrue(viewModel.allowsEditing)
    XCTAssertTrue(viewModel.isSearchable)
  }

  func testAFolderRowOpensItsLevel() {
    let folder = AudiobookShelfLibraryItem(folderName: "Series", path: "Series", libraryId: "lib", bookCount: 2)

    XCTAssertEqual(
      viewModel.destination(for: folder),
      .library(source: .folders(libraryID: "lib", path: "Series"), title: "Series")
    )
  }

  /// The Folders tab is a new way to reach Stream: it must still sell the entitlement first
  func testStreamingAFolderLevelWithoutTheEntitlementOffersSubscribing() {
    viewModel.onStreamTapped(useSelectedItems: false)

    XCTAssertTrue(navigation.showingSubscribe)
    XCTAssertNil(viewModel.pendingImportBatch)
  }
}

// MARK: - Share links: the server calls

/// `@unchecked Sendable`: a test double used from one task at a time
private final class ShareHTTPStub: IntegrationHTTPClient, @unchecked Sendable {
  private(set) var requests = [URLRequest]()
  var status = 200
  var body = Data("{}".utf8)

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }

  func redirectLocation(for request: URLRequest) async throws -> URL {
    throw URLError(.unsupportedURL)
  }
}

@MainActor
final class AudiobookShelfShareAPITests: XCTestCase {
  private let suiteName = "AudiobookShelfShareAPITests"
  private var http: ShareHTTPStub!
  private var service: AudiobookShelfConnectionService!
  private let home = AudiobookShelfConnectionData(
    id: "home",
    url: URL(string: "https://abs.example.com/audiobookshelf")!,
    serverName: "Home",
    userID: "u1",
    userName: "reader",
    apiToken: "home-token"
  )
  private let other = AudiobookShelfConnectionData(
    id: "other",
    url: URL(string: "https://other.example.com")!,
    serverName: "Other",
    userID: "u2",
    userName: "reader",
    apiToken: "other-token"
  )

  override func setUpWithError() throws {
    try super.setUpWithError()
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set("home", forKey: "audiobookshelf_active_connection_id")
    let keychain = KeychainServiceMock()
    try keychain.set([home, other], key: .audiobookshelfConnection)
    http = ShareHTTPStub()
    service = AudiobookShelfConnectionService(keychainService: keychain, httpClient: http, defaults: defaults)
    service.setup()
  }

  override func tearDown() {
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    http = nil
    service = nil
    super.tearDown()
  }

  private func sentBody() throws -> [String: Any] {
    let body = try XCTUnwrap(http.requests.first?.httpBody)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
  }

  /// A book's share goes to the server it came from, whichever server is active
  func testAShareIsMadeOnTheBooksOwnServer() async throws {
    http.body = Data(#"{"id": "sh_1", "slug": "dune-abc123", "expiresAt": 1800000000000}"#.utf8)

    let share = try await service.createMediaItemShare(
      mediaItemId: "media_1",
      slug: "dune-abc123",
      expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
      connectionId: "other"
    )

    XCTAssertEqual(share.id, "sh_1")
    XCTAssertEqual(share.slug, "dune-abc123")
    let request = try XCTUnwrap(http.requests.first)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.absoluteString, "https://other.example.com/api/share/mediaitem")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer other-token")
    let body = try sentBody()
    XCTAssertEqual(body["slug"] as? String, "dune-abc123")
    XCTAssertEqual(body["mediaItemType"] as? String, "book")
    XCTAssertEqual(body["mediaItemId"] as? String, "media_1")
    XCTAssertEqual(body["expiresAt"] as? Int64, 1_800_000_000_000)
    XCTAssertEqual(body["isDownloadable"] as? Bool, true)
  }

  func testALinkThatNeverExpiresSendsNull() async throws {
    http.body = Data(#"{"id": "sh_2", "slug": "s"}"#.utf8)

    _ = try await service.createMediaItemShare(mediaItemId: "m", slug: "s", expiresAt: nil, connectionId: "home")

    XCTAssertTrue(try sentBody()["expiresAt"] is NSNull)
  }

  /// A named connection that's gone (the share-link sentinel, a removed server) is never swapped for
  /// the active one: that server would get an item id it doesn't have
  func testAGoneConnectionFailsWithoutARequest() async {
    do {
      _ = try await service.createMediaItemShare(mediaItemId: "m", slug: "s", expiresAt: nil, connectionId: "gone")
      XCTFail("a gone connection should throw")
    } catch {
      XCTAssertEqual((error as? URLError)?.code, .userAuthenticationRequired)
    }
    do {
      _ = try await service.fetchMediaItemId(forLibraryItemId: "li_1", connectionId: SharedLinkImportService.sharedLinkConnectionId)
      XCTFail("the share-link sentinel names no server")
    } catch {
      XCTAssertEqual((error as? URLError)?.code, .userAuthenticationRequired)
    }

    XCTAssertTrue(http.requests.isEmpty)
  }

  /// With no connection named, the active one, with its router base path
  func testNoNamedConnectionUsesTheActiveServer() async throws {
    http.body = Data(#"{"id": "sh_3", "slug": "s"}"#.utf8)

    _ = try await service.createMediaItemShare(mediaItemId: "m", slug: "s", expiresAt: nil, connectionId: nil)

    XCTAssertEqual(http.requests.first?.url?.absoluteString, "https://abs.example.com/audiobookshelf/api/share/mediaitem")
    XCTAssertEqual(http.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer home-token")
  }

  /// 403 is the server's admin-only rule, not an expired session; only a 401 means signing in again
  func testWhatTheServerAnswersBecomesTheRightError() async {
    let cases: [(Int, Error)] = [
      (409, AudiobookShelfShareError.alreadyShared),
      (403, AudiobookShelfShareError.notPermitted),
      (401, IntegrationError.sessionExpired(serverName: "Home")),
      (500, IntegrationError.unexpectedResponse(code: 500)),
    ]

    for (status, expected) in cases {
      http.status = status
      do {
        _ = try await service.createMediaItemShare(mediaItemId: "m", slug: "s", expiresAt: nil, connectionId: "home")
        XCTFail("\(status) should throw")
      } catch let error as AudiobookShelfShareError {
        XCTAssertEqual(error, expected as? AudiobookShelfShareError, "\(status)")
      } catch let error as IntegrationError {
        XCTAssertEqual(error, expected as? IntegrationError, "\(status)")
      } catch {
        XCTFail("\(status): unexpected \(error)")
      }
    }
  }

  func testTheMediaItemIdComesFromTheLibraryItem() async throws {
    http.body = Data(#"{"id": "li_1", "media": {"id": "media_9", "duration": 10}}"#.utf8)

    let mediaItemId = try await service.fetchMediaItemId(forLibraryItemId: "li_1", connectionId: "home")

    XCTAssertEqual(mediaItemId, "media_9")
    XCTAssertEqual(http.requests.first?.httpMethod ?? "GET", "GET")
    XCTAssertEqual(http.requests.first?.url?.absoluteString, "https://abs.example.com/audiobookshelf/api/items/li_1")
  }

  func testRevokingDeletesTheShare() async throws {
    try await service.deleteMediaItemShare(shareId: "sh_1", connectionId: "home")

    XCTAssertEqual(http.requests.first?.httpMethod, "DELETE")
    XCTAssertEqual(http.requests.first?.url?.absoluteString, "https://abs.example.com/audiobookshelf/api/share/mediaitem/sh_1")
  }

  func testTheLinkPeopleGetIsTheServersSharePage() throws {
    XCTAssertEqual(
      try service.shareWebURL(slug: "dune-abc123", connectionId: "home").absoluteString,
      "https://abs.example.com/audiobookshelf/share/dune-abc123"
    )
  }
}

// MARK: - Share links: which items get the row

final class ShareLinkSourceTests: XCTestCase {
  private let suiteName = "ShareLinkSourceTests"
  private var userDefaults: UserDefaults!
  private var store: MediaServerSourceStore!
  private let home = AudiobookShelfConnectionData(
    id: "home",
    url: URL(string: "https://abs.example.com")!,
    serverName: "Home",
    userID: "u1",
    userName: "reader",
    apiToken: "t"
  )

  override func setUp() {
    super.setUp()
    userDefaults = UserDefaults(suiteName: suiteName)!
    userDefaults.removePersistentDomain(forName: suiteName)
    store = MediaServerSourceStore(userDefaults: userDefaults)
  }

  override func tearDown() {
    userDefaults.removePersistentDomain(forName: suiteName)
    store = nil
    userDefaults = nil
    super.tearDown()
  }

  private func item(
    _ relativePath: String,
    type: SimpleItemType = .book,
    links: [SimpleExternalResource]? = nil
  ) -> SimpleLibraryItem {
    SimpleLibraryItem(
      title: relativePath,
      details: "",
      speed: 1,
      currentTime: 0,
      duration: 100,
      percentCompleted: 0,
      isFinished: false,
      relativePath: relativePath,
      remoteURL: nil,
      artworkURL: nil,
      orderRank: 0,
      parentFolder: nil,
      originalFileName: relativePath,
      lastPlayDate: nil,
      type: type,
      uuid: UUID().uuidString,
      externalResources: links
    )
  }

  private func link(_ provider: ExternalResource.ProviderName, _ providerId: String, hostId: String?) -> SimpleExternalResource {
    SimpleExternalResource(
      providerName: provider.rawValue,
      providerId: providerId,
      syncStatus: ExternalResource.SyncStatus.stream.rawValue,
      lastSyncedAt: nil,
      hostId: hostId
    )
  }

  private func resolve(_ item: SimpleLibraryItem, connected: Bool = true) -> ShareLinkSource {
    ShareLinkSource.resolve(for: item, store: store, connections: [home], hasActiveConnection: connected)
  }

  private func onServer(_ itemId: String, connectionId: String = "home") -> MediaServerSourceInfo {
    MediaServerSourceInfo(kind: .audiobookshelf, connectionId: connectionId, itemId: itemId)
  }

  /// A streamed book's own link wins over anything recorded for its path
  func testAStreamedBooksLinkComesFirst() {
    store.setSource(onServer("li_recorded", connectionId: "elsewhere"), for: "Dune.m4b")

    XCTAssertEqual(
      resolve(item("Dune.m4b", links: [link(.audiobookshelf, "li_linked", hostId: home.stableHostId)])),
      .known(onServer("li_linked"))
    )
  }

  /// No saved server to make the link on
  func testALinkToAServerThatIsntSavedHasNoRow() {
    XCTAssertEqual(
      resolve(item("Dune.m4b", links: [link(.audiobookshelf, "li_1", hostId: "https://unknown.example.com")])),
      .none
    )
  }

  func testAnotherServersBookHasNoRow() {
    XCTAssertEqual(resolve(item("Dune.m4b", links: [link(.jellyfin, "jf_1", hostId: "jf-server")])), .none)

    store.setSource(MediaServerSourceInfo(kind: .jellyfin, connectionId: "j", itemId: "jf_2"), for: "Other.m4b")
    XCTAssertEqual(resolve(item("Other.m4b")), .none)
  }

  /// A Hardcover link is no server
  func testAHardcoverLinkDoesntCount() {
    store.setSource(onServer("li_4"), for: "Read.m4b")

    XCTAssertEqual(resolve(item("Read.m4b", links: [link(.hardcover, "hc_1", hostId: nil)])), .known(onServer("li_4")))
  }

  func testADownloadedBookUsesWhatWasRecorded() {
    store.setSource(onServer("li_5"), for: "Book.m4b")

    XCTAssertEqual(resolve(item("Book.m4b")), .known(onServer("li_5")))
  }

  /// A book assembled from one multi-file download is found through its files
  func testAFolderUsesWhatItsFilesAgreeOn() {
    store.setSource(onServer("li_6"), for: "Volume/01.mp3")
    store.setSource(onServer("li_6"), for: "Volume/02.mp3")

    XCTAssertEqual(resolve(item("Volume", type: .bound)), .known(onServer("li_6")))
  }

  /// A book someone sent through a share link is on their server, not one of yours
  func testABookFromSomeoneElsesShareHasNoRow() {
    store.setSource(onServer("li_7", connectionId: SharedLinkImportService.sharedLinkConnectionId), for: "Gift")

    XCTAssertEqual(resolve(item("Gift", type: .bound)), .none)
  }

  /// A download whose server isn't saved any more is looked for by title, never sent to another
  /// server under its old item id
  func testADownloadFromARemovedServerIsSearchedForByTitle() {
    store.setSource(onServer("li_8", connectionId: "removed"), for: "Old Server.m4b")

    XCTAssertEqual(resolve(item("Old Server.m4b")), .searchActiveServer)
    XCTAssertEqual(resolve(item("Old Server.m4b"), connected: false), .none)
  }

  func testNothingRecordedSearchesTheActiveServer() {
    XCTAssertEqual(resolve(item("Old Import.m4b")), .searchActiveServer)
    XCTAssertEqual(resolve(item("Old Import.m4b"), connected: false), .none)
  }
}

// MARK: - Share links: the recipient's side

final class ShareLinkUniversalLinkTests: XCTestCase {
  private func activity(_ url: String) -> NSUserActivity {
    let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
    activity.webpageURL = URL(string: url)
    return activity
  }

  func testAShareLinkIsASharedImport() {
    let action = CommandParser.parse(activity("https://audiobooks.thealvernaz.space/share/dune-abc123"))

    XCTAssertEqual(action?.command, .sharedImport)
    XCTAssertEqual(action?.getQueryValue(for: "url"), "https://audiobooks.thealvernaz.space/share/dune-abc123")
  }

  func testUnderARouterBasePathToo() {
    XCTAssertEqual(
      CommandParser.parse(activity("https://audiobooks.thealvernaz.space/audiobookshelf/share/dune-abc123"))?.command,
      .sharedImport
    )
  }

  func testOtherPagesAreLeftToTheBrowser() {
    for url in [
      "https://audiobooks.thealvernaz.space/library/abc",
      "https://audiobooks.thealvernaz.space/share/",
      "https://audiobooks.thealvernaz.space/share",
      "http://audiobooks.thealvernaz.space/share/dune-abc123",
    ] {
      XCTAssertNil(CommandParser.parse(activity(url)), url)
    }
  }

  /// Through the URL scheme any web page could start a download from any server
  func testTheURLSchemeCantStartASharedImport() {
    XCTAssertNil(CommandParser.parse(URL(string: "bookplayer://sharedImport?url=https://evil.example/share/x")!))
  }

  func testThePlaybackActivityStillPlays() {
    XCTAssertEqual(CommandParser.parse(NSUserActivity(activityType: Constants.UserActivityPlayback))?.command, .play)
  }
}

@MainActor
final class SharedLinkImportNamingTests: XCTestCase {
  func testTheShareAPIIsBesideTheSharePage() {
    XCTAssertEqual(
      SharedLinkImportService.publicShareURL(for: URL(string: "https://h.example/share/s1")!)?.absoluteString,
      "https://h.example/public/share/s1"
    )
    XCTAssertEqual(
      SharedLinkImportService.publicShareURL(for: URL(string: "https://h.example:8443/audiobookshelf/share/s1")!)?.absoluteString,
      "https://h.example:8443/audiobookshelf/public/share/s1"
    )
    XCTAssertNil(SharedLinkImportService.publicShareURL(for: URL(string: "https://h.example/library/s1")!))
  }

  private func track(_ index: Int, _ title: String?, _ mimeType: String? = nil) -> SharedLinkImportService.PublicShareResponse.AudioTrack {
    SharedLinkImportService.PublicShareResponse.AudioTrack(index: index, title: title, contentUrl: "/t/\(index)", mimeType: mimeType)
  }

  /// The index first, zero-padded, keeps the server's order; only a real audio extension is kept
  func testTrackFilesAreNamedInPlayOrder() {
    XCTAssertEqual(SharedLinkImportService.trackFileName(for: track(1, "Opening.mp3")), "001 - Opening.mp3")
    XCTAssertEqual(SharedLinkImportService.trackFileName(for: track(2, "Chapter Two", "audio/mpeg")), "002 - Chapter Two.mp3")
    XCTAssertEqual(
      SharedLinkImportService.trackFileName(for: track(3, "Chapter 1.Intro", "audio/mp4")),
      "003 - Chapter 1.Intro.m4a",
      "a dot in a title isn't a file type"
    )
    XCTAssertEqual(
      SharedLinkImportService.trackFileName(for: track(6, "Part 1. The Beginning", "audio/mp4")),
      "006 - Part 1. The Beginning.m4a"
    )
    XCTAssertEqual(SharedLinkImportService.trackFileName(for: track(4, nil)), "004 - Track 4.m4a")
    XCTAssertEqual(SharedLinkImportService.trackFileName(for: track(5, "a/b: c.mp3")), "005 - a_b_ c.mp3")
  }

  /// A title can't climb out of Documents or hide itself
  func testTheFolderIsNamedSafelyAfterTheTitle() {
    XCTAssertEqual(MediaServerDownloadFolders.folderName(title: "Dune", fallback: "dune-abc"), "Dune")
    XCTAssertEqual(MediaServerDownloadFolders.folderName(title: "", fallback: "dune-abc"), "dune-abc")
    XCTAssertEqual(MediaServerDownloadFolders.folderName(title: "..", fallback: "s"), "untitled_file")
    XCTAssertEqual(MediaServerDownloadFolders.folderName(title: "../../Library", fallback: "s"), "Library")
    XCTAssertEqual(MediaServerDownloadFolders.folderName(title: ".hidden", fallback: "s"), "hidden")
    let long = MediaServerDownloadFolders.folderName(title: String(repeating: "書", count: 200), fallback: "s")
    XCTAssertLessThanOrEqual(long.utf8.count, 200)
    XCTAssertFalse(long.isEmpty)
  }

  /// Two shares with the same title, both waiting to be imported, get folders of their own, each with
  /// its own provenance
  func testSameTitleSharesGetFoldersOfTheirOwn() throws {
    let suiteName = "SharedLinkImportNamingTests"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = MediaServerSourceStore(userDefaults: defaults)
    let title = "Reserve \(UUID().uuidString.prefix(8))"
    let documents = DataManager.getDocumentsFolderURL()
    defer {
      for name in [title, "\(title) 2", "\(title) 3", "\(title) 4", "\(title) 5"] {
        try? FileManager.default.removeItem(at: documents.appendingPathComponent(name))
      }
    }
    func share(_ itemId: String) -> MediaServerSourceInfo {
      MediaServerSourceInfo(kind: .audiobookshelf, connectionId: SharedLinkImportService.sharedLinkConnectionId, itemId: itemId, shouldBindFolder: true)
    }

    let first = MediaServerDownloadFolders.reserveFolder(named: title, info: share("li_a"), store: store, folderInUse: { _ in false })
    let second = MediaServerDownloadFolders.reserveFolder(named: title, info: share("li_b"), store: store, folderInUse: { _ in false })

    XCTAssertEqual(first, title)
    XCTAssertEqual(second, "\(title) 2")
    XCTAssertEqual(store.takeLandedSource(at: first)?.itemId, "li_a")
    XCTAssertEqual(store.takeLandedSource(at: second)?.itemId, "li_b")

    // A folder already in Documents, and one a queued download is filling, are taken too
    try FileManager.default.createDirectory(at: documents.appendingPathComponent(title), withIntermediateDirectories: true)
    let third = MediaServerDownloadFolders.reserveFolder(
      named: title,
      info: share("li_c"),
      store: store,
      folderInUse: { $0 == "\(title) 2" }
    )
    XCTAssertEqual(third, "\(title) 3")
  }

  /// A readable title prefix and a random suffix, safe in a URL path
  func testSlugs() {
    let slug = ShareLinkSheetView.makeSlug(from: "The Hobbit: There & Back Again!")
    XCTAssertTrue(slug.hasPrefix("the-hobbit-there-back-again-"), slug)
    XCTAssertEqual(slug.count, "the-hobbit-there-back-again-".count + 6)
    XCTAssertEqual(ShareLinkSheetView.makeSlug(from: "!!!").count, 6)
    XCTAssertLessThanOrEqual(ShareLinkSheetView.makeSlug(from: String(repeating: "a", count: 80)).count, 30 + 7)
    XCTAssertNotEqual(ShareLinkSheetView.makeSlug(from: "Dune"), ShareLinkSheetView.makeSlug(from: "Dune"))
  }
}

// MARK: - Export

final class ShareExportArchiverTests: XCTestCase {
  func testTheZipIsNamedSafelyAfterTheTitle() {
    XCTAssertEqual(ShareExportArchiver.archiveFileName(for: "AC/DC: Live"), "AC_DC_ Live.zip")
  }

  func testAFolderGoesAsAZipOfItsFiles() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)/My Book")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
    try Data("one".utf8).write(to: folder.appendingPathComponent("01.mp3"))
    try Data("two".utf8).write(to: folder.appendingPathComponent("02.mp3"))

    let zip = try await ShareExportArchiver.zipDirectory(at: folder, archiveName: "My Book")
    defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }

    XCTAssertEqual(zip.lastPathComponent, "My Book.zip")
    let unzipped = folder.deletingLastPathComponent().appendingPathComponent("unzipped")
    XCTAssertTrue(SSZipArchive.unzipFile(atPath: zip.path, toDestination: unzipped.path))
    let names = (FileManager.default.enumerator(atPath: unzipped.path)?.allObjects as? [String] ?? [])
      .map { ($0 as NSString).lastPathComponent }
    XCTAssertTrue(names.contains("01.mp3"), "\(names)")
    XCTAssertTrue(names.contains("02.mp3"), "\(names)")
  }
}
