//
//  HummingbirdRootView.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-05-18.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import SwiftUI

/// Top-level container for the Hummingbird integration. Drives a connection-form
/// sheet when no server is configured, otherwise renders the bookshelf browser.
struct HummingbirdRootView: View {
  let connectionService: HummingbirdConnectionService
  var skipServerPicker: Bool = false

  @StateObject private var connectionViewModel: HummingbirdConnectionViewModel
  @StateObject private var libraryViewModel: HummingbirdLibraryViewModel

  @EnvironmentObject private var singleFileDownloadService: SingleFileDownloadService
  @EnvironmentObject private var theme: ThemeViewModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.listState) private var listState

  @State private var showConnectionForm = false
  @State private var showServerPicker = false
  @State private var showConnectionDetails = false

  init(
    connectionService: HummingbirdConnectionService,
    singleFileDownloadService: SingleFileDownloadService,
    skipServerPicker: Bool = false
  ) {
    self.connectionService = connectionService
    self.skipServerPicker = skipServerPicker
    self._connectionViewModel = .init(
      wrappedValue: .init(connectionService: connectionService)
    )
    self._libraryViewModel = .init(
      wrappedValue: HummingbirdLibraryViewModel(
        connectionService: connectionService,
        singleFileDownloadService: singleFileDownloadService
      )
    )
  }

  var body: some View {
    NavigationStack {
      HummingbirdLibraryView(viewModel: libraryViewModel)
        .navigationTitle(connectionService.connection?.serverName ?? "Hummingbird")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItemGroup(placement: .cancellationAction) {
            Button {
              dismiss()
            } label: {
              HStack(spacing: 4) {
                Image(systemName: "chevron.backward")
                Text("media_servers_title".localized)
              }
              .foregroundStyle(theme.linkColor)
            }
            .accessibilityLabel("media_servers_title".localized)
          }
          ToolbarItem(placement: .topBarTrailing) {
            Menu {
              Button {
                showConnectionDetails = true
              } label: {
                Label("integration_connection_details_title".localized, systemImage: "server.rack")
              }
            } label: {
              Image(systemName: "gearshape")
                .foregroundStyle(theme.linkColor)
            }
            .accessibilityLabel("settings_title")
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
        Button("integration_sign_in_button".localized) {
          libraryViewModel.sessionExpiredError = nil
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
      NavigationStack {
        IntegrationConnectionView(viewModel: connectionViewModel, integrationName: "Hummingbird")
          .toolbar {
            ToolbarItemGroup(placement: .cancellationAction) {
              Button { showConnectionForm = false } label: {
                Image(systemName: "xmark")
                  .foregroundStyle(theme.linkColor)
              }
            }
          }
          .navigationBarTitleDisplayMode(.inline)
      }
      .tint(theme.linkColor)
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
    .onChange(of: connectionViewModel.connectionState) { _, newValue in
      if newValue == .connected {
        showConnectionForm = false
        Task { await libraryViewModel.loadBookshelf() }
      }
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
