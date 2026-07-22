//
//  ShareLinkSheetView.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-07-21.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import SwiftUI

/// Creates and manages a public share link for an Audiobookshelf-sourced book. The link opens
/// the book directly in BookPlayer for recipients with the app (universal link), and lands on
/// the server's share page — playable in the browser — for everyone else. Recipients don't
/// need an account on the server; the link itself is the access grant, bounded by the chosen
/// expiry.
struct ShareLinkSheetView: View {
  let item: SimpleLibraryItem
  let sourceInfo: MediaServerSourceInfo

  @Environment(\.audiobookshelfService) private var audiobookshelfService
  @Environment(\.dismiss) private var dismiss

  enum Expiry: String, CaseIterable, Identifiable {
    case week
    case month
    case threeMonths
    case never

    var id: String { rawValue }

    var titleKey: String {
      switch self {
      case .week: return "share_link_expiry_week"
      case .month: return "share_link_expiry_month"
      case .threeMonths: return "share_link_expiry_three_months"
      case .never: return "share_link_expiry_never"
      }
    }

    private static let day: TimeInterval = 24 * 60 * 60

    var date: Date? {
      switch self {
      case .week: return Date(timeIntervalSinceNow: 7 * Self.day)
      case .month: return Date(timeIntervalSinceNow: 30 * Self.day)
      case .threeMonths: return Date(timeIntervalSinceNow: 90 * Self.day)
      case .never: return nil
      }
    }
  }

  struct ActiveLink {
    let shareId: String
    let url: URL
    let expiresAt: Date?
  }

  private enum Phase {
    case setup
    case creating
    case revoking(ActiveLink)
    case ready(ActiveLink)
  }

  @State private var phase: Phase = .setup
  @State private var expiry: Expiry = .month
  @State private var errorMessage: String?

