//
//  MediaServerSourceStoreTests.swift
//  BookPlayerTests
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

@testable import BookPlayerKit
import XCTest

/// The provenance store's three stages (pending by request URL, landed under Documents, resolved by
/// library path) and how entries follow paths around
final class MediaServerSourceStoreTests: XCTestCase {
  private let suiteName = "MediaServerSourceStoreTests"
  private var userDefaults: UserDefaults!
  private var store: MediaServerSourceStore!

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

  private func info(_ itemId: String, kind: MediaServerKind = .audiobookshelf, bind: Bool? = nil) -> MediaServerSourceInfo {
    MediaServerSourceInfo(kind: kind, connectionId: "conn-1", itemId: itemId, shouldBindFolder: bind)
  }

  // MARK: - Stages

  func testADownloadGoesFromPendingToLandedToResolved() {
    let url = URL(string: "https://abs.example.com/api/items/li_1/download")!
    store.registerPendingDownload(url, info: info("li_1"))

    store.landPendingDownload(url, at: "Dune.m4b")
    XCTAssertNil(store.source(for: "Dune.m4b"), "landed isn't in the library yet")

    store.resolveLandedSources(from: "Dune.m4b", to: "Dune-1.m4b")

    XCTAssertEqual(store.source(for: "Dune-1.m4b"), info("li_1"))
    XCTAssertNil(store.source(for: "Dune.m4b"))
    XCTAssertNil(store.takeLandedSource(at: "Dune.m4b"), "the landed entry is used up")
  }

  func testLandingWithoutAPendingEntryDoesNothing() {
    store.landPendingDownload(URL(string: "https://example.com/a.mp3")!, at: "a.mp3")

    XCTAssertNil(store.takeLandedSource(at: "a.mp3"))
  }

  func testRemovingAPendingDownloadLeavesALandedOneAlone() {
    let url = URL(string: "https://example.com/a.mp3")!
    store.registerPendingDownload(url, info: info("a"))
    store.landPendingDownload(url, at: "a.mp3")

    store.removePendingDownload(url)

    XCTAssertEqual(store.takeLandedSource(at: "a.mp3"), info("a"))
  }

  func testAFolderBringsItsLandedContentsIntoTheLibrary() {
    store.registerLandingSource(info("li_9", bind: true), at: "Shared Book")
    store.registerLandingSource(info("li_9"), at: "Shared Book/01.mp3")
    store.registerLandingSource(info("other"), at: "Shared Bookshelf/01.mp3")

    store.resolveLandedSources(from: "Shared Book", to: "Shared Book-1")

    XCTAssertEqual(store.source(for: "Shared Book-1"), info("li_9", bind: true))
    XCTAssertEqual(store.source(for: "Shared Book-1/01.mp3"), info("li_9"))
    XCTAssertNil(store.source(for: "Shared Bookshelf/01.mp3"), "a sibling with the same prefix doesn't come along")
    XCTAssertEqual(store.takeLandedSource(at: "Shared Bookshelf/01.mp3"), info("other"))
  }

  func testRemovingLandedSourcesTakesTheFolderAndItsContents() {
    store.registerLandingSource(info("a"), at: "Folder")
    store.registerLandingSource(info("a"), at: "Folder/01.mp3")
    store.registerLandingSource(info("b"), at: "Folder 2/01.mp3")

    store.removeLandedSources(under: "Folder")

    XCTAssertNil(store.takeLandedSource(at: "Folder"))
    XCTAssertNil(store.takeLandedSource(at: "Folder/01.mp3"))
    XCTAssertEqual(store.takeLandedSource(at: "Folder 2/01.mp3"), info("b"))
  }

  // MARK: - Following the library

  func testMovingAFolderMovesItsEntryAndItsContents() {
    store.setSource(info("a"), for: "Shelf")
    store.setSource(info("a"), for: "Shelf/Book/01.mp3")
    store.setSource(info("b"), for: "Shelf 2/01.mp3")

    store.moveSources(from: "Shelf", to: "Archive/Shelf")

    XCTAssertEqual(store.source(for: "Archive/Shelf"), info("a"))
    XCTAssertEqual(store.source(for: "Archive/Shelf/Book/01.mp3"), info("a"))
    XCTAssertNil(store.source(for: "Shelf"))
    XCTAssertNil(store.source(for: "Shelf/Book/01.mp3"))
    XCTAssertEqual(store.source(for: "Shelf 2/01.mp3"), info("b"))
  }

  func testRemovingAnItemTakesItsContentsAndNothingElse() {
    store.setSource(info("a"), for: "Shelf")
    store.setSource(info("a"), for: "Shelf/01.mp3")
    store.setSource(info("b"), for: "Shelf 2")

    store.removeSources(under: "Shelf")

    XCTAssertNil(store.source(for: "Shelf"))
    XCTAssertNil(store.source(for: "Shelf/01.mp3"))
    XCTAssertEqual(store.source(for: "Shelf 2"), info("b"))
  }

