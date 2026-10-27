//
//  ShareDownloadReceiverTests.swift
//  BookPlayerTests
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import Foundation
import XCTest

@testable import BookPlayer
@testable import BookPlayerKit

/// Collects what a callback reports, from whatever thread it's called on
final class ShareDownloadCallbackLog: @unchecked Sendable {
  private let lock = NSLock()
  private var entries = [String]()

  func append(_ entry: String) {
    lock.withLock { entries.append(entry) }
  }

  var values: [String] {
    lock.withLock { entries }
  }
}

/// Answers the share downloads' requests in tests, by URL
final class ShareDownloadURLProtocolStub: URLProtocol {
  enum Reply {
    case answer(status: Int, headers: [String: String], body: Data)
    case fail(URLError)
    /// Never answers, so the test can cancel the task
    case hold
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var replies = [String: Reply]()

  static func reset() {
    lock.withLock { replies = [:] }
  }

  static func reply(_ url: String, _ reply: Reply) {
    lock.withLock { replies[url] = reply }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let reply = Self.lock.withLock { Self.replies[request.url?.absoluteString ?? ""] }
    guard let url = request.url, let reply else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
      return
    }

    switch reply {
    case .answer(let status, let headers, let body):
      let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: body)
      client?.urlProtocolDidFinishLoading(self)
    case .fail(let error):
      client?.urlProtocol(self, didFailWithError: error)
    case .hold:
      break
    }
  }

  override func stopLoading() {}
}

/// The delegate both processes give a share's session (fork), driven by a real session: downloads land or
/// become failures, and a task is marked done only after that
final class ShareDownloadReceiverTests: XCTestCase {
  private var root: URL!
  private var sharedFolder: URL!
  private var failures: ShareImportFailureStore!
  private var registry: ShareDownloadSessionRegistry!
  private let identifier = "receiver-tests.shareext.session"

  override func setUp() {
    super.setUp()
    root = FileManager.default.temporaryDirectory.appendingPathComponent("ShareDownloadReceiverTests-\(UUID().uuidString)")
    sharedFolder = root.appendingPathComponent("Shared", isDirectory: true)
    failures = ShareImportFailureStore(folder: root.appendingPathComponent("failures", isDirectory: true))
    registry = ShareDownloadSessionRegistry(folder: root.appendingPathComponent("sessions", isDirectory: true))
    ShareDownloadURLProtocolStub.reset()
  }

  override func tearDown() {
    ShareDownloadURLProtocolStub.reset()
    try? FileManager.default.removeItem(at: root)
    super.tearDown()
  }

