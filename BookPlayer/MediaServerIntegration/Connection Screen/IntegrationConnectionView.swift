//
//  IntegrationConnectionView.swift
//  BookPlayer
//
//  Created by Gianni Carlo on 4/5/26.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import SwiftUI

struct IntegrationConnectionView<VM: IntegrationConnectionViewModelProtocol>: View {
  @ObservedObject var viewModel: VM

  let integrationName: String

  @State private var isLoading = false
  @State private var error: Error?

  /// Tracks the in-flight network task for connect/sign-in/Quick-Connect-start so the view
  /// can cancel it on dismissal. Without this, swiping the sheet down while a sign-in is
  /// still in flight would let the view model persist a connection the user thought they
  /// gave up on.
  @State private var actionTask: Task<Void, Never>?

  @EnvironmentObject var theme: ThemeViewModel

  /// Whether the Quick Connect sheet is currently being presented. Derived from the view
  /// model's `quickConnectStatus`: a non-nil status means there is something for the sheet
  /// to render (poll progress, code, success transition, or terminal failure).
  private var isQuickConnectSheetPresented: Binding<Bool> {
    Binding(
      get: { viewModel.quickConnectStatus != nil },
      set: { newValue in
        // The user dismissed the sheet by gesture/swipe — clean up the in-flight flow.
        if !newValue {
          viewModel.handleCancelQuickConnect()
        }
      }
    )
  }

  var body: some View {
    Form {
      if viewModel.isAddingServer {
        // Adding a new server from settings — show the connection flow
        switch viewModel.connectionState {
        case .disconnected, .connected:
          IntegrationDisconnectedView(
            serverUrl: $viewModel.form.serverUrl,
            placeholderURL: integrationName == "Jellyfin"
              ? "http://jellyfin.example.com:8096"
              : "http://audiobookshelf.example.com",
            integrationName: integrationName,
            onCommit: onConnect
          )
          IntegrationCustomHeadersSectionView(
            customHeaders: $viewModel.form.customHeaders
          )
        case .foundServer:
          IntegrationServerInformationSectionView(
            serverName: viewModel.form.serverName,
            serverUrl: viewModel.form.serverUrl
          )
          IntegrationServerFoundView(
            username: $viewModel.form.username,
            password: $viewModel.form.password,
            onCommit: onSignIn
          )
          if viewModel.quickConnectSupported {
            IntegrationQuickConnectSectionView(onStart: onStartQuickConnect)
          }
          IntegrationCustomHeadersSectionView(
            customHeaders: $viewModel.form.customHeaders
          )
        }
      } else {
        switch viewModel.connectionState {
        case .disconnected:
          IntegrationDisconnectedView(
            serverUrl: $viewModel.form.serverUrl,
            placeholderURL: integrationName == "Jellyfin"
              ? "http://jellyfin.example.com:8096"
              : "http://audiobookshelf.example.com",
            integrationName: integrationName,
            onCommit: onConnect
          )
          IntegrationCustomHeadersSectionView(
            customHeaders: $viewModel.form.customHeaders
          )
        case .foundServer:
          IntegrationServerInformationSectionView(
            serverName: viewModel.form.serverName,
            serverUrl: viewModel.form.serverUrl
          )
          IntegrationServerFoundView(
            username: $viewModel.form.username,
            password: $viewModel.form.password,
            onCommit: onSignIn
          )
          if viewModel.quickConnectSupported {
            IntegrationQuickConnectSectionView(onStart: onStartQuickConnect)
          }
          IntegrationCustomHeadersSectionView(
            customHeaders: $viewModel.form.customHeaders
          )
        case .connected:
          IntegrationServerInformationSectionView(
            serverName: viewModel.form.serverName,
            serverUrl: viewModel.form.serverUrl
          )
          IntegrationCustomHeadersSectionView(
            customHeaders: $viewModel.form.customHeaders,
            onCommit: { viewModel.handleCustomHeadersUpdate() }
          )
          IntegrationConnectedView(viewModel: viewModel)
        }
      }
    }
    .scrollContentBackground(.hidden)
    .background(theme.systemBackgroundColor)
    .errorAlert(error: $error)
    .sheet(isPresented: isQuickConnectSheetPresented) {
      // The sheet is bound to the view model's status. When the flow finishes successfully
      // the view model nils out the status and the sheet auto-dismisses; when it fails the
      // sheet shows the error message until the user taps OK.
      IntegrationQuickConnectSheetView(
        status: viewModel.quickConnectStatus ?? .retrievingCode,
        serverUrl: viewModel.form.serverUrl,
        onCancel: { viewModel.handleCancelQuickConnect() }
      )
      .environmentObject(theme)
    }
    .overlay {
      Group {
        if isLoading {
          ProgressView()
            .tint(.white)
            .padding()
            .background(
              Color.black
                .opacity(0.9)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            )
            .ignoresSafeArea(.all)
        }
      }
    }
    .toolbar {
      if viewModel.isAddingServer {
        ToolbarItem(placement: .cancellationAction) {
          Button("cancel_button".localized) {
            viewModel.handleCancelAddServerAction()
          }
          .foregroundStyle(theme.linkColor)
        }
        ToolbarItemGroup(placement: .confirmationAction) {
          if viewModel.connectionState == .foundServer {
            signInToolbarButton
          } else {
            connectToolbarButton
          }
        }
      } else {
        ToolbarItem(placement: .principal) {
          Text(localizedNavigationTitle)
            .bpFont(.headline)
            .foregroundStyle(theme.primaryColor)
        }
        ToolbarItemGroup(placement: .confirmationAction) {
          switch viewModel.connectionState {
          case .disconnected:
            connectToolbarButton
          case .foundServer:
            signInToolbarButton
          case .connected:
            EmptyView()
          }
        }
      }
    }
    .tint(theme.linkColor)
    .onDisappear {
      actionTask?.cancel()
      actionTask = nil
    }
  }

