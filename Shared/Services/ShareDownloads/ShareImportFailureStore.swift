//
//  ShareImportFailureStore.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import Foundation

/// Something shared to BookPlayer that didn't make it into the library (fork): a file the share
/// extension couldn't copy, or a shared link whose download failed or wasn't an audiobook. It's kept
/// until the app has shown it, since the share sheet is long gone by the time a download ends.
public struct ShareImportFailure: Codable, Hashable, Identifiable, Sendable {
  /// What went wrong. The text is made from it in the app when it's shown: the share extension carries
  /// no translations, so text made there would be the bare keys
  public enum Reason: Codable, Hashable, Sendable {
    /// A shared file couldn't be copied for the import (the system's description)
    case copyFailed(detail: String)
    /// The download didn't finish (the system's description)
    case downloadFailed(detail: String)
    /// The server answered with an error status
    case httpStatus(code: Int)
    /// The download arrived but couldn't be put where the import picks it up (the system's description)
    case saveFailed(detail: String)
    /// The download stopped because the app holding it was closed from the app switcher
    case stoppedByForceQuit
    /// The server didn't say it was audio, and the name has no audio file extension
    case unsupportedExtension
    /// The server sent something that isn't audio, such as a web page
    case unsupportedType(mimeType: String)
  }

  public let id: UUID
  public let date: Date
  /// What the person shared, as they'd recognise it: the file's or the link's name
  public let source: String
  public let reason: Reason

  public init(id: UUID = UUID(), date: Date = Date(), source: String, reason: Reason) {
    self.id = id
    self.date = date
    self.source = source
    self.reason = reason
  }
}

/// The failures waiting to be shown, one file each in a folder of the App Group container (fork). The
/// share extension and the app both write here, at any moment; with a file per failure neither ever
/// reads, changes and writes back what the other may be writing, so nothing gets lost.
public final class ShareImportFailureStore: @unchecked Sendable, BPLogger {
  /// The most failures kept; past it the oldest go
  public static let maxStored = 50

  /// The store both processes share, or nil when the App Group container can't be reached
  public static var appGroup: ShareImportFailureStore? {
    ShareDownloads.appGroupContainer.map {
      ShareImportFailureStore(folder: $0.appendingPathComponent("share-import-failures", isDirectory: true))
    }
  }

  private let folder: URL
  private let fileManager: FileManager

  public init(folder: URL, fileManager: FileManager = .default) {
    self.folder = folder
    self.fileManager = fileManager
  }

  /// Keeps a failure until it's shown. Never throws: a failure that can't be kept is logged, as there's
  /// no one to tell
  public func append(_ failure: ShareImportFailure) {
    do {
      try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(failure)
      try data.write(to: fileURL(for: failure.id), options: .atomic)
    } catch {
      Self.logger.error("Share import failure not kept: \(error.localizedDescription)")
      return
    }

    // The oldest beyond the cap go. Two processes trimming at once can at worst leave one too many or
    // one too few; neither drops a failure newer than the ones being trimmed
    let kept = pending()
    if kept.count > Self.maxStored {
      remove(ids: Set(kept.prefix(kept.count - Self.maxStored).map(\.id)))
    }
  }

  /// Every failure kept, oldest first. A file that can't be read (a write the other process lost
  /// partway, or a format from an older build) is deleted
  public func pending() -> [ShareImportFailure] {
    guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return [] }

    var failures = [ShareImportFailure]()
    for name in names where name.hasSuffix(".json") {
      let url = folder.appendingPathComponent(name)
      guard
        let data = try? Data(contentsOf: url),
        let failure = try? JSONDecoder().decode(ShareImportFailure.self, from: data)
      else {
        try? fileManager.removeItem(at: url)
        continue
      }
      failures.append(failure)
    }

    return failures.sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
  }

  /// Forgets these failures, once they've been shown. Others, including any written meanwhile, stay
  public func remove(ids: Set<UUID>) {
    for id in ids {
      try? fileManager.removeItem(at: fileURL(for: id))
    }
  }

  private func fileURL(for id: UUID) -> URL {
    folder.appendingPathComponent("\(id.uuidString).json")
  }
}
