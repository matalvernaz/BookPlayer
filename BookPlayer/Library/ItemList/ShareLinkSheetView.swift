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
  /// `nil` when the item has no recorded provenance (imports that predate tracking, or
  /// mappings severed by the old zip-extraction path). The sheet then resolves the book
  /// against the active ABS connection by title search before offering to create a link.
  let sourceInfo: MediaServerSourceInfo?

  @Environment(\.audiobookshelfService) private var audiobookshelfService
  @Environment(\.mediaServerSourceStore) private var mediaServerSourceStore
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
    case resolving
    case unavailable(String)
    case setup
    case creating
    case revoking(ActiveLink)
    case ready(ActiveLink)
  }

  @State private var phase: Phase
  @State private var expiry: Expiry = .month
  @State private var errorMessage: String?
  /// Source the sheet operates on: `sourceInfo` when provenance was recorded, otherwise the
  /// result of the on-appear title search.
  @State private var resolvedSource: MediaServerSourceInfo?
  /// Server-side "Title – Author" of a search-resolved book, displayed so the user can verify
  /// the match before minting. `nil` when provenance was recorded (no search happened).
  @State private var matchedServerTitle: String?

  init(item: SimpleLibraryItem, sourceInfo: MediaServerSourceInfo?) {
    self.item = item
    self.sourceInfo = sourceInfo
    // Provenance-less items open straight into the server search; showing `setup` first
    // would flash an inert Create button for a frame.
    _phase = State(initialValue: sourceInfo == nil ? .resolving : .setup)
  }

  private var isErrorPresented: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }

  var body: some View {
    Form {
      switch phase {
      case .resolving:
        progressRow("share_link_resolving_message")
      case .unavailable(let message):
        unavailableContent(message)
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
      if let sourceInfo {
        resolvedSource = sourceInfo
        restoreCachedLink()
      } else {
        resolveFromServer()
      }
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
      VStack(alignment: .leading, spacing: 4) {
        if let matchedServerTitle {
          Text(String.localizedStringWithFormat("share_link_match_footer_format".localized, matchedServerTitle))
        }
        Text("share_link_setup_footer")
      }
    }
  }

  @ViewBuilder
  private func unavailableContent(_ message: String) -> some View {
    Section {
      Text(message)
    } header: {
      Text(item.title)
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

  /// Matches a provenance-less item against the active ABS connection by title so existing
  /// imports can still be shared. Prefers an exact (case/diacritic-insensitive) title match
  /// across book libraries, falling back to the first search hit; the resolved server title is
  /// surfaced in the setup footer so the user can verify the match before minting.
  private func resolveFromServer() {
    phase = .resolving
    Task {
      do {
        guard let connection = audiobookshelfService.connection else {
          phase = .unavailable("share_link_no_connection_message".localized)
          return
        }
        let libraries = try await audiobookshelfService.fetchLibraries()
          .filter { $0.mediaType == "book" }

        var exactMatch: AudiobookShelfLibraryItem?
        var firstResult: AudiobookShelfLibraryItem?
        for library in libraries {
          let results = try await audiobookshelfService.searchItems(
            in: library.id,
            query: item.title,
            limit: 5
          )
          if firstResult == nil { firstResult = results.first }
          if let exact = results.first(where: {
            $0.title.compare(item.title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
          }) {
            exactMatch = exact
            break
          }
        }

        guard let match = exactMatch ?? firstResult else {
          phase = .unavailable(
            String.localizedStringWithFormat("share_link_no_match_format".localized, item.title)
          )
          return
        }

        resolvedSource = MediaServerSourceInfo(
          kind: .audiobookshelf,
          connectionId: connection.id,
          itemId: match.id
        )
        matchedServerTitle = match.authorName.map { "\(match.title) – \($0)" } ?? match.title
        phase = .setup
        restoreCachedLink()
      } catch {
        phase = .unavailable(error.localizedDescription)
      }
    }
  }

  private func restoreCachedLink() {
    guard let itemId = resolvedSource?.itemId else { return }
    guard let cached = MintedShareLinkCache.link(for: itemId) else { return }
    if let expiresAt = cached.expiresAt, expiresAt <= Date() {
      MintedShareLinkCache.remove(for: itemId)
      return
    }
    guard let url = URL(string: cached.urlString) else { return }
    phase = .ready(ActiveLink(shareId: cached.shareId, url: url, expiresAt: cached.expiresAt))
  }

  private func createLink() {
    guard let source = resolvedSource else { return }
    phase = .creating
    let expiresAt = expiry.date
    Task {
      do {
        let mediaItemId = try await audiobookshelfService.fetchMediaItemId(
          forLibraryItemId: source.itemId,
          connectionId: source.connectionId
        )
        let share = try await audiobookshelfService.createMediaItemShare(
          mediaItemId: mediaItemId,
          slug: Self.makeSlug(from: item.title),
          expiresAt: expiresAt,
          connectionId: source.connectionId
        )
        let url = try audiobookshelfService.shareWebURL(
          slug: share.slug,
          connectionId: source.connectionId
        )
        let link = ActiveLink(shareId: share.id, url: url, expiresAt: expiresAt)
        MintedShareLinkCache.store(
          MintedShareLinkCache.Entry(
            shareId: link.shareId,
            urlString: url.absoluteString,
            expiresAt: expiresAt
          ),
          for: source.itemId
        )
        // A successful mint on a search-resolved match is user confirmation the match is
        // right (the server title is shown in the footer) — record it as provenance so the
        // row resolves directly next time and progress reporting picks the book up too.
        if matchedServerTitle != nil {
          mediaServerSourceStore.setSource(source, for: item.relativePath)
        }
        phase = .ready(link)
      } catch {
        errorMessage = error.localizedDescription
        phase = .setup
      }
    }
  }

  private func revokeLink(_ link: ActiveLink) {
    guard let source = resolvedSource else { return }
    phase = .revoking(link)
    Task {
      do {
        try await audiobookshelfService.deleteMediaItemShare(
          shareId: link.shareId,
          connectionId: source.connectionId
        )
        MintedShareLinkCache.remove(for: source.itemId)
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
