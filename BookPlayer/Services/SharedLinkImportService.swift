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
import UniformTypeIdentifiers

/// Imports a book from an Audiobookshelf public share link (fork): the universal link
/// `https://<server>/share/<slug>`. No account on that server is needed, since the share's session
/// cookie is the only credential, so this works for anyone who was sent the URL.
///
/// It fetches the share's track list, downloads the tracks into one folder through
/// `SingleFileDownloadService`, and records the folder as bind-on-complete so
/// `MediaServerBoundBookCompleter` makes it one book once it's in the library.
@MainActor
final class SharedLinkImportService: BPLogger {
  /// The provenance `connectionId` of share-link imports. Never a saved connection's id: anything
  /// that reports to a book's server finds none for it, which is right, since whoever imported it
  /// has no account there.
  static let sharedLinkConnectionId = "public-share-link"

  /// A track whose title doesn't end in an audio extension gets one from its MIME type, so the
  /// import still sees an audio file
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

  // MARK: - Share payload (the part of ABS `GET /public/share/:slug` that's read)

  struct PublicShareResponse: Decodable {
    let id: String
    let slug: String
    let playbackSession: PlaybackSession

    struct PlaybackSession: Decodable {
      let libraryItemId: String?
      let displayTitle: String?
      let audioTracks: [AudioTrack]
    }

    struct AudioTrack: Decodable {
      let index: Int
      let title: String?
      let contentUrl: String
      let mimeType: String?
    }
  }

  static func startImport(from url: URL, mainCoordinator: MainCoordinator) {
    Task { await runImport(from: url, mainCoordinator: mainCoordinator) }
  }

  private static func runImport(from url: URL, mainCoordinator: MainCoordinator) async {
    guard let shareURL = publicShareURL(for: url) else {
      logger.warning("shared import: no public share URL for \(url.absoluteString)")
      return
    }

    let share: PublicShareResponse
    let sessionCookieHeader: String?
    do {
      let (data, response) = try await urlSession.data(from: shareURL)
      guard let httpResponse = response as? HTTPURLResponse else {
        throw URLError(.badServerResponse)
      }
      // ABS deletes an expired share the first time it's asked for after expiring, so "expired" and
      // "revoked" both arrive as a 404
      guard httpResponse.statusCode != 404 else {
        mainCoordinator.showAlert("error_title".localized, message: "shared_import_expired_alert".localized)
        return
      }
      guard (200...299).contains(httpResponse.statusCode) else {
        throw URLError(.badServerResponse)
      }
      share = try JSONDecoder().decode(PublicShareResponse.self, from: data)
      sessionCookieHeader = shareSessionCookie(from: httpResponse, url: shareURL)
    } catch {
      logger.warning("shared import failed for \(shareURL.absoluteString): \(error.localizedDescription)")
      mainCoordinator.showAlert(
        "error_title".localized,
        message: String.localizedStringWithFormat("shared_import_failed_alert".localized, error.localizedDescription)
      )
      return
    }

    // The sharer, or anyone who already has this book from the same server, gets their copy opened
    // instead of a second download
    if let libraryItemId = share.playbackSession.libraryItemId,
      let existingPath = existingImportPath(for: libraryItemId, store: mainCoordinator.mediaServerSourceStore),
      mainCoordinator.libraryService.getSimpleItem(with: existingPath) != nil
    {
      UIAccessibility.post(notification: .announcement, argument: "shared_import_already_in_library".localized)
      mainCoordinator.loadPlayer(existingPath, autoplay: false, showPlayer: true)
      return
    }

    let tracks = share.playbackSession.audioTracks.sorted(by: { $0.index < $1.index })
    var requests = [URLRequest]()
    var fileNames = [String]()
    for track in tracks {
      // `contentUrl` is a path from the server's root that already carries any router base path,
      // so it's resolved against the share URL rather than rebuilt. Only on the share's own server:
      // the request carries its session cookie
      guard
        let trackURL = URL(string: track.contentUrl, relativeTo: shareURL)?.absoluteURL,
        trackURL.scheme == shareURL.scheme,
        trackURL.host == shareURL.host,
        trackURL.port == shareURL.port
      else {
        continue
      }
      var request = URLRequest(url: trackURL)
      if let sessionCookieHeader {
        request.setValue(sessionCookieHeader, forHTTPHeaderField: "Cookie")
      }
      requests.append(request)
      fileNames.append(trackFileName(for: track))
    }

    // An ebook-only share, for one
    guard !requests.isEmpty else {
      mainCoordinator.showAlert("error_title".localized, message: "shared_import_empty_alert".localized)
      return
    }

    let title = share.playbackSession.displayTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let downloadService = mainCoordinator.singleFileDownloadService

    // Recorded before the downloads start, against the folder they land in, so the import that
    // brings the folder into the library finds it with the bind flag. `libraryItemId` keeps the
    // check above working for the next tap on the same link
    let folderName = MediaServerDownloadFolders.reserveFolder(
      named: MediaServerDownloadFolders.folderName(title: title, fallback: share.slug),
      info: MediaServerSourceInfo(
        kind: .audiobookshelf,
        connectionId: sharedLinkConnectionId,
        itemId: share.playbackSession.libraryItemId ?? share.id,
        shouldBindFolder: true
      ),
      store: mainCoordinator.mediaServerSourceStore,
      folderInUse: { downloadService.hasQueuedDownloads(inFolder: $0) }
    )

    downloadService.handleDownload(requests, folderName: folderName, fileNames: fileNames)

    UIAccessibility.post(
      notification: .announcement,
      argument: String.localizedStringWithFormat(
        "shared_import_started_announcement".localized,
        title.isEmpty ? folderName : title
      )
    )
  }

