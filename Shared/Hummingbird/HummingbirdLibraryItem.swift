//
//  HummingbirdLibraryItem.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-05-18.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import Foundation

/// One entry of Hummingbird's `/bookshelf/list` or `/search` (fork). Hummingbird flattens books ×
/// formats into one entry per playable copy, so a book id can appear once per format; each entry is
/// its own downloadable thing.
public struct HummingbirdLibraryItem: Identifiable, Hashable {
  /// `"\(bookId)-\(format)"`, so the same book in two formats doesn't collide as a row
  public let id: String
  /// Hummingbird's node_id: the key of the book on the server (bookmarks, returns)
  public let bookId: Int
  /// Format id from the server's format catalog, part of the download paths
  public let format: Int
  /// Display title, already carrying the format suffix the server adds
  public let title: String
  /// Where the server says to download this copy
  public let downloadURL: URL
  /// When the loan runs out, or nil for libraries without loan periods (NNELS). When set, the
  /// downloaded book is deleted and returned once the date passes.
  public let dueDate: Date?

  public init(
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

  /// Format ids BookPlayer can play, from hummingbird's `formats.yaml`. Text, braille and PDF
  /// editions are left out here; the server keeps listing them for clients that can use them.
  ///
  /// 1 DAISY 2.02 full text and audio, 2 DAISY 3 full text and audio, 4 MP3, 10 EPUB 3 full text
  /// and audio, 11 DAISY 2.02 audio, 13 DAISY 3 audio.
  public static let audioFormatIds: Set<Int> = [1, 2, 4, 10, 11, 13]

  public var isAudioFormat: Bool {
    Self.audioFormatIds.contains(format)
  }
}

// MARK: - Decoding from /bookshelf/list and /search

extension HummingbirdLibraryItem {
  /// Hummingbird's `BookItem` as it appears in `items` of `/bookshelf/list` and `/search`
  public struct APIItem: Codable {
    public let id: Int
    public let title: String
    public let url: String
    /// ISO-8601 due date when the library has loan periods
    public let dueDate: String?

    enum CodingKeys: String, CodingKey {
      case id, title, url
      case dueDate = "due_date"
    }
  }
}

// MARK: - DODP resource list (/resources/{fmt}/{node_id})

/// One file a book is made of, as DODP's `getContentResources` describes it and Hummingbird's
/// `/resources` endpoint lists it. The list is in the zip's storage order, which the DAISY
/// specifications don't make the reading order.
public struct DODPResource: Codable, Hashable {
  public let uri: String
  public let mimeType: String
  public let size: Int
  /// The file's path inside the book ("audio/01.mp3")
  public let localURI: String

  public init(uri: String, mimeType: String, size: Int, localURI: String) {
    self.uri = uri
    self.mimeType = mimeType
    self.size = size
    self.localURI = localURI
  }
}

/// What `/protocols/hummingbird/v1/resources/{fmt}/{node_id}` returns
public struct ResourcesResponse: Codable {
  public let contentId: String
  public let format: Int
  public let resources: [DODPResource]
}
