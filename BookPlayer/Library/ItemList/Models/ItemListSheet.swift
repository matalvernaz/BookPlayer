//
//  ItemListSheet.swift
//  BookPlayer
//
//  Created by Gianni Carlo on 4/10/25.
//  Copyright © 2025 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Foundation

/// Represents all possible sheet types in ItemListView
enum ItemListSheet: Identifiable {
  case itemDetails(SimpleLibraryItem)
  case queuedTasks
  case foldersSelection
  case libraryOptions
  /// `sourceInfo` is `nil` when the item has no recorded provenance (imports that predate
  /// tracking); the sheet then resolves the book against the active ABS connection by title.
  case shareLink(SimpleLibraryItem, MediaServerSourceInfo?)

  var id: String {
    switch self {
    case .itemDetails(let item):
      return "itemDetails-\(item.id)"
    case .queuedTasks:
      return "queuedTasks"
    case .foldersSelection:
      return "foldersSelection"
    case .libraryOptions:
      return "libraryOptions"
    case .shareLink(let item, _):
      return "shareLink-\(item.id)"
    }
  }
}
