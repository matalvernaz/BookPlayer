//
//  HummingbirdLibraryItem.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-05-18.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import Foundation

/// A single book entry from Hummingbird's `/bookshelf/list` or `/search` response.
/// Hummingbird pre-flattens books × formats into one entry per playable copy, so a
/// single book-id may appear multiple times (one per format). The downstream code
/// treats each entry as its own downloadable thing.
struct HummingbirdLibraryItem: Identifiable, Hashable {
  /// Composite id `"\(bookId)-\(format)"` so the same book in multiple formats
  /// doesn't collide as a List row.
  let id: String
  /// Hummingbird's node_id -- used as the bookmark/progress key on the server.
  let bookId: Int
  /// Format id from the format catalog. Carried through to /download path.
  let format: Int
  /// Display title (already includes the format suffix per Hummingbird's
  /// `_flatten_to_items` helper).
  let title: String
  /// Absolute URL the server suggests for download. Already includes the format
  /// + node_id + trailing-slash path.
  let downloadURL: URL
  /// Server-side loan expiry, or nil for libraries without a loan period
  /// (NNELS). When set, BookPlayer auto-deletes + auto-returns the book once
  /// the date passes.
  let dueDate: Date?

  init(
    bookId: Int,
    format: Int,
    title: String,
    downloadURL: URL,
    dueDate: Date? = nil
  ) {
    self.id = "\(bookId)-\(format)"
    self.bookId = bookId
    self.format = format
    self.title = title
    self.downloadURL = downloadURL
    self.dueDate = dueDate
  }
}

// MARK: - Decoding from /bookshelf/list and /search

extension HummingbirdLibraryItem {
  /// Hummingbird's `BookItem` schema as it appears in the JSON envelope of
  /// `/bookshelf/list` (`items: [...]`) and `/search` (`items: [...]`).
  struct APIItem: Codable {
    let id: Int
    let title: String
    let url: String
    /// ISO-8601 due date when the library has a loan period, otherwise nil.
    /// CodingKey maps the server's snake_case to a Swift-friendly name.
    let dueDate: String?

    enum CodingKeys: String, CodingKey {
      case id, title, url
      case dueDate = "due_date"
    }
  }
}
