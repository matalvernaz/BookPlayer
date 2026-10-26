//
//  SoundBoothLibraryItem.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Foundation

/// A row of the SoundBooth library (fork): a series or season to open, or a book or episode to
/// download. A title has chapters, which a download brings in as one book.
struct SoundBoothLibraryItem: Identifiable, Hashable {
  enum Kind: String {
    case series
    case group  // a season
    case book
    case episode
  }

  let id: String
  let displayName: String
  let kind: Kind
  /// SoundBooth's own format value (`audiobook`, `cinematic`, `immersion`, `bonus`), nil for series and
  /// seasons. It tells apart titles with the same name: the same story is sold in several formats
  let format: String?
  /// The series this title belongs to, when known: it leads the download's folder name, so two titles
  /// that share a name never become one book
  let seriesName: String?
  /// When an unreleased episode comes out, nil once it's out. Season bundles sell ahead of their weekly
  /// episodes, which show before they can be downloaded
  let releaseDate: Date?

  var isReleased: Bool { releaseDate == nil }
  /// Released books and episodes download; series and seasons open
  var isDownloadable: Bool { (kind == .book || kind == .episode) && isReleased }
  var isNavigable: Bool { kind == .series || kind == .group }

  /// The line under the title: its format, and when it comes out if it isn't out yet
  var detailLabel: String? {
    let releaseLabel = releaseDate.map {
      String(format: "soundbooth_releases_format".localized, $0.formatted(date: .abbreviated, time: .omitted))
    }
    let parts = [Self.formatDisplayName(format), releaseLabel].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// The level a series or season row opens, nil for titles
  var childNode: SoundBoothNode? {
    switch kind {
    case .series: return .series(id: id, name: displayName)
    case .group: return .season(id: id, name: displayName)
    case .book, .episode: return nil
    }
  }

  var symbolName: String {
    switch kind {
    case .series: "books.vertical"
    case .group: "rectangle.stack"
    case .book, .episode: "waveform"
    }
  }

  /// A series or season row
  init(id: String, displayName: String, kind: Kind) {
    self.id = id
    self.displayName = displayName
    self.kind = kind
    self.format = nil
    self.seriesName = nil
    self.releaseDate = nil
  }

  /// A row for an API element: an owned title, or an episode of an owned season bundle (which has no
  /// library entry of its own)
  init(raw: SoundBoothElement, isGroup: Bool = false, seriesName: String? = nil, now: Date = Date()) {
    self.id = raw.id
    self.displayName = raw.name
    if isGroup {
      self.kind = .group
    } else {
      self.kind = raw.subtype == "episode" ? .episode : .book
    }
    self.format = isGroup ? nil : raw.format.flatMap { $0.isEmpty ? nil : $0 }
    self.seriesName = seriesName
    if let releaseDate = raw.releaseDate, releaseDate > now {
      self.releaseDate = releaseDate
    } else {
      self.releaseDate = nil
    }
  }

  /// SoundBooth's format values as its storefront names them, in the user's language. A value this app
  /// doesn't know shows as itself rather than being hidden
  static func formatDisplayName(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    switch raw {
    case "audiobook": return "soundbooth_format_audiobook".localized
    case "cinematic": return "soundbooth_format_cinematic".localized
    case "immersion": return "soundbooth_format_immersion".localized
    case "bonus": return "soundbooth_format_bonus".localized
    default: return raw.capitalized
    }
  }

  static func == (lhs: SoundBoothLibraryItem, rhs: SoundBoothLibraryItem) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}
