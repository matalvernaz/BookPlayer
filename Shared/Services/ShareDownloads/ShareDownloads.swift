//
//  ShareDownloads.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import Foundation
import UniformTypeIdentifiers

/// Web links shared to BookPlayer (fork). The share extension downloads each share's links in a
/// background session of its own, which the system keeps running after the share sheet closes, and
/// whichever process holds the session when a download ends puts the file in the shared folder, where
/// the app's import picks it up. Both processes build their sessions and judge their downloads here,
/// so they can't drift apart.
public enum ShareDownloads {
  // MARK: - Sessions

  /// Every share session's identifier starts with this. One session per share: a background session
  /// may only be used by one process at a time, and an extension process can take a second share
  /// before it's gone
  public static var sessionIdentifierPrefix: String {
    "\(Bundle.main.configurationString(for: .bundleIdentifier)).shareext."
  }

  public static func makeSessionIdentifier() -> String {
    sessionIdentifierPrefix + UUID().uuidString
  }

  public static func isShareSession(_ identifier: String) -> Bool {
    identifier.hasPrefix(sessionIdentifierPrefix)
  }

  /// The one configuration both processes use for a share's session. The app reconnecting with any
  /// other container would never see the files the system downloaded for the extension
  public static func sessionConfiguration(identifier: String) -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
    configuration.sharedContainerIdentifier = Constants.ApplicationGroupIdentifier
    configuration.sessionSendsLaunchEvents = true
    configuration.isDiscretionary = false
    return configuration
  }

  /// A share's session, with its events delivered in order on one queue, so a download's file is
  /// handled before its task ends and the session's "finished events" comes last
  public static func makeSession(identifier: String, receiver: ShareDownloadReceiver) -> URLSession {
    URLSession(
      configuration: sessionConfiguration(identifier: identifier),
      delegate: receiver,
      delegateQueue: BPURLSession.serialDelegateQueue()
    )
  }

  /// The App Group container both processes write to, nil when the entitlement is missing
  public static var appGroupContainer: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Constants.ApplicationGroupIdentifier)
  }

  /// July builds kept the failures and the cancelled shares in two single files; neither is read now
  public static func removeJulyFiles(in container: URL?, fileManager: FileManager = .default) {
    guard let container else { return }
    for name in ["share-import-failures.json", "share-canceled.json"] {
      try? fileManager.removeItem(at: container.appendingPathComponent(name))
    }
  }

  // MARK: - Links

  /// The file extensions BookPlayer imports from a shared link
  public static let supportedFileExtensions: Set<String> = [
    "mp3", "m4a", "m4b", "aac", "flac", "ogg", "opus", "wav", "wma",
    "aiff", "aif", "caf",
    "mp4", "m4v", "mov",
    "zip",
  ]

  /// Whether a shared link is one BookPlayer downloads: http or https, to a file with a supported
  /// extension. Anything else would land as a web page dressed as an audiobook
  public static func isDownloadableWebURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
    return supportedFileExtensions.contains(url.pathExtension.lowercased())
  }

  /// A shared link as the person would recognise it: its file name, else its host
  public static func sourceName(for url: URL?) -> String {
    guard let url else { return "" }
    let lastComponent = url.lastPathComponent
    if !lastComponent.isEmpty, lastComponent != "/" {
      return lastComponent
    }
    return url.host ?? url.absoluteString
  }

  // MARK: - Names

  /// The longest name a download lands under, in UTF-8 bytes (iOS refuses names over 255)
  static let maxNameBytes = 200

  /// The name a finished download lands under: the server's suggestion, else the link's own name,
  /// made safe for a file name. A name left with no extension (".mp3" loses its dot) gets the link's,
  /// or the one the server's type implies, when it's one BookPlayer imports
  public static func fileName(suggested: String?, url: URL?, mimeType: String?) -> String {
    let raw = suggested.flatMap { $0.isEmpty ? nil : $0 } ?? url?.lastPathComponent ?? ""
    var name = MediaServerFileNames.sanitize(raw)

    if (name as NSString).pathExtension.isEmpty {
      let linkExtension = url?.pathExtension.lowercased() ?? ""
      let typeExtension = mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension?.lowercased() } ?? ""
      if supportedFileExtensions.contains(linkExtension) {
        name += ".\(linkExtension)"
      } else if supportedFileExtensions.contains(typeExtension) {
        name += ".\(typeExtension)"
      }
    }

    return limited(name)
  }

  /// `name` cut at a whole character to fit `maxNameBytes`, keeping its extension
  static func limited(_ name: String) -> String {
    guard name.utf8.count > maxNameBytes else { return name }

    let fileExtension = (name as NSString).pathExtension
    let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
    let keepsSuffix = suffix.utf8.count < maxNameBytes
    let stem = keepsSuffix ? (name as NSString).deletingPathExtension : name
    let budget = maxNameBytes - (keepsSuffix ? suffix.utf8.count : 0)

    var result = ""
    for character in stem {
      guard result.utf8.count + String(character).utf8.count <= budget else { break }
      result.append(character)
    }
    return keepsSuffix ? result + suffix : result
  }

  // MARK: - Checks

  /// Types that are web pages, login walls or error bodies, never an audiobook
  private static let rejectedMIMETypes: Set<String> = [
    "text/html", "text/plain", "application/json",
    "application/xml", "application/problem+json",
  ]

  /// Archive and playlist types taken without looking at the name
  private static let acceptedMIMETypes: Set<String> = [
    "application/zip", "application/x-zip-compressed",
    "application/x-mpegurl", "application/vnd.apple.mpegurl",
  ]

  /// Types sane servers send for any binary download and broken ones for everything: the name decides
  private static let ambiguousMIMETypes: Set<String> = [
    "application/octet-stream", "binary/octet-stream",
    "application/download", "application/force-download",
  ]

  /// Why a finished download isn't imported, or nil to import it. An error status first, then the type:
  /// web and error types never, audio, video and archives always, and the name's extension decides the
  /// rest (July's rules, unchanged)
  public static func rejection(statusCode: Int?, mimeType: String?, fileName: String) -> ShareImportFailure.Reason? {
    if let statusCode, !(200..<300).contains(statusCode) {
      return .httpStatus(code: statusCode)
    }

    let fileExtension = (fileName as NSString).pathExtension.lowercased()
    let extensionMatches = supportedFileExtensions.contains(fileExtension)

    guard let mimeType = mimeType?.lowercased(), !mimeType.isEmpty else {
      return extensionMatches ? nil : .unsupportedExtension
    }
    if rejectedMIMETypes.contains(mimeType) {
      return .unsupportedType(mimeType: mimeType)
    }
    if mimeType.hasPrefix("audio/") || mimeType.hasPrefix("video/") || acceptedMIMETypes.contains(mimeType) {
      return nil
    }
    if ambiguousMIMETypes.contains(mimeType) {
      return extensionMatches ? nil : .unsupportedExtension
    }
    return extensionMatches ? nil : .unsupportedType(mimeType: mimeType)
  }

  /// What became of a finished download
  public enum Outcome: Equatable {
    case landed(URL)
    case failed(ShareImportFailure.Reason)
  }

  /// Judges a finished download and, if it's an audiobook, moves it into `folder`. Must run before the
  /// session's delegate call returns: the system deletes the download's file right after
  public static func finish(download location: URL, response: URLResponse?, originalURL: URL?, into folder: URL) -> Outcome {
    let name = fileName(suggested: response?.suggestedFilename, url: originalURL, mimeType: response?.mimeType)
    let statusCode = (response as? HTTPURLResponse)?.statusCode

    if let reason = rejection(statusCode: statusCode, mimeType: response?.mimeType, fileName: name) {
      return .failed(reason)
    }

    do {
      return .landed(try land(location, named: name, in: folder))
    } catch {
      return .failed(.saveFailed(detail: error.localizedDescription))
    }
  }

  /// Moves a finished download into `folder` under `name`, or "Name 2.mp3", "Name 3.mp3"… when the name
  /// is taken. The other process may take a name between the check and the move, which the move then
  /// refuses, so the next number is tried
  public static func land(
    _ location: URL,
    named name: String,
    in folder: URL,
    fileManager: FileManager = .default
  ) throws -> URL {
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

    let stem = (name as NSString).deletingPathExtension
    let fileExtension = (name as NSString).pathExtension
    for number in 1...100 {
      let candidate: String
      if number == 1 {
        candidate = name
      } else if fileExtension.isEmpty {
        candidate = "\(stem) \(number)"
      } else {
        candidate = "\(stem) \(number).\(fileExtension)"
      }

      let destination = folder.appendingPathComponent(candidate)
      if fileManager.fileExists(atPath: destination.path) {
        continue
      }
      do {
        try fileManager.moveItem(at: location, to: destination)
        return destination
      } catch let error as CocoaError where error.code == .fileWriteFileExists {
        continue
      }
    }
    throw CocoaError(.fileWriteFileExists)
  }

  /// The failure a task's error means. Nothing in BookPlayer cancels a share's download, so a
  /// cancellation is reported too, and one the system made because the app was closed from the app
  /// switcher says so
  public static func failureReason(for error: Error) -> ShareImportFailure.Reason {
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain,
       nsError.code == NSURLErrorCancelled,
       let cancelReason = nsError.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] as? Int,
       cancelReason == NSURLErrorCancelledReasonUserForceQuitApplication {
      return .stoppedByForceQuit
    }
    return .downloadFailed(detail: error.localizedDescription)
  }
}
