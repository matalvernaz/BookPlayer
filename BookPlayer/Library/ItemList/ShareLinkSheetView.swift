//
//  ShareLinkSheetView.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-07-21.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import SwiftUI

/// Creates and manages a public share link for an Audiobookshelf book (fork). The link opens the
/// book in BookPlayer for people who have the app (universal link), and the server's share page,
/// which plays in the browser, for everyone else. Nobody needs an account on the server: the link
/// is the access, until it expires.
struct ShareLinkSheetView: View {
  let item: SimpleLibraryItem
  /// `nil` when nothing records which server book this is (an import from before provenance was
  /// kept): the sheet then finds the book on the active Audiobookshelf server by title.
  let sourceInfo: MediaServerSourceInfo?

  @Environment(\.audiobookshelfService) private var audiobookshelfService
  @Environment(\.mediaServerSourceStore) private var mediaServerSourceStore
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var theme: ThemeViewModel

  enum Expiry: String, CaseIterable, Identifiable {
    case week
    case month
    case threeMonths
    case never

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
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
  /// The server book the sheet works on: `sourceInfo`, else what the title search found
  @State private var resolvedSource: MediaServerSourceInfo?
  /// "Title – Author" of a book found by title search, shown so the match can be checked before a
  /// link is made. `nil` when the book was known.
  @State private var matchedServerTitle: String?

  init(item: SimpleLibraryItem, sourceInfo: MediaServerSourceInfo?) {
    self.item = item
    self.sourceInfo = sourceInfo
    // Straight into the search when the book isn't known, rather than a frame of an inert Create
    _phase = State(initialValue: sourceInfo == nil ? .resolving : .setup)
  }

  private var isErrorPresented: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }

