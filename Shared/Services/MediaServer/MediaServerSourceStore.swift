//
//  MediaServerSourceStore.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-05-17.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import Foundation

/// Persists which library items came from a media server integration so that playback progress can
/// be reported back to that server.
///
/// The store has two stages because the eventual `relativePath` of a downloaded item isn't known
/// until the download finishes and `SingleFileDownloadService` writes the file to disk under the
/// server-supplied filename. So integration view models register at *download initiation* using
/// the request URL, and `MediaServerSourceTracker` upgrades the entry to a `relativePath`-keyed
/// record when the download completes.
///
/// State is persisted to UserDefaults so a process restart mid-download doesn't lose the pending
/// mapping, and so previously-imported integration items remember their origin across launches.
public final class MediaServerSourceStore {
  /// Single-writer queue serializes UserDefaults reads/writes. The store is safe to call from any
  /// thread; callers don't need to hop to a specific queue.
  private let queue = DispatchQueue(label: "com.bookplayer.media-server-source-store")
  private let userDefaults: UserDefaults

  private enum Key {
    /// `[relativePath: MediaServerSourceInfo]` — permanent record per imported library item.
    static let resolved = "MediaServerSourceStore.resolved"
    /// `[downloadURLString: MediaServerSourceInfo]` — in-flight downloads waiting for their
    /// final filename. Cleared on completion (success or failure).
    static let pending = "MediaServerSourceStore.pending"
  }

  public init(userDefaults: UserDefaults = .standard) {
    self.userDefaults = userDefaults
  }

  // MARK: - Resolved (relativePath-keyed)

  /// Returns the source info for an imported library item, or `nil` if the item was not imported
  /// from a media server integration (or if its source mapping was cleared).
  public func source(for relativePath: String) -> MediaServerSourceInfo? {
    queue.sync {
      readResolved()[relativePath]
    }
  }

  /// Snapshot of every imported integration item's source info, keyed by relativePath. Used by
  /// the loan-expiry scanner (and similar maintenance sweeps) so they don't have to iterate
  /// `LibraryService` and re-check provenance per item.
  public var allResolved: [String: MediaServerSourceInfo] {
    queue.sync { readResolved() }
  }

  /// Atomically reads and removes the mapping for `relativePath`, returning it. Used by the
  /// import pipeline when a container file (a downloaded zip) is replaced by its extracted
  /// contents — the container's entry must not outlive the container, and its provenance is
  /// re-recorded against each extracted file instead.
  public func takeSource(for relativePath: String) -> MediaServerSourceInfo? {
    queue.sync {
      var resolved = readResolved()
      guard let info = resolved.removeValue(forKey: relativePath) else { return nil }
      writeResolved(resolved)
      return info
    }
  }

  /// Returns the source every mapped descendant of `folderRelativePath` agrees on, or `nil`
  /// when the folder has no mapped descendants or they disagree on origin. Provenance is
  /// recorded per file, so a volume assembled from one multi-file download has no entry of
  /// its own — folder-level features (share links) resolve it through the children instead.
  /// Disagreement means the folder mixes items from different server books (e.g. a playlist),
  /// which has no single origin to resolve to.
  public func unanimousDescendantSource(under folderRelativePath: String) -> MediaServerSourceInfo? {
    queue.sync {
      let prefix = folderRelativePath + "/"
      let descendants = readResolved().filter { $0.key.hasPrefix(prefix) }
      guard let first = descendants.first?.value else { return nil }
      let allAgree = descendants.values.allSatisfy {
        $0.kind == first.kind && $0.connectionId == first.connectionId && $0.itemId == first.itemId
      }
      return allAgree ? first : nil
    }
  }

  /// Drops the source mapping for a library item. Called when the user deletes an item so we
  /// don't keep reporting progress for something that no longer exists locally.
  public func removeSource(for relativePath: String) {
    queue.sync {
      var resolved = readResolved()
      guard resolved.removeValue(forKey: relativePath) != nil else { return }
      writeResolved(resolved)
    }
  }

  /// Re-keys every source mapping under `oldRelativePath` — the item itself and, when a
  /// folder moves, its descendants — to live under `newRelativePath`. Must be called
  /// whenever a mapped item's `relativePath` changes; otherwise the move silently severs
  /// progress reporting and loan tracking for the item.
  public func moveSources(from oldRelativePath: String, to newRelativePath: String) {
    queue.sync {
      var resolved = readResolved()
      var changed = false
      for (key, info) in resolved {
        let newKey: String
        if key == oldRelativePath {
          newKey = newRelativePath
        } else if key.hasPrefix(oldRelativePath + "/") {
          newKey = newRelativePath + key.dropFirst(oldRelativePath.count)
        } else {
          continue
        }
        resolved.removeValue(forKey: key)
        resolved[newKey] = info
        changed = true
      }
      if changed { writeResolved(resolved) }
    }
  }

  /// Records a source mapping directly. Used when the relativePath is already known at import
  /// time (e.g. tests, or future code paths that bypass `SingleFileDownloadService`).
  public func setSource(_ info: MediaServerSourceInfo, for relativePath: String) {
    queue.sync {
      var resolved = readResolved()
      resolved[relativePath] = info
      writeResolved(resolved)
    }
  }

  // MARK: - Pending (downloadURL-keyed)

  /// Records that an in-flight download is sourced from a media server. The corresponding
  /// `finalize(...)` call must follow once the file lands on disk and we know its filename, or
  /// the entry will eventually be evicted by `pruneStalePending`.
  public func registerPendingDownload(_ url: URL, info: MediaServerSourceInfo) {
    queue.sync {
      var pending = readPending()
      pending[url.absoluteString] = info
      writePending(pending)
    }
  }

  /// Promotes a pending entry to a permanent `relativePath` mapping. Called by
  /// `MediaServerSourceTracker` on download success.
  public func finalizePendingDownload(_ url: URL, relativePath: String) {
    queue.sync {
      var pending = readPending()
      guard let info = pending.removeValue(forKey: url.absoluteString) else { return }
      writePending(pending)

      var resolved = readResolved()
      resolved[relativePath] = info
      writeResolved(resolved)
    }
  }

  /// Drops a pending entry without promoting it. Called on download failure / cancellation.
  public func removePendingDownload(_ url: URL) {
    queue.sync {
      var pending = readPending()
      guard pending.removeValue(forKey: url.absoluteString) != nil else { return }
      writePending(pending)
    }
  }

  // MARK: - Persistence helpers

  private func readResolved() -> [String: MediaServerSourceInfo] {
    guard let data = userDefaults.data(forKey: Key.resolved) else { return [:] }
    return (try? JSONDecoder().decode([String: MediaServerSourceInfo].self, from: data)) ?? [:]
  }

  private func writeResolved(_ map: [String: MediaServerSourceInfo]) {
    if let data = try? JSONEncoder().encode(map) {
      userDefaults.set(data, forKey: Key.resolved)
    }
  }

  private func readPending() -> [String: MediaServerSourceInfo] {
    guard let data = userDefaults.data(forKey: Key.pending) else { return [:] }
    return (try? JSONDecoder().decode([String: MediaServerSourceInfo].self, from: data)) ?? [:]
  }

  private func writePending(_ map: [String: MediaServerSourceInfo]) {
    if let data = try? JSONEncoder().encode(map) {
      userDefaults.set(data, forKey: Key.pending)
    }
  }
}
