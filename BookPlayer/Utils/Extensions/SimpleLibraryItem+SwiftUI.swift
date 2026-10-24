//
//  SimpleLibraryItem+SwiftUI.swift
//  BookPlayer
//
//  Created by Gianni Carlo on 23/8/25.
//  Copyright © 2025 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import SwiftUI
import UniformTypeIdentifiers

/// What the library's Export hands to the share sheet (fork): the real files, typed as what they
/// are, and named so a destination like Files on a Mac has a name to save under
extension SimpleLibraryItem: @retroactive Transferable {
  public static var transferRepresentation: some TransferRepresentation {
    /// A book is one audio file: the original goes, so a multi-GB book isn't copied first
    FileRepresentation(exportedContentType: .audio) { item in
      SentTransferredFile(item.fileURL, allowAccessingOriginalFile: true)
    }
    .suggestedFileName { item in
      item.fileURL.lastPathComponent
    }
    .exportingCondition { item in
      item.type == .book
    }

    /// Folders and bound books are directories, which most destinations (Mail, other apps) can't
    /// take: they go as a zip named after the title
    FileRepresentation(exportedContentType: .zip) { item in
      let zipURL = try await ShareExportArchiver.zipDirectory(
        at: item.fileURL,
        archiveName: item.title
      )
      return SentTransferredFile(zipURL)
    }
    .suggestedFileName { item in
      ShareExportArchiver.archiveFileName(for: item.title)
    }
    .exportingCondition { item in
      item.type != .book
    }
  }
}

/// Zips a library folder for Export.
enum ShareExportArchiver {
  /// `<title>.zip`, the title made safe as a file name the way stream imports name their files
  static func archiveFileName(for title: String) -> String {
    MediaServerFileNames.sanitize(title) + ".zip"
  }

  /// A zip of `directoryURL`, in a temporary folder of its own, named after `archiveName`.
  ///
  /// `NSFileCoordinator`'s `.forUploading` read hands a directory over as a zip without an
  /// archiving library. The coordinator removes that zip once the accessor returns, so it's copied
  /// out first.
  static func zipDirectory(at directoryURL: URL, archiveName: String) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var result: Result<URL, Error>?

        coordinator.coordinate(
          readingItemAt: directoryURL,
          options: .forUploading,
          error: &coordinatorError
        ) { zippedURL in
          do {
            let stagingDirectory = FileManager.default.temporaryDirectory
              .appendingPathComponent("share-export-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            let destinationURL = stagingDirectory.appendingPathComponent(archiveFileName(for: archiveName))
            try FileManager.default.copyItem(at: zippedURL, to: destinationURL)
            result = .success(destinationURL)
          } catch {
            result = .failure(error)
          }
        }

        if let coordinatorError {
          continuation.resume(throwing: coordinatorError)
        } else if let result {
          continuation.resume(with: result)
        } else {
          continuation.resume(throwing: CocoaError(.fileReadUnknown))
        }
      }
    }
  }
}
