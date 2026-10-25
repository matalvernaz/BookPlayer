//
//  HummingbirdLibraryListItemView.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-05-18.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import SwiftUI

/// One book on the Hummingbird screen (fork). The whole row is the download button, so VoiceOver
/// reads it as one element (title, due date, "Button") and a tap anywhere on it downloads.
struct HummingbirdLibraryListItemView: View {
  let item: HummingbirdLibraryItem
  let onDownload: () -> Void

  @EnvironmentObject var theme: ThemeViewModel

  var body: some View {
    Button(action: onDownload) {
      HStack(spacing: 12) {
        Image(systemName: "book.closed.fill")
          .foregroundStyle(theme.secondaryColor)
          .frame(width: 28)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(item.title)
            .bpFont(.titleRegular)
            .foregroundStyle(theme.primaryColor)
          if let dueDate = item.dueDate {
            Text(Self.dueDateLabel(for: dueDate, now: Date()))
              .bpFont(.caption)
              .foregroundStyle(theme.secondaryColor)
          }
        }
        Spacer(minLength: 0)
        Image(systemName: "arrow.down.circle")
          .foregroundStyle(theme.linkColor)
          .accessibilityHidden(true)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityHint("download_title".localized)
  }

  /// When the loan runs out, as a countdown: "Due today" on the day itself (whether it can still be
  /// listened to tonight matters more than the hour), otherwise "Due in 3 days" or "Overdue, was due
  /// 2 days ago" from the system's relative wording
  static func dueDateLabel(for dueDate: Date, now: Date, calendar: Calendar = .current) -> String {
    let dayDifference = calendar.dateComponents(
      [.day],
      from: calendar.startOfDay(for: now),
      to: calendar.startOfDay(for: dueDate)
    ).day ?? 0

    if dayDifference == 0 {
      return "hummingbird_due_today".localized
    }

    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    formatter.dateTimeStyle = .named
    let relative = formatter.localizedString(for: dueDate, relativeTo: now)

    if dueDate < now {
      return String(format: "hummingbird_overdue_format".localized, relative)
    }
    return String(format: "hummingbird_due_format".localized, relative)
  }
}
