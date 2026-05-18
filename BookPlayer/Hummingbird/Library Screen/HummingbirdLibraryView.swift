//
//  HummingbirdLibraryView.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-05-18.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import SwiftUI

struct HummingbirdLibraryView: View {
  @ObservedObject var viewModel: HummingbirdLibraryViewModel
  @EnvironmentObject var theme: ThemeViewModel

  var body: some View {
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
            Task { await viewModel.loadBookshelf() }
          }
          .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      default:
        List(viewModel.items) { item in
          HummingbirdLibraryListItemView(item: item) {
            viewModel.downloadItem(item)
          }
        }
        .listStyle(.plain)
        .refreshable {
          await viewModel.loadBookshelf()
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
        await viewModel.loadBookshelf()
      }
    }
  }
}
