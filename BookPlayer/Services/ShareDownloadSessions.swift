//
//  ShareDownloadSessions.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Foundation
import UIKit

/// Keeps the app connected to the share extension's background downloads (fork). iOS wakes the app for
/// a share's session once the extension is gone, but it never relaunches an app the person closed from
/// the app switcher, so the app also reconnects, at launch and on every foreground, to the sessions the
/// registry still holds that started more than `reconnectMargin` ago: a margin against opening a session
/// the extension may still hold (a session is one process's at a time), not proof that it let go.
///
/// A session is closed only once its events are known to be delivered: the system says so, or every task
/// the share started has been handled. Closing lets running tasks finish; it's forgotten after its last
/// delegate call.
@MainActor
final class ShareDownloadSessions: BPLogger {
  /// The part of a session this needs: closing it
  protocol SessionHandle: AnyObject {
    func finishTasksAndInvalidate()
  }

  struct Dependencies {
    var registry: ShareDownloadSessionRegistry?
    var failures: ShareImportFailureStore?
    var sharedFolder: () -> URL
    var now: () -> Date
    /// Opens the session with this identifier, delivering its events to the receiver
    var openSession: (_ identifier: String, _ receiver: ShareDownloadReceiver) -> SessionHandle
    var notificationCenter: NotificationCenter

    static var live: Dependencies {
      Dependencies(
        registry: .appGroup,
        failures: .appGroup,
        sharedFolder: { DataManager.getSharedFilesFolderURL() },
        now: Date.init,
        openSession: { identifier, receiver in
          ShareDownloads.makeSession(identifier: identifier, receiver: receiver)
        },
        notificationCenter: .default
      )
    }
  }

  static let shared = ShareDownloadSessions()

  /// How old a recorded session must be before the app opens it without being woken for it
  static let reconnectMargin: TimeInterval = 120

  private let dependencies: Dependencies
  /// The sessions open in this process, by identifier: each is opened once
  private(set) var openSessions = [String: SessionHandle]()
  private var foregroundObserver: NSObjectProtocol?

  init(dependencies: Dependencies = .live) {
    self.dependencies = dependencies
  }

  /// Reconnects now and on every return to the foreground. Called once, at launch
  func start() {
    reconnectRecordedSessions()
    foregroundObserver = dependencies.notificationCenter.addObserver(
      forName: UIApplication.willEnterForegroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.reconnectRecordedSessions()
      }
    }
  }

  /// iOS woke the app for this session. It only hands a session over once the extension is gone, so
  /// its age doesn't matter
  func activate(_ identifier: String) {
    open(identifier)
  }

  /// Opens every recorded session old enough that the extension has let it go
  func reconnectRecordedSessions() {
    guard let registry = dependencies.registry else { return }

    let cutoff = dependencies.now().addingTimeInterval(-Self.reconnectMargin)
    for session in registry.sessions() where session.startedAt <= cutoff {
      open(session.identifier)
    }
  }

  private func open(_ identifier: String) {
    guard openSessions[identifier] == nil else { return }

    let notificationCenter = dependencies.notificationCenter
    let receiver = ShareDownloadReceiver(
      sessionIdentifier: identifier,
      sharedFolder: dependencies.sharedFolder(),
      failures: dependencies.failures,
      registry: dependencies.registry,
      onFinishedEvents: { [weak self] identifier in
        // The wake coordinator answers iOS on this; then the session can close
        notificationCenter.post(name: .backgroundSessionFinishedEvents, object: identifier)
        Task { @MainActor in self?.close(identifier) }
      },
      onAllTasksDone: { [weak self] identifier in
        Task { @MainActor in self?.close(identifier) }
      },
      onInvalidated: { [weak self] identifier in
        Task { @MainActor in self?.openSessions[identifier] = nil }
      }
    )
    Self.logger.info("Opening share download session \(identifier)")
    openSessions[identifier] = dependencies.openSession(identifier, receiver)
  }

  /// Closes the session once its running tasks end; their events still arrive first
  private func close(_ identifier: String) {
    openSessions[identifier]?.finishTasksAndInvalidate()
  }
}

extension URLSession: ShareDownloadSessions.SessionHandle {}
