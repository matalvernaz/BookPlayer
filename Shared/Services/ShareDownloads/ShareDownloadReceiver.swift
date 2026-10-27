//
//  ShareDownloadReceiver.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import Foundation

/// What becomes of the share extension's downloads as they end (fork), in whichever process holds the
/// session then: the extension while it's still running, the app after that. A download lands in the
/// shared folder, where the app's import picks it up, or becomes a failure the app shows. Each task is
/// marked done in the registry once its end is handled; closing the session is its owner's call.
public final class ShareDownloadReceiver: NSObject, URLSessionDownloadDelegate, BPLogger, @unchecked Sendable {
  public typealias Callback = @Sendable (_ sessionIdentifier: String) -> Void

  public let sessionIdentifier: String
  private let sharedFolder: URL
  private let failures: ShareImportFailureStore?
  private let registry: ShareDownloadSessionRegistry?
  private let onFinishedEvents: Callback?
  private let onAllTasksDone: Callback?
  private let onInvalidated: Callback?

  /// - Parameters:
  ///   - onFinishedEvents: The system has delivered every event it was holding for the session
  ///   - onAllTasksDone: Every task the share started has had its end handled
  ///   - onInvalidated: The session closed, after its last delegate call
  public init(
    sessionIdentifier: String,
    sharedFolder: URL,
    failures: ShareImportFailureStore?,
    registry: ShareDownloadSessionRegistry?,
    onFinishedEvents: Callback? = nil,
    onAllTasksDone: Callback? = nil,
    onInvalidated: Callback? = nil
  ) {
    self.sessionIdentifier = sessionIdentifier
    self.sharedFolder = sharedFolder
    self.failures = failures
    self.registry = registry
    self.onFinishedEvents = onFinishedEvents
    self.onAllTasksDone = onAllTasksDone
    self.onInvalidated = onInvalidated
  }

  public func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    let link = downloadTask.originalRequest?.url
    switch ShareDownloads.finish(download: location, response: downloadTask.response, originalURL: link, into: sharedFolder) {
    case .landed(let destination):
      Self.logger.info("Shared download landed as \(destination.lastPathComponent)")
    case .failed(let reason):
      failures?.append(ShareImportFailure(source: ShareDownloads.sourceName(for: link), reason: reason))
    }
  }

  /// Every task ends here, after its file (if any) was handled above on the same queue, so the done
  /// marker always follows the landing or the failure
  public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error {
      let link = task.originalRequest?.url
      failures?.append(
        ShareImportFailure(source: ShareDownloads.sourceName(for: link), reason: ShareDownloads.failureReason(for: error))
      )
    }

    guard let registry else { return }
    registry.markDone(sessionIdentifier, taskIdentifier: task.taskIdentifier)
    if registry.isComplete(sessionIdentifier) {
      onAllTasksDone?(sessionIdentifier)
    }
  }

  public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    onFinishedEvents?(sessionIdentifier)
  }

  /// The session's last delegate call has been made. Closed on purpose (no error), everything it had
  /// was handled, so it's forgotten. Ended by an error (another process still holding it, say), nothing
  /// shows its downloads were handled, so its record stays for the next reconnect. Either way its owner
  /// lets go of it
  public func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
    if let error {
      Self.logger.error("Share download session ended with an error, kept for a reconnect: \(error.localizedDescription)")
    } else {
      registry?.forget(sessionIdentifier)
    }
    onInvalidated?(sessionIdentifier)
  }
}
