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
    HStack(spacing: 12) {
      Image(systemName: item.placeholderImageName)
        .foregroundStyle(theme.secondaryColor)
        .frame(width: 28)
        .accessibilityHidden(true)

      Text(item.displayName)
        .bpFont(.titleRegular)
        .foregroundStyle(theme.primaryColor)

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
    .accessibilityAction(named: "import_button".localized, onDownload)
  }
}
