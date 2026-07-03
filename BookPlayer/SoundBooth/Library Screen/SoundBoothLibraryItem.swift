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
    case book
    case episode
    case group
  }

  let id: String
  let displayName: String
  let kind: Kind
  let coverURL: URL?

  var isDownloadable: Bool { kind != .group }
  var isNavigable: Bool { kind == .group }

  var placeholderImageName: String {
    switch kind {
    case .book, .episode: "waveform"
    case .group: "rectangle.stack"
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
