//
//  SoundBoothLibraryListItemView.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import SwiftUI

struct SoundBoothLibraryListItemView: View {
  let item: SoundBoothLibraryItem
  let onDownload: () -> Void

  @EnvironmentObject var theme: ThemeViewModel

  var body: some View {
    // Only expose the Import action when the row can actually be downloaded — an unreleased
    // episode has no download button, so VoiceOver shouldn't offer a dead action either.
    if item.isDownloadable {
      row.accessibilityAction(named: "import_button".localized, onDownload)
    } else {
      row
    }
  }

  @ViewBuilder
  private var row: some View {
    HStack(spacing: 12) {
      Image(systemName: item.placeholderImageName)
        .foregroundStyle(theme.secondaryColor)
        .frame(width: 28)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(item.displayName)
          .bpFont(.titleRegular)
          .foregroundStyle(theme.primaryColor)

        if let detail = item.detailLabel {
          Text(detail)
            .bpFont(.caption)
            .foregroundStyle(theme.secondaryColor)
        }
      }

      Spacer()

      if item.isDownloadable {
        Button {
          onDownload()
        } label: {
          Image(systemName: "arrow.down.circle")
            .foregroundStyle(theme.linkColor)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("import_button".localized)
      }
    }
    .accessibilityElement(children: .combine)
  }
}
