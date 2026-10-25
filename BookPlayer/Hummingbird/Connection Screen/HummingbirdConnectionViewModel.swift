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

/// The Hummingbird sign-in flow and connection details (fork), on the shared integration screens.
/// Password sign-in only: Hummingbird has no SSO or code flow, so Connect goes straight to the
/// password step.
@MainActor
final class HummingbirdConnectionViewModel: IntegrationConnectionViewModelProtocol, BPLogger {
  let connectionService: HummingbirdConnectionService

  @Published var form: IntegrationConnectionFormViewModel
  @Published var viewMode: IntegrationViewMode = .regular
  @Published var signInFlow: SignInStep?
  @Published private(set) var signInCompletedAt: Date?
  @Published var isAddingServer: Bool = false
  @Published var flowPath: [ConnectionFlowStep] = []

  /// The connection a re-authentication started from, so signing in to the same account at an
  /// edited URL updates that row instead of leaving an orphan
  private var reauthConnectionID: String?

  /// When set, the view model works on this saved connection (its details, its sign-out) whichever
  /// connection is active: `MediaServersView`'s per-server details sheet
  let targetConnectionId: String?

  /// The URL Connect validated with a ping. Sign In sends the credentials there, never to whatever
  /// the form says by then, so an edit in between can't send them to a server nobody checked
  private var pingedURL: String?

  var servers: [IntegrationServerInfo] {
    connectionService.connections.map { data in
      IntegrationServerInfo(
        id: data.id,
        serverName: data.serverName,
        serverUrl: data.url.absoluteString,
        userName: data.userName
      )
    }
  }

  init(
    connectionService: HummingbirdConnectionService,
    mode: IntegrationViewMode = .regular,
    connectionId: String? = nil
  ) {
    self.connectionService = connectionService
    self.targetConnectionId = connectionId
    self._viewMode = .init(initialValue: mode)
    let form = IntegrationConnectionFormViewModel()

    switch mode {
    case .addServer:
      self._signInFlow = .init(initialValue: .enteringServerURL)
      self._isAddingServer = .init(initialValue: true)
    case .regular, .viewDetails:
      let data = connectionId.flatMap { id in
        connectionService.connections.first(where: { $0.id == id })
      } ?? connectionService.connection

      if let data {
        form.setValues(
          url: data.url.absoluteString,
          serverName: data.serverName,
          userName: data.userName,
          customHeaders: data.customHeaders
        )
        self._signInFlow = .init(initialValue: nil)
      } else {
        self._signInFlow = .init(initialValue: .enteringServerURL)
      }
    }

    self._form = .init(initialValue: form)
  }

  func handleConnectAction() async throws {
    let normalizedURL = Self.normalizedServerURL(form.serverUrl)
    if normalizedURL != form.serverUrl {
      form.serverUrl = normalizedURL
    }
    let serverName = try await connectionService.pingServer(
      at: normalizedURL,
      customHeaders: form.customHeadersDictionary()
    )
    pingedURL = normalizedURL
    signInFlow = .enteringCredentials
    flowPath = [stepAfterConnect]
    form.serverName = serverName
  }

  func handleSignInAction() async throws {
    guard let serverUrl = pingedURL else {
      throw IntegrationError.urlMalformed(nil)
    }

    // The username is trimmed (autocorrect adds a trailing space), the password is sent as typed: a
    // password can start or end with a space, and Hummingbird replays it as Basic auth on every
    // request, so a trimmed one would fail every time after this
    let username = form.username.trimmingCharacters(in: .whitespacesAndNewlines)
    try await connectionService.signIn(
      username: username,
      password: form.password,
      serverUrl: serverUrl,
      serverName: form.serverName,
      customHeaders: form.customHeadersDictionary(),
      replacingID: reauthConnectionID
    )

    // Kept through a failed attempt, so retrying a wrong password still goes to the checked URL
    pingedURL = nil
    isAddingServer = false
    if let data = connectionService.connection {
      form.setValues(
        url: data.url.absoluteString,
        serverName: data.serverName,
        userName: data.userName,
        customHeaders: data.customHeaders
      )
    }
    signInFlow = nil
    flowPath = []
    signInCompletedAt = Date()
  }

  func prepareReauth() {
    let data = targetConnectionId.flatMap { id in
      connectionService.connections.first(where: { $0.id == id })
    } ?? connectionService.connection

    if let data {
      reauthConnectionID = data.id
      form.setValues(
        url: data.url.absoluteString,
        serverName: data.serverName,
        userName: data.userName,
        customHeaders: data.customHeaders
      )
    }
    pingedURL = nil
    signInFlow = .enteringServerURL
    flowPath = []
  }

  /// The typed address trimmed, with `https://` added when it has no scheme, so it parses as an
  /// absolute URL with a host
  static func normalizedServerURL(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return trimmed }
    let lowered = trimmed.lowercased()
    if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
      return trimmed
    }
    return "https://" + trimmed
  }

  func handleSignOutAction() {
    if let targetId = targetConnectionId {
      connectionService.deleteConnection(id: targetId)
    } else {
      connectionService.deleteConnection()
    }
    form = IntegrationConnectionFormViewModel()
    // The details screen that signed out closes; reconnecting goes through Add Server
    signInFlow = nil
    flowPath = []
    if let data = connectionService.connection {
      form.setValues(
        url: data.url.absoluteString,
        serverName: data.serverName,
        userName: data.userName,
        customHeaders: data.customHeaders
      )
    }
  }

  func handleSignOutAction(id: String) {
    connectionService.deleteConnection(id: id)
    if connectionService.connections.isEmpty {
      form = IntegrationConnectionFormViewModel()
      signInFlow = nil
      flowPath = []
    } else if let data = connectionService.connection {
      form.setValues(
        url: data.url.absoluteString,
        serverName: data.serverName,
        userName: data.userName,
        customHeaders: data.customHeaders
      )
    }
  }

  func handleActivateAction(id: String) {
    connectionService.activateConnection(id: id)
    if let data = connectionService.connection {
      form.setValues(
        url: data.url.absoluteString,
        serverName: data.serverName,
        userName: data.userName,
        customHeaders: data.customHeaders
      )
    }
  }

  func handleAddServerAction() {
    isAddingServer = true
    signInFlow = .enteringServerURL
    flowPath = []
    form = IntegrationConnectionFormViewModel()
  }

  func handleCancelAddServerAction() {
    isAddingServer = false
    signInFlow = nil
    flowPath = []
    pingedURL = nil
    if let data = connectionService.connection {
      form.setValues(
        url: data.url.absoluteString,
        serverName: data.serverName,
        userName: data.userName,
        customHeaders: data.customHeaders
      )
    }
  }
}
