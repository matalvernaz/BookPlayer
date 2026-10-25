//
//  MediaServerDownloadFolders.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Foundation

/// Folders in Documents for multi-file media-server downloads (fork): Audiobookshelf share links and
/// Hummingbird DAISY books. Each download takes a folder nobody else holds and records its
/// provenance there, so the import that brings the folder into the library carries it.
enum MediaServerDownloadFolders {
  /// Names are capped well under the file system's 255 bytes, leaving room for the import's `-1` on
  /// a clash and a number added here
  static let maxNameBytes = 200

  /// A title made safe as one folder name (upstream's stream-import sanitizer), else `fallback`
  static func folderName(title: String, fallback: String) -> String {
    limited(MediaServerFileNames.sanitize(title.isEmpty ? fallback : title))
  }

  /// Takes a folder in Documents named `base` for one download and records `info` there. Another
  /// download with the same name may be running or waiting to be imported, so the first name nobody
  /// holds wins: `Dune`, `Dune 2`, `Dune 3`… A folder is held when it's in Documents, when a queued
  /// download fills it (`folderInUse`), or when another download recorded it. Not a random suffix:
  /// the folder's name becomes the book's title.
  static func reserveFolder(
    named base: String,
    info: MediaServerSourceInfo,
    store: MediaServerSourceStore,
    folderInUse: (String) -> Bool
  ) -> String {
    let documents = DataManager.getDocumentsFolderURL()
    var candidate = base
    var number = 2
    while folderInUse(candidate)
      || store.hasLandedSource(at: candidate)
      || FileManager.default.fileExists(atPath: documents.appendingPathComponent(candidate).path)
    {
      candidate = "\(base) \(number)"
      number += 1
    }

    store.registerLandingSource(info, at: candidate)
    return candidate
  }

  /// Names for the files of one book, in the order they play: by their paths in the book
  /// (`localizedStandardCompare`, so "2" comes before "12"), flattened to one level and made unique
  /// the way stream imports name a volume's books, then numbered. The import sorts a folder by name,
  /// and the number makes that sort follow this order whatever flattening did to the names.
  static func numberedFileNames(forPaths paths: [String]) -> [(path: String, fileName: String)] {
    let ordered = paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    let flattened = MediaServerFileNames.volumeChildFileNames(ordered)
    let width = max(3, String(ordered.count).count)

    return zip(ordered, flattened).enumerated().map { index, pair in
      let (stem, fileExtension) = MediaServerFileNames.splitExtension(pair.1)
      let number = String(format: "%0\(width)d", index + 1)
      let name = fileExtension.isEmpty || stem == pair.1
        ? "\(number) - \(limited(pair.1))"
        : "\(number) - \(limited(stem)).\(fileExtension)"
      return (pair.0, name)
    }
  }

  /// `name` cut at a whole character to fit `maxNameBytes`
  static func limited(_ name: String) -> String {
    var result = ""
    for character in name {
      guard result.utf8.count + String(character).utf8.count <= maxNameBytes else { break }
      result.append(character)
    }
    return result
  }
}