  private var isErrorPresented: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }

  var body: some View {
    Form {
      switch phase {
      case .setup:
        setupContent
      case .creating:
        progressRow("share_link_creating_message")
      case .revoking:
        progressRow("share_link_revoking_message")
      case .ready(let link):
        readyContent(link)
      }
    }
    .navigationTitle("share_link_sheet_title")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("done_title") {
          dismiss()
        }
      }
    }
    .alert("error_title", isPresented: isErrorPresented) {
      Button("ok_button", role: .cancel) {}
    } message: {
      if let errorMessage {
        Text(errorMessage)
      }
    }
    .onAppear {
      restoreCachedLink()
    }
  }

  @ViewBuilder
  private var setupContent: some View {
    Section {
      Picker("share_link_expiry_title", selection: $expiry) {
        ForEach(Expiry.allCases) { option in
          Text(LocalizedStringKey(option.titleKey)).tag(option)
        }
      }
      Button {
        createLink()
      } label: {
        Label("share_link_create_button", systemImage: "link.badge.plus")
      }
    } header: {
      Text(item.title)
    } footer: {
      Text("share_link_setup_footer")
    }
  }

  @ViewBuilder
  private func readyContent(_ link: ActiveLink) -> some View {
    Section {
      Text(link.url.absoluteString)
        .font(.footnote)
        .textSelection(.enabled)
        .accessibilityLabel(Text("share_link_url_accessibility_label"))
        .accessibilityValue(link.url.absoluteString)
      ShareLink(item: link.url, message: Text(item.title)) {
        Label("share_link_share_button", systemImage: "square.and.arrow.up")
      }
      Button {
        UIPasteboard.general.url = link.url
        UIAccessibility.post(
          notification: .announcement,
          argument: "share_link_copied_announcement".localized
        )
      } label: {
        Label("share_link_copy_button", systemImage: "doc.on.doc")
      }
    } header: {
      Text(item.title)
    } footer: {
      Text(expiryDescription(for: link))
    }

    Section {
      Button(role: .destructive) {
        revokeLink(link)
      } label: {
        Label("share_link_revoke_button", systemImage: "trash")
      }
    } footer: {
      Text("share_link_revoke_footer")
    }
  }

  @ViewBuilder
  private func progressRow(_ messageKey: String) -> some View {
    HStack(spacing: 8) {
      ProgressView()
      Text(LocalizedStringKey(messageKey))
    }
    .accessibilityElement(children: .combine)
  }

  private func expiryDescription(for link: ActiveLink) -> String {
    guard let expiresAt = link.expiresAt else {
      return "share_link_no_expiry".localized
    }
    let formatted = DateFormatter.localizedString(from: expiresAt, dateStyle: .medium, timeStyle: .none)
    return String.localizedStringWithFormat("share_link_expires_format".localized, formatted)
  }

  // MARK: - Actions

  private func restoreCachedLink() {
    guard let cached = MintedShareLinkCache.link(for: sourceInfo.itemId) else { return }
    if let expiresAt = cached.expiresAt, expiresAt <= Date() {
      MintedShareLinkCache.remove(for: sourceInfo.itemId)
      return
    }
    guard let url = URL(string: cached.urlString) else { return }
    phase = .ready(ActiveLink(shareId: cached.shareId, url: url, expiresAt: cached.expiresAt))
  }

  private func createLink() {
    phase = .creating
    let expiresAt = expiry.date
    Task {
      do {
        let mediaItemId = try await audiobookshelfService.fetchMediaItemId(
          forLibraryItemId: sourceInfo.itemId,
          connectionId: sourceInfo.connectionId
        )
        let share = try await audiobookshelfService.createMediaItemShare(
          mediaItemId: mediaItemId,
          slug: Self.makeSlug(from: item.title),
          expiresAt: expiresAt,
          connectionId: sourceInfo.connectionId
        )
        let url = try audiobookshelfService.shareWebURL(
          slug: share.slug,
          connectionId: sourceInfo.connectionId
        )
        let link = ActiveLink(shareId: share.id, url: url, expiresAt: expiresAt)
        MintedShareLinkCache.store(
          MintedShareLinkCache.Entry(
            shareId: link.shareId,
            urlString: url.absoluteString,
            expiresAt: expiresAt
          ),
          for: sourceInfo.itemId
        )
        phase = .ready(link)
      } catch {
        errorMessage = error.localizedDescription
        phase = .setup
      }
    }
  }

  private func revokeLink(_ link: ActiveLink) {
    phase = .revoking(link)
    Task {
      do {
        try await audiobookshelfService.deleteMediaItemShare(
          shareId: link.shareId,
          connectionId: sourceInfo.connectionId
        )
        MintedShareLinkCache.remove(for: sourceInfo.itemId)
        UIAccessibility.post(
          notification: .announcement,
          argument: "share_link_revoked_announcement".localized
        )
        phase = .setup
      } catch {
        errorMessage = error.localizedDescription
        phase = .ready(link)
      }
    }
  }

  /// URL-path-safe slug: a readable title prefix plus a random suffix. The suffix makes slug
  /// collisions with unrelated shares effectively impossible, so a 409 from the server can be
  /// interpreted as "this *item* is already shared" rather than a slug clash.
  static func makeSlug(from title: String) -> String {
    let maxTitleLength = 30
    let allowed = CharacterSet.lowercaseLetters.union(.decimalDigits)

    var prefix = title
      .lowercased()
      .map { character -> Character in
        let isAllowed = character.unicodeScalars.allSatisfy { allowed.contains($0) }
        return isAllowed ? character : "-"
      }
      .reduce(into: "") { result, character in
        // collapse runs of "-" so punctuation-heavy titles stay readable
        if character == "-", result.hasSuffix("-") { return }
        result.append(character)
      }
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

    if prefix.count > maxTitleLength {
      prefix = String(prefix.prefix(maxTitleLength))
    }

    let suffixAlphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
    let suffix = String((0..<6).compactMap { _ in suffixAlphabet.randomElement() })

    return prefix.isEmpty ? suffix : "\(prefix)-\(suffix)"
  }
}

/// Share links this device has minted, keyed by ABS library item id, so reopening the sheet
/// shows the existing link (ABS allows one active share per item) and can revoke it. Local
/// cache only — links minted from the ABS web UI aren't visible here.
enum MintedShareLinkCache {
  struct Entry: Codable {
    let shareId: String
    let urlString: String
    let expiresAt: Date?
  }

  private static let defaultsKey = "userSettingsMintedShareLinks"

  static func link(for itemId: String) -> Entry? {
    readAll()[itemId]
  }

  static func store(_ entry: Entry, for itemId: String) {
    var all = readAll()
    all[itemId] = entry
    writeAll(all)
  }

  static func remove(for itemId: String) {
    var all = readAll()
    all.removeValue(forKey: itemId)
    writeAll(all)
  }

  private static func readAll() -> [String: Entry] {
    guard
      let data = UserDefaults.standard.data(forKey: defaultsKey),
      let entries = try? JSONDecoder().decode([String: Entry].self, from: data)
    else {
      return [:]
    }
    return entries
  }

  private static func writeAll(_ entries: [String: Entry]) {
    guard let data = try? JSONEncoder().encode(entries) else { return }
    UserDefaults.standard.set(data, forKey: defaultsKey)
  }
}
