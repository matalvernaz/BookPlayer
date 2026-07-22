//
//  MainCoordinator.swift
//  BookPlayer
//
//  Created by Gianni Carlo on 5/9/21.
//  Copyright © 2021 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Combine
import RevenueCat
import SwiftUI
import Themeable
import UIKit

@MainActor
class MainCoordinator: NSObject {
  var mainController: UIViewController?

  let importManager: ImportManager
  let playerManager: PlayerManager
  let playerLoaderService: PlayerLoaderService
  let singleFileDownloadService: SingleFileDownloadService
  let libraryService: LibraryService
  let playbackService: PlaybackService
  let listSyncRefreshService: ListSyncRefreshService
  let accountService: AccountService
  var syncService: SyncService
  let watchConnectivityService: PhoneWatchConnectivityService
  let jellyfinConnectionService: JellyfinConnectionService
  let audiobookshelfConnectionService: AudiobookShelfConnectionService
  let hummingbirdConnectionService: HummingbirdConnectionService
  let soundboothConnectionService: SoundBoothConnectionService
  let hardcoverService: HardcoverService
  let preferencesService: PreferencesSyncService
  let mediaServerSourceStore: MediaServerSourceStore
  /// Holds strong refs to the source tracker and progress dispatcher so they stay alive for the
  /// lifetime of the main coordinator. Neither is referenced outside this class.
  private let mediaServerSourceTracker: MediaServerSourceTracker
  private let mediaServerProgressDispatcher: MediaServerProgressDispatcher
  /// Sweeps expired Hummingbird loans. NNELS never has a due date so this is
  /// usually a cheap no-op; kept alive across the coordinator's lifetime so
  /// the `scenePhase = .active` observer can fire repeatedly.
  private let hummingbirdLoanExpiryScanner: HummingbirdLoanExpiryScanner
  /// Promotes multi-file media-server folders (Hummingbird, SoundBooth)
  /// to bound-books once their downloads finish, seeding any server-side
  /// resume position. Resilient to mid-batch app termination via the
  /// foreground-transition + launch sweeps.
  private let boundBookCompleter: MediaServerBoundBookCompleter
  /// Pulls server-side bookmarks for freshly-imported Hummingbird
  /// books so a resume position set on device A surfaces on device B.
  /// Pairs with HummingbirdProgressReporter (which pushes the same
  /// shape upward) to give two-way bookmark sync.
  private let hummingbirdBookmarkPuller: HummingbirdBookmarkPuller

  var playerState: PlayerState { AppServices.shared.playerState }

  /// Reference to know if the import screen is already being shown (or in the process of showing)
  weak var importCoordinator: ImportCoordinator?
  /// Retry loop that keeps attempting to present the import screen while files are pending.
  /// Non-nil while the loop is alive; see ``showImport()``.
  private var importPresentationTask: Task<Void, Never>?
  /// Interval between import-presentation attempts. Long enough for any in-flight
  /// modal transition (~0.4-0.6s) to settle before the next try.
  private static let importPresentationRetryNanoseconds: UInt64 = 750_000_000
  let navigationController: UINavigationController

  private var disposeBag = Set<AnyCancellable>()

