//
//  MediaServerSourceTracker.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-05-17.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Combine
import Foundation

/// Bridges `SingleFileDownloadService` events to `MediaServerSourceStore` so that media-server
/// downloads transition from "pending by request URL" to "resolved by relativePath" once the
/// server hands us the actual filename.
///
/// Stateless wrt history — only acts on events coming in after init. That's fine because the
/// store persists pending entries to UserDefaults, so a process restart between download start
/// and finish still resolves correctly via the next finish event.
final class MediaServerSourceTracker: BPLogger {
  private let store: MediaServerSourceStore
  private var subscription: AnyCancellable?

  init(
    store: MediaServerSourceStore,
    downloadService: SingleFileDownloadService
  ) {
    self.store = store
    self.subscription = downloadService.eventsPublisher.sink { [weak self] event in
      self?.handle(event)
    }
  }

  private func handle(_ event: SingleFileDownloadService.Events) {
    switch event {
    case .finished(let task):
      finalize(task: task)
    case .error(_, let task, _):
      cancel(task: task)
    case .starting, .progress, .bytesWritten:
      break
    }
  }

  /// On success, we look up the pending entry by request URL and promote it to a
  /// relativePath-keyed mapping. The relativePath we predict here is the same one `ImportManager`
  /// ends up creating: documents folder + suggested filename.
  private func finalize(task: URLSessionTask) {
    guard
      let requestURL = task.originalRequest?.url,
      let filename = task.response?.suggestedFilename ?? task.originalRequest?.url?.lastPathComponent
    else {
      return
    }

    store.finalizePendingDownload(requestURL, relativePath: filename)
  }

  private func cancel(task: URLSessionTask) {
    guard let requestURL = task.originalRequest?.url else { return }
    store.removePendingDownload(requestURL)
  }
}
