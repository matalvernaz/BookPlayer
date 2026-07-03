//
//  SoundBoothConnectionView.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import SwiftUI

/// Custom two-step sign-in for SoundBooth: enter the account email, receive a code by email,
/// then enter the code. Purpose-built because SoundBooth's passwordless flow doesn't map onto
/// the shared server-URL/credentials connection screen.
struct SoundBoothConnectionView: View {
  @ObservedObject var viewModel: SoundBoothConnectionViewModel
  @EnvironmentObject private var theme: ThemeViewModel

  @FocusState private var emailFocused: Bool
  @FocusState private var codeFocused: Bool

  var body: some View {
    Form {
      switch viewModel.step {
      case .enteringEmail:
        emailSection
      case .enteringCode:
        codeSection
      }

      if let errorMessage = viewModel.errorMessage {
        Section {
          Text(errorMessage)
            .foregroundStyle(.red)
            .accessibilityLabel("Error: \(errorMessage)")
        }
      }
    }
    .navigationTitle("SoundBooth")
    .navigationBarTitleDisplayMode(.inline)
    .disabled(viewModel.isBusy)
    .overlay {
      if viewModel.isBusy {
        ProgressView().controlSize(.large)
      }
    }
    .tint(theme.linkColor)
  }

  @ViewBuilder
  private var emailSection: some View {
    Section {
      TextField("Email", text: $viewModel.email)
        .textContentType(.emailAddress)
        .keyboardType(.emailAddress)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .focused($emailFocused)
        .accessibilityLabel("SoundBooth account email")
    } header: {
      Text("Sign in to SoundBooth")
    } footer: {
      Text("We'll email you a one-time code to sign in. No password needed.")
    }

    Section {
      Button {
        Task { await viewModel.sendCode() }
      } label: {
        Text("Send code")
          .frame(maxWidth: .infinity)
      }
      .disabled(viewModel.email.isEmpty)
    }
    .onAppear { emailFocused = true }
  }

  @ViewBuilder
  private var codeSection: some View {
    Section {
      TextField("Code", text: $viewModel.code)
        .textContentType(.oneTimeCode)
        .keyboardType(.numberPad)
        .focused($codeFocused)
        .accessibilityLabel("Login code")
    } header: {
      Text("Enter your code")
    } footer: {
      Text("Enter the code we emailed to \(viewModel.email).")
    }

    Section {
      Button {
        Task { await viewModel.verify() }
      } label: {
        Text("Verify")
          .frame(maxWidth: .infinity)
      }
      .disabled(viewModel.code.isEmpty)

      Button("Use a different email") {
        viewModel.editEmail()
      }
      .foregroundStyle(theme.linkColor)
    }
    .onAppear { codeFocused = true }
  }
}
