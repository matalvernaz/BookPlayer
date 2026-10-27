//
//  ShareDownloadsTests.swift
//  BookPlayerTests
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import Foundation
import XCTest

@testable import BookPlayer
@testable import BookPlayerKit

/// A temporary folder per test, removed afterwards
private func makeTemporaryFolder() -> URL {
  let folder = FileManager.default.temporaryDirectory
    .appendingPathComponent("ShareDownloadsTests-\(UUID().uuidString)", isDirectory: true)
  try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  return folder
}

/// Links, names, the type rules and landing for links shared to BookPlayer (fork)
final class ShareDownloadsTests: XCTestCase {
  private var folder: URL!

  override func setUp() {
    super.setUp()
    folder = makeTemporaryFolder()
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: folder)
    super.tearDown()
  }

  private func url(_ string: String) -> URL {
    URL(string: string)!
  }

  /// A downloaded file waiting in the system's temporary folder
  private func download(_ contents: String = "audio") -> URL {
    let location = FileManager.default.temporaryDirectory.appendingPathComponent("download-\(UUID().uuidString).tmp")
    try? Data(contents.utf8).write(to: location)
    return location
  }

  // MARK: - Links

  func testOnlyWebLinksToFilesBookPlayerImportsAreDownloaded() {
    XCTAssertTrue(ShareDownloads.isDownloadableWebURL(url("https://example.com/books/Dune.m4b")))
    XCTAssertTrue(ShareDownloads.isDownloadableWebURL(url("http://example.com/a.mp3?token=1")))
    XCTAssertTrue(ShareDownloads.isDownloadableWebURL(url("HTTPS://example.com/A.MP3")))
    XCTAssertTrue(ShareDownloads.isDownloadableWebURL(url("https://example.com/box.zip")))

    XCTAssertFalse(ShareDownloads.isDownloadableWebURL(url("https://example.com/article")), "a web page")
    XCTAssertFalse(ShareDownloads.isDownloadableWebURL(url("https://example.com/notes.pdf")))
    XCTAssertFalse(ShareDownloads.isDownloadableWebURL(url("ftp://example.com/a.mp3")))
    XCTAssertFalse(ShareDownloads.isDownloadableWebURL(URL(fileURLWithPath: "/tmp/a.mp3")), "files aren't downloaded")
  }

  func testALinkIsNamedByItsFileElseItsHost() {
    XCTAssertEqual(ShareDownloads.sourceName(for: url("https://example.com/books/Dune%20Part%201.m4b")), "Dune Part 1.m4b")
    XCTAssertEqual(ShareDownloads.sourceName(for: url("https://example.com/")), "example.com")
    XCTAssertEqual(ShareDownloads.sourceName(for: nil), "")
  }

  // MARK: - Names

  /// July kept only what followed the last slash: "AC/DC.mp3" became "DC.mp3"
  func testASlashInTheServersNameIsReplacedNotCut() {
    let name = ShareDownloads.fileName(suggested: "AC/DC.mp3", url: url("https://example.com/x.mp3"), mimeType: "audio/mpeg")
    XCTAssertEqual(name, "AC_DC.mp3")
  }

  func testTheServersNameIsPreferredToTheLinks() {
    let name = ShareDownloads.fileName(suggested: "Dune.m4b", url: url("https://example.com/download.m4b"), mimeType: nil)
    XCTAssertEqual(name, "Dune.m4b")
    XCTAssertEqual(
      ShareDownloads.fileName(suggested: nil, url: url("https://example.com/Dune.m4b"), mimeType: nil),
      "Dune.m4b"
    )
    XCTAssertEqual(
      ShareDownloads.fileName(suggested: "", url: url("https://example.com/Dune.m4b"), mimeType: nil),
      "Dune.m4b"
    )
  }

  /// Sanitizing ".mp3" leaves "mp3": the extension comes back from the link, or from the server's type
  func testANameThatLostItsExtensionGetsOneBack() {
    XCTAssertEqual(
      ShareDownloads.fileName(suggested: ".mp3", url: url("https://example.com/get.mp3"), mimeType: nil),
      "mp3.mp3"
    )
    XCTAssertEqual(
      ShareDownloads.fileName(suggested: ".mp3", url: url("https://example.com/get"), mimeType: "audio/mpeg"),
      "mp3.mp3"
    )
    XCTAssertEqual(
      ShareDownloads.fileName(suggested: "book", url: url("https://example.com/get"), mimeType: "text/html"),
      "book",
      "a type BookPlayer doesn't import gives no extension"
    )
  }

  func testANameWithNothingUsableFallsBack() {
    XCTAssertEqual(
      ShareDownloads.fileName(suggested: "///", url: url("https://example.com/a.mp3"), mimeType: nil),
      "untitled_file.mp3"
    )
  }

  func testALongNameIsCutToTheByteLimitKeepingItsExtension() {
    let long = String(repeating: "é", count: 150) + ".m4b"  // 304 bytes
    let name = ShareDownloads.fileName(suggested: long, url: nil, mimeType: nil)
    XCTAssertTrue(name.hasSuffix(".m4b"))
    XCTAssertLessThanOrEqual(name.utf8.count, ShareDownloads.maxNameBytes)
    XCTAssertTrue(name.hasPrefix("ééé"), "cut at whole characters")
  }

  // MARK: - Checks

  func testAnErrorStatusIsRefusedWhateverTheType() {
    XCTAssertEqual(ShareDownloads.rejection(statusCode: 404, mimeType: "audio/mpeg", fileName: "a.mp3"), .httpStatus(code: 404))
    XCTAssertEqual(ShareDownloads.rejection(statusCode: 500, mimeType: nil, fileName: "a.mp3"), .httpStatus(code: 500))
    XCTAssertNil(ShareDownloads.rejection(statusCode: 206, mimeType: "audio/mpeg", fileName: "a.mp3"))
  }

  func testTheTypeRules() {
    XCTAssertEqual(
      ShareDownloads.rejection(statusCode: 200, mimeType: "text/html", fileName: "a.mp3"),
      .unsupportedType(mimeType: "text/html"),
      "a web page, even under an audio name"
    )
    XCTAssertEqual(
      ShareDownloads.rejection(statusCode: 200, mimeType: "Application/JSON", fileName: "a.mp3"),
      .unsupportedType(mimeType: "application/json")
    )
    XCTAssertNil(ShareDownloads.rejection(statusCode: 200, mimeType: "audio/mpeg", fileName: "download"))
    XCTAssertNil(ShareDownloads.rejection(statusCode: 200, mimeType: "video/mp4", fileName: "download"))
    XCTAssertNil(ShareDownloads.rejection(statusCode: 200, mimeType: "application/zip", fileName: "download"))
    XCTAssertNil(ShareDownloads.rejection(statusCode: 200, mimeType: "application/octet-stream", fileName: "a.flac"))
    XCTAssertEqual(
      ShareDownloads.rejection(statusCode: 200, mimeType: "application/octet-stream", fileName: "download"),
      .unsupportedExtension
    )
    XCTAssertNil(ShareDownloads.rejection(statusCode: 200, mimeType: nil, fileName: "a.m4b"))
    XCTAssertEqual(ShareDownloads.rejection(statusCode: 200, mimeType: nil, fileName: "a.pdf"), .unsupportedExtension)
    XCTAssertNil(ShareDownloads.rejection(statusCode: 200, mimeType: "image/x-odd", fileName: "a.opus"))
    XCTAssertEqual(
      ShareDownloads.rejection(statusCode: 200, mimeType: "image/png", fileName: "a.png"),
      .unsupportedType(mimeType: "image/png")
    )
  }

  // MARK: - Landing

  func testADownloadLandsUnderItsName() throws {
    let landed = try ShareDownloads.land(download(), named: "Dune.m4b", in: folder)
    XCTAssertEqual(landed.lastPathComponent, "Dune.m4b")
    XCTAssertTrue(FileManager.default.fileExists(atPath: landed.path))
  }

  /// July put a uuid in front of every name, and so in the book's title
  func testATakenNameIsNumbered() throws {
    let first = try ShareDownloads.land(download("1"), named: "Dune.m4b", in: folder)
    let second = try ShareDownloads.land(download("2"), named: "Dune.m4b", in: folder)
    let third = try ShareDownloads.land(download("3"), named: "Dune.m4b", in: folder)

    XCTAssertEqual([first, second, third].map(\.lastPathComponent), ["Dune.m4b", "Dune 2.m4b", "Dune 3.m4b"])
    XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "2")
  }

  func testFinishingJudgesThenLands() {
    let link = url("https://example.com/Dune.m4b")
    let audio = HTTPURLResponse(url: link, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/mp4"])
    let outcome = ShareDownloads.finish(download: download(), response: audio, originalURL: link, into: folder)
    XCTAssertEqual(outcome, .landed(folder.appendingPathComponent("Dune.m4b")))

    let page = HTTPURLResponse(url: link, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])
    let refused = ShareDownloads.finish(download: download(), response: page, originalURL: link, into: folder)
    XCTAssertEqual(refused, .failed(.unsupportedType(mimeType: "text/html")))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["Dune.m4b"], "nothing more landed")
  }

  // MARK: - Errors

  func testAForceQuitCancellationSaysSo() {
    let forceQuit = NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorCancelled,
      userInfo: [NSURLErrorBackgroundTaskCancelledReasonKey: NSURLErrorCancelledReasonUserForceQuitApplication]
    )
    XCTAssertEqual(ShareDownloads.failureReason(for: forceQuit), .stoppedByForceQuit)

    let offline = URLError(.notConnectedToInternet)
    XCTAssertEqual(ShareDownloads.failureReason(for: offline), .downloadFailed(detail: offline.localizedDescription))

    let cancelled = URLError(.cancelled)
    XCTAssertEqual(
      ShareDownloads.failureReason(for: cancelled),
      .downloadFailed(detail: cancelled.localizedDescription),
      "nothing in BookPlayer cancels a share's download, so any other cancellation is reported too"
    )
  }

  func testJulysFilesAreRemoved() throws {
    for name in ["share-import-failures.json", "share-canceled.json", "keep.json"] {
      try Data("[]".utf8).write(to: folder.appendingPathComponent(name))
    }

    ShareDownloads.removeJulyFiles(in: folder)

    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["keep.json"])
  }

  func testSessionIdentifiersAreTheShareExtensions() {
    let identifier = ShareDownloads.makeSessionIdentifier()
    XCTAssertTrue(ShareDownloads.isShareSession(identifier))
    XCTAssertNotEqual(identifier, ShareDownloads.makeSessionIdentifier(), "one per share")
    XCTAssertFalse(ShareDownloads.isShareSession(BackgroundTransferSessions.downloadIdentifier))
    XCTAssertFalse(ShareDownloads.isShareSession("SingleFileDownloadService"))

    let configuration = ShareDownloads.sessionConfiguration(identifier: identifier)
    XCTAssertEqual(configuration.identifier, identifier)
    XCTAssertEqual(configuration.sharedContainerIdentifier, Constants.ApplicationGroupIdentifier)
    XCTAssertTrue(configuration.sessionSendsLaunchEvents)
    XCTAssertFalse(configuration.isDiscretionary)
  }
}

