//
//  SoundBoothRootView.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import SwiftUI

/// The SoundBooth library (fork): the active account's library, or the sign-in when there's no account
/// or its session expired. Takes what the screen needs from the environment, as the other
/// integrations' roots do.
struct SoundBoothRootView: View {
  let connectionService: SoundBoothConnectionService

  @EnvironmentObject private var singleFileDownloadService: SingleFileDownloadService
  @Environment(\.mediaServerSourceStore) private var mediaServerSourceStore

  var body: some View {
    SoundBoothLibraryRoot(
      connectionService: connectionService,
      singleFileDownloadService: singleFileDownloadService,
      sourceStore: mediaServerSourceStore
    )
  }
}

/// The screen itself, owning its view models: built once, from the root's environment
private struct SoundBoothLibraryRoot: View {
  let connectionService: SoundBoothConnectionService

  @StateObject private var connectionViewModel: SoundBoothConnectionViewModel
  @StateObject private var libraryViewModel: SoundBoothLibraryViewModel

  @EnvironmentObject private var theme: ThemeViewModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.closeMediaServers) private var closeMediaServers

  @State private var showConnectionForm = false
  @State private var showAccountDetails = false
  @State private var path = NavigationPath()

  init(
    connectionService: SoundBoothConnectionService,
    singleFileDownloadService: SingleFileDownloadService,
    sourceStore: MediaServerSourceStore
  ) {
    self.connectionService = connectionService
    self._connectionViewModel = .init(wrappedValue: .init(connectionService: connectionService))
    self._libraryViewModel = .init(
      wrappedValue: SoundBoothLibraryViewModel(
        connectionService: connectionService,
        singleFileDownloadService: singleFileDownloadService,
        sourceStore: sourceStore
      )
    )
  }

  var body: some View {
    NavigationStack(path: $path) {
      SoundBoothLibraryView(viewModel: libraryViewModel)
        .navigationTitle(connectionService.connection?.serverName ?? "SoundBooth")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Menu {
              Button {
                showAccountDetails = true
              } label: {
                Label("integration_connection_details_title".localized, systemImage: "person.crop.circle")
              }
              // Pull to refresh is hard to reach with VoiceOver; this is the same reload
              Button {
                Task { await libraryViewModel.loadLibrary() }
              } label: {
                Label("soundbooth_refresh_button".localized, systemImage: "arrow.clockwise")
              }
              Button {
                closeMediaServers()
              } label: {
                Label("voiceover_close_button".localized, systemImage: "xmark")
              }
            } label: {
              Image(systemName: "gearshape")
                .foregroundStyle(theme.linkColor)
            }
            .accessibilityLabel("settings_title".localized)
          }
        }
        .navigationDestination(for: SoundBoothNode.self) { node in
          SoundBoothLibraryView(viewModel: libraryViewModel, node: node)
            .navigationTitle(node.title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    .tint(theme.linkColor)
    .alert(
      "error_title".localized,
      isPresented: .init(
        get: { libraryViewModel.sessionExpiredError != nil },
        set: { if !$0 { libraryViewModel.sessionExpiredError = nil } }
      ),
      actions: {
        // Signs in again with the saved email filled in, keeping the account's connection
        Button("integration_sign_in_button".localized) {
          libraryViewModel.sessionExpiredError = nil
          connectionViewModel.prepareReauth()
          showConnectionForm = true
        }
        Button("cancel_button".localized, role: .cancel) {
          libraryViewModel.sessionExpiredError = nil
          dismiss()
        }
      },
      message: { Text(libraryViewModel.sessionExpiredError?.localizedDescription ?? "") }
    )
    // Once, here: every level of the stack shares the view model, so a per-level alert would show on
    // all of them at once
    .alert(
      "error_title".localized,
      isPresented: .init(
        get: { libraryViewModel.downloadError != nil },
        set: { if !$0 { libraryViewModel.downloadError = nil } }
      ),
      actions: { Button("ok_button".localized) { libraryViewModel.downloadError = nil } },
      message: { Text(libraryViewModel.downloadError ?? "") }
    )
    .sheet(isPresented: $showConnectionForm) {
      NavigationStack {
        SoundBoothConnectionView(viewModel: connectionViewModel)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button {
                showConnectionForm = false
              } label: {
                Image(systemName: "xmark")
                  .foregroundStyle(theme.linkColor)
              }
              .accessibilityLabel("voiceover_close_button".localized)
            }
          }
      }
      .tint(theme.linkColor)
      .environmentObject(theme)
    }
    .sheet(isPresented: $showAccountDetails) {
      NavigationStack {
        if let connectionId = connectionService.connection?.id {
          SoundBoothAccountDetailsView(connectionService: connectionService, connectionId: connectionId) {
            showAccountDetails = false
          }
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("done_title".localized) {
                showAccountDetails = false
              }
            }
          }
        }
      }
      .tint(theme.linkColor)
      .environmentObject(theme)
    }
    .environmentObject(theme)
    .onChange(of: connectionService.connection?.id) { oldValue, newValue in
      if newValue == nil {
        // Signed out: nothing left here to browse
        dismiss()
      } else if oldValue != nil {
        // Another account is active now (the one on screen was logged out): its library, from the top
        path = NavigationPath()
        Task { await libraryViewModel.loadLibrary() }
      }
    }
    .onChange(of: connectionViewModel.signInCompletedAt) { _, newValue in
      guard newValue != nil else { return }
      showConnectionForm = false
      Task { await libraryViewModel.loadLibrary() }
    }
    .task {
      if connectionService.connections.isEmpty {
        showConnectionForm = true
      } else {
        await libraryViewModel.loadLibrary()
      }
    }
  }
}
