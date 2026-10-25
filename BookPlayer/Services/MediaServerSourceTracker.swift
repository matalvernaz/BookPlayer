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
/// download fails. `ImportOperation` takes it from there into the library. A folder reserved for a
/// multi-file download (`MediaServerDownloadFolders`) is let go once all its downloads have ended
/// with nothing saved in it, so its name can be used again.
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

    downloadService.folderDownloadsEndedPublisher
      .sink { [weak self] folderName in
        self?.release(folder: folderName)
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

  /// Lets go of a folder's landed entries when nothing is left in it to import: every download into
  /// it failed, or the import already took it (it brings the entries into the library before it
  /// removes the folder, so a missing folder has nothing left to lose). The folder itself is never
  /// deleted here.
  private func release(folder folderName: String) {
    let folderURL = DataManager.getDocumentsFolderURL().appendingPathComponent(folderName)
    guard Self.holdsNothing(folderURL) else { return }

    store.removeLandedSources(under: folderName)
  }

  /// Whether the folder at `url` is missing or empty, hidden files aside. One that can't be listed
  /// (or isn't a folder) counts as holding something: the reservation stays.
  static func holdsNothing(_ url: URL) -> Bool {
    guard FileManager.default.fileExists(atPath: url.path) else { return true }

    guard
      let contents = try? FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: nil,
        options: .skipsHiddenFiles
      )
    else {
      return false
    }

    return contents.isEmpty
  }
}
