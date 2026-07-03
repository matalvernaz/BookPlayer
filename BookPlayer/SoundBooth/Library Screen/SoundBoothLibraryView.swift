//
//  SoundBoothLibraryView.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import SwiftUI

/// One level of the owned-library drill-down. The same view renders every level (`node`):
/// series/season rows push the next level via `NavigationLink`; book/episode rows are
/// downloadable leaves. The host `NavigationStack` (in `SoundBoothRootView`) resolves the
/// pushed nodes back into this view.
struct SoundBoothLibraryView: View {
  @ObservedObject var viewModel: SoundBoothLibraryViewModel
  var node: SoundBoothNode = .root
  @EnvironmentObject var theme: ThemeViewModel

  var body: some View {
    content
      .alert(
        "error_title".localized,
        isPresented: .init(
          get: { viewModel.downloadError != nil },
          set: { if !$0 { viewModel.downloadError = nil } }
        ),
        actions: { Button("ok_button".localized) { viewModel.downloadError = nil } },
        message: { Text(viewModel.downloadError ?? "") }
      )
  }

  @ViewBuilder
  private var content: some View {
    VStack(spacing: 0) {
      if let status = viewModel.downloadStatus {
        downloadBanner(status)
      }

      let sections = viewModel.sections(for: node)
      Group {
        switch viewModel.loadState {
        case .idle, .loading where sections.isEmpty:
          ProgressView()
            .progressViewStyle(.circular)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message) where sections.isEmpty:
          failedView(message)
        default:
          if sections.isEmpty {
            if viewModel.isFetchingSeason(node) {
              ProgressView()
                .progressViewStyle(.circular)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
              emptyView
            }
          } else {
            List {
              if viewModel.canDownloadSeason(node) {
                Section {
                  Button {
                    viewModel.downloadSeason(node)
                  } label: {
                    HStack(spacing: 12) {
                      Image(systemName: "arrow.down.circle")
                        .foregroundStyle(theme.linkColor)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                      Text("Download season")
                        .bpFont(.titleRegular)
                        .foregroundStyle(theme.linkColor)
                    }
                  }
                  .accessibilityValue("\(viewModel.releasedEpisodeCount(node)) episodes")
                }
              }
              ForEach(sections) { section in
                Section {
                  ForEach(section.rows) { item in
                    rowView(item)
                  }
                } header: {
                  if let title = section.title {
                    Text(title)
                      .bpFont(.caption)
                      .foregroundStyle(theme.secondaryColor)
                  }
                }
              }
            }
            .listStyle(.plain)
            .refreshable {
              await viewModel.refresh(node)
            }
          }
        }
      }
    }
    .scrollContentBackground(.hidden)
    .background(theme.systemBackgroundColor)
    .task {
      await viewModel.loadSeasonIfNeeded(node)
    }
  }

  @ViewBuilder
  private func rowView(_ item: SoundBoothLibraryItem) -> some View {
    if item.isNavigable, let child = item.childNode {
      NavigationLink(value: child) {
        HStack(spacing: 12) {
          Image(systemName: item.placeholderImageName)
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

  @ViewBuilder
  private func downloadBanner(_ status: String) -> some View {
    HStack(spacing: 8) {
      ProgressView().progressViewStyle(.circular).scaleEffect(0.7)
      Text(status).bpFont(.caption).foregroundStyle(theme.primaryColor)
      Spacer()
      Button {
        viewModel.dismissDownloadStatus()
      } label: {
        Image(systemName: "xmark").foregroundStyle(theme.secondaryColor)
      }
      .accessibilityLabel("dismiss_button".localized)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(theme.secondarySystemBackgroundColor)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private func failedView(_ message: String) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle")
        .font(.largeTitle)
        .foregroundStyle(theme.secondaryColor)
      Text(message)
        .multilineTextAlignment(.center)
        .foregroundStyle(theme.secondaryColor)
        .padding(.horizontal)
      Button("integration_retry_button".localized) {
        Task { await viewModel.loadLibrary() }
      }
      .buttonStyle(.bordered)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private var emptyView: some View {
    VStack(spacing: 12) {
      Image(systemName: "books.vertical")
        .font(.largeTitle)
        .foregroundStyle(theme.secondaryColor)
        .accessibilityHidden(true)
      Text("library_empty_title".localized)
        .multilineTextAlignment(.center)
        .foregroundStyle(theme.secondaryColor)
        .padding(.horizontal)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
  }
}
