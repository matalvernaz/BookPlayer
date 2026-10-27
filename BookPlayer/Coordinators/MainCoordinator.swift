//
//  MainCoordinator.swift
//  BookPlayer
//
//  Created by Gianni Carlo on 5/9/21.
//  Copyright © 2021 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Combine
import Observation
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
  /// Hummingbird (fork)
  let hummingbirdConnectionService: HummingbirdConnectionService
  /// SoundBooth (fork)
  let soundboothConnectionService: SoundBoothConnectionService
  let syncQueueService: SyncQueueService
  let hardcoverService: HardcoverService
  let preferencesService: PreferencesSyncService
  /// Which library items came from a media server (fork); owned by `AppServices`
  let mediaServerSourceStore: MediaServerSourceStore
  /// Lands a download's provenance once its file is saved
  private let mediaServerSourceTracker: MediaServerSourceTracker
  /// Binds bind-flagged folder downloads into books
  private let boundBookCompleter: MediaServerBoundBookCompleter
  /// Returns a Hummingbird book when the user deletes it (fork)
  private let hummingbirdLoanReturns: HummingbirdLoanReturns
  /// Returns and deletes Hummingbird books whose loan ran out (fork)
  private let hummingbirdLoanExpiryScanner: HummingbirdLoanExpiryScanner
  /// Sends Hummingbird books' positions back to their servers (fork)
  private let hummingbirdProgressReporter: HummingbirdProgressReporter
  /// Starts unplayed Hummingbird books at their server bookmark (fork)
  private let hummingbirdBookmarkPuller: HummingbirdBookmarkPuller

  var playerState: PlayerState { AppServices.shared.playerState }

  /// Reference to know if the import screen is already being shown (or in the process of showing)
  weak var importCoordinator: ImportCoordinator?
  let navigationController: UINavigationController

  private var disposeBag = Set<AnyCancellable>()

  init(
    navigationController: UINavigationController,
    coreServices: CoreServices
  ) {
    self.navigationController = navigationController
    self.libraryService = coreServices.libraryService
    let sourceStore = AppServices.shared.mediaServerSourceStore
    self.mediaServerSourceStore = sourceStore
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
      preferencesService: coreServices.preferencesService,
      chapterRefreshService: coreServices.mediaServerChapterService
    )
    self.syncQueueService = coreServices.syncQueueService
    self.singleFileDownloadService = SingleFileDownloadService(networkClient: NetworkClient())
    self.watchConnectivityService = coreServices.watchService
    let jellyfinService = JellyfinConnectionService()
    jellyfinService.setup()
    jellyfinService.mediaServerSourceStore = sourceStore
    self.jellyfinConnectionService = jellyfinService

    let audiobookshelfService = AudiobookShelfConnectionService()
    audiobookshelfService.setup()
    audiobookshelfService.mediaServerSourceStore = sourceStore
    self.audiobookshelfConnectionService = audiobookshelfService

    let hummingbirdService = HummingbirdConnectionService()
    hummingbirdService.setup()
    self.hummingbirdConnectionService = hummingbirdService
    self.hummingbirdLoanReturns = HummingbirdLoanReturns(connectionService: hummingbirdService)
    self.hummingbirdLoanExpiryScanner = HummingbirdLoanExpiryScanner(
      connectionService: hummingbirdService,
      sourceStore: sourceStore,
      libraryService: coreServices.libraryService,
      playerManager: coreServices.playerManager,
      syncService: coreServices.syncService
    )
    self.hummingbirdProgressReporter = HummingbirdProgressReporter(
      playerManager: coreServices.playerManager,
      sourceStore: sourceStore
    ) { [hummingbirdService] bookmark, bookId, connectionId in
      try await hummingbirdService.reportBookmark(bookmark, bookId: bookId, connectionId: connectionId)
    }
    self.hummingbirdBookmarkPuller = HummingbirdBookmarkPuller(
      sourceStore: sourceStore,
      libraryService: coreServices.libraryService,
      isLoadedInPlayer: { [playerManager = coreServices.playerManager] relativePath in
        playerManager.currentItem?.relativePath == relativePath
      }
    ) { [hummingbirdService] bookId, connectionId in
      try await hummingbirdService.fetchBookmark(bookId: bookId, connectionId: connectionId)
    }

    let soundboothService = SoundBoothConnectionService()
    soundboothService.setup()
    self.soundboothConnectionService = soundboothService

    self.mediaServerSourceTracker = MediaServerSourceTracker(
      store: sourceStore,
      downloadService: singleFileDownloadService
    )
    self.boundBookCompleter = MediaServerBoundBookCompleter(
      sourceStore: sourceStore,
      libraryService: coreServices.libraryService,
      downloadService: singleFileDownloadService
    )

    self.hardcoverService = coreServices.hardcoverService
    self.preferencesService = coreServices.preferencesService

    ThemeManager.shared.libraryService = libraryService

    super.init()

    setUpTheming()
  }

  /// Points Audiobookshelf and Jellyfin downloads' provenance at their servers' current identities,
  /// which upstream's progress push resolves the connection by (fork): an edited address, or a server
  /// that has started reporting its id, is picked up
  private func refreshProvenanceHosts() {
    func hostIds<C: IntegrationHostIdentifiable & Identifiable>(_ connections: [C]) -> [String: String] where C.ID == String {
      Dictionary(connections.map { ($0.id, $0.stableHostId) }, uniquingKeysWith: { first, _ in first })
    }
    mediaServerSourceStore.refreshHostIds([
      .audiobookshelf: hostIds(audiobookshelfConnectionService.connections),
      .jellyfin: hostIds(jellyfinConnectionService.connections),
    ])
  }

  /// Refreshes the hosts whenever either service's connections change. Observation reports a change
  /// before it lands, so the refresh runs right after it, on the next main-actor turn, and observes again
  private func observeConnectionsForProvenanceHosts() {
    withObservationTracking {
      _ = audiobookshelfConnectionService.connections
      _ = jellyfinConnectionService.connections
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.refreshProvenanceHosts()
        self?.observeConnectionsForProvenanceHosts()
      }
    }
  }

  func start() {
    if var currentTheme = libraryService.getLibraryCurrentTheme() {
      currentTheme.useDarkVariant = ThemeManager.shared.useDarkVariant
      ThemeManager.shared.currentTheme = currentTheme
    }

    bindObservers()

    accountService.loginIfUserExists(delegate: self)

    // Loans that ran out while the app was closed; coming back to the foreground scans again
    Task { await hummingbirdLoanExpiryScanner.scan() }
    // Bookmarks saved elsewhere for Hummingbird books not played here yet
    hummingbirdBookmarkPuller.startPull()
    // Downloads' server identities, for the progress push, now and whenever the connections change
    refreshProvenanceHosts()
    observeConnectionsForProvenanceHosts()

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
      .environment(\.syncQueueService, syncQueueService)
      .environment(\.uploadContinuation, AppServices.shared.uploadContinuation)
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

  func showImport() {
    guard
      importManager.hasPendingFiles(),
      importCoordinator == nil,
      let topVC = WindowHelper.activeWindow?.rootViewController?.getTopVisibleViewController()
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
