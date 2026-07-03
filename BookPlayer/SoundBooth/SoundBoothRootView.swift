//
//  SoundBoothRootView.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import SwiftUI

/// Top-level container for the SoundBooth integration: shows the email-code sign-in sheet when
/// no account is connected, otherwise the owned-library browser. Mirrors `HummingbirdRootView`.
struct SoundBoothRootView: View {
  let connectionService: SoundBoothConnectionService

  @StateObject private var connectionViewModel: SoundBoothConnectionViewModel
  @StateObject private var libraryViewModel: SoundBoothLibraryViewModel

  @EnvironmentObject private var theme: ThemeViewModel
  @Environment(\.dismiss) private var dismiss

  @State private var showConnectionForm = false

  init(
    connectionService: SoundBoothConnectionService,
    singleFileDownloadService: SingleFileDownloadService
  ) {
    self.connectionService = connectionService
    self._connectionViewModel = .init(
      wrappedValue: .init(connectionService: connectionService)
    )
    self._libraryViewModel = .init(
      wrappedValue: SoundBoothLibraryViewModel(
        connectionService: connectionService,
        singleFileDownloadService: singleFileDownloadService
      )
    )
  }

  var body: some View {
    NavigationStack {
      SoundBoothLibraryView(viewModel: libraryViewModel)
        .navigationTitle(connectionService.connection?.serverName ?? "SoundBooth")
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
          if connectionService.connection != nil {
            ToolbarItemGroup(placement: .topBarTrailing) {
              Button {
                Task { await libraryViewModel.loadLibrary() }
              } label: {
                Image(systemName: "arrow.clockwise")
                  .foregroundStyle(theme.linkColor)
              }
              .accessibilityLabel("Refresh library")

              Menu {
                Button(role: .destructive) {
                  connectionService.deleteConnection()
                  showConnectionForm = true
                } label: {
                  Label("integration_sign_out_button".localized, systemImage: "rectangle.portrait.and.arrow.right")
                }
              } label: {
                Image(systemName: "gearshape")
                  .foregroundStyle(theme.linkColor)
              }
              .accessibilityLabel("settings_title".localized)
            }
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
        SoundBoothConnectionView(viewModel: connectionViewModel)
          .toolbar {
            ToolbarItemGroup(placement: .cancellationAction) {
              Button {
                showConnectionForm = false
              } label: {
                Image(systemName: "xmark")
                  .foregroundStyle(theme.linkColor)
              }
            }
          }
      }
      .tint(theme.linkColor)
      .environmentObject(theme)
    }
    .onChange(of: connectionViewModel.signInCompletedAt) { _, newValue in
      if newValue != nil {
        showConnectionForm = false
        Task { await libraryViewModel.loadLibrary() }
      }
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
