//
//  MediaServerProgressDispatcher.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-05-17.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Combine
import Foundation

/// Listens to the `PlayerManager`'s existing playback notifications, looks up whether the
/// currently-playing item came from a media server, and forwards progress to the matching
/// `MediaServerProgressReporter`.
///
/// Lives outside `PlayerManager` on purpose: no integration concern leaks into the player, and
/// when the user is playing a purely local book the dispatcher does a single dictionary lookup
/// per notification and exits.
final class MediaServerProgressDispatcher: BPLogger {
  /// `.bookPlaying` fires on every player tick (~1Hz). Reporting that often would hammer the
  /// upstream server; this window matches the cadence the official ABS app uses for periodic
  /// progress writes. Pause/stop/finish bypass this gate via `reportFinal(...)`.
  static let inProgressThrottle: TimeInterval = 15

  private weak var playerManager: PlayerManager?
  private let sourceStore: MediaServerSourceStore
  private let reporters: [MediaServerKind: MediaServerProgressReporter]
  private let accountService: AccountServiceProtocol?

  private var observers: [NSObjectProtocol] = []
  /// `relativePath -> Date` of last in-progress report. Per-item so switching between two
  /// integration books doesn't make either of them wait the throttle window for its first
  /// update.
  private var lastInProgressByPath: [String: Date] = [:]

  init(
    playerManager: PlayerManager,
    sourceStore: MediaServerSourceStore,
    reporters: [MediaServerProgressReporter],
    accountService: AccountServiceProtocol?
  ) {
    self.playerManager = playerManager
    self.sourceStore = sourceStore
    self.reporters = Dictionary(uniqueKeysWithValues: reporters.map { ($0.kind, $0) })
    self.accountService = accountService

    subscribe()
  }

  /// Gates outbound progress reports. Pro entitlement (`hasSyncEnabled()`) follows the same rule
  /// Tortuga's own cloud sync uses; the TestFlight bypass mirrors `AppEnvironment.isPurchaseEnabled`'s
  /// "no IAP in TestFlight" — beta users can't subscribe even if they want to, so the gate would
  /// otherwise make the feature un-testable in TestFlight.
  private var isProgressReportingAllowed: Bool {
    if AppEnvironment.isTestFlight { return true }
    return accountService?.hasSyncEnabled() == true
  }

  deinit {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
  }

  // MARK: - Subscriptions

  private func subscribe() {
    let center = NotificationCenter.default
    observers.append(center.addObserver(
      forName: .bookPlaying, object: nil, queue: nil
    ) { [weak self] _ in
      self?.handlePlayingTick()
    })
    observers.append(center.addObserver(
      forName: .bookPaused, object: nil, queue: nil
    ) { [weak self] _ in
      self?.handleBoundary()
    })
    observers.append(center.addObserver(
      forName: .bookEnd, object: nil, queue: nil
    ) { [weak self] _ in
      self?.handleBoundary(markFinished: true)
    })
    observers.append(center.addObserver(
      forName: .bookStopped, object: nil, queue: nil
    ) { [weak self] _ in
      self?.handleBoundary()
    })
  }

  // MARK: - Handlers

  private func handlePlayingTick() {
    guard isProgressReportingAllowed else { return }
    // Throttle on the raw item path BEFORE building a snapshot — the snapshot
    // does a source-store lookup (a full JSON decode) that shouldn't run on
    // every 1Hz tick just to be discarded by the throttle.
    guard let relativePath = playerManager?.currentItem?.relativePath else { return }
    let now = Date()
    if let last = lastInProgressByPath[relativePath],
       now.timeIntervalSince(last) < Self.inProgressThrottle {
      return
    }

    guard let snapshot = currentSnapshot() else { return }
    lastInProgressByPath[snapshot.relativePath] = now

    let update = MediaServerProgressUpdate(
      info: snapshot.info,
      currentTime: snapshot.currentTime,
      duration: snapshot.duration,
      isFinished: snapshot.isFinished
    )
    reporters[snapshot.info.kind]?.reportInProgress(update)
  }

  /// Pause / stop / finish — always flush an up-to-date final report so the cross-device resume
  /// position is accurate even if the in-progress throttle hasn't fired recently.
  /// Resets the in-progress gate so the next session immediately reports.
  private func handleBoundary(markFinished: Bool = false) {
    guard isProgressReportingAllowed else { return }
    guard let snapshot = currentSnapshot() else { return }
    lastInProgressByPath[snapshot.relativePath] = nil

    let update = MediaServerProgressUpdate(
      info: snapshot.info,
      currentTime: snapshot.currentTime,
      duration: snapshot.duration,
      isFinished: markFinished || snapshot.isFinished
    )
    reporters[snapshot.info.kind]?.reportFinal(update)
  }

  // MARK: - Snapshot

  private struct Snapshot {
    let info: MediaServerSourceInfo
    let relativePath: String
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isFinished: Bool
  }

  private func currentSnapshot() -> Snapshot? {
    guard let item = playerManager?.currentItem else { return nil }
    guard let info = sourceStore.source(for: item.relativePath) else { return nil }
    return Snapshot(
      info: info,
      relativePath: item.relativePath,
      currentTime: item.currentTime,
      duration: item.duration,
      isFinished: item.isFinished
    )
  }
}
