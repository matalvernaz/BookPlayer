//
//  MediaServerProvenanceLibraryTests.swift
//  BookPlayerTests
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

@testable import BookPlayer
@testable import BookPlayerKit
import XCTest

/// `LibraryService` keeps media-server provenance in step with the library: per item as each move or
/// delete succeeds, and once for a folder rename
@MainActor
final class MediaServerProvenanceLibraryTests: XCTestCase {
  private let suiteName = "MediaServerProvenanceLibraryTests"
  private var userDefaults: UserDefaults!
  private var store: MediaServerSourceStore!
  private var sut: LibraryService!
  /// Files made immutable to make an operation fail; made mutable again before cleanup
  private var lockedFiles = [URL]()

  override func setUp() {
    super.setUp()
    DataTestUtils.clearFolderContents(url: DataManager.getProcessedFolderURL())
    userDefaults = UserDefaults(suiteName: suiteName)!
    userDefaults.removePersistentDomain(forName: suiteName)
    store = MediaServerSourceStore(userDefaults: userDefaults)
    let dataManager = DataManager(coreDataStack: CoreDataStack(testPath: "/dev/null"))
    sut = LibraryService()
    sut.setup(dataManager: dataManager, audioMetadataService: AudioMetadataService())
    sut.mediaServerSourceStore = store
    _ = sut.getLibrary()
  }

  override func tearDown() {
    for url in lockedFiles {
      setImmutable(url, false)
    }
    lockedFiles = []
    DataTestUtils.clearFolderContents(url: DataManager.getProcessedFolderURL())
    userDefaults.removePersistentDomain(forName: suiteName)
    sut = nil
    store = nil
    userDefaults = nil
    super.tearDown()
  }

  private func info(_ itemId: String) -> MediaServerSourceInfo {
    MediaServerSourceInfo(kind: .audiobookshelf, connectionId: "conn-1", itemId: itemId)
  }

  private func ref(_ item: BookPlayerKit.LibraryItem) -> LibraryItemRef {
    LibraryItemRef(relativePath: item.relativePath, uuid: item.uuid)
  }

  private func rootBook(_ title: String) -> Book {
    let book = StubFactory.book(dataManager: sut.dataManager, title: title, duration: 100)
    sut.getLibraryReference().addToItems(book)
    sut.dataManager.saveContext()
    return book
  }

  private func rootFolder(_ title: String) throws -> Folder {
    let folder = try StubFactory.folder(dataManager: sut.dataManager, title: title)
    sut.getLibraryReference().addToItems(folder)
    sut.dataManager.saveContext()
    return folder
  }

  private func setImmutable(_ url: URL, _ immutable: Bool) {
    var url = url
    var values = URLResourceValues()
    values.isUserImmutable = immutable
    try? url.setResourceValues(values)
  }

  /// Makes the item's file refuse to be moved or deleted
  private func lock(_ item: BookPlayerKit.LibraryItem) {
    let url = DataManager.getProcessedFolderURL().appendingPathComponent(item.relativePath)
    setImmutable(url, true)
    lockedFiles.append(url)
  }

  // MARK: - Moves

  func testAMovedBookTakesItsEntry() throws {
    let book = rootBook("dune")
    let shelf = try rootFolder("Shelf")
    store.setSource(info("li_1"), for: book.relativePath)

    try sut.moveItems([ref(book)], inside: shelf.relativePath)

    XCTAssertEqual(store.source(for: "Shelf/dune.txt"), info("li_1"))
    XCTAssertNil(store.source(for: "dune.txt"))
  }

  /// The re-key starts from the path the folder had before the move, so its books follow by prefix
  func testAMovedFolderTakesItsBooksEntries() throws {
    let volume = try rootFolder("Volume")
    let book = rootBook("part-1")
    try sut.moveItems([ref(book)], inside: volume.relativePath)
    store.setSource(info("li_2"), for: "Volume")
    store.setSource(info("li_2"), for: "Volume/part-1.txt")
    let archive = try rootFolder("Archive")

    try sut.moveItems([ref(volume)], inside: archive.relativePath)

    XCTAssertEqual(store.source(for: "Archive/Volume"), info("li_2"))
    XCTAssertEqual(store.source(for: "Archive/Volume/part-1.txt"), info("li_2"))
    XCTAssertNil(store.source(for: "Volume"))
    XCTAssertNil(store.source(for: "Volume/part-1.txt"))
  }

  /// An item left where it is, its name taken at the destination, keeps its entry, and the item that
  /// has that name keeps its own
  func testAnItemLeftWhereItIsKeepsItsEntry() throws {
    let shelf = try rootFolder("Shelf")
    let other = rootBook("same")
    try sut.moveItems([ref(other)], inside: shelf.relativePath)
    store.setSource(info("other"), for: "Shelf/same.txt")
    let book = rootBook("same")
    store.setSource(info("mine"), for: "same.txt")

    let outcome = try sut.moveItems([ref(book)], inside: shelf.relativePath)

    XCTAssertEqual(outcome.notMoved.map(\.relativePath), ["same.txt"])
    XCTAssertEqual(store.source(for: "same.txt"), info("mine"))
    XCTAssertEqual(store.source(for: "Shelf/same.txt"), info("other"))
  }