  private func landedNames() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: sharedFolder.path)) ?? []).sorted()
  }

  /// Downloads the links through a session whose delegate is the real receiver, as a share's session is
  /// set up (serial delegate queue, the share recorded before its tasks start), and waits until every
  /// task has been handled. `whenDone` runs inside the receiver's "all tasks done" call
  private func download(
    _ links: [String],
    cancelling: Bool = false,
    whenDone: @escaping @Sendable () -> Void = {}
  ) async throws {
    let allDone = expectation(description: "every task handled")
    let receiver = ShareDownloadReceiver(
      sessionIdentifier: identifier,
      sharedFolder: sharedFolder,
      failures: failures,
      registry: registry,
      onAllTasksDone: { _ in
        whenDone()
        allDone.fulfill()
      }
    )
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ShareDownloadURLProtocolStub.self]
    let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: BPURLSession.serialDelegateQueue())
    let tasks = links.map { session.downloadTask(with: URL(string: $0)!) }
    try registry.record(
      ShareDownloadSessionRegistry.Session(identifier: identifier, startedAt: Date(), taskIdentifiers: tasks.map(\.taskIdentifier))
    )

    for task in tasks {
      task.resume()
      if cancelling {
        task.cancel()
      }
    }
    await fulfillment(of: [allDone], timeout: 10)
    session.finishTasksAndInvalidate()
  }

  func testAnAudioDownloadLandsUnderTheServersName() async throws {
    ShareDownloadURLProtocolStub.reply(
      "https://example.com/get.mp3",
      .answer(
        status: 200,
        headers: ["Content-Type": "audio/mpeg", "Content-Disposition": #"attachment; filename="Dune.mp3""#],
        body: Data("ID3 audio".utf8)
      )
    )
    let landed = sharedFolder.appendingPathComponent("Dune.mp3")

    try await download(["https://example.com/get.mp3"]) {
      XCTAssertTrue(FileManager.default.fileExists(atPath: landed.path), "landed before the task was marked done")
    }

    XCTAssertEqual(landedNames(), ["Dune.mp3"])
    XCTAssertEqual(try Data(contentsOf: landed), Data("ID3 audio".utf8))
    XCTAssertEqual(failures.pending(), [])
  }

  func testAnErrorStatusIsAFailureAndLandsNothing() async throws {
    ShareDownloadURLProtocolStub.reply(
      "https://example.com/Dune.m4b",
      .answer(status: 404, headers: ["Content-Type": "audio/mp4"], body: Data("Not Found".utf8))
    )
    let failures = self.failures!

    try await download(["https://example.com/Dune.m4b"]) {
      XCTAssertEqual(failures.pending().count, 1, "kept before the task was marked done")
    }

    XCTAssertEqual(landedNames(), [])
    XCTAssertEqual(failures.pending().map(\.reason), [.httpStatus(code: 404)])
    XCTAssertEqual(failures.pending().map(\.source), ["Dune.m4b"])
  }

  func testAWebPageIsAFailure() async throws {
    ShareDownloadURLProtocolStub.reply(
      "https://example.com/Dune.mp3",
      .answer(status: 200, headers: ["Content-Type": "text/html"], body: Data("<html>Sign in</html>".utf8))
    )

    try await download(["https://example.com/Dune.mp3"])

    XCTAssertEqual(landedNames(), [])
    XCTAssertEqual(failures.pending().map(\.reason), [.unsupportedType(mimeType: "text/html")])
  }

  /// July only logged these: a share that never downloaded said nothing
  func testADownloadThatNeverArrivesIsAFailure() async throws {
    ShareDownloadURLProtocolStub.reply("https://example.com/Dune.mp3", .fail(URLError(.notConnectedToInternet)))

    try await download(["https://example.com/Dune.mp3"])

    let reasons = failures.pending().map(\.reason)
    XCTAssertEqual(reasons.count, 1)
    guard case .downloadFailed = reasons.first else {
      return XCTFail("expected downloadFailed, got \(reasons)")
    }
    XCTAssertEqual(failures.pending().map(\.source), ["Dune.mp3"])
  }

  /// Nothing in BookPlayer cancels a share's download, so a cancellation is reported like any failure
  func testACancelledDownloadIsReported() async throws {
    ShareDownloadURLProtocolStub.reply("https://example.com/Dune.mp3", .hold)

    try await download(["https://example.com/Dune.mp3"], cancelling: true)

    let reasons = failures.pending().map(\.reason)
    XCTAssertEqual(reasons.count, 1)
    guard case .downloadFailed = reasons.first else {
      return XCTFail("expected downloadFailed, got \(reasons)")
    }
  }

  /// One share, two links: the session is done only once both are handled
  func testEveryTaskOfAShareIsHandledBeforeItsDone() async throws {
    ShareDownloadURLProtocolStub.reply(
      "https://example.com/One.mp3",
      .answer(status: 200, headers: ["Content-Type": "audio/mpeg"], body: Data("one".utf8))
    )
    ShareDownloadURLProtocolStub.reply(
      "https://example.com/Two.mp3",
      .answer(status: 500, headers: [:], body: Data())
    )
    let failures = self.failures!
    let sharedFolder = self.sharedFolder!

    try await download(["https://example.com/One.mp3", "https://example.com/Two.mp3"]) {
      XCTAssertTrue(FileManager.default.fileExists(atPath: sharedFolder.appendingPathComponent("One.mp3").path))
      XCTAssertEqual(failures.pending().map(\.reason), [.httpStatus(code: 500)])
    }

    XCTAssertTrue(registry.isComplete(identifier))
  }

  func testFinishedEventsAndTheEndOfTheSessionAreReported() throws {
    let finished = ShareDownloadCallbackLog()
    let invalidated = ShareDownloadCallbackLog()
    let receiver = ShareDownloadReceiver(
      sessionIdentifier: identifier,
      sharedFolder: sharedFolder,
      failures: failures,
      registry: registry,
      onFinishedEvents: { finished.append($0) },
      onInvalidated: { invalidated.append($0) }
    )
    try registry.record(ShareDownloadSessionRegistry.Session(identifier: identifier, startedAt: Date(), taskIdentifiers: [1]))

    receiver.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession.shared)
    XCTAssertEqual(finished.values, [identifier])
    XCTAssertNotNil(registry.session(identifier), "finished events alone don't forget the session")

    receiver.urlSession(URLSession.shared, didBecomeInvalidWithError: nil)
    XCTAssertEqual(invalidated.values, [identifier])
    XCTAssertNil(registry.session(identifier), "forgotten after the session's last call")
  }

  /// A session ended by an error (GPT: the extension may still have held it) proves nothing was handled:
  /// its record stays for the next reconnect, and its owner still lets go of it
  func testASessionEndedByAnErrorIsKeptForAReconnect() throws {
    let invalidated = ShareDownloadCallbackLog()
    let receiver = ShareDownloadReceiver(
      sessionIdentifier: identifier,
      sharedFolder: sharedFolder,
      failures: failures,
      registry: registry,
      onInvalidated: { invalidated.append($0) }
    )
    try registry.record(ShareDownloadSessionRegistry.Session(identifier: identifier, startedAt: Date(), taskIdentifiers: [1]))

    receiver.urlSession(URLSession.shared, didBecomeInvalidWithError: URLError(.unknown))

    XCTAssertEqual(invalidated.values, [identifier])
    XCTAssertNotNil(registry.session(identifier))
  }
}

