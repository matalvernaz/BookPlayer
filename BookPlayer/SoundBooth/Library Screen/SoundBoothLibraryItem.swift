//
//  SoundBoothLibraryItem.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import Foundation

/// A row in the SoundBooth owned-library browser. Wraps a `SoundBoothLibraryElement`
/// (a purchased book/episode, or a season Group). Books and episodes are downloadable
/// (each is a multi-chapter item resolved via `item-resources`); Groups are navigable
/// containers (a season's episodes).
struct SoundBoothLibraryItem: IntegrationLibraryItemProtocol {
  enum Kind: String {
    case series
    case group  // a season
    case book
    case episode
  }

  let id: String
  let displayName: String
  let kind: Kind
  let coverURL: URL?
  /// Human-readable production format ("Cinematic Audio", "Audiobook", …), nil for containers.
  /// Distinguishes same-named titles — SoundBooth sells the same story in multiple formats.
  let formatLabel: String?
  /// Name of the series this title belongs to, when known. Prefixed onto the download folder so
  /// two different products that share a display name can't collide into one bound book.
  let seriesName: String?
  /// False for preorder-season episodes whose release date is still in the future.
  let isReleased: Bool
  /// "Releases <date>" for unreleased episodes, nil otherwise.
  let releaseDateLabel: String?

  /// Released books/episodes are downloadable leaves; series and seasons are navigable containers.
  var isDownloadable: Bool { (kind == .book || kind == .episode) && isReleased }
  var isNavigable: Bool { kind == .series || kind == .group }

  /// Secondary line under the title: production format, plus release date when not yet out.
  var detailLabel: String? {
    let parts = [formatLabel, releaseDateLabel].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// The hierarchy node a navigable row drills into (nil for downloadable leaves).
  var childNode: SoundBoothNode? {
    switch kind {
    case .series: return .series(id: id, name: displayName)
    case .group: return .season(id: id, name: displayName)
    case .book, .episode: return nil
    }
  }

  var placeholderImageName: String {
    switch kind {
    case .series: "books.vertical"
    case .group: "rectangle.stack"
    case .book, .episode: "waveform"
    }
  }

  init(id: String, displayName: String, kind: Kind, coverURL: URL? = nil) {
    self.id = id
    self.displayName = displayName
    self.kind = kind
    self.coverURL = coverURL
    self.formatLabel = nil
    self.seriesName = nil
    self.isReleased = true
    self.releaseDateLabel = nil
  }

  init(element: SoundBoothLibraryElement, seriesName: String? = nil) {
    self.init(raw: element.element, isGroup: element.isGroup, seriesName: seriesName)
  }

  /// Build a row from a bare API element — used both for owned library items and for episodes of
  /// an owned season bundle fetched via `u/items/list` (which have no library wrapper).
  init(raw: SoundBoothElement, isGroup: Bool = false, seriesName: String? = nil) {
    self.id = raw.id
    self.displayName = raw.name
    if isGroup {
      self.kind = .group
    } else {
      self.kind = raw.subtype == "episode" ? .episode : .book
    }
    self.coverURL = raw.coverURL
    self.formatLabel = Self.formatDisplayName(raw.format)
    self.seriesName = seriesName
    self.isReleased = raw.isReleased
    self.releaseDateLabel = raw.isReleased
      ? nil
      : raw.releaseDate.map { "Releases " + $0.formatted(date: .abbreviated, time: .omitted) }
  }

  /// Display name for a raw API format value. Known values get proper storefront names; anything
  /// new falls back to the capitalized raw value rather than hiding it.
  static func formatDisplayName(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    switch raw {
    case "audiobook": return "Audiobook"
    case "cinematic": return "Cinematic Audio"
    case "immersion": return "Immersion"
    case "bonus": return "Bonus"
    default: return raw.capitalized
    }
  }
}

extension SoundBoothLibraryItem: Hashable {
  static func == (lhs: SoundBoothLibraryItem, rhs: SoundBoothLibraryItem) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}
