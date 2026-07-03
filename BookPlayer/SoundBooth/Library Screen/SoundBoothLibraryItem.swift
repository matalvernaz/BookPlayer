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

  /// Books/episodes are downloadable leaves; series and seasons are navigable containers.
  var isDownloadable: Bool { kind == .book || kind == .episode }
  var isNavigable: Bool { kind == .series || kind == .group }

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
  }

  init(element: SoundBoothLibraryElement) {
    self.id = element.element.id
    self.displayName = element.element.name
    if element.isGroup {
      self.kind = .group
    } else {
      self.kind = element.element.subtype == "episode" ? .episode : .book
    }
    self.coverURL = element.element.coverURL
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
