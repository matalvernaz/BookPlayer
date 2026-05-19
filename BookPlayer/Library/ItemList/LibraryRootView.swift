//
//  LibraryRootView.swift
//  BookPlayer
//
//  Created by Gianni Carlo on 10/8/25.
//  Copyright © 2025 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import DirectoryWatcher
import SwiftUI

struct LibraryRootView: View {
  let showSecondOnboarding: () -> Void
  let showImport: () -> Void

  @State private var path = [LibraryNode]()

  @State private var newFolderName: String = ""
  @State private var isFirstLoad = true

  @State private var importOperationState = ImportOperationState()
  @State private var loadingState = LoadingOverlayState()

  /// Failures recovered from `ShareImportFailureStore` on foreground — drained once per scene
  /// activation, surfaced in an alert plus a VoiceOver announcement. Cleared when the user
  /// dismisses the alert.
  @State private var pendingShareImportFailures: [ShareImportFailure] = []

  @StateObject private var documentFolderWatcher = DirectoryWatcher.watch(
    DataManager.getDocumentsFolderURL(),
    ignoreDirectories: false
  )!
  @StateObject private var sharedFolderWatcher = DirectoryWatcher.watch(
    DataManager.getSharedFilesFolderURL(),
    ignoreDirectories: false
  )!

  /// Environment
  @StateObject private var theme = ThemeViewModel()

  @EnvironmentObject private var playerManager: PlayerManager
  @EnvironmentObject private var importManager: ImportManager
  @EnvironmentObject private var singleFileDownloadService: SingleFileDownloadService
  @EnvironmentObject private var listSyncRefreshService: ListSyncRefreshService

