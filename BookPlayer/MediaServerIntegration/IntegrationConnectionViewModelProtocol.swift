//
//  IntegrationConnectionViewModelProtocol.swift
//  BookPlayer
//
//  Created by Gianni Carlo on 4/5/26.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import SwiftUI

/// Current step of the sign-in flow. `nil` means the user is not actively
/// signing in — the view should show the connection-details UI for the
/// active connection (server info + custom headers + logout). Multi-server
/// management lives in `MediaServersView`, not here.
enum SignInStep {
  /// User is entering the server URL (initial step).
  case enteringServerURL
  /// Server has been validated; user is entering credentials.
  case enteringCredentials
}

enum IntegrationViewMode {
  /// Bound to a live library session; pre-populates form from the active connection.
  case regular
  /// Cog → Connection Details flow; pre-populates form, shows connection-details UI.
  case viewDetails
  /// Dedicated Add Server flow; starts with empty form, no active-connection state leaks.
  case addServer
}

struct IntegrationServerInfo: Identifiable {
  let id: String
  let serverName: String
  let serverUrl: String
  let userName: String
}

/// Status of an out-of-band code-based authentication flow (Jellyfin Quick Connect).
///
/// The device asks the server for a short user-facing code, then polls until the user enters
/// that code in an already-authenticated session of the server's web UI. While the device is
/// waiting it sits in `.awaitingCode`; once the server marks the request authorized, the device
/// enters `.authenticating` while it exchanges the secret for an access token. Failures are
/// surfaced as `.failed`, with a localized message ready for display.
enum QuickConnectStatus: Equatable {
  /// The client has called the server's `/QuickConnect/Initiate` endpoint and is waiting for
  /// the user-facing code to come back. Briefly visible while the network round-trip completes.
  case retrievingCode

  /// The server returned a short code and the client is polling. The user must enter this code
  /// on the server's web UI (User menu → Quick Connect) to authorize the device.
  case awaitingCode(String)

  /// The user authorized the request. The client is exchanging the secret for an access token.
  case authenticating

  /// The flow ended in a failure. The associated value is a user-presentable message.
  case failed(String)
}

struct IntegrationServerInfo: Identifiable {
  let id: String
  let serverName: String
  let serverUrl: String
  let userName: String
  let isActive: Bool
}

@MainActor
protocol IntegrationConnectionViewModelProtocol: ObservableObject {
  associatedtype FormVM: IntegrationConnectionFormViewModelProtocol

  var form: FormVM { get set }
  var viewMode: IntegrationViewMode { get set }

  /// Drives what the view renders.
  /// `.enteringServerURL` → URL form; `.enteringCredentials` → credentials form; `nil` → connection-details UI.
  var signInFlow: SignInStep? { get set }

  /// Timestamp of the last successful sign-in. Observers use this as a signal
  /// to react to real sign-in completions (distinct from cancellations).
  var signInCompletedAt: Date? { get }

  /// All saved server connections
  var servers: [IntegrationServerInfo] { get }

  /// Whether the user is adding a new server from the settings screen
  /// (vs the initial-connect flow). Used by the toolbar to surface a Cancel
  /// button when adding from Settings.
  var isAddingServer: Bool { get set }

  /// All saved server connections
  var servers: [IntegrationServerInfo] { get }

  /// Whether the user is adding a new server from the settings screen
  var isAddingServer: Bool { get set }

  func handleConnectAction() async throws
  func handleSignInAction() async throws
  func handleSignOutAction()

  /// Sign out a specific server by ID
  func handleSignOutAction(id: String)

  /// Switch active server
  func handleActivateAction(id: String)

  /// Begin adding a new server from settings
  func handleAddServerAction()

  /// Cancel adding a new server
  func handleCancelAddServerAction()

  /// Persist any changes made to the custom-headers list while the connection is already live.
  func handleCustomHeadersUpdate()

  /// Whether this integration supports an out-of-band code-based sign-in flow (Jellyfin's
  /// Quick Connect). The shared connection UI uses this to decide whether to surface the
  /// "Use Quick Connect" affordance. Default: `false` — concrete view models opt in.
  var quickConnectSupported: Bool { get }

  /// Current state of an in-flight Quick Connect flow, or `nil` if none is running. The
  /// shared UI observes this to drive the awaiting-code overlay and final sign-in.
  var quickConnectStatus: QuickConnectStatus? { get }

  /// Begin the Quick Connect flow. Throws if the underlying api-client cannot be reached
  /// (e.g. before `handleConnectAction()` has succeeded). The view model is responsible for
  /// completing sign-in and transitioning the connection to `.connected`.
  func handleStartQuickConnect() async throws

  /// Cancel an in-flight Quick Connect flow, dismiss any failure status, and free the
  /// underlying poller. Safe to call when no flow is running.
  func handleCancelQuickConnect()
}

/// Default no-op implementations so that integrations without code-based sign-in (e.g.
/// AudiobookShelf) can conform to this protocol without boilerplate. Concrete view models
/// override these to opt in.
extension IntegrationConnectionViewModelProtocol {
  var quickConnectSupported: Bool { false }
  var quickConnectStatus: QuickConnectStatus? { nil }
  func handleStartQuickConnect() async throws {}
  func handleCancelQuickConnect() {}

  /// Force the connection sheet into the password-entry posture for a saved
  /// server whose session has gone stale. Called by each root view before
  /// presenting the form in response to the session-expired alert's "Sign
  /// In" action.
  ///
  /// Without this, the `@StateObject` VM init sees `connectionService.connection
  /// != nil` and locks in `connectionState = .connected`, which renders the
  /// `IntegrationConnectedView` (Sign Out only) -- a dead-end trap where the
  /// only way out is to delete the connection and re-add it from scratch,
  /// losing customHeaders and selectedLibraryId. `.foundServer` preserves the
  /// existing serverName/URL/headers/username (already populated by the VM's
  /// init) and shows the password field.
  func prepareForReauth() {
    connectionState = .foundServer
    form.password = ""
  }
}
