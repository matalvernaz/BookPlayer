//
//  HummingbirdConnectionViewModel.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-05-18.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Combine
import SwiftUI

/// Hummingbird-local state machine. Was on the shared protocol pre-multi-server
/// merge; develop's reworked protocol switched to `signInFlow` instead. Kept
/// here because Hummingbird's UI still drives off this three-state shape.
enum IntegrationConnectionState {
  case disconnected
  case foundServer
  case connected
}

@MainActor
final class HummingbirdConnectionViewModel: IntegrationConnectionViewModelProtocol, BPLogger {
  let connectionService: HummingbirdConnectionService

  @Published var form: IntegrationConnectionFormViewModel
  @Published var viewMode: IntegrationViewMode = .regular
  @Published var connectionState: IntegrationConnectionState
  @Published var isAddingServer: Bool = false
  /// Required by `IntegrationConnectionViewModelProtocol` post-multi-server merge.
  /// Hummingbird drives its UI from `connectionState`; these are protocol stubs.
  @Published var signInFlow: SignInStep? = nil
  @Published var signInCompletedAt: Date? = nil

  /// Force the connection sheet into the password-entry posture for a saved
  /// server whose session has gone stale. Called by `HummingbirdRootView` before
  /// presenting the form in response to the session-expired alert's "Sign In".
  /// Was a protocol-extension default; moved here when the protocol switched
  /// from `connectionState` to `signInFlow` upstream.
  func prepareForReauth() {
    connectionState = .foundServer
    form.password = ""
  }

  var servers: [IntegrationServerInfo] {
    connectionService.connections.map { data in
      IntegrationServerInfo(
        id: data.id,
        serverName: data.serverName,
        serverUrl: data.url.absoluteString,
        userName: data.userName,
        isActive: data.id == connectionService.connection?.id
      )
    }
  }

  init(
    connectionService: HummingbirdConnectionService,
    mode: IntegrationViewMode = .regular
  ) {
    self.connectionService = connectionService
    self._viewMode = .init(initialValue: mode)
    let form = IntegrationConnectionFormViewModel()

    if let data = connectionService.connection {
      form.setValues(
        url: data.url.absoluteString,
        serverName: data.serverName,
        userName: data.userName,
        customHeaders: data.customHeaders
      )
      self._connectionState = .init(initialValue: .connected)
    } else {
      self._connectionState = .init(initialValue: .disconnected)
    }
    self._form = .init(initialValue: form)
  }

  @MainActor
  func handleConnectAction() async throws {
    let normalizedURL = Self.normalizedServerURL(form.serverUrl)
    if normalizedURL != form.serverUrl {
      form.serverUrl = normalizedURL
    }
    let serverName = try await connectionService.pingServer(
      at: normalizedURL,
      customHeaders: form.customHeadersDictionary()
    )
    connectionState = .foundServer
    form.serverName = serverName
  }

  @MainActor
  func handleSignInAction() async throws {
    let wasAdding = isAddingServer
    // Trim the username (iOS autocorrect appends spaces) but send the password
    // verbatim — SecureFields aren't autocorrected, a legitimate password may
    // begin or end with a space, and Hummingbird replays it on every Basic-auth
    // request, so a trimmed-on-save password would fail forever.
    let username = form.username.trimmingCharacters(in: .whitespacesAndNewlines)
    let password = form.password
    try await connectionService.signIn(
      username: username,
      password: password,
      serverUrl: form.serverUrl,
      serverName: form.serverName,
      customHeaders: form.customHeadersDictionary()
    )

    if wasAdding {
      isAddingServer = false
    }
    if let data = connectionService.connection {
      form.setValues(url: data.url.absoluteString, serverName: data.serverName, userName: data.userName)
    }
    connectionState = .connected
  }

  /// Mirror ABS's URL normalization: prepend https:// if no scheme so URL parsing
  /// produces an absolute URL with a host (else the ping POST fails with an
  /// opaque URLError).
  static func normalizedServerURL(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return trimmed }
    let lowered = trimmed.lowercased()
    if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
      return trimmed
    }
    return "https://" + trimmed
  }

  @MainActor
  func handleSignOutAction() {
    connectionService.deleteConnection()
    form = IntegrationConnectionFormViewModel()
    connectionState = connectionService.connections.isEmpty ? .disconnected : .connected
    if let data = connectionService.connection {
      form.setValues(url: data.url.absoluteString, serverName: data.serverName, userName: data.userName)
    }
  }

  func handleSignOutAction(id: String) {
    connectionService.deleteConnection(id: id)
    if connectionService.connections.isEmpty {
      form = IntegrationConnectionFormViewModel()
      connectionState = .disconnected
    } else if let data = connectionService.connection {
      form.setValues(url: data.url.absoluteString, serverName: data.serverName, userName: data.userName)
    }
  }

  func handleActivateAction(id: String) {
    connectionService.activateConnection(id: id)
    if let data = connectionService.connection {
      form.setValues(url: data.url.absoluteString, serverName: data.serverName, userName: data.userName)
    }
  }

  func handleAddServerAction() {
    isAddingServer = true
    form = IntegrationConnectionFormViewModel()
  }

  func handleCancelAddServerAction() {
    isAddingServer = false
    if let data = connectionService.connection {
      form.setValues(url: data.url.absoluteString, serverName: data.serverName, userName: data.userName)
    }
    connectionState = .connected
  }

  @MainActor
  func handleCustomHeadersUpdate() {
    connectionService.updateCustomHeaders(form.customHeadersDictionary())
  }
}
