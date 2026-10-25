//
//  MediaServerDeletion.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Foundation

/// The server items a user's delete took out of the library (fork), so their servers can be told:
/// a Hummingbird loan goes back when its book is deleted. Read in two steps around the delete,
/// because `LibraryService.delete` drops the provenance of what it deletes.
enum MediaServerDeletion {
  /// The `.mediaServerItemsDeleted` key holding its `[MediaServerSourceInfo]`
  static let entriesKey = "entries"

  /// What a delete of `items` could take, read before it runs: each item's provenance and, for a
  /// folder, that of everything under it. A "folder only" delete leaves the folder's content in the
  /// library, so the folder's own entry isn't counted then.
  static func snapshot(
    of items: [SimpleLibraryItem],
    mode: DeleteMode,
    store: MediaServerSourceStore
  ) -> [MediaServerSourceInfo] {
    var entries = [MediaServerSourceInfo]()
    for item in items {
      for (relativePath, info) in store.sources(under: item.relativePath) {
        if mode == .shallow, item.type != .book, relativePath == item.relativePath { continue }
        entries.append(info)
      }
    }
    return entries
  }

  /// The server items of `snapshot` that no library item comes from anymore, once each. Read after
  /// the delete, whether or not it threw: what it didn't reach (the rest of a batch that failed
  /// partway, the children a "folder only" delete moved out) keeps its provenance, and so does
  /// another copy of the same book.
  static func gone(
    from snapshot: [MediaServerSourceInfo],
    store: MediaServerSourceStore
  ) -> [MediaServerSourceInfo] {
    let remaining = Set(store.allResolved.values.map(Identity.init))
    var seen = Set<Identity>()

    return snapshot.filter { info in
      let identity = Identity(info)
      guard !remaining.contains(identity) else { return false }
      return seen.insert(identity).inserted
    }
  }

  /// Sends `gone(from:store:)` to whoever returns loans, when there's anything in it
  static func postGone(from snapshot: [MediaServerSourceInfo], store: MediaServerSourceStore) {
    let entries = gone(from: snapshot, store: store)
    guard !entries.isEmpty else { return }

    NotificationCenter.default.post(name: .mediaServerItemsDeleted, object: nil, userInfo: [entriesKey: entries])
  }

  /// One item on one server, whatever else its entries say
  private struct Identity: Hashable {
    let kind: MediaServerKind
    let connectionId: String
    let itemId: String

    init(_ info: MediaServerSourceInfo) {
      self.kind = info.kind
      self.connectionId = info.connectionId
      self.itemId = info.itemId
    }
  }
}
