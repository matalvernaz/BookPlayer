//
//  JellyfinConnectionViewModel.swift
//  BookPlayer
//
//  Created by Lysann Tranvouez on 2024-10-25.
//  Copyright © 2024 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Combine
import Get
import JellyfinAPI
import SwiftUI

@MainActor
final class JellyfinConnectionViewModel: IntegrationConnectionViewModelProtocol, BPLogger {
  let connectionService: JellyfinConnectionService

  @Published var form: IntegrationConnectionFormViewModel
  @Published var viewMode: IntegrationViewMode = .regular
  @Published var connectionState: IntegrationConnectionState
  @Published var isAddingServer: Bool = false

  /// Current state of an in-flight Quick Connect flow, or `nil` if none is running.
  /// Mirrored to the shared `IntegrationConnectionView` via the protocol so it can render
  /// the awaiting-code overlay and react to failure/success.
  @Published var quickConnectStatus: QuickConnectStatus?

  /// Jellyfin's official iOS SDK supports Quick Connect on every server build that exposes
  /// `/QuickConnect/Enabled`. The shared connection UI uses this constant to decide whether
  /// to surface the "Use Quick Connect" affordance.
  let quickConnectSupported: Bool = true

  /// Active Quick Connect controller, retained so the polling task isn't deallocated and
  /// so cancel/cleanup can call `stop()`. Nil when no flow is in progress.
  private var activeQuickConnect: JellyfinAPI.QuickConnect?

  /// Cancellable for the Combine subscription to the Quick Connect helper's `state` publisher.
  /// Stored separately from `disposeBag` so we can drop just this subscription when the flow
  /// ends (success, failure, or cancellation) without disturbing other long-lived ones.
  private var quickConnectStateSubscription: AnyCancellable?

  private var disposeBag = Set<AnyCancellable>()

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
    connectionService: JellyfinConnectionService,
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
    let serverName = try await connectionService.findServer(
      at: form.serverUrl,
      customHeaders: form.customHeadersDictionary()
    )
    connectionState = .foundServer
    form.serverName = serverName
  }

  @MainActor
  func handleSignInAction() async throws {
    do {
      let wasAdding = isAddingServer
      try await connectionService.signIn(
        username: form.username,
        password: form.password,
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
    } catch APIError.unacceptableStatusCode(let statusCode) {
      switch statusCode {
      case 400...499:
        throw IntegrationError.clientError(code: statusCode)
      default:
        throw IntegrationError.unexpectedResponse(code: statusCode)
      }
    } catch {
      throw error
    }
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

  // MARK: - Quick Connect

  /// Starts the Jellyfin Quick Connect flow.
  ///
  /// Builds a controller bound to the current api-client, subscribes to its state publisher,
  /// then kicks the flow off. Subsequent state transitions are handled in
  /// ``handleQuickConnectStateChange(_:)``: on `.authenticated` we exchange the secret for an
  /// access token via `signInWithQuickConnect`; on `.error` we surface the message via
  /// `quickConnectStatus = .failed(...)` so the view can show an alert.
  ///
  /// Throws synchronously only for the initial-setup failure case (e.g. no api-client because
  /// the user hasn't pointed at a server yet). Mid-flight failures arrive asynchronously via
  /// the published state.
  @MainActor
  func handleStartQuickConnect() async throws {
    // Idempotent: ignore if a flow is already in progress.
    guard activeQuickConnect == nil else { return }

    let manager = try connectionService.makeQuickConnectController()
    activeQuickConnect = manager
    quickConnectStatus = .retrievingCode

    quickConnectStateSubscription = manager.$state
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        guard let self else { return }
        Task { @MainActor in
          self.handleQuickConnectStateChange(state)
        }
      }

    manager.start()
  }

  /// Cancels an in-flight Quick Connect flow and clears any pending status.
  /// Safe to call when no flow is running.
  @MainActor
  func handleCancelQuickConnect() {
    activeQuickConnect?.stop()
    activeQuickConnect = nil
    quickConnectStateSubscription?.cancel()
    quickConnectStateSubscription = nil
    quickConnectStatus = nil
  }

  /// Maps JellyfinAPI's Quick Connect helper states to our protocol-level
  /// `QuickConnectStatus` and drives the final sign-in step on `.authenticated`.
  @MainActor
  private func handleQuickConnectStateChange(_ state: JellyfinAPI.QuickConnect.State) {
    switch state {
    case .idle:
      // We never voluntarily transition back to idle from the helper itself; nil out so the
      // view dismisses any leftover overlay defensively.
      quickConnectStatus = nil
    case .retrievingCode:
      quickConnectStatus = .retrievingCode
    case .polling(let code):
      quickConnectStatus = .awaitingCode(code)
    case .authenticated(let secret):
      quickConnectStatus = .authenticating
      Task { @MainActor in
        await self.completeQuickConnectSignIn(secret: secret)
      }
    case .error(let qcError):
      Self.logger.error("Quick Connect failed: \(qcError.localizedDescription)")
      quickConnectStatus = .failed(Self.message(for: qcError))
      activeQuickConnect = nil
      quickConnectStateSubscription?.cancel()
      quickConnectStateSubscription = nil
    }
  }

  /// Exchanges the authorized Quick Connect secret for an access token via the connection
  /// service, then transitions the form/state to look the same as a successful
  /// username/password sign-in. Errors are surfaced via `quickConnectStatus = .failed(...)`.
  @MainActor
  private func completeQuickConnectSignIn(secret: String) async {
    do {
      let userName = try await connectionService.signInWithQuickConnect(
        secret: secret,
        serverName: form.serverName,
        customHeaders: form.customHeadersDictionary()
      )

      if isAddingServer {
        isAddingServer = false
      }

      if let data = connectionService.connection {
        form.setValues(
          url: data.url.absoluteString,
          serverName: data.serverName,
          userName: data.userName
        )
      } else {
        form.username = userName
      }
      connectionState = .connected
      quickConnectStatus = nil
      activeQuickConnect = nil
      quickConnectStateSubscription?.cancel()
      quickConnectStateSubscription = nil
    } catch {
      Self.logger.error("Quick Connect sign-in failed: \(error.localizedDescription)")
      quickConnectStatus = .failed(error.localizedDescription)
      activeQuickConnect = nil
      quickConnectStateSubscription?.cancel()
      quickConnectStateSubscription = nil
    }
  }

  /// Translates the JellyfinAPI helper's error cases into a user-presentable, localizable
  /// message. Kept as a static helper so the mapping isn't entangled with view-model state.
  private static func message(for error: JellyfinAPI.QuickConnect.QuickConnectError) -> String {
    switch error {
    case .maxPollingHit:
      return "jellyfin_quick_connect_error_timeout".localized
    case .retrievingCodeFailed:
      return "jellyfin_quick_connect_error_no_code".localized
    case .other(let message):
      return message
    }
  }
}
