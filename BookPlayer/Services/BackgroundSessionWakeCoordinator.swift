//
//  BackgroundSessionWakeCoordinator.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Foundation
import UIKit

/// Answers iOS when it relaunches or wakes the app for a background session's events
/// (`application(_:handleEventsForBackgroundURLSession:completionHandler:)`). Calling iOS's
/// completion handler lets it suspend the app, so for the upload sessions it waits until the
/// upload has handled the finished parts and handed the session the next ones — calling it
/// earlier froze those requests until the next wake (P2b). Either order of the handler and
/// the session's "finished events" callback works: the spike saw both.
@MainActor
final class BackgroundSessionWakeCoordinator: BPLogger {
  struct Dependencies {
    /// Recreates the session(s) behind an identifier, so iOS delivers their events
    var activateSessions: (String) -> Void
    /// The upload queue's `settleUploads()`
    var settleUploads: () async -> Void
    /// `SyncService.settleDownloads()`: the finished downloads' follow-up work
    var settleDownloads: () async -> Void
    var beginBackgroundTask: (@escaping () -> Void) -> UIBackgroundTaskIdentifier
    var endBackgroundTask: (UIBackgroundTaskIdentifier) -> Void
    /// Longest wait before answering iOS anyway
    var timeout: Duration
    /// A "finished events" older than this belongs to an earlier wake, not the next one
    var staleEventsAfter: TimeInterval = 60

    static var live: Dependencies {
      Dependencies(
        activateSessions: { identifier in
          if BackgroundTransferSessions.uploadIdentifiers.contains(identifier) {
            BackgroundTransferSessions.activateUploadSessions()
          } else if ShareDownloads.isShareSession(identifier) {
            // A share extension's download session (fork)
            MainActor.assumeIsolated {
              ShareDownloadSessions.shared.activate(identifier)
            }
          }
        },
        settleUploads: {
          guard let queue = try? await AppServices.shared.awaitCoreServices().syncQueueService else { return }
          await queue.settleUploads()
        },
        settleDownloads: {
          guard let sync = try? await AppServices.shared.awaitCoreServices().syncService else { return }
          await sync.settleDownloads()
        },
        beginBackgroundTask: { expiration in
          UIApplication.shared.beginBackgroundTask(withName: "background-session-wake", expirationHandler: expiration)
        },
        endBackgroundTask: { UIApplication.shared.endBackgroundTask($0) },
        timeout: .seconds(25)
      )
    }
  }

  private let dependencies: Dependencies
  /// Per session, this wake's handler; the token keeps a timer from an earlier wake from
  /// answering a later one
  private var handlers = [String: (token: UUID, handler: () -> Void)]()
  /// Sessions whose events finished before iOS handed over their handler, and when
  private var finishedWithoutHandler = [String: Date]()
  private var observer: NSObjectProtocol?

  init(dependencies: Dependencies = .live) {
    self.dependencies = dependencies
    observer = NotificationCenter.default.addObserver(
      forName: .backgroundSessionFinishedEvents,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let identifier = notification.object as? String else { return }
      MainActor.assumeIsolated {
        self?.sessionFinishedEvents(identifier)
      }
    }
  }

  deinit {
    if let observer {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  func handleEvents(forSession identifier: String, completionHandler: @escaping () -> Void) {
    Self.logger.info("Woken for background session \(identifier)")
    // Anything else (e.g. the single-file media-server downloads, whose queue lives only in
    // memory) has nothing to resume in the background
    guard isOwned(identifier) else {
      completionHandler()
      return
    }

    // A new wake for the same session: the earlier one's handler is still owed an answer
    if let previous = handlers[identifier] {
      Self.logger.info("Background session \(identifier): superseded by a new wake")
      previous.handler()
    }
    let token = UUID()
    handlers[identifier] = (token, completionHandler)
    dependencies.activateSessions(identifier)

    if let finishedAt = finishedWithoutHandler.removeValue(forKey: identifier),
       Date().timeIntervalSince(finishedAt) < dependencies.staleEventsAfter {
      answer(identifier, token: token)
    } else {
      // The session may never report back (e.g. it isn't created in this launch)
      scheduleFallback(for: identifier, token: token)
    }
  }

  private func sessionFinishedEvents(_ identifier: String) {
    guard isOwned(identifier) else { return }
    guard let token = handlers[identifier]?.token else {
      // Share sessions the app reconnects to on its own finish with no wake to answer, each under a new
      // identifier (fork): drop the entries no wake can use any more, so they don't pile up
      let now = Date()
      finishedWithoutHandler = finishedWithoutHandler.filter {
        now.timeIntervalSince($0.value) < dependencies.staleEventsAfter
      }
      finishedWithoutHandler[identifier] = now
      return
    }
    answer(identifier, token: token)
  }

  private func isOwned(_ identifier: String) -> Bool {
    BackgroundTransferSessions.uploadIdentifiers.contains(identifier)
      || identifier == BackgroundTransferSessions.downloadIdentifier
      || ShareDownloads.isShareSession(identifier)
  }

  /// Sessions whose events finished before a wake handed over their handler, for tests
  var finishedWithoutHandlerCount: Int {
    finishedWithoutHandler.count
  }

  /// The session's work settles first, under a background task so it isn't frozen
  /// mid-request or mid-write: uploads queue their next parts; downloads finish their
  /// follow-up (chapters, verification, scheduling — Core Data in the App Group container)
  private func answer(_ identifier: String, token: UUID) {
    let settle: () async -> Void
    if BackgroundTransferSessions.uploadIdentifiers.contains(identifier) {
      settle = dependencies.settleUploads
    } else if ShareDownloads.isShareSession(identifier) {
      // A share's files landed inside its delegate calls, before "finished events" (fork)
      settle = {}
    } else {
      settle = dependencies.settleDownloads
    }

    var backgroundTask = UIBackgroundTaskIdentifier.invalid
    let finish: (String) -> Void = { [weak self] reason in
      self?.callHandler(for: identifier, token: token, reason: reason)
      if backgroundTask != .invalid {
        self?.dependencies.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
      }
    }
    // iOS calls the expiration handler on the main thread and expects the task ended there
    backgroundTask = dependencies.beginBackgroundTask {
      MainActor.assumeIsolated { finish("background time expired") }
    }
    Task {
      await settle()
      finish("settled")
    }
    Task {
      try? await Task.sleep(for: dependencies.timeout)
      finish("timed out")
    }
  }

  private func scheduleFallback(for identifier: String, token: UUID) {
    Task {
      try? await Task.sleep(for: dependencies.timeout)
      callHandler(for: identifier, token: token, reason: "no events reported")
    }
  }

  /// Once per wake: the first of settle, timeout or expiration wins
  private func callHandler(for identifier: String, token: UUID, reason: String) {
    guard let entry = handlers[identifier], entry.token == token else { return }
    handlers[identifier] = nil
    Self.logger.info("Background session \(identifier) done (\(reason))")
    entry.handler()
  }
}