/// The failures both processes write and the app shows (fork)
final class ShareImportFailureStoreTests: XCTestCase {
  private var folder: URL!

  override func setUp() {
    super.setUp()
    folder = makeTemporaryFolder().appendingPathComponent("failures", isDirectory: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    super.tearDown()
  }

  private func failure(_ source: String, at seconds: TimeInterval = 0) -> ShareImportFailure {
    ShareImportFailure(date: Date(timeIntervalSince1970: 1_000 + seconds), source: source, reason: .httpStatus(code: 404))
  }

  func testFailuresStayUntilRemoved() {
    let store = ShareImportFailureStore(folder: folder)
    let first = failure("a.mp3", at: 1)
    let second = failure("b.mp3", at: 2)
    store.append(second)
    store.append(first)

    XCTAssertEqual(store.pending(), [first, second], "oldest first")
    XCTAssertEqual(store.pending(), [first, second], "reading doesn't remove")

    store.remove(ids: [first.id])
    XCTAssertEqual(store.pending(), [second])
  }

  func testEveryReasonRoundTrips() {
    let store = ShareImportFailureStore(folder: folder)
    let reasons: [ShareImportFailure.Reason] = [
      .copyFailed(detail: "disk full"), .downloadFailed(detail: "offline"), .httpStatus(code: 403),
      .saveFailed(detail: "no space"), .stoppedByForceQuit, .unsupportedExtension, .unsupportedType(mimeType: "text/html"),
    ]
    for (index, reason) in reasons.enumerated() {
      store.append(ShareImportFailure(date: Date(timeIntervalSince1970: Double(index)), source: "s", reason: reason))
    }

    XCTAssertEqual(store.pending().map(\.reason), reasons)
  }

  func testTheOldestGoPastTheCap() {
    let store = ShareImportFailureStore(folder: folder)
    let failures = (0...ShareImportFailureStore.maxStored).map { failure("\($0)", at: Double($0)) }
    for item in failures {
      store.append(item)
    }

    XCTAssertEqual(store.pending(), Array(failures.dropFirst()), "51 kept the newest 50")
  }

  /// July kept one JSON array; a file that doesn't read is dropped and the store carries on
  func testAnUnreadableFileIsDroppedAndTheStoreCarriesOn() throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let stale = folder.appendingPathComponent("\(UUID().uuidString).json")
    try Data(#"[{"id":"x","message":"share_import_failure_http_status"}]"#.utf8).write(to: stale)
    let store = ShareImportFailureStore(folder: folder)

    XCTAssertEqual(store.pending(), [])
    XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))

