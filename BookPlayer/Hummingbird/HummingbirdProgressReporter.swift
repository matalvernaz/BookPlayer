//
//  HummingbirdProgressReporter.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Combine
import Foundation

/// Sends the listening position of a book downloaded from Hummingbird back to its server as a bookmark
/// (fork). Upstream's progress push covers Audiobookshelf and Jellyfin downloads; Hummingbird isn't one
/// of its providers, so its books report here: a tick at most every 15 seconds while playing, the
/// position on pause, and whether it's finished when the player says the book ended. Failures are logged
/// and dropped: the next tick carries the position again.
@MainActor
final class HummingbirdProgressReporter: BPLogger {
  /// How a bookmark leaves: `HummingbirdConnectionService.reportBookmark` in the app
  typealias Send = @MainActor (_ bookmark: HummingbirdBookmark, _ bookId: String, _ connectionId: String) async throws -> Void

  /// The fewest seconds between two ticks for one book. Pauses and ends go at once
  static let tickInterval: TimeInterval = 15

  private let playerManager: PlayerManagerProtocol
  private let sourceStore: MediaServerSourceStore
  private let send: Send
  private let now: () -> Date
  private let notificationCenter: NotificationCenter
  private var observers = [NSObjectProtocol]()
  private var currentItemSubscription: AnyCancellable?

  /// The Hummingbird book the reporter last reported, the one a `.bookEnd` is about. `.bookEnd` names no
  /// book, and its second post comes after the player loaded the next one, so it's never read from
  /// `currentItem` then; it's forgotten once its end is reported and when another book is loaded
  private var reportedItem: (item: PlayableItem, info: MediaServerSourceInfo)?
  /// When each book's last tick went, by relativePath
  private var lastTickAt = [String: Date]()
  /// The books with a bookmark on its way, by relativePath: one at a time per book
  private var sending = Set<String>()
  /// The newest bookmark waiting for its book's send to finish
  private var waiting = [String: (bookmark: HummingbirdBookmark, info: MediaServerSourceInfo)]()

  init(
    playerManager: PlayerManagerProtocol,
    sourceStore: MediaServerSourceStore,
    notificationCenter: NotificationCenter = .default,
    now: @escaping () -> Date = Date.init,
    send: @escaping Send
  ) {
    self.playerManager = playerManager
    self.sourceStore = sourceStore
    self.notificationCenter = notificationCenter
    self.now = now
    self.send = send

    observers.append(notificationCenter.addObserver(forName: .bookPlaying, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.reportTick() }
    })
    observers.append(notificationCenter.addObserver(forName: .bookPaused, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.reportPause() }
    })
    observers.append(notificationCenter.addObserver(forName: .bookEnd, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.reportEnd() }
    })
    // Another book loaded: a later `.bookEnd` isn't about the one reported before
    currentItemSubscription = playerManager.currentItemPublisher()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] item in
        MainActor.assumeIsolated {
          guard let self, let reported = self.reportedItem else { return }
          if item?.relativePath != reported.item.relativePath {
            self.reportedItem = nil
          }
        }
      }
  }

  deinit {
    for observer in observers {
      notificationCenter.removeObserver(observer)
    }
  }

  /// The current item and its provenance, when it's a Hummingbird download
  private func currentHummingbirdItem() -> (item: PlayableItem, info: MediaServerSourceInfo)? {
    guard
      let item = playerManager.currentItem,
      let info = sourceStore.source(for: item.relativePath),
      info.kind == .hummingbird
    else { return nil }
    return (item, info)
  }

  func reportTick() {
    guard let current = currentHummingbirdItem() else { return }
    reportedItem = current

    let path = current.item.relativePath
    if let last = lastTickAt[path], now().timeIntervalSince(last) < Self.tickInterval {
      return
    }
    lastTickAt[path] = now()
    enqueue(Self.bookmark(for: current.item, isFinished: current.item.isFinished), path: path, info: current.info)
  }

  func reportPause() {
    guard let current = currentHummingbirdItem() else { return }
    reportedItem = current
    lastTickAt[current.item.relativePath] = now()
    enqueue(
      Self.bookmark(for: current.item, isFinished: current.item.isFinished),
      path: current.item.relativePath,
      info: current.info
    )
  }

  /// The book reported last, finished or not as the player now says (marking a book unfinished posts
  /// `.bookEnd` too). Once: the second `.bookEnd` finds nothing to report
  func reportEnd() {
    guard let reported = reportedItem else { return }
    reportedItem = nil
    let item = reported.item
    let bookmark = item.isFinished
      ? HummingbirdBookmark(currentTime: item.duration, duration: item.duration, isFinished: true)
      : Self.bookmark(for: item, isFinished: false)
    lastTickAt[item.relativePath] = now()
    enqueue(bookmark, path: item.relativePath, info: reported.info)
  }

  private static func bookmark(for item: PlayableItem, isFinished: Bool) -> HummingbirdBookmark {
    HummingbirdBookmark(currentTime: item.currentTime, duration: item.duration, isFinished: isFinished)
  }

  /// Sends now, or after the book's send on its way, replacing whatever was waiting
  private func enqueue(_ bookmark: HummingbirdBookmark, path: String, info: MediaServerSourceInfo) {
    guard !sending.contains(path) else {
      waiting[path] = (bookmark, info)
      return
    }
    sending.insert(path)
    Task { [weak self] in
      await self?.deliver(bookmark, path: path, info: info)
    }
  }

  private func deliver(_ bookmark: HummingbirdBookmark, path: String, info: MediaServerSourceInfo) async {
    do {
      try await send(bookmark, info.itemId, info.connectionId)
    } catch {
      Self.logger.warning("Hummingbird bookmark not saved: \(error.localizedDescription)")
    }
    sending.remove(path)
    if let next = waiting.removeValue(forKey: path) {
      enqueue(next.bookmark, path: path, info: next.info)
    }
  }
}