  @Environment(\.listState) private var listState
  @Environment(\.playerState) private var playerState
  @Environment(\.libraryService) private var libraryService
  @Environment(\.playbackService) private var playbackService
  @Environment(\.syncService) private var syncService
  @Environment(\.hardcoverService) private var hardcoverService
  @Environment(\.hummingbirdService) private var hummingbirdService
  @Environment(\.mediaServerSourceStore) private var mediaServerSourceStore
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    NavigationStack(path: $path) {
      ItemListView {
        ItemListViewModel(
          libraryNode: .root,
          libraryService: libraryService,
          playbackService: playbackService,
          playerManager: playerManager,
          syncService: syncService,
          listSyncRefreshService: listSyncRefreshService,
          loadingState: loadingState,
          listState: listState,
          singleFileDownloadService: singleFileDownloadService,
          mediaServerSourceStore: mediaServerSourceStore,
          hummingbirdService: hummingbirdService
        )
      }
      .navigationDestination(for: LibraryNode.self) { node in
        ItemListView {
          ItemListViewModel(
            libraryNode: node,
            libraryService: libraryService,
            playbackService: playbackService,
            playerManager: playerManager,
            syncService: syncService,
            listSyncRefreshService: listSyncRefreshService,
            loadingState: loadingState,
            listState: listState,
            singleFileDownloadService: singleFileDownloadService,
            mediaServerSourceStore: mediaServerSourceStore,
            hummingbirdService: hummingbirdService
          )
        }
        .navigationBarTitleDisplayMode(.inline)
        .errorAlert(error: $loadingState.error)
      }
      .errorAlert(error: $loadingState.error)
      .loadingOverlay(loadingState.show, message: loadingState.message)
      .onAppear {
        guard isFirstLoad else { return }

        isFirstLoad = false

        Task {
          await handleLibraryLoaded()
        }
      }
      .onChange(of: scenePhase) {
        guard scenePhase == .active else { return }
        showImport()
        drainShareImportFailures()
      }
      .alert(
        "share_import_failure_alert_title".localized,
        isPresented: Binding(
          get: { !pendingShareImportFailures.isEmpty },
          set: { if !$0 { pendingShareImportFailures = [] } }
        ),
        actions: {
          Button("ok_button".localized) { pendingShareImportFailures = [] }
        },
        message: {
          Text(pendingShareImportFailures.map { "• \($0.message)" }.joined(separator: "\n"))
        }
      )
      .onReceive(syncService.downloadErrorPublisher) { (relativePath, error) in
        let errorMessage = "\(relativePath)\n\(error.localizedDescription)"
        loadingState.error = BookPlayerError.networkError(errorMessage)
      }
      .onReceive(importManager.observeFiles()) { files in
        guard !files.isEmpty, !singleFileDownloadService.isDownloading else { return }

        showImport()
      }
      .onReceive(singleFileDownloadService.eventsPublisher) { event in
        // Re-trigger the import flow when a download queue drains.
        //
        // `observeFiles` short-circuits while `isDownloading` is
        // true, and `CurrentValueSubject` doesn't re-fire when a
        // download merely finishes -- only when the set of pending
        // import URLs changes. For Hummingbird's multi-file flow
        // that's a real problem: the folder URL gets added to the
        // import set the moment the directory is created (first
        // file's move), `observeFiles` fires once and is blocked by
        // `isDownloading=true`, the rest of the files land in the
        // same folder (no new URLs added -> no new events), and
        // after the LAST file finishes the queue has drained but
        // nothing prods the import flow. Result: files sit in
        // `documents/folderName/*` and never get imported. Without
        // this prod the user sees "100% downloaded" with no books
        // appearing in the library.
        //
        // Reported follow-up: even when the dialog DID appear (via
        // the folder watcher firing `observeFiles` mid-download
        // during the brief `processNextDownload` window when
        // `isDownloading` is momentarily false), the user could
        // interact with it for a split second before it dismissed.
        // That's almost certainly a UIKit presentation-conflict
        // flash: showImport() runs while another modal (the
        // Hummingbird library sheet, the connection sheet, etc.)
        // is mid-animation. So this handler also waits ~750ms
        // before presenting so any in-flight UIKit transition has
        // a chance to settle.
        guard case .finished = event else { return }
        Task { @MainActor in
          // 1. Yield once so SingleFileDownloadService's own
          //    `currentTask = nil` cleanup (a separate @MainActor
          //    Task scheduled inside the SAME sink closure, AFTER
          //    this one) actually runs first. Without the yield,
          //    our Task is FIFO-first and sees the stale
          //    `currentTask` -- `isDownloading` reads true and the
          //    guard below short-circuits exactly when we'd want it
          //    to fire (the last file in a batch).
          await Task.yield()
          // 2. Settle delay. Any concurrent modal animation (sheet
          //    presentation, dismissal, navigation pop) needs time
          //    to complete before we layer another modal on top --
          //    otherwise UIKit can drop the presentation and the
          //    dialog flashes briefly before disappearing.
          try? await Task.sleep(nanoseconds: 750_000_000)
          guard
            !singleFileDownloadService.isDownloading,
            importManager.hasPendingFiles()
          else { return }
          showImport()
        }
      }
      .onReceive(documentFolderWatcher.newFilesPublisher) { files in
        files.forEach { importManager.process($0) }
      }
      .onReceive(sharedFolderWatcher.newFilesPublisher) { files in
        files.forEach { importManager.process($0) }
      }
      .onReceive(importManager.operationPublisher) { operation in
        importOperationState.isOperationActive = true
        importOperationState.processingTitle = String.localizedStringWithFormat(
          "import_processing_description".localized,
          operation.files.count
        )
        operation.completionBlock = {
          DispatchQueue.main.async {
            self.importOperationState.isOperationActive = false
            self.importOperationState.processingTitle = ""
            self.handleOperationCompletion(operation.processedFiles, suggestedFolderName: operation.suggestedFolderName)
          }
        }

        importManager.start(operation)
      }
    }
    .tint(theme.linkColor)
    .environmentObject(theme)
    .environment(\.loadingState, loadingState)
    .environment(\.importOperationState, importOperationState)
  }

  func handleLibraryLoaded() async {
    await loadLastBookIfNeeded()
    importManager.notifyPendingFiles()
    showSecondOnboarding()

    let pendingActions = AppServices.shared.pendingURLActions
    AppServices.shared.pendingURLActions.removeAll()
    for action in pendingActions {
      ActionParserService.handleAction(action)
    }
  }

  /// Drain share-import failures that piled up while the app wasn't foregrounded — these come
  /// from the share extension's synchronous copy errors and the main app's background-download
  /// delegate move/HTTP errors. We surface them via the alert (visible) and a VoiceOver
  /// announcement so a blind user knows the share didn't actually succeed.
  func drainShareImportFailures() {
    let failures = ShareImportFailureStore.drain()
    guard !failures.isEmpty else { return }
    pendingShareImportFailures = failures

    let announcement: String = {
      if failures.count == 1 {
        return failures[0].message
      }
      let summary = String(
        format: "share_import_failure_announcement_multiple".localized,
        failures.count
      )
      return summary + " " + failures.map(\.message).joined(separator: ". ")
    }()
    UIAccessibility.post(notification: .announcement, argument: announcement)
  }

  func loadLastBookIfNeeded() async {
    guard
      playerManager.currentItem == nil,
      let libraryItem = libraryService.getLibraryLastItem()
    else { return }

    do {
      try await AppServices.shared.coreServices?.playerLoaderService.loadPlayer(
        libraryItem.relativePath,
        autoplay: false,
        recordAsLastBook: false
      )
      if UserDefaults.standard.bool(forKey: Constants.UserActivityPlayback) {
        UserDefaults.standard.removeObject(forKey: Constants.UserActivityPlayback)
        playerManager.play()
      }

      if UserDefaults.standard.bool(forKey: Constants.UserDefaults.showPlayer) {
        UserDefaults.standard.removeObject(forKey: Constants.UserDefaults.showPlayer)
        playerState.showPlayer = true
      }
    } catch BPPlayerError.fileMissing {
      // Silent preload: if the last-played file is missing on disk,
      // swallow the error. The user will see the proper alert if/when
      // they explicitly try to play this book. Surfacing it here would
      // race with other cold-launch presentations (e.g. the import sheet).
    } catch {
      loadingState.error = error
    }
  }

  func handleOperationCompletion(_ files: [URL], suggestedFolderName: String?) {
    guard !files.isEmpty else {
      return
    }

    Task { @MainActor in
      let processedItems = await libraryService.insertItems(from: files)
      var itemIdentifiers = processedItems.map({ $0.relativePath })
      var itemIdentifiersPairs = processedItems.map({ LibraryItemRef(relativePath: $0.relativePath, uuid: $0.uuid) })
      do {
        await syncService.scheduleUpload(items: processedItems)
        /// Move imported files to current selected folder so the user can see them
        if let lastItem = path.last,
           let folderRelativePath = lastItem.folderRelativePath {
          try libraryService.moveItems(itemIdentifiersPairs, inside: folderRelativePath)
          syncService.scheduleMove(items: itemIdentifiersPairs, to: LibraryItemRef(relativePath: folderRelativePath, uuid: lastItem.uuid ))
          /// Update identifiers after moving for the follow up action alert
          itemIdentifiers = itemIdentifiers.map({ "\(folderRelativePath)/\($0)" })
        }
      } catch {
        loadingState.error = error
        return
      }

      /// Reload all items
      listState.reloadAll(padding: itemIdentifiers.count)

      await hardcoverService.processAutoMatch(for: processedItems)

      let availableFolders =
        self.libraryService.getItems(
          notIn: itemIdentifiers,
          parentFolder: path.last?.folderRelativePath
        )?.filter({ $0.type == .folder }) ?? []

      let singleFolder: SimpleLibraryItem? =
        processedItems.count == 1 && processedItems.allSatisfy({ $0.type == .folder })
        ? processedItems.first : nil
      let hasOnlyBooks = processedItems.allSatisfy({ $0.type == .book })

      var firstTitle: String?
      if let suggestedFolderName {
        firstTitle = suggestedFolderName
      } else if let relativePath = itemIdentifiers.first {
        /// Xcode Cloud is throwing an error on #keyPath(BookPlayerKit.LibraryItem.title)
        firstTitle =
          libraryService.getItemProperty(
            "title",
            relativePath: relativePath
          ) as? String
      }

      importOperationState.alertParameters = .init(
        itemIdentifiers: itemIdentifiersPairs,
        hasOnlyBooks: hasOnlyBooks,
        singleFolder: singleFolder,
        availableFolders: availableFolders,
        suggestedFolderName: firstTitle,
        lastNode: path.last ?? .root
      )
    }
  }
}

extension LibraryRootView {
  @MainActor
  final class Model {
    init() {}
  }
}

#Preview {
  LibraryRootView {
  } showImport: {
  }
}