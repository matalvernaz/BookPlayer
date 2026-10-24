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
  /// A public share link for an Audiobookshelf book (fork). `nil` source: nothing records which
  /// server book it is, so the sheet finds it on the active server by title
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