  /// A move that fails on its second item has still moved the first, so the first's entry moved too
  func testAMoveThatFailsPartwayKeepsWhatMoved() throws {
    let first = rootBook("first")
    let second = rootBook("second")
    let shelf = try rootFolder("Shelf")
    store.setSource(info("a"), for: first.relativePath)
    store.setSource(info("b"), for: second.relativePath)
    lock(second)

    XCTAssertThrowsError(try sut.moveItems([ref(first), ref(second)], inside: shelf.relativePath))

    XCTAssertEqual(store.source(for: "Shelf/first.txt"), info("a"))
    XCTAssertNil(store.source(for: "first.txt"))
    XCTAssertEqual(store.source(for: "second.txt"), info("b"))
    XCTAssertNil(store.source(for: "Shelf/second.txt"))
  }

  func testARenamedFolderTakesItsEntryAndItsBooks() throws {
    let volume = try rootFolder("Volume")
    let book = rootBook("part-1")
    try sut.moveItems([ref(book)], inside: volume.relativePath)
    store.setSource(info("li_3"), for: "Volume")
    store.setSource(info("li_3"), for: "Volume/part-1.txt")

    let newPath = try sut.renameFolder(at: "Volume", with: "Renamed")

    XCTAssertEqual(newPath, "Renamed")
    XCTAssertEqual(store.source(for: "Renamed"), info("li_3"))
    XCTAssertEqual(store.source(for: "Renamed/part-1.txt"), info("li_3"))
    XCTAssertNil(store.source(for: "Volume"))
    XCTAssertNil(store.source(for: "Volume/part-1.txt"))
  }

  // MARK: - Deletes

  /// A delete that fails on its second item has still deleted the first
  func testADeleteThatFailsPartwayDropsOnlyWhatWasDeleted() throws {
    let first = rootBook("first")
    let second = rootBook("second")
    store.setSource(info("a"), for: first.relativePath)
    store.setSource(info("b"), for: second.relativePath)
    lock(second)

    XCTAssertThrowsError(
      try sut.delete([SimpleLibraryItem(from: first), SimpleLibraryItem(from: second)], mode: .deep)
    )

    XCTAssertNil(store.source(for: "first.txt"))
    XCTAssertEqual(store.source(for: "second.txt"), info("b"))
  }

  /// "Delete folder only" moves the books up with their entries, then drops the folder's
  func testAShallowFolderDeleteKeepsItsBooksEntries() throws {
    let volume = try rootFolder("Volume")
    let book = rootBook("part-1")
    try sut.moveItems([ref(book)], inside: volume.relativePath)
    store.setSource(info("li_4"), for: "Volume")
    store.setSource(info("li_4"), for: "Volume/part-1.txt")

    try sut.delete([SimpleLibraryItem(from: volume)], mode: .shallow)

    XCTAssertEqual(store.source(for: "part-1.txt"), info("li_4"))
    XCTAssertNil(store.source(for: "Volume"))
    XCTAssertNil(store.source(for: "Volume/part-1.txt"))
  }

  func testADeepFolderDeleteDropsEverythingUnderIt() throws {
    let volume = try rootFolder("Volume")
    let book = rootBook("part-1")
    try sut.moveItems([ref(book)], inside: volume.relativePath)
    store.setSource(info("li_5"), for: "Volume")
    store.setSource(info("li_5"), for: "Volume/part-1.txt")
    store.setSource(info("kept"), for: "Volume 2")

    try sut.delete([SimpleLibraryItem(from: volume)], mode: .deep)

    XCTAssertNil(store.source(for: "Volume"))
    XCTAssertNil(store.source(for: "Volume/part-1.txt"))
    XCTAssertEqual(store.source(for: "Volume 2"), info("kept"))
  }

  /// Items a sync listing no longer has go through the same delete, on the background context
  func testASyncRemovalDropsTheRemovedItemsEntries() async throws {
    let kept = rootBook("kept")
    let removed = rootBook("removed")
    store.setSource(info("k"), for: kept.relativePath)
    store.setSource(info("r"), for: removed.relativePath)

    await sut.removeItems(notIn: [kept.relativePath], parentFolder: nil)

    XCTAssertEqual(store.source(for: "kept.txt"), info("k"))
    XCTAssertNil(store.source(for: "removed.txt"))
  }

