//
//  HummingbirdRootView.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-05-18.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import SwiftUI

/// The Hummingbird library (fork): the bookshelf of the active connection, or the sign-in flow when
/// there's no connection or its session expired. Takes what the screen needs from the environment,
/// as the other integrations' roots do, and hands it to the screen's view models.
struct HummingbirdRootView: View {
  let connectionService: HummingbirdConnectionService

  @EnvironmentObject private var singleFileDownloadService: SingleFileDownloadService
  @Environment(\.mediaServerSourceStore) private var mediaServerSourceStore

  var body: some View {
    HummingbirdLibraryRoot(
      connectionService: connectionService,
      singleFileDownloadService: singleFileDownloadService,
      sourceStore: mediaServerSourceStore
    )
  }
}

/// The screen itself, owning its view models: built once, from the root's environment
private struct HummingbirdLibraryRoot: View {
  let connectionService: HummingbirdConnectionService

  @StateObject private var connectionViewModel: HummingbirdConnectionViewModel
  @StateObject private var libraryViewModel: HummingbirdLibraryViewModel

  @EnvironmentObject private var theme: ThemeViewModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.closeMediaServers) private var closeMediaServers

  @State private var showConnectionForm = false
  @State private var showConnectionDetails = false

  init(
    connectionService: HummingbirdConnectionService,
    singleFileDownloadService: SingleFileDownloadService,
    sourceStore: MediaServerSourceStore
  ) {
    self.connectionService = connectionService
    self._connectionViewModel = .init(
      wrappedValue: .init(connectionService: connectionService)
    )
    self._libraryViewModel = .init(
      wrappedValue: HummingbirdLibraryViewModel(
        connectionService: connectionService,
        singleFileDownloadService: singleFileDownloadService,
        sourceStore: sourceStore
      )
    )
  }

  var body: some View {
    NavigationStack {
      HummingbirdLibraryView(viewModel: libraryViewModel)
        .navigationTitle(connectionService.connection?.serverName ?? "Hummingbird")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Menu {
              Button {
                showConnectionDetails = true
              } label: {
                Label("integration_connection_details_title".localized, systemImage: "server.rack")
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
    }
    .tint(theme.linkColor)
    .alert(
      "error_title".localized,
      isPresented: .init(
        get: { libraryViewModel.sessionExpiredError != nil },
        set: { if !$0 { libraryViewModel.sessionExpiredError = nil } }
      ),
      actions: {
        // To the address step with the saved connection filled in: the details screen has no way to
        // sign in again
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
    .sheet(isPresented: $showConnectionForm) {
      // The flow has its own NavigationStack and cancel buttons
      IntegrationConnectionFlowView(viewModel: connectionViewModel, kind: .hummingbird, integrationName: "Hummingbird")
        .environmentObject(theme)
    }
    .sheet(isPresented: $showConnectionDetails) {
      NavigationStack {
        IntegrationSettingsView(integrationName: "Hummingbird") {
          HummingbirdConnectionViewModel(
            connectionService: connectionService,
            mode: .viewDetails
          )
        }
        .toolbar {
          if connectionService.connection == nil {
            ToolbarItemGroup(placement: .cancellationAction) {
              Button {
                dismiss()
              } label: {
                Image(systemName: "xmark")
                  .foregroundStyle(theme.linkColor)
              }
              .accessibilityLabel("voiceover_close_button".localized)
            }
          } else {
            ToolbarItemGroup(placement: .confirmationAction) {
              Button("done_title".localized) {
                showConnectionDetails = false
              }
            }
          }
        }
      }
      .tint(theme.linkColor)
      .environmentObject(theme)
    }
    .environmentObject(theme)
    .onChange(of: connectionService.connection?.id) { _, newValue in
      // Signed out from the details screen: nothing left here to browse
      if newValue == nil { dismiss() }
    }
    .onChange(of: connectionViewModel.signInCompletedAt) { _, newValue in
      guard newValue != nil else { return }
      showConnectionForm = false
      Task { await libraryViewModel.loadBookshelf() }
    }
    .task {
      if connectionService.connections.isEmpty {
        showConnectionForm = true
      } else {
        await libraryViewModel.loadBookshelf()
      }
    }
  }
}
