//
//  SoundBoothConnectionView.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import SwiftUI

/// The SoundBooth sign-in (fork): the account's email, then the code SoundBooth emails to it.
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
            .foregroundStyle(theme.errorColor)
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
    .onDisappear {
      viewModel.cancelPendingAuth()
    }
  }

  @ViewBuilder
  private var emailSection: some View {
    Section {
      TextField("email_title".localized, text: $viewModel.email)
        .textContentType(.emailAddress)
        .keyboardType(.emailAddress)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .focused($emailFocused)
        .submitLabel(.send)
        .onSubmit { viewModel.sendCode() }
        .accessibilityLabel("soundbooth_email_accessibility".localized)
    } header: {
      Text("soundbooth_sign_in_header".localized)
    } footer: {
      Text("soundbooth_email_footer".localized)
    }

    Section {
      Button {
        viewModel.sendCode()
      } label: {
        Text("soundbooth_send_code_button".localized)
          .frame(maxWidth: .infinity)
      }
      .disabled(viewModel.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .onAppear { emailFocused = true }
  }

  @ViewBuilder
  private var codeSection: some View {
    Section {
      TextField("soundbooth_code_label".localized, text: $viewModel.code)
        .textContentType(.oneTimeCode)
        .keyboardType(.numberPad)
        .focused($codeFocused)
        .accessibilityLabel("soundbooth_code_accessibility".localized)
    } header: {
      Text("soundbooth_code_header".localized)
    } footer: {
      Text(String(format: "soundbooth_code_footer_format".localized, viewModel.email))
    }

    Section {
      Button {
        viewModel.verify()
      } label: {
        Text("integration_sign_in_button".localized)
          .frame(maxWidth: .infinity)
      }
      .disabled(viewModel.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

      Button("soundbooth_different_email_button".localized) {
        viewModel.editEmail()
      }
      .foregroundStyle(theme.linkColor)
    }
    .onAppear { codeFocused = true }
  }
}

/// A saved SoundBooth account (fork): its email and Log out. SoundBooth has no server address or
/// headers to show, so this is all there is to the connection's details.
struct SoundBoothAccountDetailsView: View {
  let connectionService: SoundBoothConnectionService
  let connectionId: String
  /// Called after the account is removed, so the screen showing this can close
  var onSignedOut: () -> Void = {}

  @EnvironmentObject private var theme: ThemeViewModel

  var body: some View {
    Form {
      if let connection = connectionService.connections.first(where: { $0.id == connectionId }) {
        Section {
          Text(connection.email)
            .foregroundStyle(theme.primaryColor)
        } header: {
          Text("soundbooth_account_header".localized)
            .foregroundStyle(theme.secondaryColor)
        }
      }
      Section {
        Button(role: .destructive) {
          connectionService.deleteConnection(id: connectionId)
          onSignedOut()
        } label: {
          Text("logout_title".localized)
        }
      }
    }
    .navigationTitle("SoundBooth")
    .navigationBarTitleDisplayMode(.inline)
  }
}
