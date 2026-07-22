//
//  SharedLinkImportService.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-07-21.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Foundation
import UIKit

/// Imports a book from an Audiobookshelf public share link (universal link
/// `https://<server>/share/<slug>`). The link needs no account on the source server: the
/// share's session cookie is the only credential, so this works for recipients who were
/// simply sent the URL.
///
/// Flow mirrors the other media-server dispatchers (Hummingbird/SoundBooth): fetch the
/// track list, fan the files out through `SingleFileDownloadService` into a folder, and
/// register the folder with `shouldBindFolder` so `MediaServerBoundBookCompleter`
/// promotes it to a single playable bound book once the downloads land.
@MainActor
final class SharedLinkImportService: BPLogger {
  /// Provenance `connectionId` recorded for share-link imports. Deliberately never matches a
  /// saved connection id: the progress dispatcher resolves connections by id and quietly skips
  /// items whose connection is gone — which is correct here, since the recipient has no
  /// account on the source server to report progress to.
  static let sharedLinkConnectionId = "public-share-link"

  /// Track filenames come from the share payload and normally carry an extension. When one
  /// doesn't, an extension is guessed from the track's MIME type so the import pipeline still
  /// recognizes the file as audio.
  private static let fileExtensionByMimeType: [String: String] = [
    "audio/mp4": "m4a",
    "audio/mpeg": "mp3",
    "audio/aac": "aac",
    "audio/flac": "flac",
    "audio/x-flac": "flac",
    "audio/ogg": "ogg",
    "audio/wav": "wav",
    "audio/x-wav": "wav",
  ]
  private static let fallbackFileExtension = "m4a"

  private static let shareSessionCookieName = "share_session_id"