  init(
    navigationController: UINavigationController,
    coreServices: CoreServices
  ) {
    self.navigationController = navigationController
    self.libraryService = coreServices.libraryService
    // Created ahead of the services it's wired into further down so the import
    // pipeline can carry download provenance through zip extraction.
    let sourceStore = MediaServerSourceStore()
    self.importManager = ImportManager(
      libraryService: coreServices.libraryService,
      mediaServerSourceStore: sourceStore
    )
    self.accountService = coreServices.accountService
    self.syncService = coreServices.syncService
    self.playbackService = coreServices.playbackService
    self.playerManager = coreServices.playerManager
    self.playerLoaderService = coreServices.playerLoaderService
    self.listSyncRefreshService = ListSyncRefreshService(
      playerManager: playerManager,
      syncService: syncService,
      playerLoaderService: coreServices.playerLoaderService,
      preferencesService: coreServices.preferencesService
    )
    self.singleFileDownloadService = SingleFileDownloadService(networkClient: NetworkClient())
    self.watchConnectivityService = coreServices.watchService
    let jellyfinService = JellyfinConnectionService()
    jellyfinService.setup()
    self.jellyfinConnectionService = jellyfinService

    let audiobookshelfService = AudiobookShelfConnectionService()
    audiobookshelfService.setup()
    self.audiobookshelfConnectionService = audiobookshelfService

    let hummingbirdService = HummingbirdConnectionService()
    hummingbirdService.setup()
    self.hummingbirdConnectionService = hummingbirdService

    let soundboothService = SoundBoothConnectionService()
    soundboothService.setup()
    self.soundboothConnectionService = soundboothService

    self.hardcoverService = coreServices.hardcoverService
    self.preferencesService = coreServices.preferencesService

    self.mediaServerSourceStore = sourceStore
    audiobookshelfService.mediaServerSourceStore = sourceStore
    jellyfinService.mediaServerSourceStore = sourceStore
    hummingbirdService.mediaServerSourceStore = sourceStore
    soundboothService.mediaServerSourceStore = sourceStore
    // Gate Tortuga sync against media-server-sourced items so progress
    // ticks / deletes / list-syncs don't cross-talk with the source
    // server's authoritative record.
    syncService.setMediaServerSourceStore(sourceStore)
    self.mediaServerSourceTracker = MediaServerSourceTracker(
      store: sourceStore,
      downloadService: self.singleFileDownloadService
    )
    self.mediaServerProgressDispatcher = MediaServerProgressDispatcher(
      playerManager: self.playerManager,
      sourceStore: sourceStore,
      reporters: [
        AudiobookShelfProgressReporter(connectionService: audiobookshelfService),
        JellyfinProgressReporter(connectionService: jellyfinService),
        HummingbirdProgressReporter(connectionService: hummingbirdService),
        SoundBoothProgressReporter(connectionService: soundboothService),
      ],
      accountService: coreServices.accountService
    )
    self.hummingbirdLoanExpiryScanner = HummingbirdLoanExpiryScanner(
      connectionService: hummingbirdService,
      sourceStore: sourceStore,
      libraryService: libraryService
    )
    self.boundBookCompleter = MediaServerBoundBookCompleter(
      sourceStore: sourceStore,
      libraryService: libraryService,
      downloadService: self.singleFileDownloadService
    )
    self.hummingbirdBookmarkPuller = HummingbirdBookmarkPuller(
      connectionService: hummingbirdService,
      sourceStore: sourceStore,
      libraryService: libraryService,
      downloadService: self.singleFileDownloadService
    )

    ThemeManager.shared.libraryService = libraryService

    super.init()

    setUpTheming()
    // Sweep once on launch. Subsequent sweeps are driven by the
    // foreground-transition notification inside the scanner itself.
    Task { [scanner = hummingbirdLoanExpiryScanner] in await scanner.scan() }
  }

  func start() {
    if var currentTheme = libraryService.getLibraryCurrentTheme() {
      currentTheme.useDarkVariant = ThemeManager.shared.useDarkVariant
      ThemeManager.shared.currentTheme = currentTheme
    }

    bindObservers()

    accountService.loginIfUserExists(delegate: self)

    let vc = AppHostingViewController(
      rootView: MainView {
        self.showSecondOnboarding()
      } showImport: {
        self.showImport()
      }
      .environmentObject(singleFileDownloadService)
      .environmentObject(importManager)
      .environmentObject(playerManager)
      .environmentObject(listSyncRefreshService)
      .environment(\.libraryService, libraryService)
      .environment(\.accountService, accountService)
      .environment(\.syncService, syncService)
      .environment(\.jellyfinService, jellyfinConnectionService)
      .environment(\.audiobookshelfService, audiobookshelfConnectionService)
      .environment(\.hummingbirdService, hummingbirdConnectionService)
      .environment(\.soundboothService, soundboothConnectionService)
      .environment(\.mediaServerSourceStore, mediaServerSourceStore)
      .environment(\.hardcoverService, hardcoverService)
      .environment(\.playerState, playerState)
      .environment(\.playerLoaderService, playerLoaderService)
      .environment(\.playbackService, playbackService)
      .environment(\.preferencesService, preferencesService)
    )
    vc.modalPresentationStyle = .fullScreen
    vc.modalTransitionStyle = .crossDissolve
    
    // Set window interface style BEFORE presenting the view controller
    // This ensures SwiftUI views are initialized with the correct colorScheme
    if let window = navigationController.view.window ?? WindowHelper.activeWindow {
      if UserDefaults.standard.bool(forKey: Constants.UserDefaults.systemThemeVariantEnabled) {
        window.overrideUserInterfaceStyle = .unspecified
      } else {
        window.overrideUserInterfaceStyle = ThemeManager.shared.useDarkVariant ? .dark : .light
      }
    }
    
    navigationController.present(vc, animated: false)
    mainController = vc

    AppServices.shared.coreServices?.watchService.startSession()
  }

  func showSecondOnboarding() {
    guard let anonymousId = accountService.getAnonymousId() else { return }

    let coordinator = SecondOnboardingCoordinator(
      flow: .modalOnlyFlow(
        presentingController: mainController!,
        modalPresentationStyle: .fullScreen
      ),
      anonymousId: anonymousId,
      accountService: accountService,
      eventsService: EventsService()
    )
    coordinator.start()
  }

