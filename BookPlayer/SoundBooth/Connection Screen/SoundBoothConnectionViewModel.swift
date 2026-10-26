//
//  SoundBoothConnectionViewModel.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Foundation
import UIKit

/// The SoundBooth sign-in (fork): enter the account's email, get a code by email, enter the code.
/// Its own small screen: the shared connection flow is shaped for a server address and a password, and
/// SoundBooth has neither.
@MainActor
final class SoundBoothConnectionViewModel: ObservableObject, BPLogger {
  enum Step: Equatable {
    /// Asking for the account's email; Send Code moves on
    case enteringEmail
    /// A code was emailed; asking for it
    case enteringCode
  }

  let connectionService: SoundBoothConnectionService

  @Published var email: String = ""
  @Published var code: String = ""
  @Published private(set) var step: Step = .enteringEmail
  @Published var isBusy: Bool = false
  /// Why the last step failed, shown under the form. Announced: focus stays on the button that failed
  @Published var errorMessage: String? {
    didSet {
      guard let errorMessage, errorMessage != oldValue else { return }
      UIAccessibility.post(notification: .announcement, argument: errorMessage)
    }
  }
  /// Set when a sign-in succeeds, so the screen showing this can close and load the library
  @Published private(set) var signInCompletedAt: Date?

  /// The connection a re-authentication started from: signing in to that account again keeps its id
  private(set) var replacingID: String?
  /// The send-code or verify request in flight, so closing the screen cancels it. The service checks
  /// for that before it saves anything, the other half of the rule
  private var authTask: Task<Void, Never>?

  init(connectionService: SoundBoothConnectionService) {
    self.connectionService = connectionService
  }

  /// Starts over from the email step for the saved account's session that expired, its email filled in
  func prepareReauth() {
    authTask?.cancel()
    if let connection = connectionService.connection {
      email = connection.email
      replacingID = connection.id
    }
    code = ""
    errorMessage = nil
    step = .enteringEmail
  }

  func sendCode() {
    authTask?.cancel()
    authTask = Task { [weak self] in
      await self?.performSendCode()
    }
  }

  func verify() {
    authTask?.cancel()
    authTask = Task { [weak self] in
      await self?.performVerify()
    }
  }

  /// The screen went away: whatever was in flight is dropped
  func cancelPendingAuth() {
    authTask?.cancel()
    authTask = nil
    isBusy = false
  }

  /// Back to the email step (a wrong address, or to have the code sent again)
  func editEmail() {
    step = .enteringEmail
    code = ""
    errorMessage = nil
  }

  private func performSendCode() async {
    let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.contains("@") else {
      errorMessage = "soundbooth_email_invalid".localized
      return
    }
    email = trimmed
    isBusy = true
    errorMessage = nil
    defer { if !Task.isCancelled { isBusy = false } }
    do {
      try await connectionService.requestLoginCode(email: trimmed)
      guard !Task.isCancelled else { return }
      step = .enteringCode
    } catch let error where Self.isCancellation(error) {
      // Closed or replaced
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func performVerify() async {
    // Codes are digits: the spaces of a pasted "123 456" aren't part of it
    let trimmedCode = code.filter { !$0.isWhitespace }
    guard !trimmedCode.isEmpty else {
      errorMessage = "soundbooth_code_missing".localized
      return
    }
    isBusy = true
    errorMessage = nil
    defer { if !Task.isCancelled { isBusy = false } }
    do {
      try await connectionService.signIn(email: email, code: trimmedCode, replacingID: replacingID)
      guard !Task.isCancelled else { return }
      signInCompletedAt = Date()
    } catch let error where Self.isCancellation(error) {
      // Closed or replaced
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// URLSession cancels with `URLError.cancelled`, not `CancellationError`
  private static func isCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
  }
}