  private static let urlSession: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 30
    return URLSession(configuration: configuration)
  }()

  // MARK: - Share payload (subset of ABS `GET /public/share/:slug`)

  struct PublicShareResponse: Decodable {
    let id: String
    let slug: String
    let playbackSession: PlaybackSession

    struct PlaybackSession: Decodable {
      let libraryItemId: String?
      let displayTitle: String?
      let displayAuthor: String?
      let audioTracks: [AudioTrack]
    }

    struct AudioTrack: Decodable {
      let index: Int
      let title: String?
      let contentUrl: String
      let mimeType: String?
    }
  }

  class func startImport(from url: URL) {
    Task { await self.runImport(from: url) }
  }

  private class func runImport(from url: URL) async {
    guard let mainCoordinator = AppDelegate.shared?.activeSceneDelegate?.mainCoordinator else {
      return
    }

    guard let shareURL = publicShareURL(for: url) else {
      Self.logger.warning("shared import: could not derive public share URL from \(url.absoluteString)")
      return
    }

    let share: PublicShareResponse
    let sessionCookieHeader: String?
    do {
      let (data, response) = try await urlSession.data(from: shareURL)
      guard let httpResponse = response as? HTTPURLResponse else {
        throw URLError(.badServerResponse)
      }
      // ABS deletes expired shares on first access after expiry, so both "expired" and
      // "revoked" surface as 404 here.
      guard httpResponse.statusCode != 404 else {
        mainCoordinator.showAlert(
          "error_title".localized,
          message: "shared_import_expired_alert".localized
        )
        return
      }
      guard (200...299).contains(httpResponse.statusCode) else {
        throw URLError(.badServerResponse)
      }
      share = try JSONDecoder().decode(PublicShareResponse.self, from: data)
      sessionCookieHeader = shareSessionCookie(from: httpResponse, url: shareURL)
    } catch {
      Self.logger.warning("shared import failed for \(shareURL.absoluteString): \(error.localizedDescription)")
      mainCoordinator.showAlert(
        "error_title".localized,
        message: String.localizedStringWithFormat(
          "shared_import_failed_alert".localized, error.localizedDescription
        )
      )
      return
    }

    // The sharer (or anyone who already imported this share's book from the same server)
    // gets the existing copy opened instead of a duplicate download.
    if let libraryItemId = share.playbackSession.libraryItemId,
      let existingPath = existingImportPath(
        for: libraryItemId,
        store: mainCoordinator.mediaServerSourceStore
      ),
      mainCoordinator.libraryService.getSimpleItem(with: existingPath) != nil
    {
      UIAccessibility.post(
        notification: .announcement,
        argument: "shared_import_already_in_library".localized
      )
      mainCoordinator.loadPlayer(existingPath, autoplay: false, showPlayer: true)
      return
    }

    let tracks = share.playbackSession.audioTracks.sorted(by: { $0.index < $1.index })
    guard !tracks.isEmpty else {
      // e.g. an ebook-only item was shared
      mainCoordinator.showAlert(
        "error_title".localized,
        message: "shared_import_empty_alert".localized
      )
      return
    }

    let title = share.playbackSession.displayTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
    let folderName = sanitizedFileName(title?.isEmpty == false ? title! : share.slug)

    var requests = [URLRequest]()
    var fileNames = [String]()
    for track in tracks {
      // `contentUrl` is a server-relative path that already includes any router base path,
      // so resolve it against the share URL's origin rather than rebuilding the path.
      guard let trackURL = URL(string: track.contentUrl, relativeTo: shareURL)?.absoluteURL else {
        continue
      }
      var request = URLRequest(url: trackURL)
      if let sessionCookieHeader {
        request.setValue(sessionCookieHeader, forHTTPHeaderField: "Cookie")
      }
      requests.append(request)
      fileNames.append(trackFileName(for: track))
    }

    guard !requests.isEmpty else {
      mainCoordinator.showAlert(
        "error_title".localized,
        message: "shared_import_empty_alert".localized
      )
      return
    }

    // Register provenance before queueing so the bound-book completer's sweep can never
    // observe a finished download without the bind flag. `libraryItemId` keeps the
    // duplicate-import check above working for future taps on the same link.
    mainCoordinator.mediaServerSourceStore.setSource(
      MediaServerSourceInfo(
        kind: .audiobookshelf,
        connectionId: sharedLinkConnectionId,
        itemId: share.playbackSession.libraryItemId ?? share.id,
        shouldBindFolder: true
      ),
      for: folderName
    )

    mainCoordinator.singleFileDownloadService.handleDownload(
      requests,
      folderName: folderName,
      fileNames: fileNames
    )

    UIAccessibility.post(
      notification: .announcement,
      argument: String.localizedStringWithFormat(
        "shared_import_started_announcement".localized,
        title ?? folderName,
        requests.count
      )
    )
  }

  /// Maps a share page URL (`…/share/<slug>`) to the public share API endpoint
  /// (`…/public/share/<slug>`), preserving scheme, host, port, and any router base path.
  static func publicShareURL(for url: URL) -> URL? {
    let components = url.pathComponents
    guard
      components.count >= 3,
      components[components.count - 2] == "share"
    else {
      return nil
    }

    let slug = components[components.count - 1]
    // pathComponents starts with "/"; everything before the trailing "share/<slug>" is base path
    let basePathComponents = components[1..<(components.count - 2)]

    var urlComponents = URLComponents()
    urlComponents.scheme = url.scheme
    urlComponents.host = url.host
    urlComponents.port = url.port
    urlComponents.path = "/"
      + (basePathComponents + ["public", "share", slug]).joined(separator: "/")

    return urlComponents.url
  }

  private class func shareSessionCookie(from response: HTTPURLResponse, url: URL) -> String? {
    guard let headerFields = response.allHeaderFields as? [String: String] else { return nil }
    let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
    guard let sessionCookie = cookies.first(where: { $0.name == shareSessionCookieName }) else {
      return nil
    }
    return "\(sessionCookie.name)=\(sessionCookie.value)"
  }

  /// Zero-padded index prefix keeps multi-file books in play order once bound — bound books
  /// play their files in name order, and the server's track order is the source of truth.
  private class func trackFileName(for track: PublicShareResponse.AudioTrack) -> String {
    var name = track.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if name.isEmpty {
      name = "Track \(track.index)"
    }
    name = sanitizedFileName(name)

    if (name as NSString).pathExtension.isEmpty {
      let ext = track.mimeType.flatMap { fileExtensionByMimeType[$0] } ?? fallbackFileExtension
      name += ".\(ext)"
    }

    return String(format: "%03d - %@", track.index, name)
  }

  private class func sanitizedFileName(_ name: String) -> String {
    name
      .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r"))
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private class func existingImportPath(
    for libraryItemId: String,
    store: MediaServerSourceStore
  ) -> String? {
    store.allResolved.first(where: { _, info in
      info.kind == .audiobookshelf && info.itemId == libraryItemId
    })?.key
  }
}