  // MARK: Utils

  func onConnect() {
    actionTask?.cancel()
    isLoading = true
    actionTask = Task { @MainActor in
      defer { isLoading = false }
      do {
        try await viewModel.handleConnectAction()
        try Task.checkCancellation()
      } catch is CancellationError {
        // Sheet dismissed mid-flight; nothing to surface.
      } catch {
        self.error = error
      }
    }
  }

  func onSignIn() {
    actionTask?.cancel()
    isLoading = true
    actionTask = Task { @MainActor in
      defer { isLoading = false }
      do {
        try await viewModel.handleSignInAction()
        try Task.checkCancellation()
      } catch is CancellationError {
        return
      } catch {
        self.error = error
      }
    }
  }

  /// Starts the Quick Connect flow. Failures during the flow itself are surfaced inside the
  /// sheet via the view model's `quickConnectStatus = .failed(...)`; this handler only needs
  /// to catch the synchronous setup error (no api-client / network unreachable on initiate).
  func onStartQuickConnect() {
    actionTask?.cancel()
    actionTask = Task { @MainActor in
      do {
        try await viewModel.handleStartQuickConnect()
      } catch is CancellationError {
        return
      } catch {
        self.error = error
      }
    }
  }

  // MARK: - Navigation Title

  private var localizedNavigationTitle: String {
    switch viewModel.connectionState {
    case .disconnected, .foundServer: integrationName
    case .connected: "integration_connection_details_title".localized
    }
  }

  // MARK: - Navigation Buttons

  @ViewBuilder
  private var connectToolbarButton: some View {
    Button(
      "integration_connect_button",
      action: onConnect
    )
    .foregroundStyle(theme.linkColor)
    .disabledWithOpacity(viewModel.form.serverUrl.isEmpty)
  }

  @ViewBuilder
  private var signInToolbarButton: some View {
    Button(
      "integration_sign_in_button",
      action: onSignIn
    )
    .foregroundStyle(theme.linkColor)
    .disabledWithOpacity(
      viewModel.form.serverUrl.isEmpty || viewModel.form.username.isEmpty
    )
  }
}
