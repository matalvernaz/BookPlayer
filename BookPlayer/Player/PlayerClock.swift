//
//  PlayerClock.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import Foundation

/// How far `PlayerManager` trusts the player's clock (see `PlayerTimeSample`): the baseline for spotting
/// moves the player makes on its own, and the seek of ours in flight. Times are relative to the current
/// file. A value of its own, so a run of readings can be tested.
///
/// The seek in flight (fork): a seek to the start of a file from more than 30 s in could be undone. A tick
/// before the seek landed read the old position, which became the baseline and was saved; the landed
/// reading was then judged against it as the player snapping back to the start, and seeked back
/// (GH #1641/#1664's "previous chapter" restart). Holding readings back until the seek lands closes that
/// path, within bounds: a seek whose completion never comes stops holding them after `seekTimeout`.
struct PlayerClock: Equatable {
  /// One seek of ours, so a late completion can't settle a newer seek, even one to the same time
  struct SeekID: Equatable {
    fileprivate let value: Int
  }

  enum State: Equatable {
    /// Nothing loaded, so there's no baseline yet
    case unknown
    /// Readings are judged against `expected`, which comes from our own seeks and from every accepted
    /// reading. `recoveries` counts the seeks back since the last accepted reading
    case tracking(expected: TimeInterval, recoveries: Int)
    /// A seek back to `target` is in flight
    case recovering(target: TimeInterval, attempt: Int)
    /// A seek of ours to `target` is in flight: until it lands, readings are the player's old position
    case seeking(target: TimeInterval, id: SeekID, startedAt: Date)
  }

  /// What a reading means for the player manager
  enum Observation: Equatable {
    /// A real position: record it
    case record(TimeInterval)
    /// Nothing to record or do
    case ignore
    /// The player moved without us: seek back to this
    case recover(TimeInterval)
  }

  /// Caps the seeks back in a row, so a clock that stays broken can't loop seeks
  static let maxRecoveries = 3
  /// A reading this close to a seek's target means the seek has landed
  static let landedTolerance: TimeInterval = 1.5
  /// How long a seek holds readings back when its completion doesn't come
  static let seekTimeout: TimeInterval = 3

  private(set) var state = State.unknown
  private var lastSeekID = 0

  /// The position we trust: the baseline, or the target of the seek or recovery in flight
  var expectedTime: TimeInterval? {
    switch state {
    case .unknown:
      return nil
    case .tracking(let expected, _):
      return expected
    case .recovering(let target, _):
      return target
    case .seeking(let target, _, _):
      return target
    }
  }

  /// Nothing loaded
  mutating func reset() {
    state = .unknown
  }

  /// Trust a position the player is at, by a file's start or a reading
  mutating func trust(_ time: TimeInterval) {
    state = .tracking(expected: time, recoveries: 0)
  }

  /// A seek of ours to `target` starts: readings are held back until it lands
  mutating func beginSeek(to target: TimeInterval, at now: Date) -> SeekID {
    lastSeekID += 1
    let id = SeekID(value: lastSeekID)
    state = .seeking(target: target, id: id, startedAt: now)
    return id
  }

  /// A seek of ours ended. Only the newest one, only when it finished, and only while the player is still
  /// on the current chapter's file: a seek that ends after a jump to another file has started reads the
  /// old file (and the load that follows resets the clock). Then the player's reading is the position, if
  /// the clock takes it (returned, to be saved), else the target is trusted and nothing is saved
  mutating func seekCompleted(id: SeekID, finished: Bool, reading: TimeInterval, onCurrentFile: Bool) -> TimeInterval? {
    guard
      onCurrentFile,
      case .seeking(let target, let current, _) = state,
      current == id,
      finished
    else { return nil }

    if case .valid(let landed) = PlayerTimeSample(playerTime: reading, expected: target) {
      trust(landed)
      return landed
    }
    trust(target)
    return nil
  }

  /// What a reading of the player's clock means
  mutating func observe(_ reading: TimeInterval, at now: Date) -> Observation {
    switch state {
    case .recovering:
      // A seek back is in flight, and its target is the position we already hold
      return .ignore
    case .seeking(let target, _, let startedAt):
      let landed = reading.isFinite && abs(reading - target) <= Self.landedTolerance
      let timedOut = now.timeIntervalSince(startedAt) >= Self.seekTimeout
      guard landed || timedOut else {
        // The player's old position, until our seek lands
        return .ignore
      }
      // Landed, or waited out: judged against the target, as a seek was before the guard
      trust(target)
    case .unknown, .tracking:
      break
    }

    switch PlayerTimeSample(playerTime: reading, expected: expectedTime) {
    case .valid(let time):
      trust(time)
      return .record(time)
    case .ignore:
      return .ignore
    case .recover:
      guard
        case .tracking(let expected, let recoveries) = state,
        recoveries < Self.maxRecoveries
      else { return .ignore }
      state = .recovering(target: expected, attempt: recoveries + 1)
      return .recover(expected)
    }
  }

  /// A seek back ended. Unless a seek of ours has set a newer baseline since, its target is the baseline
  mutating func recoveryCompleted() {
    guard case .recovering(let target, let attempt) = state else { return }
    state = .tracking(expected: target, recoveries: attempt)
  }

  /// iOS 27 can snap a paused item back to the file start: where to put it back before resuming, if so.
  /// Nothing while a seek of ours or a recovery is in flight
  func restoreTarget(for reading: TimeInterval) -> TimeInterval? {
    guard
      case .tracking(let expected, _) = state,
      PlayerTimeSample(playerTime: reading, expected: expected) == .recover
    else { return nil }
    return expected
  }

  /// The position to save as playback pauses (fork): the player's own reading, when it plays the current
  /// file, nothing of ours is in flight, and the clock takes the reading. Otherwise nil, and the last
  /// tick's position stands
  mutating func snapshotTime(reading: TimeInterval, onCurrentFile: Bool) -> TimeInterval? {
    guard
      onCurrentFile,
      case .tracking(let expected, _) = state,
      case .valid(let time) = PlayerTimeSample(playerTime: reading, expected: expected)
    else { return nil }
    trust(time)
    return time
  }
}
