//
//  MediaServerBoundBookCompleter.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-05-18.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Combine
import Foundation
import UIKit

/// Binds media-server folder downloads into single playable books once they're in the library,
/// for any download whose provenance opted in via ``MediaServerSourceInfo/shouldBindFolder``
/// (Audiobookshelf share links, Hummingbird DAISY archives, SoundBooth multi-chapter titles).
///
/// Without this, a multi-file download lands as a *folder* of audio files, and the user has to
/// bind it by hand to get one playable book.
///
/// Sweep-based rather than counting events: at launch, on returning to the foreground, after every
/// download finishes and after every import, it walks the provenance store for bind-flagged folders
/// still typed ``SimpleItemType/folder`` and binds them. That survives the app being killed
/// mid-batch: the next launch finishes the bind.
///
/// Binding also applies the source's one-shot resume seed (``MediaServerSourceInfo/seedTime``):
/// the account's position on the server, so a book picked up mid-story there resumes there.
final class MediaServerBoundBookCompleter: BPLogger {
  private let sourceStore: MediaServerSourceStore
  private let libraryService: LibraryService

  private var subscription: AnyCancellable?
  private var foregroundObserver: NSObjectProtocol?
  private var importObserver: NSObjectProtocol?

  init(
    sourceStore: MediaServerSourceStore,
    libraryService: LibraryService,
    downloadService: SingleFileDownloadService
  ) {
    self.sourceStore = sourceStore
    self.libraryService = libraryService

    // Folders left unbound by an earlier session
    Task { @MainActor [weak self] in self?.sweep() }

    // The batch that's downloading now
    self.subscription = downloadService.eventsPublisher.sink { [weak self] event in
      switch event {
      case .finished, .error:
        Task { @MainActor [weak self] in self?.sweep() }
      default:
        break
      }
    }

    // Downloads that finished in the background
    self.foregroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.sweep() }
    }

    // A folder imported after its last file arrived
    self.importObserver = NotificationCenter.default.addObserver(
      forName: .importItemsInserted,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.sweep() }
    }
  }

  deinit {
    for observer in [foregroundObserver, importObserver].compactMap({ $0 }) {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  @MainActor
  func sweep() {
    for (relativePath, info) in sourceStore.allResolved {
      // Only folders the download explicitly marked bind-on-complete
      guard info.shouldBindFolder == true else { continue }
      guard let item = libraryService.getSimpleItem(with: relativePath) else { continue }
      // Per-file entries are books, and a bound folder is done
      guard item.type == .folder else { continue }
      do {
        try libraryService.updateFolder(at: relativePath, type: .bound)
        Self.logger.info("media-server folder auto-bound: \(relativePath)")
      } catch {
        Self.logger.warning("auto-bind failed for \(relativePath): \(error.localizedDescription)")
        continue
      }
      // Runs only in the sweep that binds (the item is `.bound` afterwards), so a position the
      // user moves later is never overwritten
      if let seedTime = info.seedTime, seedTime > 0 {
        libraryService.updatePlaybackTime(
          relativePath: relativePath,
          time: seedTime,
          date: Date(),
          scheduleSave: true
        )
        Self.logger.info("seeded resume position \(Int(seedTime))s for \(relativePath)")
      }
    }
  }
}
