//
//  MediaServerDownloadLandingTests.swift
//  BookPlayerTests
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

@testable import BookPlayer
@testable import BookPlayerKit
import Combine
import XCTest

/// `SingleFileDownloadService` says a file was saved only once it's really in Documents, and the
/// tracker lands a download's provenance from that alone: `.finished` is sent before the move, and
/// for failed downloads too
@MainActor
final class MediaServerDownloadLandingTests: XCTestCase {
  private let suiteName = "MediaServerDownloadLandingTests"
  private var userDefaults: UserDefaults!
  private var store: MediaServerSourceStore!
  private var service: SingleFileDownloadService!
  private var saved = [(task: URLSessionTask, destination: URL)]()
  private var events = [String]()
  private var disposeBag = Set<AnyCancellable>()
  private var stagingFolder: URL!
  /// What the tests put in Documents, removed afterwards
  private var documentsLeftovers = [URL]()

  override func setUp() {
    super.setUp()
    userDefaults = UserDefaults(suiteName: suiteName)!
    userDefaults.removePersistentDomain(forName: suiteName)
    store = MediaServerSourceStore(userDefaults: userDefaults)
    service = SingleFileDownloadService(networkClient: NetworkClientMock(mockedResponse: NoResponse()))
    saved = []
    events = []
    service.savedFilesPublisher
      .sink { [weak self] in self?.saved.append($0) }
      .store(in: &disposeBag)
    service.eventsPublisher
      .sink { [weak self] event in
        switch event {
        case .finished: self?.events.append("finished")
        case .error(let kind, _, _): self?.events.append("error-\(kind)")
        default: break
        }
      }
      .store(in: &disposeBag)
    stagingFolder = FileManager.default.temporaryDirectory
      .appendingPathComponent("landing-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: stagingFolder, withIntermediateDirectories: true)
  }

  override func tearDown() {
    disposeBag.removeAll()
    for url in documentsLeftovers {
      try? FileManager.default.removeItem(at: url)
    }
    documentsLeftovers = []
    try? FileManager.default.removeItem(at: stagingFolder)
    userDefaults.removePersistentDomain(forName: suiteName)
    service = nil
    store = nil
    userDefaults = nil
    super.tearDown()
  }

  private struct NoResponse: Decodable {}

  /// An unstarted task for `url`: all a finished download's handling reads is its request
  private func task(_ url: String) -> URLSessionTask {
    URLSession.shared.downloadTask(with: URL(string: url)!)
  }

  /// A downloaded file waiting in the session's temporary location
  private func downloadedFile() -> URL {
    let url = stagingFolder.appendingPathComponent(UUID().uuidString)
    try? Data("audio".utf8).write(to: url)
    return url
  }

  /// Where `relativePath` is under Documents; whatever an earlier run left there goes now, and what
  /// this test puts there goes afterwards
  private func documents(_ relativePath: String) -> URL {
    let url = DataManager.getDocumentsFolderURL().appendingPathComponent(relativePath)
    let topLevel = DataManager.getDocumentsFolderURL()
      .appendingPathComponent(String(relativePath.split(separator: "/").first!))
    try? FileManager.default.removeItem(at: topLevel)
    documentsLeftovers.append(topLevel)
    return url
  }

  private func info(_ itemId: String) -> MediaServerSourceInfo {
    MediaServerSourceInfo(kind: .jellyfin, connectionId: "conn-1", itemId: itemId)
  }

  // MARK: - The saved-file signal

  func testASavedDownloadIsReportedOnceWithWhereItWent() throws {
    let expected = documents("landing-root-a.mp3")
    let download = task("https://example.com/files/landing-root-a.mp3")

    service.finishDownload(download, fileURL: downloadedFile(), error: nil, folderName: nil, fileName: nil)

    XCTAssertEqual(saved.count, 1)
    XCTAssertTrue(saved.first?.task === download)
    XCTAssertEqual(saved.first?.destination.standardizedFileURL, expected.standardizedFileURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
    XCTAssertEqual(events, ["finished"])
  }

  func testAFolderDownloadReportsItsPathInTheFolder() {
    let expected = documents("Landing Folder/landing-b.mp3")

    service.finishDownload(
      task("https://example.com/files/landing-b.mp3"),
      fileURL: downloadedFile(),
      error: nil,
      folderName: "Landing Folder",
      fileName: nil
    )

    XCTAssertEqual(saved.map { $0.destination.standardizedFileURL }, [expected.standardizedFileURL])
  }

  func testAFileNameGivenWithTheDownloadIsTheNameItGets() {
    let expected = documents("Landing Share/001 - Opening.mp3")

    service.finishDownload(
      task("https://example.com/public/share/s/track/1"),
      fileURL: downloadedFile(),
      error: nil,
      folderName: "Landing Share",
      fileName: "001 - Opening.mp3"
    )

    XCTAssertEqual(saved.map { $0.destination.standardizedFileURL }, [expected.standardizedFileURL])
    XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
  }

  func testAFailedDownloadReportsNoSavedFile() {
    service.finishDownload(
      task("https://example.com/files/landing-c.mp3"),
      fileURL: nil,
      error: URLError(.timedOut),
      folderName: nil,
      fileName: nil
    )

    XCTAssertTrue(saved.isEmpty)
    XCTAssertEqual(events, ["finished", "error-network"])
  }

  func testAMoveThatFailsReportsNoSavedFile() {
    service.finishDownload(
      task("https://example.com/files/landing-d.mp3"),
      fileURL: stagingFolder.appendingPathComponent("gone"),
      error: nil,
      folderName: nil,
      fileName: nil
    )

    XCTAssertTrue(saved.isEmpty)
    XCTAssertEqual(events, ["finished", "error-general"])
  }

  func testATakenNameReportsNoSavedFile() throws {
    let taken = documents("landing-e.mp3")
    try Data("already here".utf8).write(to: taken)

    service.finishDownload(
      task("https://example.com/files/landing-e.mp3"),
      fileURL: downloadedFile(),
      error: nil,
      folderName: nil,
      fileName: nil
    )

    XCTAssertTrue(saved.isEmpty)
    XCTAssertEqual(events, ["finished", "error-general"])
    XCTAssertEqual(try String(contentsOf: taken, encoding: .utf8), "already here")
  }

  // MARK: - The tracker

  func testASavedDownloadLandsAtItsPathUnderDocuments() {
    let tracker = MediaServerSourceTracker(store: store, downloadService: service)
    let url = "https://example.com/Items/jf_1/Download"
    store.registerPendingDownload(URL(string: url)!, info: info("jf_1"))
    _ = documents("Landing Shelf/Download")

    service.finishDownload(task(url), fileURL: downloadedFile(), error: nil, folderName: "Landing Shelf", fileName: nil)

    XCTAssertEqual(store.takeLandedSource(at: "Landing Shelf/Download"), info("jf_1"))
    withExtendedLifetime(tracker) {}
  }

  /// `.finished` comes first for a failed download too: nothing lands, and the pending entry goes
  func testAFailedDownloadLandsNothingAndDropsItsPendingEntry() {
    let tracker = MediaServerSourceTracker(store: store, downloadService: service)
    let url = URL(string: "https://example.com/Items/jf_2/Download")!
    store.registerPendingDownload(url, info: info("jf_2"))

    service.finishDownload(task(url.absoluteString), fileURL: nil, error: URLError(.networkConnectionLost), folderName: nil, fileName: nil)

    XCTAssertNil(store.takeLandedSource(at: "Download"))
    store.landPendingDownload(url, at: "probe")
    XCTAssertNil(store.takeLandedSource(at: "probe"), "the pending entry was dropped")
    withExtendedLifetime(tracker) {}
  }

  /// An error that arrives for a download after it was saved doesn't undo the landing
  func testALateErrorLeavesALandedDownloadAlone() {
    let tracker = MediaServerSourceTracker(store: store, downloadService: service)
    let url = "https://example.com/files/landing-f.mp3"
    store.registerPendingDownload(URL(string: url)!, info: info("jf_3"))
    _ = documents("landing-f.mp3")
    let download = task(url)

    service.finishDownload(download, fileURL: downloadedFile(), error: nil, folderName: nil, fileName: nil)
    service.eventsPublisher.send(.error(.general, task: download, underlyingError: nil))

    XCTAssertEqual(store.takeLandedSource(at: "landing-f.mp3"), info("jf_3"))
    withExtendedLifetime(tracker) {}
  }

  // MARK: - Letting go of a folder nothing was saved into

  /// A folder is reported when the download that ended was its last one, however it ended: the
  /// completion step is the same for a success, a failure and a cancel
  func testAFolderIsReportedOnceNothingQueuedSavesThere() {
    XCTAssertEqual(SingleFileDownloadService.folderToRelease(ended: "F", queued: [nil, "G"]), "F")
    XCTAssertNil(SingleFileDownloadService.folderToRelease(ended: "F", queued: ["G", "F"]))
    XCTAssertNil(SingleFileDownloadService.folderToRelease(ended: nil, queued: []))
  }

  func testAMissingFolderLetsGoOfItsEntries() {
    let tracker = MediaServerSourceTracker(store: store, downloadService: service)
    _ = documents("Release Missing")
    _ = documents("Release Missing 2")
    store.registerLandingSource(info("a"), at: "Release Missing")
    store.registerLandingSource(info("a"), at: "Release Missing/01.mp3")
    store.registerLandingSource(info("b"), at: "Release Missing 2")

    service.folderDownloadsEndedPublisher.send("Release Missing")

    XCTAssertFalse(store.hasLandedSource(at: "Release Missing"))
    XCTAssertFalse(store.hasLandedSource(at: "Release Missing/01.mp3"))
    XCTAssertTrue(store.hasLandedSource(at: "Release Missing 2"))
    withExtendedLifetime(tracker) {}
  }

  /// The service makes the folder before it moves a file in, so a move that fails leaves it empty:
  /// the reservation goes, the folder stays (the import may already have it queued)
  func testAFolderLeftEmptyByAFailedMoveIsLetGoButKept() {
    let tracker = MediaServerSourceTracker(store: store, downloadService: service)
    let folderURL = documents("Release Empty")
    store.registerLandingSource(info("c"), at: "Release Empty")
    service.finishDownload(
      task("https://example.com/files/release-c.mp3"),
      fileURL: stagingFolder.appendingPathComponent("not-there"),
      error: nil,
      folderName: "Release Empty",
      fileName: nil
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.path), "precondition: the service made the folder")
    XCTAssertEqual(events, ["finished", "error-general"])

    service.folderDownloadsEndedPublisher.send("Release Empty")

    XCTAssertFalse(store.hasLandedSource(at: "Release Empty"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.path))
    withExtendedLifetime(tracker) {}
  }

  /// Hidden files aren't anything to import
  func testAFolderWithOnlyHiddenFilesIsLetGo() throws {
    let tracker = MediaServerSourceTracker(store: store, downloadService: service)
    let folderURL = documents("Release Hidden")
    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    try Data().write(to: folderURL.appendingPathComponent(".DS_Store"))
    store.registerLandingSource(info("h"), at: "Release Hidden")

    service.folderDownloadsEndedPublisher.send("Release Hidden")

    XCTAssertFalse(store.hasLandedSource(at: "Release Hidden"))
    withExtendedLifetime(tracker) {}
  }

  /// A file landed: the import brings the folder in and a partial book still binds
  func testAFolderWithAFileKeepsItsEntries() {
    let tracker = MediaServerSourceTracker(store: store, downloadService: service)
    _ = documents("Release Kept")
    store.registerLandingSource(info("d"), at: "Release Kept")
    service.finishDownload(
      task("https://example.com/files/release-d.mp3"),
      fileURL: downloadedFile(),
      error: nil,
      folderName: "Release Kept",
      fileName: nil
    )

    service.folderDownloadsEndedPublisher.send("Release Kept")

    XCTAssertTrue(store.hasLandedSource(at: "Release Kept"))
    withExtendedLifetime(tracker) {}
  }

  /// One that can't be listed (here a file where the folder would be) counts as holding something
  func testAFolderThatCantBeListedKeepsItsEntries() throws {
    let tracker = MediaServerSourceTracker(store: store, downloadService: service)
    let url = documents("Release Unreadable")
    try Data("not a folder".utf8).write(to: url)
    store.registerLandingSource(info("e"), at: "Release Unreadable")

    service.folderDownloadsEndedPublisher.send("Release Unreadable")

    XCTAssertTrue(store.hasLandedSource(at: "Release Unreadable"))
    withExtendedLifetime(tracker) {}
  }

  /// Through the real completion step: the folder is only reported after its last download's own
  /// move, so a last file that arrives keeps the reservation even when every earlier one failed
  func testTheLastDownloadOfAFolderReportsItAfterItsMove() async throws {
    let downloads = service!
    let tracker = MediaServerSourceTracker(store: store, downloadService: downloads)
    var ended = [String]()
    downloads.folderDownloadsEndedPublisher
      .sink { ended.append($0) }
      .store(in: &disposeBag)
    _ = documents("Release Last")
    store.registerLandingSource(info("f"), at: "Release Last")

    downloads.handleDownload(
      [URLRequest(url: URL(string: "https://example.com/r/1.mp3")!), URLRequest(url: URL(string: "https://example.com/r/2.mp3")!)],
      folderName: "Release Last",
      fileNames: ["001 - 1.mp3", "002 - 2.mp3"]
    )
    let first = try await runningTask(of: downloads, after: nil)
    downloads.downloadEnded(first, fileURL: nil, error: URLError(.timedOut))
    let second = try await runningTask(of: downloads, after: first)
    XCTAssertTrue(ended.isEmpty, "the folder's second download was still queued")
    downloads.downloadEnded(second, fileURL: downloadedFile(), error: nil)
    try await waitUntil { !ended.isEmpty }

    XCTAssertEqual(ended, ["Release Last"])
    XCTAssertTrue(store.hasLandedSource(at: "Release Last"))
    withExtendedLifetime(tracker) {}
  }

  /// Every download failed, one of them cancelled: the folder is let go once, after the last
  func testAFolderWhoseDownloadsAllEndedWithoutAFileIsLetGo() async throws {
    let downloads = service!
    let tracker = MediaServerSourceTracker(store: store, downloadService: downloads)
    var ended = [String]()
    downloads.folderDownloadsEndedPublisher
      .sink { ended.append($0) }
      .store(in: &disposeBag)
    _ = documents("Release Failed")
    store.registerLandingSource(info("g"), at: "Release Failed")
    store.registerLandingSource(info("g"), at: "Release Failed/01.mp3")

    downloads.handleDownload(
      [URLRequest(url: URL(string: "https://example.com/s/1.mp3")!), URLRequest(url: URL(string: "https://example.com/s/2.mp3")!)],
      folderName: "Release Failed"
    )
    let first = try await runningTask(of: downloads, after: nil)
    downloads.downloadEnded(first, fileURL: nil, error: URLError(.cancelled))
    let second = try await runningTask(of: downloads, after: first)
    downloads.downloadEnded(second, fileURL: nil, error: URLError(.networkConnectionLost))
    try await waitUntil { !ended.isEmpty }

    XCTAssertEqual(ended, ["Release Failed"])
    XCTAssertFalse(store.hasLandedSource(at: "Release Failed"))
    XCTAssertFalse(store.hasLandedSource(at: "Release Failed/01.mp3"))
    withExtendedLifetime(tracker) {}
  }

  /// The download the service has started once it's started one other than `previous`
  private func runningTask(of downloads: SingleFileDownloadService, after previous: URLSessionTask?) async throws -> URLSessionTask {
    for _ in 0..<200 {
      if let task = downloads.currentDownloadTask, task !== previous {
        return task
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("no download started")
    throw URLError(.timedOut)
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<200 where !condition() {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
  }
}