/// The app's side of the share downloads (fork): which sessions it reconnects to, and when it closes them
@MainActor
final class ShareDownloadSessionsTests: XCTestCase {
  private final class FakeSession: ShareDownloadSessions.SessionHandle {
    var closed = 0

    func finishTasksAndInvalidate() {
      closed += 1
    }
  }

  private var root: URL!
  private var registry: ShareDownloadSessionRegistry!
  private var now = Date(timeIntervalSince1970: 2_000_000)
  private var center: NotificationCenter!
  /// Every session opened, in order, with the receiver it was given
  private var opened = [(identifier: String, session: FakeSession, receiver: ShareDownloadReceiver)]()
  private var sessions: ShareDownloadSessions!

  override func setUp() {
    super.setUp()
    root = FileManager.default.temporaryDirectory.appendingPathComponent("ShareDownloadSessionsTests-\(UUID().uuidString)")
    // The registry drops sessions a week old by its own clock, so it reads the test's
    registry = ShareDownloadSessionRegistry(
      folder: root.appendingPathComponent("sessions", isDirectory: true),
      now: { [unowned self] in self.now }
    )
    center = NotificationCenter()
    opened = []
    let root = self.root!
    sessions = ShareDownloadSessions(dependencies: .init(
      registry: registry,
      failures: ShareImportFailureStore(folder: root.appendingPathComponent("failures", isDirectory: true)),
      sharedFolder: { root.appendingPathComponent("Shared", isDirectory: true) },
      now: { [unowned self] in self.now },
      openSession: { [unowned self] identifier, receiver in
        let session = FakeSession()
        self.opened.append((identifier, session, receiver))
        return session
      },
      notificationCenter: center
    ))
  }

  override func tearDown() {
    sessions = nil
    try? FileManager.default.removeItem(at: root)
    super.tearDown()
  }

  private func record(_ identifier: String, startedSecondsAgo: TimeInterval, tasks: [Int] = [1]) throws {
    try registry.record(
      ShareDownloadSessionRegistry.Session(
        identifier: identifier,
        startedAt: now.addingTimeInterval(-startedSecondsAgo),
        taskIdentifiers: tasks
      )
    )
  }

  private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
    for _ in 0..<200 where !condition() {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertTrue(condition(), file: file, line: line)
  }

  /// A task of a session the test didn't start, for its identifier: never resumed
  private func unstartedTask() -> URLSessionTask {
    URLSession.shared.downloadTask(with: URL(string: "https://example.invalid/a.mp3")!)
  }

