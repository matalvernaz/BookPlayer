//
//  MediaServerDownloadPushTests.swift
//  BookPlayerTests
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

@testable import BookPlayer
@testable import BookPlayerKit
import Combine
import CoreData
import XCTest

/// The keys a download's provenance gives upstream's progress push (fork): only Audiobookshelf and
/// Jellyfin downloads whose server is known, never the tracks of one multi-file item
final class MediaServerPushKeysTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var store: MediaServerSourceStore!

  override func setUp() {
    super.setUp()
    suiteName = "MediaServerPushKeysTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    store = MediaServerSourceStore(userDefaults: defaults)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    store = nil
    defaults = nil
    super.tearDown()
  }

  private func audiobookshelf(_ itemId: String, host: String? = "https://abs.example.com", connection: String = "abs-1") -> MediaServerSourceInfo {
    MediaServerSourceInfo(kind: .audiobookshelf, connectionId: connection, itemId: itemId, hostId: host)
  }

  private func jellyfin(_ itemId: String, host: String? = "8d3f-guid") -> MediaServerSourceInfo {
    MediaServerSourceInfo(kind: .jellyfin, connectionId: "jf-1", itemId: itemId, hostId: host)
  }

  private func keys(_ providerName: String, _ providerId: String, _ hostId: String) -> MediaServerSourceStore.PushKeys {
    MediaServerSourceStore.PushKeys(providerName: providerName, providerId: providerId, hostId: hostId)
  }

  func testADownloadNamesItsServerItem() {
    store.setSource(audiobookshelf("li_1"), for: "Dune.m4b")
    store.setSource(jellyfin("jf_2"), for: "Messiah.m4b")

    XCTAssertEqual(store.pushKeys(for: "Dune.m4b"), keys("audiobookshelf", "li_1", "https://abs.example.com"))
    XCTAssertEqual(store.pushKeys(for: "Messiah.m4b"), keys("jellyfin", "jf_2", "8d3f-guid"))
  }

  /// The provider names are upstream's `ProviderName` values: the push's lane and its switch read them
  func testTheProviderNamesAreUpstreams() {
    XCTAssertEqual(ExternalResource.ProviderName(rawValue: MediaServerKind.audiobookshelf.rawValue)?.mediaServer, .audiobookshelf)
    XCTAssertEqual(ExternalResource.ProviderName(rawValue: MediaServerKind.jellyfin.rawValue)?.mediaServer, .jellyfin)
  }

  func testNothingWithoutAKnownServer() {
    store.setSource(audiobookshelf("li_1", host: nil), for: "July.m4b")
    store.setSource(audiobookshelf("li_2", host: ""), for: "Empty.m4b")

    XCTAssertNil(store.pushKeys(for: "July.m4b"))
    XCTAssertNil(store.pushKeys(for: "Empty.m4b"))
    XCTAssertNil(store.pushKeys(for: "Local.m4b"))
  }

  /// Hummingbird and SoundBooth aren't upstream providers, whatever their entries carry
  func testNothingForHummingbirdOrSoundBooth() {
    store.setSource(MediaServerSourceInfo(kind: .hummingbird, connectionId: "hb", itemId: "12", hostId: "x"), for: "Daisy")
    store.setSource(MediaServerSourceInfo(kind: .soundbooth, connectionId: "sb", itemId: "b1", hostId: "x"), for: "Drama")

    XCTAssertNil(store.pushKeys(for: "Daisy"))
    XCTAssertNil(store.pushKeys(for: "Drama"))
  }

  /// A zip without a wrapping folder lands one item's tracks as separate books: none of them is the
  /// item's position
  func testTheTracksOfOneItemSendNothing() {
    store.setSource(audiobookshelf("li_9"), for: "Book/01.mp3")
    store.setSource(audiobookshelf("li_9"), for: "Book/02.mp3")
    store.setSource(audiobookshelf("li_8"), for: "01.mp3")
    store.setSource(audiobookshelf("li_8"), for: "02.mp3")

    XCTAssertNil(store.pushKeys(for: "Book/01.mp3"))
    XCTAssertNil(store.pushKeys(for: "Book/02.mp3"))
    XCTAssertNil(store.pushKeys(for: "01.mp3"))
  }

  /// Copies of one item in different folders each push, as upstream's streamed copies do
  func testCopiesInDifferentFoldersEachSend() {
    store.setSource(audiobookshelf("li_1"), for: "Shelf A/Dune.m4b")
    store.setSource(audiobookshelf("li_1"), for: "Shelf B/Dune.m4b")

    XCTAssertEqual(store.pushKeys(for: "Shelf A/Dune.m4b"), keys("audiobookshelf", "li_1", "https://abs.example.com"))
    XCTAssertEqual(store.pushKeys(for: "Shelf B/Dune.m4b"), keys("audiobookshelf", "li_1", "https://abs.example.com"))
  }

  /// The answer is remembered per path until the store changes: a move re-asks
  func testTheAnswerFollowsAMove() {
    store.setSource(audiobookshelf("li_9"), for: "Book/01.mp3")
    store.setSource(audiobookshelf("li_9"), for: "Book/02.mp3")
    XCTAssertNil(store.pushKeys(for: "Book/01.mp3"))

    store.moveSources(from: "Book/02.mp3", to: "Elsewhere/02.mp3")

    XCTAssertEqual(store.pushKeys(for: "Book/01.mp3"), keys("audiobookshelf", "li_9", "https://abs.example.com"))
    XCTAssertEqual(store.pushKeys(for: "Elsewhere/02.mp3"), keys("audiobookshelf", "li_9", "https://abs.example.com"))
  }

  func testTheAnswerFollowsANewSiblingAndADelete() {
    store.setSource(audiobookshelf("li_9"), for: "Book/01.mp3")
    XCTAssertNotNil(store.pushKeys(for: "Book/01.mp3"))

    store.setSource(audiobookshelf("li_9"), for: "Book/02.mp3")
    XCTAssertNil(store.pushKeys(for: "Book/01.mp3"))

    store.removeSources(under: "Book/02.mp3")
    XCTAssertNotNil(store.pushKeys(for: "Book/01.mp3"))
    XCTAssertNil(store.pushKeys(for: "Book/02.mp3"))
  }

  // MARK: - Hosts

  /// Every stage takes its connection's current host: July entries get one, an edited address or a
  /// server that now reports its id is followed, and a connection that's gone leaves the host it had
  func testTheRefreshFollowsTheConnections() {
    store.setSource(audiobookshelf("li_1", host: nil), for: "July.m4b")
    store.setSource(audiobookshelf("li_2", host: "https://old.example.com"), for: "Moved.m4b")
    store.setSource(jellyfin("jf_3", host: "https://jf.example.com"), for: "Guid.m4b")
    store.setSource(audiobookshelf("li_4", host: "https://gone.example.com", connection: "abs-gone"), for: "Gone.m4b")
    store.setSource(MediaServerSourceInfo(kind: .hummingbird, connectionId: "abs-1", itemId: "12"), for: "Daisy")
    store.registerPendingDownload(URL(string: "https://abs.example.com/api/items/li_5/download")!, info: audiobookshelf("li_5", host: nil))
    store.registerLandingSource(audiobookshelf("li_6", host: nil), at: "Landed.m4b")

    store.refreshHostIds([
      .audiobookshelf: ["abs-1": "https://abs.example.com"],
      .jellyfin: ["jf-1": "8d3f-guid"],
    ])

    XCTAssertEqual(store.source(for: "July.m4b")?.hostId, "https://abs.example.com")
    XCTAssertEqual(store.source(for: "Moved.m4b")?.hostId, "https://abs.example.com")
    XCTAssertEqual(store.source(for: "Guid.m4b")?.hostId, "8d3f-guid")
    XCTAssertEqual(store.source(for: "Gone.m4b")?.hostId, "https://gone.example.com")
    XCTAssertNil(store.source(for: "Daisy")?.hostId, "only Audiobookshelf and Jellyfin entries")
    store.landPendingDownload(URL(string: "https://abs.example.com/api/items/li_5/download")!, at: "Pending.m4b")
    XCTAssertEqual(store.takeLandedSource(at: "Pending.m4b")?.hostId, "https://abs.example.com")
    XCTAssertEqual(store.takeLandedSource(at: "Landed.m4b")?.hostId, "https://abs.example.com")
    XCTAssertEqual(store.pushKeys(for: "July.m4b"), keys("audiobookshelf", "li_1", "https://abs.example.com"))
  }

  /// Stores from before the field read as they were, and one written with it keeps it
  func testAStoreWithoutHostsStillReadsAndAHostIsKept() {
    let july = #"{"Dune.m4b": {"kind": "audiobookshelf", "connectionId": "c1", "itemId": "li_1"}}"#
    defaults.set(Data(july.utf8), forKey: "MediaServerSourceStore.resolved")
    let upgraded = MediaServerSourceStore(userDefaults: defaults)
    XCTAssertEqual(upgraded.source(for: "Dune.m4b"), MediaServerSourceInfo(kind: .audiobookshelf, connectionId: "c1", itemId: "li_1"))

    upgraded.setSource(audiobookshelf("li_2"), for: "Messiah.m4b")
    let reread = MediaServerSourceStore(userDefaults: defaults)
    XCTAssertEqual(reread.source(for: "Messiah.m4b")?.hostId, "https://abs.example.com")
  }
}

