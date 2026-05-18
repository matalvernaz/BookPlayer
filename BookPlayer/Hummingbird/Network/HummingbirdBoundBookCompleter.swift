//
//  HummingbirdBoundBookCompleter.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-05-18.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Combine
import Foundation
import UIKit

/// Auto-binds Hummingbird-sourced bound-book folders into single playable
/// items once the multi-file download finishes.
///
/// Without this, a downloaded DAISY archive lands as a *folder* with
/// many audio children in BookPlayer's library, and the user has to
/// manually "bind" it via the UI to get one playable item. Same disk
/// state, two CoreData representations -- folder vs bound.
///
/// Approach is sweep-based rather than per-event-counted: on app
/// launch, on foreground transition, and after every download finishes,
/// we walk the media-server source store for Hummingbird-sourced
/// folders that are still typed ``.folder`` (not ``.bound``) and
/// upgrade them. This is resilient to mid-batch app termination -- the
/// next launch finishes the bind even if the user killed BookPlayer
/// during the download.
final class HummingbirdBoundBookCompleter: BPLogger {
  private let sourceStore: MediaServerSourceStore
  private let libraryService: LibraryService
  private let downloadService: SingleFileDownloadService

  private var subscription: AnyCancellable?
  private var foregroundObserver: NSObjectProtocol?

  init(
    sourceStore: MediaServerSourceStore,
    libraryService: LibraryService,
    downloadService: SingleFileDownloadService
  ) {
    self.sourceStore = sourceStore
    self.libraryService = libraryService
    self.downloadService = downloadService

    // Sweep at launch for any incomplete-bound folders from prior sessions.
    Task { @MainActor [weak self] in await self?.sweep() }

    // Sweep after every per-file download finishes -- catches the just-
    // completed batch in the live session.
    self.subscription = downloadService.eventsPublisher.sink { [weak self] event in
      switch event {
      case .finished, .error:
        Task { @MainActor [weak self] in await self?.sweep() }
      default:
        break
      }
    }

    // Sweep on foreground transitions so background-completed downloads
    // get bound when the user returns to the app.
    self.foregroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      Task { @MainActor [weak self] in await self?.sweep() }
    }
  }

  deinit {
    if let foregroundObserver {
      NotificationCenter.default.removeObserver(foregroundObserver)
    }
  }

  @MainActor
  func sweep() async {
    for (relativePath, info) in sourceStore.allResolved {
      guard info.kind == .hummingbird else { continue }
      guard let item = libraryService.getSimpleItem(with: relativePath) else { continue }
      // Skip per-file source mappings (those have ``.book`` type) and
      // anything already bound. Only ``.folder`` items need promotion.
      guard item.type == .folder else { continue }
      do {
        try libraryService.updateFolder(at: relativePath, type: .bound)
        Self.logger.info("Hummingbird folder auto-bound: \(relativePath)")
      } catch {
        Self.logger.warning(
          "Hummingbird auto-bind failed for \(relativePath): \(error.localizedDescription)"
        )
      }
    }
  }
}
