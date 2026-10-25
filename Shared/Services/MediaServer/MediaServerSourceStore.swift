//
//  MediaServerSourceStore.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-05-17.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import Foundation

/// Remembers which library items were downloaded from a media server, and from which server item,
/// so they can be addressed there again (share links, progress reporting).
///
/// A download's library path isn't known when it starts, so an entry moves through three stages:
///
/// 1. **pending**, keyed by the download's request URL: registered by the connection service that
///    builds the request.
/// 2. **landed**, keyed by the path the file got under the Documents folder: written when
///    `SingleFileDownloadService` has moved the file there (`MediaServerSourceTracker`), or up front
///    for a folder download whose folder name is chosen by the caller.
/// 3. **resolved**, keyed by the library `relativePath`: written by `ImportOperation` when it brings
///    the file into the library, under the name it really got there (a clash renames it).
///
/// Resolved entries follow the item afterwards: `LibraryService` re-keys them when items move or a
/// folder is renamed, and drops them when items are deleted. The store is not transactional with
/// Core Data: it's updated as each file operation succeeds, so a failed library save afterwards
/// (which `saveContext` turns into a crash anyway) can leave the two out of step.
///
/// Everything is persisted to UserDefaults (JSON data per stage), so a restart between the stages
/// loses nothing. The `resolved` and `pending` keys and shapes are the July 2026 ones.
///
/// What it reads is kept in memory until its next write: the library asks about every item on
/// screen each time it draws its menus. So the app uses one store, ``shared`` (`AppServices` and the
/// environment's default both hand it out); another instance on the same defaults would read stale
/// data. Tests make their own on a suite.
public final class MediaServerSourceStore: @unchecked Sendable {
  /// The app's store, on the standard defaults
  public static let shared = MediaServerSourceStore(userDefaults: .standard)

  /// Serializes every read-modify-write (all state goes through it, hence `@unchecked Sendable`):
  /// the store is called from the main thread, URLSession delegate queues and Core Data background
  /// contexts.
  private let queue = DispatchQueue(label: "com.bookplayer.media-server-source-store")
  private let userDefaults: UserDefaults
  /// Each stage's map as last read or written, by defaults key
  private var cache = [String: [String: MediaServerSourceInfo]]()
  /// What the mapped items under each folder agree on, built from the resolved map when asked
  private var folderSummaries: [String: FolderSummary]?

  private enum FolderSummary {
    case unanimous(MediaServerSourceInfo)
    case mixed
  }

  enum Key {
    /// `[relativePath: MediaServerSourceInfo]`: one entry per library item that came from a server.
    static let resolved = "MediaServerSourceStore.resolved"
    /// `[requestURLString: MediaServerSourceInfo]`: downloads that haven't been saved yet.
    static let pending = "MediaServerSourceStore.pending"
    /// `[documentsRelativePath: MediaServerSourceInfo]`: files saved in Documents (or expected
    /// there) that haven't been imported yet.
    static let landed = "MediaServerSourceStore.landed"
  }

  public init(userDefaults: UserDefaults) {
    self.userDefaults = userDefaults
  }

  // MARK: - Resolved (library relativePath)

  /// The provenance of a library item, or `nil` when it wasn't downloaded from a media server.
  public func source(for relativePath: String) -> MediaServerSourceInfo? {
    queue.sync {
      read(Key.resolved)[relativePath]
    }
  }

  /// Every library item's provenance, keyed by relativePath.
  public var allResolved: [String: MediaServerSourceInfo] {
    queue.sync { read(Key.resolved) }
  }

  /// The entries of the item at `relativePath` and, for a folder, of everything under it
  public func sources(under relativePath: String) -> [String: MediaServerSourceInfo] {
    queue.sync {
      read(Key.resolved).filter { Self.isSelfOrDescendant($0.key, of: relativePath) }
    }
  }

  /// Records an item's provenance directly, when its library path is already known.
  public func setSource(_ info: MediaServerSourceInfo, for relativePath: String) {
    queue.sync {
      var resolved = read(Key.resolved)
      resolved[relativePath] = info
      write(resolved, to: Key.resolved)
    }
  }