/// What `updatePlaybackTime` hands upstream's progress push: one key set per update, the link's when
/// the book has one, else its provenance's
@MainActor
final class MediaServerDownloadPushLibraryTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var store: MediaServerSourceStore!
  private var sut: LibraryService!
  private var subscription: AnyCancellable?

  override func setUp() {
    super.setUp()
    DataTestUtils.clearFolderContents(url: DataManager.getProcessedFolderURL())
    suiteName = "MediaServerDownloadPushLibraryTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    store = MediaServerSourceStore(userDefaults: defaults)
    sut = LibraryService()
    sut.setup(dataManager: DataManager(coreDataStack: CoreDataStack(testPath: "/dev/null")), audioMetadataService: AudioMetadataService())
    sut.mediaServerSourceStore = store
    _ = sut.getLibrary()
  }

  override func tearDown() {
    subscription = nil
    DataTestUtils.clearFolderContents(url: DataManager.getProcessedFolderURL())
    defaults.removePersistentDomain(forName: suiteName)
    sut = nil
    store = nil
    defaults = nil
    super.tearDown()
  }

  private let absEntry = MediaServerSourceInfo(kind: .audiobookshelf, connectionId: "abs-1", itemId: "li_1", hostId: "https://abs.example.com")

  private func rootBook(_ title: String) -> Book {
    let book = StubFactory.book(dataManager: sut.dataManager, title: title, duration: 100)
    sut.getLibraryReference().addToItems(book)
    sut.dataManager.saveContext()
    return book
  }

  /// The first update `updatePlaybackTime` publishes: a new library's throttle lets it through at once
  private func published(for relativePath: String) async throws -> [String: Any] {
    var received: [String: Any]?
    let arrived = expectation(description: "progress published")
    subscription = sut.progressUpdatePublisher.sink { params in
      guard received == nil else { return }
      received = params
      arrived.fulfill()
    }
    sut.updatePlaybackTime(relativePath: relativePath, time: 30, date: Date(), scheduleSave: false)
    await fulfillment(of: [arrived], timeout: 12)
    return try XCTUnwrap(received)
  }

  func testADownloadSendsItsServerItem() async throws {
    let book = rootBook("Dune")
    store.setSource(absEntry, for: book.relativePath)

    let params = try await published(for: book.relativePath)

    XCTAssertEqual(params["providerName"] as? String, "audiobookshelf")
    XCTAssertEqual(params["providerId"] as? String, "li_1")
    XCTAssertEqual(params["hostId"] as? String, "https://abs.example.com")
    XCTAssertEqual(params["currentTime"] as? Double, 30)
  }

  func testAJellyfinDownloadToo() async throws {
    let book = rootBook("Messiah")
    store.setSource(MediaServerSourceInfo(kind: .jellyfin, connectionId: "jf-1", itemId: "jf_2", hostId: "8d3f-guid"), for: book.relativePath)

    let params = try await published(for: book.relativePath)

    XCTAssertEqual(params["providerName"] as? String, "jellyfin")
    XCTAssertEqual(params["providerId"] as? String, "jf_2")
    XCTAssertEqual(params["hostId"] as? String, "8d3f-guid")
  }

  /// A book with both (a download that refilled a streamed book) sends only its link's keys: one writer
  func testALinkedBookSendsOnlyItsLink() async throws {
    let book = rootBook("Refilled")
    store.setSource(absEntry, for: book.relativePath)
    let link = SyncableExternalResource(
      providerName: "jellyfin",
      providerId: "jf-link",
      syncStatus: ExternalResource.SyncStatus.stream.rawValue,
      lastSyncedAt: nil,
      processedFile: true,
      hostId: "jf-host"
    )
    _ = ExternalResource.create(link, libraryItem: book, in: sut.dataManager.getContext())
    sut.dataManager.saveContext()

    let params = try await published(for: book.relativePath)

    XCTAssertEqual(params["providerName"] as? String, "jellyfin")
    XCTAssertEqual(params["providerId"] as? String, "jf-link")
    XCTAssertEqual(params["hostId"] as? String, "jf-host")
  }

  /// A Hummingbird bookmark the puller applies goes through `updatePlaybackTime` and isn't sent anywhere
  func testAHummingbirdPositionSendsNothing() async throws {
    let book = rootBook("Daisy")
    store.setSource(MediaServerSourceInfo(kind: .hummingbird, connectionId: "hb-1", itemId: "12"), for: book.relativePath)

    let params = try await published(for: book.relativePath)

    XCTAssertNil(params["providerName"])
    XCTAssertNil(params["hostId"])
  }

  /// Deleting a download drops its entry, so another book later at the same path sends nothing
  func testAPathReusedAfterADeleteSendsNothing() async throws {
    let book = rootBook("Dune")
    let path: String = book.relativePath
    store.setSource(absEntry, for: path)
    let item = try XCTUnwrap(sut.getSimpleItem(with: path))
    try sut.delete([item], mode: .deep)
    XCTAssertNil(store.source(for: path), "precondition: the delete dropped the entry")

    let replacement = rootBook("Dune")
    XCTAssertEqual(replacement.relativePath, path, "precondition: the same path")
    let params = try await published(for: replacement.relativePath)

    XCTAssertNil(params["providerName"])
  }

  /// A track inside an unbound multi-file download has no entry of its own: it sends nothing
  func testATrackOfAnUnboundDownloadSendsNothing() async throws {
    let folder = try StubFactory.folder(dataManager: sut.dataManager, title: "Volume")
    sut.getLibraryReference().addToItems(folder)
    sut.dataManager.saveContext()
    let tracks = ["Volume 1", "Volume 2"].map { rootBook($0) }
    _ = try sut.moveItems(tracks.map { LibraryItemRef(relativePath: $0.relativePath, uuid: $0.uuid) }, inside: folder.relativePath)
    store.setSource(absEntry, for: folder.relativePath)
    let track = try XCTUnwrap(sut.fetchContents(at: folder.relativePath, limit: nil, offset: nil)?.first)

    let params = try await published(for: track.relativePath)

    XCTAssertNil(params["providerName"])
  }

  /// A bound book's position spans its parts, so a bound book whose entry is on its folder sends it
  func testABoundBookSendsTheItem() async throws {
    let folder = try StubFactory.folder(dataManager: sut.dataManager, title: "Bound")
    sut.getLibraryReference().addToItems(folder)
    sut.dataManager.saveContext()
    let tracks = ["Bound 1", "Bound 2"].map { rootBook($0) }
    _ = try sut.moveItems(tracks.map { LibraryItemRef(relativePath: $0.relativePath, uuid: $0.uuid) }, inside: folder.relativePath)
    try sut.updateFolder(at: folder.relativePath, type: .bound)
    store.setSource(absEntry, for: folder.relativePath)

    let params = try await published(for: folder.relativePath)

    XCTAssertEqual(params["providerId"] as? String, "li_1")
  }
}