  /// Present the import screen for the pending files, retrying until it actually shows.
  ///
  /// Every caller is an edge trigger (a file landing, a download queue draining,
  /// the scene activating), but whether the presentation can succeed at that exact
  /// moment depends on UIKit state the callers can't see: a modal transition may be
  /// in flight, a download queue may still be running, or the import screen may
  /// have been presented on a media-server sheet that was then dismissed and took
  /// the screen down with it — all with the import set still pending and nothing
  /// left to re-fire. So instead of a single attempt, this arms a loop that retries
  /// while files remain pending and stops once they drain (import started or
  /// discarded). While the import screen is up the loop idles; if the screen is
  /// torn down by a parent dismissal it re-presents on the new top controller.
  func showImport() {
    guard importPresentationTask == nil else { return }

    importPresentationTask = Task { @MainActor [weak self] in
      defer { self?.importPresentationTask = nil }

      while !Task.isCancelled {
        guard let self, self.importManager.hasPendingFiles() else { return }

        // Don't present mid-queue: the import set can reference a folder that's
        // still receiving files, and the dialog would list a half-downloaded book.
        if self.importCoordinator == nil,
           !self.singleFileDownloadService.isDownloading {
          self.attemptImportPresentation()
        }

        try? await Task.sleep(nanoseconds: Self.importPresentationRetryNanoseconds)
      }
    }
  }

  /// Single presentation attempt; bails when UIKit can't host a new modal yet.
  /// Failures are not terminal — the ``showImport()`` loop tries again.
  private func attemptImportPresentation() {
    guard
      let topVC = WindowHelper.activeWindow?.rootViewController?.getTopVisibleViewController()
    else { return }

    // Defend against the "dialog flashes and dismisses" symptom
    // reported when the Hummingbird library sheet is in the middle
    // of being dismissed (or any other modal transition is in
    // flight). Presenting on a VC that's being-presented or
    // being-dismissed causes UIKit to either drop the present or
    // tear the new modal down with the parent's transition.
    guard
      !topVC.isBeingPresented,
      !topVC.isBeingDismissed,
      topVC.presentedViewController == nil
    else { return }

    let coordinator = ImportCoordinator(
      flow: .modalFlow(presentingController: topVC),
      importManager: self.importManager
    )
    importCoordinator = coordinator
    coordinator.start()
  }

  func bindObservers() {
    playerManager.currentItemPublisher()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] item in
        self?.playerState.loadedBookRelativePath = item?.relativePath
      }
      .store(in: &disposeBag)
  }

  func loadPlayer(_ relativePath: String, autoplay: Bool, showPlayer: Bool) {
    Task { @MainActor in
      let alertPresenter: AlertPresenter = self
      do {
        try await AppServices.shared.coreServices?.playerLoaderService.loadPlayer(
          relativePath,
          autoplay: autoplay
        )
        if showPlayer {
          self.showPlayer()
        }
      } catch BPPlayerError.fileMissing {
        alertPresenter.showAlert(
          "file_missing_title".localized,
          message:
            "\("file_missing_description".localized)\n\(relativePath)",
          completion: nil
        )
      } catch {
        alertPresenter.showAlert(
          "error_title".localized,
          message: error.localizedDescription,
          completion: nil
        )
      }
    }
  }

  func showPlayer() {
    playerState.showPlayer = true
  }
  
  func hasPlayerShown() -> Bool {
    return playerState.isShowingPlayer
  }

  func processFiles(urls: [URL]) {
    let temporaryDirectoryPath = FileManager.default.temporaryDirectory.absoluteString
    let documentsFolder = DataManager.getDocumentsFolderURL()

    for url in urls {
      /// At some point (iOS 17?), the OS stopped sending the picked files to the Documents/Inbox folder, instead
      /// it's now sent to a temp folder that can't be relied on to keep the file existing until the import is finished
      if url.absoluteString.contains(temporaryDirectoryPath) {
        let destinationURL = documentsFolder.appendingPathComponent(url.lastPathComponent)
        if !FileManager.default.fileExists(atPath: destinationURL.path) {
          try! FileManager.default.copyItem(at: url, to: destinationURL)
          destinationURL.disableFileProtection()
        }
      } else {
        importManager.process(url)
      }
    }
  }
}

extension MainCoordinator: PurchasesDelegate {
  nonisolated public func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {
    Task { @MainActor in
      self.accountService.updateAccount(from: customerInfo)
    }
  }
}

extension MainCoordinator: Themeable {
  func applyTheme(_ theme: SimpleTheme) {
    guard
      !UserDefaults.standard.bool(forKey: Constants.UserDefaults.systemThemeVariantEnabled)
    else {
      WindowHelper.activeWindow?.overrideUserInterfaceStyle = .unspecified
      return
    }
    // This fixes native components like alerts having the proper color theme
    WindowHelper.activeWindow?.overrideUserInterfaceStyle =
      theme.useDarkVariant
      ? .dark
      : .light
  }
}

extension MainCoordinator: AlertPresenter {
  func showAlert(_ title: String? = nil, message: String? = nil, completion: (() -> Void)? = nil) {
    mainController?.showAlert(title, message: message, completion: completion)
  }

  func showAlert(_ content: BPAlertContent) {
    mainController?.showAlert(content)
  }

  func showLoader() {
    LoadingUtils.loadAndBlock(in: mainController!)
  }

  func stopLoader() {
    LoadingUtils.stopLoading(in: mainController!)
  }
}
