//
//  MediaServerProgressReporter.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-05-17.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import Foundation

/// A snapshot of playback state for an item known to belong to a media server integration.
/// The dispatcher (`MediaServerProgressDispatcher`) builds these from `PlayerManager` state and
/// hands them to the reporter that matches the source's `MediaServerKind`.
public struct MediaServerProgressUpdate {
  public let info: MediaServerSourceInfo
  public let currentTime: TimeInterval
  public let duration: TimeInterval
  public let isFinished: Bool

  public init(info: MediaServerSourceInfo, currentTime: TimeInterval, duration: TimeInterval, isFinished: Bool) {
    self.info = info
    self.currentTime = currentTime
    self.duration = duration
    self.isFinished = isFinished
  }
}

/// Pushes BookPlayer playback state back to a specific media server. One concrete reporter per
/// integration kind; `MediaServerProgressDispatcher` picks the right one based on the source info
/// attached to the currently-playing item.
///
/// The dispatcher already throttles "in-progress" calls to avoid hammering the server during a
/// listening session, so reporters can assume an `inProgress(...)` call is "fire-and-forget at a
/// sustainable rate." `final(...)` calls correspond to pause/stop/finish boundaries and should
/// be sent immediately — they're the events that matter for cross-device resume.
public protocol MediaServerProgressReporter: AnyObject {
  /// The integration this reporter handles. Dispatcher uses this to route updates.
  var kind: MediaServerKind { get }

  /// Throttled progress tick during ongoing playback. Implementations should send the request
  /// without blocking; failures are logged and dropped (the next tick will retry implicitly).
  func reportInProgress(_ update: MediaServerProgressUpdate)

  /// Definitive update at a playback boundary (pause / stop / finish). Should send immediately;
  /// dispatcher does not throttle these.
  func reportFinal(_ update: MediaServerProgressUpdate)
}
