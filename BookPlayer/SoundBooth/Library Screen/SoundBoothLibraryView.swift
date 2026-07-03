//
//  SoundBoothLibraryView.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import SwiftUI

struct SoundBoothLibraryView: View {
  @ObservedObject var viewModel: SoundBoothLibraryViewModel
  @EnvironmentObject var theme: ThemeViewModel

  var body: some View {
    bodyContent
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

  @ViewBuilder
  private var bodyContent: some View {
    VStack(spacing: 0) {
      if let status = viewModel.downloadStatus {
        HStack(spacing: 8) {
          ProgressView()
            .progressViewStyle(.circular)
            .scaleEffect(0.7)
          Text(status)
            .bpFont(.caption)
            .foregroundStyle(theme.primaryColor)
          Spacer()
          Button {
            viewModel.dismissDownloadStatus()
          } label: {
            Image(systemName: "xmark")
              .foregroundStyle(theme.secondaryColor)
          }
          .accessibilityLabel("dismiss_button".localized)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.secondarySystemBackgroundColor)
        .accessibilityElement(children: .combine)
      }

      Group {
        switch viewModel.loadState {
        case .idle, .loading where viewModel.items.isEmpty:
          ProgressView()
            .progressViewStyle(.circular)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message) where viewModel.items.isEmpty:
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
        default:
          if viewModel.items.isEmpty {
            let activeSearch = !viewModel.searchQuery
              .trimmingCharacters(in: .whitespacesAndNewlines)
              .isEmpty
            VStack(spacing: 12) {
              Image(systemName: activeSearch ? "magnifyingglass" : "books.vertical")
                .font(.largeTitle)
                .foregroundStyle(theme.secondaryColor)
                .accessibilityHidden(true)
              Text(activeSearch
                ? "search_no_results_title".localized
                : "library_empty_title".localized)
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.secondaryColor)
                .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
          } else {
            List(viewModel.items) { item in
              SoundBoothLibraryListItemView(item: item) {
                viewModel.downloadItem(item)
              }
            }
            .listStyle(.plain)
            .refreshable {
              await viewModel.loadLibrary()
            }
          }
        }
      }
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
    .task {
      if viewModel.items.isEmpty {
        await viewModel.loadLibrary()
      }
    }
  }
}
