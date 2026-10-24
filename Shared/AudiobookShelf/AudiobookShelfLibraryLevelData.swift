//
//  AudiobookShelfLibraryLevelData.swift
//  BookPlayer
//
//  Created by Gianni Carlo on 11/14/25.
//  Copyright © 2025 BookPlayer LLC. All rights reserved.
//

import Foundation

public enum AudiobookShelfBrowseCategory: String, CaseIterable, Codable, Hashable {
  case books
  case series
  case collections
  case authors
  case narrators

  public var title: String {
    switch self {
    case .books: "Books"
    case .series: "Series"
    case .collections: "Collections"
    case .authors: "Authors"
    case .narrators: "Narrators"
    }
  }
}

public enum AudiobookShelfItemFilterGroup: String, Codable, Hashable {
  case authors
  case series
  case narrators
}

public struct AudiobookShelfItemFilter: Codable, Hashable {
  public let group: AudiobookShelfItemFilterGroup
  public let value: String
  public let title: String

  public var queryValue: String {
    let base64Value = Data(value.utf8).base64EncodedString()
    return "\(group.rawValue).\(base64Value)"
  }
}

public enum AudiobookShelfLibraryViewSource: Equatable, Hashable {
  case libraries
  case books(libraryID: String, filter: AudiobookShelfItemFilter?)
  case entities(libraryID: String, category: AudiobookShelfBrowseCategory)
  case collection(id: String)
  /// One level of the library's on-disk folder tree (fork's Folders tab): `path` is relative to the
  /// library folder's root, empty for the top level, like the items' `relPath`.
  case folders(libraryID: String, path: String)

  public var libraryID: String {
    switch self {
    case .libraries: ""
    case .books(let libraryID, _): libraryID
    case .entities(let libraryID, _): libraryID
    case .collection(let id): id
    case .folders(let libraryID, _): libraryID
    }
  }
}

public enum AudiobookShelfLibraryLevelData: Equatable, Hashable {
  case library(source: AudiobookShelfLibraryViewSource, title: String)
  case details(data: AudiobookShelfLibraryItem)
}
