//
//  MediaServerSourceInfo.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-05-17.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import Foundation

/// Which media server an integration-sourced library item came from.
public enum MediaServerKind: String, Codable, Hashable {
  case audiobookshelf
  case jellyfin
  case hummingbird
  case soundbooth
}

/// Provenance for a library item that was downloaded from a media server integration. Persisted by
/// `MediaServerSourceStore` and read whenever the item has to be addressed on its server again
/// (share links, progress reporting). Carries enough to find the still-valid connection
/// (`connectionId`) and the server-side item (`itemId`); the connection's URL and credentials are
/// looked up live, so editing a server URL or rotating a token doesn't strand earlier downloads.
///
/// `dueDate` is set for items downloaded from a server that enforces loan periods (eg. CELA,
/// Bookshare). NNELS has no loan period so it's `nil`. A periodic scanner uses it to auto-delete
/// + auto-return expired loans without the user having to track deadlines.
///
/// The persisted shape is the July 2026 one: stores written by those builds decode unchanged.
public struct MediaServerSourceInfo: Codable, Hashable {
  public let kind: MediaServerKind
  /// Stable ID of the connection (`AudiobookShelfConnectionData`, `JellyfinConnectionData`, …)
  /// that produced this download, resolved against the live connections when it's used.
  public let connectionId: String
  /// Server-side item identifier (ABS library item id, Jellyfin item id, Hummingbird node_id).
  public let itemId: String
  /// Wall-clock instant at which the server-side loan expires, or `nil` for libraries with no loan
  /// period.
  public let dueDate: Date?
  /// When `true`, the folder at this entry's path is promoted to a bound book once all its files
  /// have landed (`MediaServerBoundBookCompleter`). Set explicitly by the code that starts a
  /// multi-file download, so a folder-shaped import nobody asked to bind is never bound.
  /// `nil` decodes from entries that predate the field; treat as `false`.
  public let shouldBindFolder: Bool?
  /// Resume position (seconds into the bound book) carried over from the source server's account,
  /// applied once when the folder is auto-bound. `nil` = no server-side position to seed.
  public let seedTime: Double?
  /// The server's cross-device identity (`IntegrationHostIdentifiable.stableHostId`), for Audiobookshelf
  /// and Jellyfin downloads: what upstream's progress push resolves the connection by. Recorded when the
  /// download starts and kept current from the connection (`refreshHostIds`). `nil` for the other kinds
  /// and in entries that predate it.
  public let hostId: String?

  public init(
    kind: MediaServerKind,
    connectionId: String,
    itemId: String,
    dueDate: Date? = nil,
    shouldBindFolder: Bool? = nil,
    seedTime: Double? = nil,
    hostId: String? = nil
  ) {
    self.kind = kind
    self.connectionId = connectionId
    self.itemId = itemId
    self.dueDate = dueDate
    self.shouldBindFolder = shouldBindFolder
    self.seedTime = seedTime
    self.hostId = hostId
  }

  /// The same entry with another `hostId`
  public func with(hostId: String?) -> MediaServerSourceInfo {
    MediaServerSourceInfo(
      kind: kind,
      connectionId: connectionId,
      itemId: itemId,
      dueDate: dueDate,
      shouldBindFolder: shouldBindFolder,
      seedTime: seedTime,
      hostId: hostId
    )
  }
}
