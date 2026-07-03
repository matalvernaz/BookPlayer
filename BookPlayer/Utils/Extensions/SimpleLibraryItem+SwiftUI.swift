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

extension SimpleLibraryItem: @retroactive Transferable {
  public static var transferRepresentation: some TransferRepresentation {
    /// Books are single audio files on disk — hand over the original so multi-GB
    /// audiobooks don't get staged through a second on-disk copy.
    FileRepresentation(exportedContentType: .audio) { item in
      SentTransferredFile(item.fileURL, allowAccessingOriginalFile: true)
    }
    .exportingCondition { item in
      item.type == .book
    }

    /// Folders and bound books are directories on disk. Most share targets
    /// (Mail, third-party apps) can't take a bare directory, so archive first.
    FileRepresentation(exportedContentType: .zip) { item in
      let zipURL = try await ShareExportArchiver.zipDirectory(
        at: item.fileURL,
        archiveName: item.title
      )
      return SentTransferredFile(zipURL)
    }
    .exportingCondition { item in
      item.type != .book
    }
  }
}

/// Zips a library directory for share-sheet export.
enum ShareExportArchiver {
  /// Returns the URL of a zip of `directoryURL`, staged in a unique temp
  /// subdirectory and named after `archiveName`.
  ///
  /// Uses `NSFileCoordinator`'s `.forUploading` read, which materializes a
  /// directory as a zip without any archiving dependency. The coordinator owns
  /// the zip it yields and reclaims it when the accessor returns, so the file
  /// must be copied out before then.
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
            try FileManager.default.createDirectory(
              at: stagingDirectory,
              withIntermediateDirectories: true
            )
            let filename = ShareDownloadSupport.sanitizedFilename(archiveName) + ".zip"
            let destinationURL = stagingDirectory.appendingPathComponent(filename)
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