    let next = failure("a.mp3")
    store.append(next)
    XCTAssertEqual(store.pending(), [next])
  }

  /// The app dismissing failures while the share extension writes new ones loses none of the new ones.
  /// Two stores on one folder stand in for the two processes: the property at work is that each record
  /// is its own file (create, rename and unlink are atomic per file), which is the same across processes
  func testTwoWritersAndARemoverLoseNothing() {
    let app = ShareImportFailureStore(folder: folder)
    let extensionStore = ShareImportFailureStore(folder: folder)
    let dismissed = (0..<10).map { failure("old \($0)", at: Double($0)) }
    for item in dismissed {
      app.append(item)
    }
    let fromApp = (0..<10).map { failure("app \($0)", at: 100 + Double($0)) }
    let fromExtension = (0..<10).map { failure("extension \($0)", at: 200 + Double($0)) }

    DispatchQueue.concurrentPerform(iterations: 21) { index in
      switch index {
      case 0..<10: app.append(fromApp[index])
      case 10..<20: extensionStore.append(fromExtension[index - 10])
      default: app.remove(ids: Set(dismissed.map(\.id)))
      }
    }

    XCTAssertEqual(Set(app.pending()), Set(fromApp + fromExtension), "under the cap, so every new one stays")
  }
}

/// The share sessions the app may need to reconnect to (fork)
final class ShareDownloadSessionRegistryTests: XCTestCase {
  private var folder: URL!
  private var now = Date(timeIntervalSince1970: 1_000_000)

