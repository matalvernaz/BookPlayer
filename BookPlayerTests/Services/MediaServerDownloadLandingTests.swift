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
}
