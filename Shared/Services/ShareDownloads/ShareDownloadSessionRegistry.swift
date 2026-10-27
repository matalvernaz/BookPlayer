//
//  ShareDownloadSessionRegistry.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import Foundation

/// The share extension's background downloads that may still need the app (fork). The extension
/// records each share's session, with the tasks it started, before any of them run; whichever process
/// handles a task's end marks that task done; the session is forgotten once it's closed. The app
/// reconnects to the sessions still recorded, which are the ones the extension didn't see through.
///
/// One file per record (`<session>.json`, written once) and one empty file per finished task (in
/// `<session>.done/`), so the two processes never read, change and write back each other's records.
public final class ShareDownloadSessionRegistry: @unchecked Sendable, BPLogger {
  /// A share's background session: when it started and the tasks it started
  public struct Session: Codable, Equatable, Sendable {
    public let identifier: String
    public let startedAt: Date
    public let taskIdentifiers: [Int]

    public init(identifier: String, startedAt: Date, taskIdentifiers: [Int]) {
      self.identifier = identifier
      self.startedAt = startedAt
      self.taskIdentifiers = taskIdentifiers
    }
  }

  /// A session this old is forgotten without being reconnected: a download that hasn't ended in a
  /// week isn't coming
  public static let expiry: TimeInterval = 7 * 24 * 60 * 60

  /// The registry both processes share, or nil when the App Group container can't be reached
  public static var appGroup: ShareDownloadSessionRegistry? {
    ShareDownloads.appGroupContainer.map {
      ShareDownloadSessionRegistry(folder: $0.appendingPathComponent("share-download-sessions", isDirectory: true))
    }
  }

  private let folder: URL
  private let fileManager: FileManager
  private let now: () -> Date

  public init(folder: URL, fileManager: FileManager = .default, now: @escaping () -> Date = Date.init) {
    self.folder = folder
    self.fileManager = fileManager
    self.now = now
  }

  /// Records a share's session. The extension calls it after creating the tasks and before starting
  /// them, so a task can't end before its session is known
  public func record(_ session: Session) throws {
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(session)
    try data.write(to: recordURL(for: session.identifier), options: .atomic)
  }

  /// The sessions recorded and not forgotten, oldest first. Expired ones, unreadable ones and the
  /// done markers of forgotten ones are cleared on the way
  public func sessions() -> [Session] {
    guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return [] }

    var sessions = [Session]()
    for name in names where name.hasSuffix(".json") {
      let url = folder.appendingPathComponent(name)
      guard
        let data = try? Data(contentsOf: url),
        let session = try? JSONDecoder().decode(Session.self, from: data)
      else {
        try? fileManager.removeItem(at: url)
        continue
      }
      if now().timeIntervalSince(session.startedAt) > Self.expiry {
        forget(session.identifier)
        continue
      }
      sessions.append(session)
    }

    // Markers whose record is gone belong to a session another process just forgot
    for name in names where name.hasSuffix(".done") {
      let identifier = String(name.dropLast(".done".count))
      if !fileManager.fileExists(atPath: recordURL(for: identifier).path) {
        try? fileManager.removeItem(at: folder.appendingPathComponent(name))
      }
    }

    return sessions.sorted { ($0.startedAt, $0.identifier) < ($1.startedAt, $1.identifier) }
  }

  /// The session with this identifier, if it's recorded
  public func session(_ identifier: String) -> Session? {
    guard let data = try? Data(contentsOf: recordURL(for: identifier)) else { return nil }
    return try? JSONDecoder().decode(Session.self, from: data)
  }

  /// Marks one of a session's tasks as handled: its file landed or its failure was kept. Nothing for a
  /// session that isn't recorded
  public func markDone(_ identifier: String, taskIdentifier: Int) {
    guard fileManager.fileExists(atPath: recordURL(for: identifier).path) else { return }

    do {
      let markers = doneFolder(for: identifier)
      try fileManager.createDirectory(at: markers, withIntermediateDirectories: true)
      try Data().write(to: markers.appendingPathComponent("\(taskIdentifier)"), options: .atomic)
    } catch {
      Self.logger.error("Share download not marked done: \(error.localizedDescription)")
    }
  }

  /// Whether every task the session started has been handled
  public func isComplete(_ identifier: String) -> Bool {
    guard let session = session(identifier) else { return false }

    let markers = doneFolder(for: identifier)
    return session.taskIdentifiers.allSatisfy {
      fileManager.fileExists(atPath: markers.appendingPathComponent("\($0)").path)
    }
  }

  /// Forgets a session: its record first, so no one reconnects to it, then its markers
  public func forget(_ identifier: String) {
    try? fileManager.removeItem(at: recordURL(for: identifier))
    try? fileManager.removeItem(at: doneFolder(for: identifier))
  }

  private func recordURL(for identifier: String) -> URL {
    folder.appendingPathComponent("\(identifier).json")
  }

  private func doneFolder(for identifier: String) -> URL {
    folder.appendingPathComponent("\(identifier).done", isDirectory: true)
  }
}