  /// Without a store (the watch, the extensions) the library works as before
  func testNoStoreChangesNothing() throws {
    sut.mediaServerSourceStore = nil
    let book = rootBook("dune")
    let shelf = try rootFolder("Shelf")
    store.setSource(info("li_1"), for: book.relativePath)

    try sut.moveItems([ref(book)], inside: shelf.relativePath)

    XCTAssertEqual(store.source(for: "dune.txt"), info("li_1"))
  }
}

/// Folder downloads marked bind-on-complete become one book once they're in the library, taking the
/// server's position once
@MainActor
final class MediaServerBoundBookCompleterTests: XCTestCase {
  private let suiteName = "MediaServerBoundBookCompleterTests"
  private var userDefaults: UserDefaults!
  private var store: MediaServerSourceStore!
  private var libraryService: LibraryService!
  private var completer: MediaServerBoundBookCompleter!

  override func setUp() async throws {
    try await super.setUp()
    DataTestUtils.clearFolderContents(url: DataManager.getProcessedFolderURL())
    userDefaults = UserDefaults(suiteName: suiteName)!
    userDefaults.removePersistentDomain(forName: suiteName)
    store = MediaServerSourceStore(userDefaults: userDefaults)
    libraryService = LibraryService()
    libraryService.setup(
      dataManager: DataManager(coreDataStack: CoreDataStack(testPath: "/dev/null")),
      audioMetadataService: AudioMetadataService()
    )
    _ = libraryService.getLibrary()
    completer = MediaServerBoundBookCompleter(
      sourceStore: store,
      libraryService: libraryService,
      downloadService: SingleFileDownloadService(networkClient: NetworkClientMock(mockedResponse: Empty()))
    )
    // Its launch sweep runs now, before a test adds folders, so it can't stand in for the one a test
    // expects
    try await Task.sleep(nanoseconds: 100_000_000)
  }

  override func tearDown() {
    DataTestUtils.clearFolderContents(url: DataManager.getProcessedFolderURL())
    userDefaults.removePersistentDomain(forName: suiteName)
    completer = nil
    libraryService = nil
    store = nil
    userDefaults = nil
    super.tearDown()
  }

  /// A folder of two books in the library
  private func folderOfBooks(_ title: String) throws -> Folder {
    let folder = try StubFactory.folder(dataManager: libraryService.dataManager, title: title)
    libraryService.getLibraryReference().addToItems(folder)
    let books = ["\(title)-1", "\(title)-2"].map {
      StubFactory.book(dataManager: libraryService.dataManager, title: $0, duration: 100)
    }
    books.forEach { libraryService.getLibraryReference().addToItems($0) }
    libraryService.dataManager.saveContext()
    try libraryService.moveItems(
      books.map { LibraryItemRef(relativePath: $0.relativePath, uuid: $0.uuid) },
      inside: folder.relativePath
    )
    return folder
  }

  func testAFlaggedFolderIsBoundAndTakesItsSeedOnce() throws {
    let folder = try folderOfBooks("Shared")
    store.setSource(
      MediaServerSourceInfo(kind: .audiobookshelf, connectionId: "c", itemId: "li", shouldBindFolder: true, seedTime: 42),
      for: folder.relativePath
    )

    completer.sweep()
    // The seed is saved on the library's short delay, as playback positions are
    libraryService.dataManager.saveContext()

    let bound = try XCTUnwrap(libraryService.getSimpleItem(with: folder.relativePath))
    XCTAssertEqual(bound.type, .bound)
    XCTAssertEqual(bound.currentTime, 42, accuracy: 0.001)

    libraryService.updatePlaybackTime(relativePath: folder.relativePath, time: 90, date: Date(), scheduleSave: false)
    completer.sweep()
    libraryService.dataManager.saveContext()
    XCTAssertEqual(try XCTUnwrap(libraryService.getSimpleItem(with: folder.relativePath)).currentTime, 90, accuracy: 0.001)
  }

  /// A folder imported after its last file arrived is bound then, without waiting for a launch
  func testAnImportBindsTheFolderItBrought() async throws {
    let folder = try folderOfBooks("Imported")
    store.setSource(
      MediaServerSourceInfo(kind: .audiobookshelf, connectionId: "c", itemId: "li", shouldBindFolder: true),
      for: folder.relativePath
    )

    NotificationCenter.default.post(name: .importItemsInserted, object: nil)
    for _ in 0..<20 where libraryService.getSimpleItem(with: folder.relativePath)?.type != .bound {
      try await Task.sleep(nanoseconds: 50_000_000)
    }

    XCTAssertEqual(libraryService.getSimpleItem(with: folder.relativePath)?.type, .bound)
  }

  func testAFolderNobodyAskedToBindStaysAFolder() throws {
    let folder = try folderOfBooks("Plain")
    store.setSource(MediaServerSourceInfo(kind: .jellyfin, connectionId: "c", itemId: "jf"), for: folder.relativePath)

    completer.sweep()

    XCTAssertEqual(libraryService.getSimpleItem(with: folder.relativePath)?.type, .folder)
  }
}
