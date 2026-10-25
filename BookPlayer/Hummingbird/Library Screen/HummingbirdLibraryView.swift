//
//  HummingbirdLibraryView.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-05-18.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import SwiftUI

/// The bookshelf and the library's search (fork), with a banner while a download gets ready
struct HummingbirdLibraryView: View {
  @ObservedObject var viewModel: HummingbirdLibraryViewModel
  @EnvironmentObject var theme: ThemeViewModel

  var body: some View {
    VStack(spacing: 0) {
      if let status = viewModel.downloadStatus {
        downloadBanner(status)
      }
      content
    }
    .scrollContentBackground(.hidden)
    .background(theme.systemBackgroundColor)
    .searchable(
      text: $viewModel.searchQuery,
      placement: .navigationBarDrawer(displayMode: .always),
      prompt: Text("search_title".localized)
    )
    .onChange(of: viewModel.searchQuery) { _, newValue in
      viewModel.applySearch(query: newValue)
    }
    .alert(
      "error_title".localized,
      isPresented: .init(
        get: { viewModel.downloadError != nil },
        set: { if !$0 { viewModel.downloadError = nil } }
      ),
      actions: {
        Button("ok_button".localized) { viewModel.downloadError = nil }
      },
      message: { Text(viewModel.downloadError ?? "") }
    )
  }

  /// What's happening with the download the user just started. On this screen, where the tap was:
  /// the library's own download progress only shows on the library.
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
    // The status and its close button stay two elements: one combined element would close the
    // banner when the status is activated
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private var content: some View {
    switch viewModel.loadState {
    case .idle:
      loadingIndicator
    case .loading where viewModel.items.isEmpty:
      // A refresh with a list on screen keeps the list
      loadingIndicator
    case .failed(let message) where viewModel.items.isEmpty:
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
          Task { await viewModel.refresh() }
        }
        .buttonStyle(.bordered)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    default:
      if viewModel.items.isEmpty {
        emptyState
      } else {
        List(viewModel.items) { item in
          HummingbirdLibraryListItemView(item: item) {
            viewModel.downloadItem(item)
          }
          .listRowBackground(theme.tertiarySystemBackgroundColor)
        }
        .refreshable {
          await viewModel.refresh()
        }
      }
    }
  }

  private var loadingIndicator: some View {
    ProgressView()
      .progressViewStyle(.circular)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// Loaded with nothing in it: an empty bookshelf, or a search that found nothing
  private var emptyState: some View {
    let isSearching = !viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    return VStack(spacing: 12) {
      Image(systemName: isSearching ? "magnifyingglass" : "books.vertical")
        .font(.largeTitle)
        .foregroundStyle(theme.secondaryColor)
        .accessibilityHidden(true)
      Text(isSearching ? "hummingbird_search_no_results".localized : "hummingbird_bookshelf_empty".localized)
        .multilineTextAlignment(.center)
        .foregroundStyle(theme.secondaryColor)
        .padding(.horizontal)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