  /// The provenance every mapped item under `folderRelativePath` agrees on, or `nil` when the folder
  /// has no mapped descendants or they disagree. Provenance is recorded per file, so a book
  /// assembled from one multi-file download has no entry of its own; a folder mixing books from
  /// different server items (a playlist) has no single origin.
  public func unanimousDescendantSource(under folderRelativePath: String) -> MediaServerSourceInfo? {
    queue.sync {
      guard case .unanimous(let info) = summaries()[folderRelativePath] else { return nil }
      return info
    }
  }

  /// Re-keys the entry of the item at `oldRelativePath` and, for a folder, every entry under it.
  /// Call it with the path the item had before it moved.
  public func moveSources(from oldRelativePath: String, to newRelativePath: String) {
    guard oldRelativePath != newRelativePath else { return }

    queue.sync {
      var resolved = read(Key.resolved)
      guard Self.rekey(&resolved, from: oldRelativePath, to: newRelativePath) else { return }
      write(resolved, to: Key.resolved)
    }
  }

  /// Drops the entry of the item at `relativePath` and every entry under it.
  public func removeSources(under relativePath: String) {
    queue.sync {
      var resolved = read(Key.resolved)
      let before = resolved.count
      resolved = resolved.filter { !Self.isSelfOrDescendant($0.key, of: relativePath) }
      guard resolved.count != before else { return }
      write(resolved, to: Key.resolved)
    }
  }

  // MARK: - Pending (request URL)

  /// Records that the download of `url` comes from a media server. Its file name isn't known until
  /// the download is saved (`landPendingDownload`).
  public func registerPendingDownload(_ url: URL, info: MediaServerSourceInfo) {
    queue.sync {
      var pending = read(Key.pending)
      pending[url.absoluteString] = info
      write(pending, to: Key.pending)
    }
  }

  /// Drops a download that failed. Only ever touches the pending stage: a download that was already
  /// saved keeps its landed entry, whatever error arrives for it later.
  public func removePendingDownload(_ url: URL) {
    queue.sync {
      var pending = read(Key.pending)
      guard pending.removeValue(forKey: url.absoluteString) != nil else { return }
      write(pending, to: Key.pending)
    }
  }

  /// Moves the pending entry of `url` to the path its file was saved at under Documents.
  public func landPendingDownload(_ url: URL, at documentsRelativePath: String) {
    queue.sync {
      var pending = read(Key.pending)
      guard let info = pending.removeValue(forKey: url.absoluteString) else { return }
      write(pending, to: Key.pending)

      var landed = read(Key.landed)
      landed[documentsRelativePath] = info
      write(landed, to: Key.landed)
    }
  }

  // MARK: - Landed (path under Documents)

  /// Records the provenance of a download whose path under Documents is chosen before it starts:
  /// a multi-file download into a named folder.
  public func registerLandingSource(_ info: MediaServerSourceInfo, at documentsRelativePath: String) {
    queue.sync {
      var landed = read(Key.landed)
      landed[documentsRelativePath] = info
      write(landed, to: Key.landed)
    }
  }

  /// Whether an entry is recorded at exactly `documentsRelativePath`: a folder another download
  /// has already taken.
  public func hasLandedSource(at documentsRelativePath: String) -> Bool {
    queue.sync {
      read(Key.landed)[documentsRelativePath] != nil
    }
  }

  /// Removes and returns the landed entry at exactly `documentsRelativePath`. Used for a downloaded
  /// zip, whose entry goes to the files extracted from it.
  public func takeLandedSource(at documentsRelativePath: String) -> MediaServerSourceInfo? {
    queue.sync {
      var landed = read(Key.landed)
      guard let info = landed.removeValue(forKey: documentsRelativePath) else { return nil }
      write(landed, to: Key.landed)
      return info
    }
  }

  /// Brings the landed entries of an item imported from Documents into the library: the entry at
  /// `documentsRelativePath` and, for a folder, every entry under it, re-keyed to the library path
  /// the import gave it. A file imported without an entry changes nothing.
  public func resolveLandedSources(from documentsRelativePath: String, to libraryRelativePath: String) {
    queue.sync {
      var landed = read(Key.landed)
      let arriving = landed.filter { Self.isSelfOrDescendant($0.key, of: documentsRelativePath) }
      guard !arriving.isEmpty else { return }

      landed = landed.filter { !Self.isSelfOrDescendant($0.key, of: documentsRelativePath) }
      write(landed, to: Key.landed)

      var resolved = read(Key.resolved)
      for (path, info) in arriving {
        resolved[libraryRelativePath + path.dropFirst(documentsRelativePath.count)] = info
      }
      write(resolved, to: Key.resolved)
    }
  }

