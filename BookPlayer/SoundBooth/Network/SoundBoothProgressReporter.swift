//
//  SoundBoothProgressReporter.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Foundation

/// Progress reporter for SoundBooth-sourced items.
///
/// SoundBooth writes playback progress through PowerSync's local-DB CRUD queue, not a REST
/// endpoint — the only progress HTTP surface (`/functions/user/progresses`) is read-only, used
/// to seed resume points at import time. Replicating the write path means speaking PowerSync,
/// which is a larger effort tracked separately. Until then this reporter is intentionally a
/// no-op so the dispatcher has a handler for `.soundbooth` without pushing progress that would
/// silently fail. Resume-from-server still works (positions are seeded on download); only the
/// write-back-to-SoundBooth direction is deferred.
final class SoundBoothProgressReporter: MediaServerProgressReporter, BPLogger {
  let kind: MediaServerKind = .soundbooth

  private let connectionService: SoundBoothConnectionService

  init(connectionService: SoundBoothConnectionService) {
    self.connectionService = connectionService
  }

  func reportInProgress(_ update: MediaServerProgressUpdate) {
    // Deferred: SoundBooth progress writes ride PowerSync, not REST. See type doc.
  }

  func reportFinal(_ update: MediaServerProgressUpdate) {
    // Deferred: SoundBooth progress writes ride PowerSync, not REST. See type doc.
  }
}