/// Downloads record their server's identity, and the push finds the connection by it
@MainActor
final class MediaServerDownloadHostTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var store: MediaServerSourceStore!

  override func setUp() {
    super.setUp()
    suiteName = "MediaServerDownloadHostTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    store = MediaServerSourceStore(userDefaults: defaults)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    store = nil
    defaults = nil
    super.tearDown()
  }

  func testAnAudiobookshelfDownloadRecordsItsServer() throws {
    let service = AudiobookShelfConnectionService(keychainService: KeychainServiceMock(), defaults: defaults)
    service.mediaServerSourceStore = store
    let connection = AudiobookShelfConnectionData(
      id: "abs-1",
      url: URL(string: "https://Abs.Example.com/")!,
      serverName: "abs",
      userID: "u1",
      userName: "reader",
      apiToken: "token"
    )
    service.useConnection(connection)

    let request = try service.createItemDownloadRequest(
      AudiobookShelfLibraryItem(id: "li_1", title: "Dune", kind: .audiobook, libraryId: "lib-1")
    )
    store.landPendingDownload(try XCTUnwrap(request.url), at: "probe.m4b")

    let info = try XCTUnwrap(store.takeLandedSource(at: "probe.m4b"))
    XCTAssertEqual(info.hostId, connection.stableHostId)
    XCTAssertEqual(info.itemId, "li_1")
    XCTAssertEqual(IntegrationHostResolver.connection(for: info.hostId, in: [connection])?.id, "abs-1")
  }

  func testAJellyfinDownloadRecordsItsServer() throws {
    let service = JellyfinConnectionService(keychainService: KeychainServiceMock())
    service.mediaServerSourceStore = store
    let connection = JellyfinConnectionData(
      id: "jf-1",
      serverId: "8D3F-GUID",
      url: URL(string: "https://jf.example.com/jellyfin")!,
      serverName: "jf",
      userID: "u1",
      userName: "reader",
      accessToken: "token"
    )
    service.useConnection(connection)

    let request = try service.createItemDownloadRequest(JellyfinLibraryItem(id: "item-1", name: "Book", kind: .audiobook))
    store.landPendingDownload(try XCTUnwrap(request.url), at: "probe.m4b")

    let info = try XCTUnwrap(store.takeLandedSource(at: "probe.m4b"))
    XCTAssertEqual(info.hostId, "8D3F-GUID")
    XCTAssertEqual(IntegrationHostResolver.connection(for: "8d3f-guid", in: [connection])?.id, "jf-1", "the server id matches in any case")
  }
}