  func testOnlySessionsPastTheMarginAreReconnected() throws {
    try record("old", startedSecondsAgo: ShareDownloadSessions.reconnectMargin + 1)
    try record("recent", startedSecondsAgo: ShareDownloadSessions.reconnectMargin - 60)

    sessions.reconnectRecordedSessions()

    XCTAssertEqual(opened.map(\.identifier), ["old"])
  }

  /// iOS hands a session over only once the extension is gone
  func testAWokenSessionOpensWhateverItsAge() throws {
    try record("recent", startedSecondsAgo: 1)

    sessions.activate("recent")
    sessions.activate("never-recorded")

    XCTAssertEqual(opened.map(\.identifier), ["recent", "never-recorded"])
  }

  func testASessionIsOpenedOnce() throws {
    try record("old", startedSecondsAgo: 600)

    sessions.reconnectRecordedSessions()
    sessions.activate("old")
    sessions.reconnectRecordedSessions()

    XCTAssertEqual(opened.map(\.identifier), ["old"])
  }

  func testTheForegroundReconnects() async throws {
    sessions.start()
    XCTAssertTrue(opened.isEmpty)
    try record("old", startedSecondsAgo: 600)

    center.post(name: UIApplication.willEnterForegroundNotification, object: nil)

    try await waitUntil { opened.map(\.identifier) == ["old"] }
  }

  /// The wake coordinator answers iOS on the session's finished events; then the session closes
  func testFinishedEventsAreAnnouncedThenTheSessionCloses() async throws {
    let announced = ShareDownloadCallbackLog()
    let observer = center.addObserver(forName: .backgroundSessionFinishedEvents, object: nil, queue: nil) { notification in
      announced.append(notification.object as? String ?? "")
    }
    defer { center.removeObserver(observer) }
    sessions.activate("A")
    let first = try XCTUnwrap(opened.first)

    first.receiver.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession.shared)

    XCTAssertEqual(announced.values, ["A"])
    try await waitUntil { first.session.closed == 1 }
  }

  /// No wake asked for it: the session closes once every task the share started is handled, and not before
  func testAReconnectedSessionClosesOnceEveryTaskIsDone() async throws {
    let first = unstartedTask()
    let second = unstartedTask()
    try record("A", startedSecondsAgo: 600, tasks: [first.taskIdentifier, second.taskIdentifier])
    sessions.reconnectRecordedSessions()
    let reconnected = try XCTUnwrap(opened.first)

    reconnected.receiver.urlSession(URLSession.shared, task: first, didCompleteWithError: nil)
    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(reconnected.session.closed, 0, "one task is still out")

    reconnected.receiver.urlSession(URLSession.shared, task: second, didCompleteWithError: nil)
    try await waitUntil { reconnected.session.closed == 1 }
    XCTAssertNotNil(registry.session("A"), "kept until the session's last call")
  }

  /// Ended by an error, the session is let go but stays recorded, so the next reconnect opens it again
  func testASessionEndedByAnErrorIsReconnectedLater() async throws {
    try record("A", startedSecondsAgo: 600)
    sessions.reconnectRecordedSessions()
    let first = try XCTUnwrap(opened.first)

    first.receiver.urlSession(URLSession.shared, didBecomeInvalidWithError: URLError(.unknown))

    try await waitUntil { sessions.openSessions["A"] == nil }
    XCTAssertNotNil(registry.session("A"))
    sessions.reconnectRecordedSessions()
    XCTAssertEqual(opened.map(\.identifier), ["A", "A"])
  }

  func testAClosedSessionIsForgottenAndCanBeWokenAgain() async throws {
    try record("A", startedSecondsAgo: 600)
    sessions.activate("A")
    let first = try XCTUnwrap(opened.first)

    first.receiver.urlSession(URLSession.shared, didBecomeInvalidWithError: nil)

    XCTAssertNil(registry.session("A"))
    try await waitUntil { sessions.openSessions["A"] == nil }
    sessions.activate("A")
    XCTAssertEqual(opened.map(\.identifier), ["A", "A"])
  }
}
