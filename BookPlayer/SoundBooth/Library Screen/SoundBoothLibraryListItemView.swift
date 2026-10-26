//
//  SoundBoothLibraryListItemView.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import SwiftUI

/// A SoundBooth title (fork). A released one is a single button (title, format, "Button", hint
/// "Download"), so a tap anywhere on it downloads; an unreleased episode is plain text with its release
/// date, offering nothing to activate.
struct SoundBoothLibraryListItemView: View {
  let item: SoundBoothLibraryItem
  let onDownload: () -> Void

  @EnvironmentObject var theme: ThemeViewModel

  var body: some View {
    if item.isDownloadable {
      Button(action: onDownload) {
        content(showsDownloadGlyph: true)
      }
      .buttonStyle(.plain)
      .accessibilityHint("download_title".localized)
    } else {
      content(showsDownloadGlyph: false)
        .accessibilityElement(children: .combine)
    }
  }

  private func content(showsDownloadGlyph: Bool) -> some View {
    HStack(spacing: 12) {
      Image(systemName: item.symbolName)
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
      Spacer(minLength: 0)
      if showsDownloadGlyph {
        Image(systemName: "arrow.down.circle")
          .foregroundStyle(theme.linkColor)
          .accessibilityHidden(true)
      }
    }
    .contentShape(Rectangle())
  }
}
