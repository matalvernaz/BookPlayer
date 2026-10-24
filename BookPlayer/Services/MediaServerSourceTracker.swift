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

/// Moves a media-server download's provenance from "pending by request URL" to "landed at its path
/// under Documents" once `SingleFileDownloadService` has saved the file there, and drops it when the
/// download fails. `ImportOperation` takes it from there into the library.
///
/// It never acts on `.finished`: that event is sent before the file is moved, and for failed
/// downloads too. Only `savedFilesPublisher` says a file really arrived, with its real path.
final class MediaServerSourceTracker: BPLogger {
  private let store: MediaServerSourceStore
  private var disposeBag = Set<AnyCancellable>()

  init(
    store: MediaServerSourceStore,
    downloadService: SingleFileDownloadService
  ) {
    self.store = store

    downloadService.savedFilesPublisher
      .sink { [weak self] saved in
        self?.land(task: saved.task, destination: saved.destination)
      }
      .store(in: &disposeBag)

    downloadService.eventsPublisher
      .sink { [weak self] event in
        guard case .error(_, let task, _) = event else { return }
        self?.drop(task: task)
      }
      .store(in: &disposeBag)
  }

  private func land(task: URLSessionTask, destination: URL) {
    guard
      let requestURL = task.originalRequest?.url,
      let documentsRelativePath = MediaServerSourceStore.documentsRelativePath(of: destination)
    else {
      return
    }

    store.landPendingDownload(requestURL, at: documentsRelativePath)
  }

  /// Keyed by the request URL, so it only ever finds a download that never landed: a stray error
  /// for one that did leaves its landed entry alone.
  private func drop(task: URLSessionTask) {
    guard let requestURL = task.originalRequest?.url else { return }
    store.removePendingDownload(requestURL)
  }
}