  var body: some View {
    List {
      switch phase {
      case .resolving:
        progressSection("share_link_resolving_message")
      case .unavailable(let message):
        unavailableSection(message)
      case .setup:
        setupSection
      case .creating:
        progressSection("share_link_creating_message")
      case .revoking:
        progressSection("share_link_revoking_message")
      case .ready(let link):
        readySections(link)
      }
    }
    .applyListStyle(with: theme, background: theme.systemBackgroundColor)
    .navigationTitle("share_link_title")
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

  private var setupSection: some View {
    ThemedSection {
      Picker(selection: $expiry) {
        ForEach(Expiry.allCases) { option in
          Text(option.titleKey).tag(option)
        }
      } label: {
        Text("share_link_expiry_title")
          .bpFont(.body)
          .foregroundStyle(theme.primaryColor)
      }
      Button {
        createLink()
      } label: {
        Label("share_link_create_button", systemImage: "link.badge.plus")
          .bpFont(.body)
          .foregroundStyle(theme.linkColor)
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

  private func unavailableSection(_ message: String) -> some View {
    ThemedSection {
      Text(message)
        .bpFont(.body)
        .foregroundStyle(theme.primaryColor)
    } header: {
      Text(item.title)
    }
  }

  @ViewBuilder
  private func readySections(_ link: ActiveLink) -> some View {
    ThemedSection {
      Text(link.url.absoluteString)
        .bpFont(.footnote)
        .foregroundStyle(theme.primaryColor)
        .textSelection(.enabled)
        .accessibilityLabel(Text("share_link_url_accessibility_label"))
        .accessibilityValue(link.url.absoluteString)
      ShareLink(item: link.url, message: Text(item.title)) {
        Label("share_link_share_button", systemImage: "square.and.arrow.up")
          .bpFont(.body)
          .foregroundStyle(theme.linkColor)
      }
      Button {
        UIPasteboard.general.url = link.url
        UIAccessibility.post(notification: .announcement, argument: "share_link_copied_announcement".localized)
      } label: {
        Label("share_link_copy_button", systemImage: "doc.on.doc")
          .bpFont(.body)
          .foregroundStyle(theme.linkColor)
      }
    } header: {
      Text(item.title)
    } footer: {
      Text(expiryDescription(for: link))
    }

    ThemedSection {
      Button(role: .destructive) {
        revokeLink(link)
      } label: {
        Label("share_link_revoke_button", systemImage: "trash")
          .bpFont(.body)
      }
    } footer: {
      Text("share_link_revoke_footer")
    }
  }

  private func progressSection(_ messageKey: LocalizedStringKey) -> some View {
    ThemedSection {
      HStack(spacing: 8) {
        ProgressView()
        Text(messageKey)
          .bpFont(.body)
          .foregroundStyle(theme.primaryColor)
      }
      .accessibilityElement(children: .combine)
    }
  }

  private func expiryDescription(for link: ActiveLink) -> String {
    guard let expiresAt = link.expiresAt else {
      return "share_link_no_expiry".localized
    }
    let formatted = DateFormatter.localizedString(from: expiresAt, dateStyle: .medium, timeStyle: .none)
    return String.localizedStringWithFormat("share_link_expires_format".localized, formatted)
  }

  // MARK: - Actions

  /// Finds a book with no recorded provenance on the active Audiobookshelf server by title, so
  /// older imports can be shared too. An exact title match (ignoring case and accents) in any book
  /// library wins, else the first result; the setup footer shows what was matched.
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
          phase = .unavailable(String.localizedStringWithFormat("share_link_no_match_format".localized, item.title))
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
        // Making a link from a title-search match confirms the match (it was shown in the footer):
        // record it, so the row finds the book directly next time
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
        UIAccessibility.post(notification: .announcement, argument: "share_link_revoked_announcement".localized)
        phase = .setup
      } catch {
        errorMessage = error.localizedDescription
        phase = .ready(link)
      }
    }
  }

  /// A slug safe in a URL path: a readable title prefix plus a random suffix. The suffix makes a
  /// clash with an unrelated share practically impossible, so a 409 from the server means "this
  /// book is already shared" rather than "this slug is taken".
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
        // Runs of "-" collapse, so punctuation-heavy titles stay readable
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

/// Where an item's Share Link row points, if anywhere.
enum ShareLinkSource: Equatable {
  /// The item's Audiobookshelf book is known
  case known(MediaServerSourceInfo)
  /// Nothing records which book this is, but an Audiobookshelf server is connected: the sheet finds
  /// it there by title
  case searchActiveServer
  /// No row
  case none

  /// In order: the item's own stream link (an `ExternalResource`, its server found by host), the
  /// provenance recorded for its downloaded file, the provenance a folder's files agree on, then a
  /// title search on the active server. An item that streams from or was downloaded from another
  /// kind of server, or streams from an Audiobookshelf server not saved here, gets no row: there's
  /// no server to make the link on. So does a book someone sent through a share link: it's on their
  /// server, not one of yours. A download whose server is no longer saved (removed, or re-added
  /// under a new id) is searched for by title like a book with no provenance, never sent to
  /// another server under its old item id.
  static func resolve(
    for item: SimpleLibraryItem,
    store: MediaServerSourceStore,
    connections: [AudiobookShelfConnectionData],
    hasActiveConnection: Bool
  ) -> ShareLinkSource {
    let links = item.externalResources?.mediaServerResources ?? []
    if let link = links.first(where: { $0.mediaServer == .audiobookshelf }),
      let connection = IntegrationHostResolver.connection(for: link.hostId, in: connections)
    {
      return .known(MediaServerSourceInfo(kind: .audiobookshelf, connectionId: connection.id, itemId: link.providerId))
    }
    guard links.isEmpty else { return .none }

    let direct = store.source(for: item.relativePath)
    let inherited = direct == nil && item.type != .book
      ? store.unanimousDescendantSource(under: item.relativePath)
      : nil
    if let recorded = direct ?? inherited {
      guard
        recorded.kind == .audiobookshelf,
        recorded.connectionId != SharedLinkImportService.sharedLinkConnectionId
      else { return .none }
      if connections.contains(where: { $0.id == recorded.connectionId }) {
        return .known(recorded)
      }
    }

    return hasActiveConnection ? .searchActiveServer : .none
  }
}

/// Share links this device made, keyed by ABS library item id, so reopening the sheet shows the
/// link (ABS allows one active share per book) and can revoke it. Local only: links made in the
/// ABS web interface don't show here.
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