  /// Drops the landed entries at and under `documentsRelativePath`: the file was discarded before it
  /// was imported, so a later file with the same name mustn't inherit them.
  public func removeLandedSources(under documentsRelativePath: String) {
    queue.sync {
      var landed = read(Key.landed)
      let before = landed.count
      landed = landed.filter { !Self.isSelfOrDescendant($0.key, of: documentsRelativePath) }
      guard landed.count != before else { return }
      write(landed, to: Key.landed)
    }
  }

  // MARK: - Helpers

  /// `url`'s path under the Documents folder (the landed stage's key), or `nil` when it isn't under
  /// it. Not `URL.relativePath(to:)`, which hands back the whole path for a URL outside the base.
  public static func documentsRelativePath(of url: URL) -> String? {
    relativePath(of: url, under: DataManager.getDocumentsFolderURL())
  }

  /// Symlinks are resolved on both sides: the app container is reached through /private/var and
  /// /var alike.
  static func relativePath(of url: URL, under base: URL) -> String? {
    let basePath = base.resolvingSymlinksInPath().standardizedFileURL.path
    let path = url.resolvingSymlinksInPath().standardizedFileURL.path
    guard path.hasPrefix(basePath + "/") else { return nil }

    return String(path.dropFirst(basePath.count + 1))
  }

  /// Every folder that has mapped items under it, at any depth, with what they agree on
  private func summaries() -> [String: FolderSummary] {
    if let folderSummaries { return folderSummaries }

    var summaries = [String: FolderSummary]()
    for (path, info) in read(Key.resolved) {
      let components = path.split(separator: "/")
      var ancestor = ""
      for component in components.dropLast() {
        ancestor = ancestor.isEmpty ? String(component) : ancestor + "/" + String(component)
        switch summaries[ancestor] {
        case .none:
          summaries[ancestor] = .unanimous(info)
        case .unanimous(let agreed) where !Self.sameItem(agreed, info):
          summaries[ancestor] = .mixed
        case .unanimous, .mixed:
          break
        }
      }
    }

    folderSummaries = summaries
    return summaries
  }

  /// The same server item: what a folder's files must share to have one origin
  private static func sameItem(_ lhs: MediaServerSourceInfo, _ rhs: MediaServerSourceInfo) -> Bool {
    lhs.kind == rhs.kind && lhs.connectionId == rhs.connectionId && lhs.itemId == rhs.itemId
  }

  private static func isSelfOrDescendant(_ path: String, of ancestor: String) -> Bool {
    path == ancestor || path.hasPrefix(ancestor + "/")
  }

  /// Re-keys `oldPath` and its descendants in `map`; returns whether anything moved
  private static func rekey(
    _ map: inout [String: MediaServerSourceInfo],
    from oldPath: String,
    to newPath: String
  ) -> Bool {
    let moving = map.filter { isSelfOrDescendant($0.key, of: oldPath) }
    guard !moving.isEmpty else { return false }

    for path in moving.keys {
      map.removeValue(forKey: path)
    }
    for (path, info) in moving {
      map[newPath + path.dropFirst(oldPath.count)] = info
    }
    return true
  }

  private func read(_ key: String) -> [String: MediaServerSourceInfo] {
    if let cached = cache[key] { return cached }

    let map = userDefaults.data(forKey: key)
      .flatMap { try? JSONDecoder().decode([String: MediaServerSourceInfo].self, from: $0) } ?? [:]
    cache[key] = map
    return map
  }

  private func write(_ map: [String: MediaServerSourceInfo], to key: String) {
    guard let data = try? JSONEncoder().encode(map) else { return }
    userDefaults.set(data, forKey: key)
    cache[key] = map
    if key == Key.resolved {
      folderSummaries = nil
    }
  }
}
