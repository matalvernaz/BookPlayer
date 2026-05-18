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
}

/// Provenance for a library item that originated from a media server integration. Persisted by
/// `MediaServerSourceStore` and consumed at playback time to push progress back to the source
/// server. Carries enough info to find the still-valid connection (`connectionId`) and address the
/// server-side item (`itemId`); the connection's URL and credentials are looked up live so a user
/// editing a server URL or rotating an API token doesn't strand previously-imported items.
///
/// `dueDate` is set for items downloaded from a server that enforces loan periods (eg. CELA,
/// Bookshare). NNELS has no loan period so it's `nil`. A periodic scanner uses it to auto-delete
/// + auto-return expired loans without the user having to track deadlines.
public struct MediaServerSourceInfo: Codable, Hashable {
  public let kind: MediaServerKind
  /// Stable ID of the `AudiobookShelfConnectionData` / `JellyfinConnectionData` /
  /// `HummingbirdConnectionData` that produced this import. Resolved against the live connections
  /// list at progress-report time.
  public let connectionId: String
  /// Server-side item identifier (ABS library item id, Jellyfin item id, Hummingbird node_id).
  public let itemId: String
  /// ISO-8601 wall-clock instant at which the server-side loan expires, or `nil` for libraries
  /// with no loan period.
  public let dueDate: Date?

  public init(
    kind: MediaServerKind,
    connectionId: String,
    itemId: String,
    dueDate: Date? = nil
  ) {
    self.kind = kind
    self.connectionId = connectionId
    self.itemId = itemId
    self.dueDate = dueDate
  }
}
