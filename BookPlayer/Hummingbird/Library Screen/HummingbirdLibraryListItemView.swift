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

  /// Pretty-printed due-date string for the subtitle, or nil when the book
  /// is from a library without a loan period (NNELS).
  ///
  /// Uses ``RelativeDateTimeFormatter`` so the subtitle reads as a
  /// countdown ("Due in 3 days", "Due today", "Overdue 2 days") rather
  /// than a flat date stamp. Localised strings supply the wrapper copy
  /// in three buckets: overdue / today / future; the formatter fills
  /// in the unit-aware fragment ("3 days", "in 1 hour", etc.).
  private var dueDateLabel: String? {
    guard let dueDate = item.dueDate else { return nil }

    let calendar = Calendar.current
    let now = Date()
    let dayDiff = calendar.dateComponents(
      [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: dueDate)
    ).day ?? 0

    // Same-calendar-day -> "Due today." Distinct from "in a few hours"
    // because users care whether they can still listen tonight, not
    // the exact hour.
    if dayDiff == 0 {
      return "due_date_today".localized
    }

    let relative = RelativeDateTimeFormatter()
    relative.unitsStyle = .full
    relative.dateTimeStyle = .named
    let fragment = relative.localizedString(for: dueDate, relativeTo: now)

    if dueDate < now {
      return String.localizedStringWithFormat(
        "due_date_overdue_format".localized, fragment
      )
    }
    return String.localizedStringWithFormat(
      "due_date_subtitle_format".localized, fragment
    )
  }

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
        if let dueDateLabel {
          Text(dueDateLabel)
            .bpFont(.caption)
            .foregroundStyle(theme.secondaryColor)
        }
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
