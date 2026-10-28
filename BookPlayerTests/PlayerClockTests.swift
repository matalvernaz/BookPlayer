//
//  PlayerClockTests.swift
//  BookPlayerTests
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import Foundation
import XCTest

@testable import BookPlayer

/// The player's clock as runs of readings: the seek in flight (fork, GH #1641/#1664), the recovery and
/// restore rules it carries over from `PlayerManager`, and the paused-position snapshot
final class PlayerClockTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 1_000_000)

  private func at(_ seconds: TimeInterval) -> Date {
    start.addingTimeInterval(seconds)
  }

  // MARK: - The seek in flight

  /// #1641: 45 s into a file, "previous chapter" restarts it at 0.1. A tick before the seek lands still
  /// reads 45; without the guard that became the baseline, and the landed 0.1 read as the player snapping
  /// back to the start, so the restart was undone. With it, the restart sticks
  func testARestartFromWellIntoAFileIsNotUndone() {
    var clock = PlayerClock()
    clock.trust(45)

    let seek = clock.beginSeek(to: 0.1, at: at(0))
    XCTAssertEqual(clock.observe(45, at: at(0.5)), .ignore, "the old position, before the seek lands")
    XCTAssertEqual(clock.seekCompleted(id: seek, finished: true, reading: 0.1, onCurrentFile: true), 0.1, "where it landed is saved")
    XCTAssertEqual(clock.observe(0.3, at: at(1)), .record(0.3))
    XCTAssertEqual(clock.state, .tracking(expected: 0.3, recoveries: 0))
  }

  func testAReadingNearTheTargetMeansTheSeekLanded() {
    var clock = PlayerClock()
    clock.trust(10)
    _ = clock.beginSeek(to: 100, at: at(0))

    XCTAssertEqual(clock.observe(100.4, at: at(0.2)), .record(100.4))
    XCTAssertEqual(clock.state, .tracking(expected: 100.4, recoveries: 0))
  }

  /// Bounded: a seek whose completion never comes holds readings back for `seekTimeout`, then they're
  /// judged against its target as before the guard (so the original race can come back after that)
  func testASeekThatNeverCompletesStopsHoldingReadingsBack() {
    var clock = PlayerClock()
    _ = clock.beginSeek(to: 100, at: at(0))

    XCTAssertEqual(clock.observe(30, at: at(1)), .ignore)
    XCTAssertEqual(clock.observe(30, at: at(PlayerClock.seekTimeout)), .record(30))
  }

  func testAfterTheTimeoutAStartOfFileReadingRecoversToTheTarget() {
    var clock = PlayerClock()
    _ = clock.beginSeek(to: 100, at: at(0))

    XCTAssertEqual(clock.observe(0.1, at: at(PlayerClock.seekTimeout + 1)), .recover(100))
  }

  func testALateCompletionOfAnEarlierSeekSettlesNothing() {
    var clock = PlayerClock()
    let first = clock.beginSeek(to: 50, at: at(0))
    let second = clock.beginSeek(to: 80, at: at(0.1))

    XCTAssertNil(clock.seekCompleted(id: first, finished: true, reading: 50, onCurrentFile: true))
    XCTAssertEqual(clock.expectedTime, 80, "still waiting for the newer seek")
    XCTAssertEqual(clock.seekCompleted(id: second, finished: true, reading: 80, onCurrentFile: true), 80)
  }

  /// Sonnet: two seeks to one time, the first's completion arriving after the second started
  func testTwoSeeksToTheSameTimeAreToldApart() {
    var clock = PlayerClock()
    let first = clock.beginSeek(to: 10, at: at(0))
    let second = clock.beginSeek(to: 10, at: at(0.1))

    XCTAssertNil(clock.seekCompleted(id: first, finished: true, reading: 10, onCurrentFile: true))
    if case .seeking(_, let id, _) = clock.state {
      XCTAssertEqual(id, second)
    } else {
      XCTFail("expected the second seek in flight, got \(clock.state)")
    }
    XCTAssertEqual(clock.seekCompleted(id: second, finished: true, reading: 10, onCurrentFile: true), 10)
  }

  /// GPT: a seek that ends after a jump to another file has started reads the old file; it settles
  /// nothing and saves nothing (the new file's load resets the clock)
  func testASeekThatEndsOffTheCurrentFileSettlesNothing() {
    var clock = PlayerClock()
    let seek = clock.beginSeek(to: 10, at: at(0))

    XCTAssertNil(clock.seekCompleted(id: seek, finished: true, reading: 12, onCurrentFile: false))
    if case .seeking(let target, let id, _) = clock.state {
      XCTAssertEqual(target, 10)
      XCTAssertEqual(id, seek)
    } else {
      XCTFail("expected the seek still in flight, got \(clock.state)")
    }
  }

  func testAnUnfinishedSeekSettlesNothing() {
    var clock = PlayerClock()
    let seek = clock.beginSeek(to: 10, at: at(0))

    XCTAssertNil(clock.seekCompleted(id: seek, finished: false, reading: 10, onCurrentFile: true))
    XCTAssertEqual(clock.expectedTime, 10)
    XCTAssertEqual(clock.observe(40, at: at(0.5)), .ignore, "still held back")
  }

  /// A completion whose reading the clock doesn't take (here the start of the file, from a seek to 45)
  /// saves nothing and leaves the target as the baseline
  func testALandingTheClockRejectsSavesNothing() {
    var clock = PlayerClock()
    let seek = clock.beginSeek(to: 45, at: at(0))

    XCTAssertNil(clock.seekCompleted(id: seek, finished: true, reading: 0.1, onCurrentFile: true))
    XCTAssertEqual(clock.state, .tracking(expected: 45, recoveries: 0))
  }

  func testRecoveryAndRestoreStayQuietWhileSeeking() {
    var clock = PlayerClock()
    clock.trust(60)
    _ = clock.beginSeek(to: 45, at: at(0))

    XCTAssertNil(clock.restoreTarget(for: 0.1))
    XCTAssertEqual(clock.observe(0.1, at: at(0.5)), .ignore)
  }

  // MARK: - Carried over from PlayerManager

  func testAStartOfFileReadingFromWellInRecoversToTheBaseline() {
    var clock = PlayerClock()
    clock.trust(45)

    XCTAssertEqual(clock.observe(0.1, at: at(0)), .recover(45))
    XCTAssertEqual(clock.state, .recovering(target: 45, attempt: 1))
    XCTAssertEqual(clock.observe(0.1, at: at(1)), .ignore, "the seek back is in flight")
    XCTAssertEqual(clock.observe(46, at: at(1.5)), .ignore, "nothing is recorded until it lands")

    clock.recoveryCompleted()
    XCTAssertEqual(clock.state, .tracking(expected: 45, recoveries: 1))
  }

  func testRecoveriesStopAfterTheCap() {
    var clock = PlayerClock()
    clock.trust(45)
    for _ in 0..<PlayerClock.maxRecoveries {
      XCTAssertEqual(clock.observe(0.1, at: at(0)), .recover(45))
      clock.recoveryCompleted()
    }

    XCTAssertEqual(clock.observe(0.1, at: at(1)), .ignore, "a clock that stays broken doesn't loop seeks")
  }

  func testAnAcceptedReadingResetsTheRecoveries() {
    var clock = PlayerClock()
    clock.trust(45)
    XCTAssertEqual(clock.observe(0.1, at: at(0)), .recover(45))
    clock.recoveryCompleted()

    XCTAssertEqual(clock.observe(46, at: at(1)), .record(46))
    XCTAssertEqual(clock.state, .tracking(expected: 46, recoveries: 0))
  }

  /// A seek of ours that starts while a seek back is in flight wins: the seek back's completion doesn't
  /// overwrite it
  func testOurSeekSupersedesARecovery() {
    var clock = PlayerClock()
    clock.trust(45)
    XCTAssertEqual(clock.observe(0.1, at: at(0)), .recover(45))

    let seek = clock.beginSeek(to: 10, at: at(0.1))
    clock.recoveryCompleted()

    XCTAssertEqual(clock.expectedTime, 10)
    XCTAssertEqual(clock.seekCompleted(id: seek, finished: true, reading: 10, onCurrentFile: true), 10)
  }

  func testAPausedItemSnappedToTheStartIsPutBack() {
    var clock = PlayerClock()
    clock.trust(45)

    XCTAssertEqual(clock.restoreTarget(for: 0), 45)
    XCTAssertNil(clock.restoreTarget(for: 44))
  }

  func testWithNoBaselineAnyReadingIsRecorded() {
    var clock = PlayerClock()

    XCTAssertEqual(clock.observe(-1, at: at(0)), .ignore, "a small negative near the start is output latency")
    XCTAssertEqual(clock.state, .unknown)
    XCTAssertEqual(clock.observe(5, at: at(1)), .record(5))
  }

  // MARK: - The paused-position snapshot

  func testThePausedPositionIsTakenOffThePlayer() {
    var clock = PlayerClock()
    clock.trust(45)

    XCTAssertEqual(clock.snapshotTime(reading: 45.7, onCurrentFile: true), 45.7)
    XCTAssertEqual(clock.state, .tracking(expected: 45.7, recoveries: 0))
  }

  /// A chapter change can leave the previous file attached while the chapter has moved on
  func testNoSnapshotOffAnotherFile() {
    var clock = PlayerClock()
    clock.trust(45)

    XCTAssertNil(clock.snapshotTime(reading: 45.7, onCurrentFile: false))
    XCTAssertEqual(clock.state, .tracking(expected: 45, recoveries: 0))
  }

  func testNoSnapshotWhileASeekOrRecoveryIsInFlight() {
    var seeking = PlayerClock()
    _ = seeking.beginSeek(to: 30, at: at(0))
    XCTAssertNil(seeking.snapshotTime(reading: 30, onCurrentFile: true))

    var recovering = PlayerClock()
    recovering.trust(45)
    XCTAssertEqual(recovering.observe(0.1, at: at(0)), .recover(45))
    XCTAssertNil(recovering.snapshotTime(reading: 45, onCurrentFile: true))
  }

  /// The CarPlay snap to 0 (GH #1605) is never saved as the paused position
  func testASnapToTheStartIsNeverSnapshotted() {
    var clock = PlayerClock()
    clock.trust(45)

    XCTAssertNil(clock.snapshotTime(reading: 0, onCurrentFile: true))
    XCTAssertEqual(clock.state, .tracking(expected: 45, recoveries: 0))
  }
}
