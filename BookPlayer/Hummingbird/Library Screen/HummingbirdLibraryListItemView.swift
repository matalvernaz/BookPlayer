//
//  HummingbirdLibraryListItemView.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-05-18.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import SwiftUI

struct HummingbirdLibraryListItemView: View {
  let item: HummingbirdLibraryItem
  let onDownload: () -> Void

  @EnvironmentObject var theme: ThemeViewModel

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "book.closed.fill")
        .foregroundStyle(theme.secondaryColor)
        .frame(width: 28)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .bpFont(.titleRegular)
          .foregroundStyle(theme.primaryColor)
      }
      Spacer()
      Button {
        onDownload()
      } label: {
        Image(systemName: "arrow.down.circle")
          .foregroundStyle(theme.linkColor)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("import_button".localized)
    }
    .accessibilityElement(children: .combine)
    .accessibilityAction(named: "import_button".localized, onDownload)
  }
}
