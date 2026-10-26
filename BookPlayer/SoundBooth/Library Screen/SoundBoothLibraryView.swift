//
//  SoundBoothLibraryView.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import SwiftUI

/// One level of the SoundBooth library (fork). Series and season rows open the next level (the root's
/// `NavigationStack` brings them back to this view); titles download. A season also offers to download
/// all its released episodes as one book.
struct SoundBoothLibraryView: View {
  @ObservedObject var viewModel: SoundBoothLibraryViewModel
  var node: SoundBoothNode = .root
  @EnvironmentObject var theme: ThemeViewModel
  /// Kept across launches; on unless turned off, for when the credits rule clips a chapter that should
  /// have stayed
  @AppStorage(Constants.UserDefaults.soundboothTrimSeasonCredits, store: UserDefaults.sharedDefaults)
  private var trimSeasonCredits = true

  // The download error alert is the root's: every level shares this view model, so an alert here would
  // fire on every level of the stack at once
  var body: some View {
    VStack(spacing: 0) {
      if let status = viewModel.downloadStatus {
        downloadBanner(status)
      }
      content
    }
    .scrollContentBackground(.hidden)
    .background(theme.systemBackgroundColor)
    .task {
      await viewModel.loadSeasonIfNeeded(node)
    }
  }

  @ViewBuilder
  private var content: some View {
    let sections = viewModel.sections(for: node)
    switch viewModel.loadState {
    case .idle:
      loadingIndicator
    case .loading where sections.isEmpty:
      loadingIndicator
    case .failed(let message) where sections.isEmpty:
      failedView(message)
    default:
      if sections.isEmpty {
        if viewModel.isFetchingSeason(node) {
          loadingIndicator
        } else {
          emptyView
        }
      } else {
        list(sections)
      }
    }
  }

  private func list(_ sections: [SoundBoothLibrarySection]) -> some View {
    List {
      if viewModel.canDownloadSeason(node) {
        seasonActions
      }
      ForEach(sections) { section in
        Section {
          ForEach(section.rows) { item in
            row(item)
          }
          .listRowBackground(theme.tertiarySystemBackgroundColor)
        } header: {
          if let title = section.title {
            Text(title)
              .bpFont(.caption)
              .foregroundStyle(theme.secondaryColor)
          }
        }
      }
    }
    .refreshable {
      await viewModel.refresh(node)
    }
  }

  @ViewBuilder
  private var seasonActions: some View {
    Section {
      Button {
        viewModel.downloadSeason(node, trimCredits: trimSeasonCredits)
      } label: {
        HStack(spacing: 12) {
          Image(systemName: "arrow.down.circle")
            .foregroundStyle(theme.linkColor)
            .frame(width: 28)
            .accessibilityHidden(true)
          Text("soundbooth_download_season_button".localized)
            .bpFont(.titleRegular)
            .foregroundStyle(theme.linkColor)
        }
      }
      .accessibilityValue(
        String.localizedStringWithFormat("soundbooth_episode_count".localized, viewModel.releasedEpisodeCount(node))
      )
      .listRowBackground(theme.tertiarySystemBackgroundColor)
    }
    Section {
      Toggle("soundbooth_trim_credits_toggle".localized, isOn: $trimSeasonCredits)
        .bpFont(.titleRegular)
        .foregroundStyle(theme.primaryColor)
        .tint(theme.linkColor)
        .listRowBackground(theme.tertiarySystemBackgroundColor)
    } footer: {
      Text("soundbooth_trim_credits_footer".localized)
        .bpFont(.caption)
        .foregroundStyle(theme.secondaryColor)
    }
  }

  @ViewBuilder
  private func row(_ item: SoundBoothLibraryItem) -> some View {
    if let child = item.childNode {
      NavigationLink(value: child) {
        HStack(spacing: 12) {
          Image(systemName: item.symbolName)
            .foregroundStyle(theme.secondaryColor)
            .frame(width: 28)
            .accessibilityHidden(true)
          Text(item.displayName)
            .bpFont(.titleRegular)
            .foregroundStyle(theme.primaryColor)
        }
      }
    } else {
      SoundBoothLibraryListItemView(item: item) {
        viewModel.downloadItem(item)
      }
    }
  }

  /// What's happening with the download just started, on this screen, where the tap was
  private func downloadBanner(_ status: String) -> some View {
    HStack(spacing: 8) {
      ProgressView()
        .progressViewStyle(.circular)
        .scaleEffect(0.7)
        .accessibilityHidden(true)
      Text(status)
        .bpFont(.caption)
        .foregroundStyle(theme.primaryColor)
      Spacer(minLength: 0)
      Button {
        viewModel.dismissDownloadStatus()
      } label: {
        Image(systemName: "xmark")
          .foregroundStyle(theme.secondaryColor)
          .frame(minWidth: 44, minHeight: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("voiceover_close_button".localized)
    }
    .padding(.leading, 16)
    .padding(.trailing, 4)
    .background(theme.secondarySystemBackgroundColor)
    // Two elements, the status and its close button: one combined element would close the banner
    // when the status is activated
    .accessibilityElement(children: .contain)
  }

  private var loadingIndicator: some View {
    ProgressView()
      .progressViewStyle(.circular)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func failedView(_ message: String) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle")
        .font(.largeTitle)
        .foregroundStyle(theme.secondaryColor)
        .accessibilityHidden(true)
      Text(message)
        .multilineTextAlignment(.center)
        .foregroundStyle(theme.secondaryColor)
        .padding(.horizontal)
      Button("integration_retry_button".localized) {
        Task { await viewModel.refresh(node) }
      }
      .buttonStyle(.bordered)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyView: some View {
    VStack(spacing: 12) {
      Image(systemName: "books.vertical")
        .font(.largeTitle)
        .foregroundStyle(theme.secondaryColor)
        .accessibilityHidden(true)
      Text("soundbooth_library_empty".localized)
        .multilineTextAlignment(.center)
        .foregroundStyle(theme.secondaryColor)
        .padding(.horizontal)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