  // MARK: - What a folder's files agree on

  func testAFolderWhoseFilesAgreeHasTheirSource() {
    store.setSource(info("a"), for: "Volume/01.mp3")
    store.setSource(info("a"), for: "Volume/Disc 2/02.mp3")

    XCTAssertEqual(store.unanimousDescendantSource(under: "Volume"), info("a"))
    XCTAssertEqual(store.unanimousDescendantSource(under: "Volume/Disc 2"), info("a"))
  }

  func testAFolderMixingServerBooksHasNoSource() {
    store.setSource(info("a"), for: "Playlist/01.mp3")
    store.setSource(info("b"), for: "Playlist/02.mp3")

    XCTAssertNil(store.unanimousDescendantSource(under: "Playlist"))
  }

  func testOnlyDescendantsCount() {
    store.setSource(info("a"), for: "Volume/01.mp3")
    store.setSource(info("b"), for: "VolumeTwo/01.mp3")
    store.setSource(info("c"), for: "loose.mp3")

    XCTAssertEqual(store.unanimousDescendantSource(under: "Volume"), info("a"))
    XCTAssertNil(store.unanimousDescendantSource(under: "Missing"))
    XCTAssertNil(store.unanimousDescendantSource(under: "Volume/01.mp3"), "a file has no descendants")
  }

  /// The per-folder summary is cached: a write must reach the next question
  func testTheFolderSummaryFollowsWrites() {
    store.setSource(info("a"), for: "Volume/01.mp3")
    XCTAssertEqual(store.unanimousDescendantSource(under: "Volume"), info("a"))

    store.setSource(info("b"), for: "Volume/02.mp3")
    XCTAssertNil(store.unanimousDescendantSource(under: "Volume"))

    store.removeSources(under: "Volume/02.mp3")
    XCTAssertEqual(store.unanimousDescendantSource(under: "Volume"), info("a"))

    store.moveSources(from: "Volume", to: "Moved")
    XCTAssertNil(store.unanimousDescendantSource(under: "Volume"))
    XCTAssertEqual(store.unanimousDescendantSource(under: "Moved"), info("a"))
  }

  // MARK: - Stores written by the July 2026 builds

  /// Those builds wrote `[relativePath: MediaServerSourceInfo]` as JSON data under these exact keys in
  /// the standard defaults; an upgrade must read them as they are
  func testAJulyStoreStillReads() throws {
    let july = """
      {"Dune.m4b": {"kind": "audiobookshelf", "connectionId": "c1", "itemId": "li_1"},
       "NNELS/Book": {"kind": "hummingbird", "connectionId": "h1", "itemId": "n_2", "shouldBindFolder": true,
                      "dueDate": 800000000}}
      """
    userDefaults.set(Data(july.utf8), forKey: "MediaServerSourceStore.resolved")
    userDefaults.set(
      Data(#"{"https://abs.example.com/api/items/li_3/download": {"kind": "audiobookshelf", "connectionId": "c1", "itemId": "li_3"}}"#.utf8),
      forKey: "MediaServerSourceStore.pending"
    )
    let upgraded = MediaServerSourceStore(userDefaults: userDefaults)

    XCTAssertEqual(upgraded.source(for: "Dune.m4b"), MediaServerSourceInfo(kind: .audiobookshelf, connectionId: "c1", itemId: "li_1"))
    let hummingbird = try XCTUnwrap(upgraded.source(for: "NNELS/Book"))
    XCTAssertEqual(hummingbird.kind, .hummingbird)
    XCTAssertEqual(hummingbird.shouldBindFolder, true)
    XCTAssertEqual(hummingbird.dueDate, Date(timeIntervalSinceReferenceDate: 800_000_000))

    // A download in flight across the upgrade still lands
    upgraded.landPendingDownload(URL(string: "https://abs.example.com/api/items/li_3/download")!, at: "Book 3.m4b")
    XCTAssertEqual(upgraded.takeLandedSource(at: "Book 3.m4b")?.itemId, "li_3")
  }

  // MARK: - Paths under Documents

  func testOnlyPathsInsideTheBaseHaveARelativePath() {
    let base = URL(fileURLWithPath: "/tmp/container/Documents")

    XCTAssertEqual(MediaServerSourceStore.relativePath(of: base.appendingPathComponent("F/a.mp3"), under: base), "F/a.mp3")
    XCTAssertNil(MediaServerSourceStore.relativePath(of: base, under: base))
    XCTAssertNil(MediaServerSourceStore.relativePath(of: URL(fileURLWithPath: "/tmp/container/Documents2/a.mp3"), under: base))
    XCTAssertNil(MediaServerSourceStore.relativePath(of: URL(fileURLWithPath: "/tmp/elsewhere/a.mp3"), under: base))
  }
}
