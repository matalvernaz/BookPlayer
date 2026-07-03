//
//  SoundBoothConnectionViewModel.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Foundation

/// Drives the SoundBooth email-code sign-in. SoundBooth's auth (enter email → receive a code by
/// email → enter the code) doesn't fit the shared `IntegrationConnectionViewModelProtocol`, whose
/// steps assume "server URL then credentials", so this is a small purpose-built view model backing
/// a custom two-field view rather than the generic connection screen.
@MainActor
final class SoundBoothConnectionViewModel: ObservableObject, BPLogger {
  enum Step: Equatable {
    /// Collecting the account email; a "Send code" action moves to `.enteringCode`.
    case enteringEmail
    /// A code has been emailed; collecting it for verification.
    case enteringCode
  }

  let connectionService: SoundBoothConnectionService

  @Published var email: String = ""
  @Published var code: String = ""
  @Published private(set) var step: Step = .enteringEmail
  @Published var isBusy: Bool = false
  @Published var errorMessage: String?
  /// Set on a successful verify so the host view can dismiss and load the library.
  @Published private(set) var signInCompletedAt: Date?

  init(connectionService: SoundBoothConnectionService) {
    self.connectionService = connectionService
  }

  /// Request a login code for the entered email and advance to code entry.
  @MainActor
  func sendCode() async {
    let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.contains("@") else {
      errorMessage = "Enter the email address for your SoundBooth account."
      return
    }
    email = trimmed
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }
    do {
      try await connectionService.requestLoginCode(email: trimmed)
      step = .enteringCode
    } catch is CancellationError {
      // ignore
    } catch {
      errorMessage = Self.message(for: error)
    }
  }

  /// Verify the entered code; on success the connection is persisted by the service.
  @MainActor
  func verify() async {
    let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedCode.isEmpty else {
      errorMessage = "Enter the code from your email."
      return
    }
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }
    do {
      try await connectionService.signIn(email: email, code: trimmedCode)
      signInCompletedAt = Date()
    } catch is CancellationError {
      // ignore
    } catch {
      errorMessage = Self.message(for: error)
    }
  }

  /// Return to the email step (e.g. wrong address, or to resend).
  @MainActor
  func editEmail() {
    step = .enteringEmail
    code = ""
    errorMessage = nil
  }

  private static func message(for error: Error) -> String {
    if let integrationError = error as? IntegrationError {
      return integrationError.localizedDescription
    }
    return error.localizedDescription
  }
}
