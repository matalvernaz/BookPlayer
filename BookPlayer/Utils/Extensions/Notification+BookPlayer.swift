//
// Extensions.swift
// BookPlayer
//
// Created by Gianni Carlo on 3/10/17.
// Copyright © 2017 BookPlayer LLC. All rights reserved.
//

import UIKit

extension Notification.Name {
  static let processingFile = Notification.Name("\(Bundle.main.configurationString(for: .bundleIdentifier)).file.process")
  static let downloadProgress = Notification.Name("\(Bundle.main.configurationString(for: .bundleIdentifier)).download.progress")
  static let downloadEnd = Notification.Name("\(Bundle.main.configurationString(for: .bundleIdentifier)).download.end")
  static let requestReview = Notification.Name("\(Bundle.main.configurationString(for: .bundleIdentifier)).requestreview")
  static let donationMade = Notification.Name("\(Bundle.main.configurationString(for: .bundleIdentifier)).donation.made")
  /// Posted when the fullscreen video controller finishes tearing down. The inline
  /// surface shares the same `AVPlayer`; the fullscreen surface takes over its video
  /// output, so the inline surface must reclaim rendering once fullscreen is gone.
  static let videoFullscreenDidDismiss = Notification.Name("\(Bundle.main.configurationString(for: .bundleIdentifier)).video.fullscreen.dismissed")
  /// Posted to deep-link into Settings → Media Servers (e.g. from the missing-server
  /// prompt when a synced-down external resource has no matching connection on this device).
  static let showMediaServers = Notification.Name("\(Bundle.main.configurationString(for: .bundleIdentifier)).show.mediaservers")
  /// Posted once an import's items are in the library (fork): a media-server folder download marked
  /// bind-on-complete can be bound then, not at the next launch
  static let importItemsInserted = Notification.Name("\(Bundle.main.configurationString(for: .bundleIdentifier)).import.inserted")
  /// Posted when a delete the user asked for left no copy of some media-server items (fork), with
  /// them under `MediaServerDeletion.entriesKey`: a Hummingbird loan goes back then. Sync and the
  /// loan scanner delete without it.
  static let mediaServerItemsDeleted = Notification.Name("\(Bundle.main.configurationString(for: .bundleIdentifier)).mediaserver.items.deleted")
  /// Posted after something other than the library screens removed library items (fork: the
  /// Hummingbird loan scanner), so the lists on screen fetch again instead of showing books that
  /// are gone
  static let libraryItemsRemoved = Notification.Name("\(Bundle.main.configurationString(for: .bundleIdentifier)).library.items.removed")
}