  /// The public share API endpoint (`…/public/share/<slug>`) of a share page (`…/share/<slug>`),
  /// keeping the scheme, host, port and any router base path
  static func publicShareURL(for url: URL) -> URL? {
    let components = url.pathComponents
    guard
      components.count >= 3,
      components[components.count - 2] == "share"
    else {
      return nil
    }

    let slug = components[components.count - 1]
    // pathComponents starts with "/"; everything before the closing "share/<slug>" is base path
    let basePathComponents = components[1..<(components.count - 2)]

    var urlComponents = URLComponents()
    urlComponents.scheme = url.scheme
    urlComponents.host = url.host
    urlComponents.port = url.port
    urlComponents.path = "/" + (basePathComponents + ["public", "share", slug]).joined(separator: "/")

    return urlComponents.url
  }

  /// A zero-padded index first: a bound book plays its files in name order, and the server's track
  /// order is the one that counts
  static func trackFileName(for track: PublicShareResponse.AudioTrack) -> String {
    var name = track.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if name.isEmpty {
      name = "Track \(track.index)"
    }
    name = MediaServerFileNames.sanitize(name)

    // "Part 1. The Beginning" has no extension, whatever NSString says
    let titleExtension = (name as NSString).pathExtension
    let hasAudioExtension = UTType(filenameExtension: titleExtension)?.conforms(to: .audio) ?? false
    let stem = hasAudioExtension ? (name as NSString).deletingPathExtension : name
    let fileExtension = hasAudioExtension
      ? titleExtension
      : track.mimeType.flatMap { fileExtensionByMimeType[$0.lowercased()] } ?? fallbackFileExtension

    return String(format: "%03d - %@.%@", track.index, MediaServerDownloadFolders.limited(stem), fileExtension)
  }

  private static func shareSessionCookie(from response: HTTPURLResponse, url: URL) -> String? {
    guard let headerFields = response.allHeaderFields as? [String: String] else { return nil }
    let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
    guard let sessionCookie = cookies.first(where: { $0.name == shareSessionCookieName }) else {
      return nil
    }
    return "\(sessionCookie.name)=\(sessionCookie.value)"
  }

  private static func existingImportPath(for libraryItemId: String, store: MediaServerSourceStore) -> String? {
    store.allResolved.first(where: { _, info in
      info.kind == .audiobookshelf && info.itemId == libraryItemId
    })?.key
  }
}