  override func setUp() {
    super.setUp()
    folder = makeTemporaryFolder().appendingPathComponent("sessions", isDirectory: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    super.tearDown()
  }

  private func makeRegistry() -> ShareDownloadSessionRegistry {
    ShareDownloadSessionRegistry(folder: folder, now: { [unowned self] in self.now })
  }

  private func session(_ identifier: String, tasks: [Int] = [1, 2], startedAt: Date? = nil) -> ShareDownloadSessionRegistry.Session {
    ShareDownloadSessionRegistry.Session(identifier: identifier, startedAt: startedAt ?? now, taskIdentifiers: tasks)
  }

  func testASessionIsCompleteOnceEveryTaskIsDone() throws {
    let registry = makeRegistry()
    try registry.record(session("A", tasks: [1, 2]))

    XCTAssertFalse(registry.isComplete("A"))
    registry.markDone("A", taskIdentifier: 1)
    XCTAssertFalse(registry.isComplete("A"))
    registry.markDone("A", taskIdentifier: 7)
    XCTAssertFalse(registry.isComplete("A"), "a task it didn't start doesn't count")
    registry.markDone("A", taskIdentifier: 2)
    XCTAssertTrue(registry.isComplete("A"))
  }

  func testNothingIsMarkedForASessionNotRecorded() {
    let registry = makeRegistry()
    registry.markDone("ghost", taskIdentifier: 1)

    XCTAssertFalse(registry.isComplete("ghost"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("ghost.done").path))
  }

  func testAForgottenSessionIsGoneWithItsMarkers() throws {
    let registry = makeRegistry()
    try registry.record(session("A"))
    registry.markDone("A", taskIdentifier: 1)

    registry.forget("A")

    XCTAssertEqual(registry.sessions(), [])
    XCTAssertNil(registry.session("A"))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
  }

  func testAWeekOldSessionIsDropped() throws {
    let registry = makeRegistry()
    try registry.record(session("old", startedAt: now.addingTimeInterval(-ShareDownloadSessionRegistry.expiry - 1)))
    try registry.record(session("recent", startedAt: now.addingTimeInterval(-60)))

    XCTAssertEqual(registry.sessions().map(\.identifier), ["recent"])
    XCTAssertNil(registry.session("old"))
  }

  /// Markers left by a session the other process just forgot are cleared
  func testMarkersWithoutTheirSessionAreCleared() throws {
    let registry = makeRegistry()
    let orphan = folder.appendingPathComponent("gone.done", isDirectory: true)
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)

    _ = registry.sessions()

    XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
  }

  /// GPT's interleaving: the app forgets A while the extension records B. With a file per session, B stays
  func testForgettingOneSessionWhileAnotherIsRecordedKeepsTheNewOne() throws {
    let app = makeRegistry()
    let extensionRegistry = makeRegistry()
    try app.record(session("A"))
    let added = (0..<20).map { session("B\($0)") }

    DispatchQueue.concurrentPerform(iterations: 21) { index in
      if index == 20 {
        app.forget("A")
      } else {
        try? extensionRegistry.record(added[index])
      }
    }

    XCTAssertEqual(Set(app.sessions().map(\.identifier)), Set(added.map(\.identifier)))
  }
}
