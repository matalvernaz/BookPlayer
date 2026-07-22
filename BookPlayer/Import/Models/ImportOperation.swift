//
//  BookOperation.swift
//  BookPlayer
//
//  Created by Gianni Carlo on 8/30/18.
//  Copyright © 2018 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Foundation
import IDZSwiftCommonCrypto
import Sentry
import UniformTypeIdentifiers
import ZipArchive

/// Reference: https://www.avanderlee.com/swift/asynchronous-operations/
public class ImportOperation: Operation {
  public let files: [URL]
  public let libraryService: LibraryServiceProtocol
  public var processedFiles = [URL]()
  public var suggestedFolderName: String?

  /// Store to re-key media-server provenance when a downloaded zip is replaced by its
  /// extracted contents. Optional so callers without provenance tracking (tests) can omit it.
  private let mediaServerSourceStore: MediaServerSourceStore?
  /// Extracted-from-zip entries awaiting their final destination, keyed by temp-directory URL.
  /// Populated in `handleZip`, consumed in `processFile` once the landing filename is known.
  private var zipExtractedSources = [URL: MediaServerSourceInfo]()

  private let lockQueue = DispatchQueue(label: "com.bookplayer.asyncoperation", attributes: .concurrent)

  public override var isAsynchronous: Bool {
    return true
  }

  private var _isExecuting: Bool = false
  public override private(set) var isExecuting: Bool {
    get {
      return lockQueue.sync { () -> Bool in
        return _isExecuting
      }
    }
    set {
      willChangeValue(forKey: "isExecuting")
      lockQueue.sync(flags: [.barrier]) {
        _isExecuting = newValue
      }
      didChangeValue(forKey: "isExecuting")
    }
  }

  private var _isFinished: Bool = false
  public override private(set) var isFinished: Bool {
    get {
      return lockQueue.sync { () -> Bool in
        return _isFinished
      }
    }
    set {
      willChangeValue(forKey: "isFinished")
      lockQueue.sync(flags: [.barrier]) {
        _isFinished = newValue
      }
      didChangeValue(forKey: "isFinished")
    }
  }

  init(files: [URL],
       libraryService: LibraryServiceProtocol,
       mediaServerSourceStore: MediaServerSourceStore? = nil) {
    self.files = files
    self.libraryService = libraryService
    self.mediaServerSourceStore = mediaServerSourceStore
  }

  public override func start() {
    guard !isCancelled else {
      finish()
      return
    }

    isFinished = false
    isExecuting = true
    main()
  }

  func finish() {
    let sortDescriptor = NSSortDescriptor(key: "path", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))
    let orderedSet = NSOrderedSet(array: self.processedFiles)

    if let sortedFiles = orderedSet.sortedArray(using: [sortDescriptor]) as? [URL] {
      self.processedFiles = sortedFiles
    }

    isExecuting = false
    isFinished = true
  }

  func getInfo() -> [String: String] {
    var dictionary = [String: Int]()
    for file in self.files {
      dictionary[file.pathExtension] = (dictionary[file.pathExtension] ?? 0) + 1
    }
    var finalInfo = [String: String]()
    for (key, value) in dictionary {
      finalInfo[key] = "\(value)"
    }

    return finalInfo
  }

  func handleZip(file: URL, remainingFiles: [URL]) {
    self.suggestedFolderName = file.deletingPathExtension().lastPathComponent

    // Unzip to temporary directory
    let documentsURL = DataManager.getDocumentsFolderURL()

    let tempDirectoryURL = try! FileManager.default.url(
      for: .itemReplacementDirectory,
      in: .userDomainMask,
      appropriateFor: documentsURL,
      create: true
    )

    // The zip's media-server provenance (recorded against the downloaded archive's filename)
    // must follow the extracted contents; the archive itself is deleted below and its library
    // entry never materializes.
    let zipSource = mediaServerSourceStore?.takeSource(for: file.lastPathComponent)

    SSZipArchive.unzipFile(atPath: file.path, toDestination: tempDirectoryURL.path, progressHandler: nil) { _, success, error in
      try? FileManager.default.removeItem(at: file)

      guard success else {
        self.processFile(from: remainingFiles)
        return
      }

      let enumerator = FileManager.default.enumerator(
        at: tempDirectoryURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants], errorHandler: { (url, error) -> Bool in
          print("directoryEnumerator error at \(url): ", error)
          return true
        })!

      var files = [URL]()
      for case let fileURL as URL in enumerator {
        files.append(fileURL)
      }

      if let zipSource {
        for fileURL in files where Self.carriesZipProvenance(fileURL) {
          self.zipExtractedSources[fileURL] = zipSource
        }
      }

      self.processFile(from: remainingFiles + files)
    }
  }

  /// Extracted entries that should inherit the zip's media-server provenance: audio files, and
  /// directories (a zip that wraps its tracks in a folder lands that folder as a single item).
  /// Sidecar files (covers, metadata) are skipped so they don't leave orphaned mappings behind.
  private static func carriesZipProvenance(_ url: URL) -> Bool {
    if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
      return true
    }
    return UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) ?? false
  }

  func getNextAvailableURL(for url: URL) -> URL {
    guard FileManager.default.fileExists(atPath: url.path)  else {
      return url
    }

    let destinationBaseURL = DataManager.getProcessedFolderURL()
    let filename = url.deletingPathExtension().lastPathComponent
    let fileExt = url.pathExtension

    // set initial state for new file name
    var newFileName = ""
    var counter = 0
    var mutableURL = destinationBaseURL.appendingPathComponent(url.lastPathComponent)

    while FileManager.default.fileExists(atPath: mutableURL.path) {
      counter += 1
      newFileName = "\(filename)-\(counter)"

      if !fileExt.isEmpty {
        newFileName += ".\(fileExt)"
      }

      mutableURL = destinationBaseURL.appendingPathComponent(newFileName)
    }

    return mutableURL
  }

  private func hasExistingBook(_ fileURL: URL) -> Bool {
    guard
      let existingBook = self.libraryService.findBooks(containing: fileURL)?.first,
      let existingFileURL = existingBook.fileURL,
      !FileManager.default.fileExists(atPath: existingFileURL.path)
    else { return false }

    // Add support for iCloud documents
    let accessGranted = fileURL.startAccessingSecurityScopedResource()

    defer { fileURL.stopAccessingSecurityScopedResource() }

    do {
      // create parent folder if it doesn't exist
      let parentFolder = existingFileURL.deletingLastPathComponent()

      if !FileManager.default.fileExists(atPath: parentFolder.path) {
        try FileManager.default.createDirectory(at: parentFolder, withIntermediateDirectories: true, attributes: nil)
      }

      try FileManager.default.copyItem(at: fileURL, to: existingFileURL)

      if DataManager.isAppManagedSource(fileURL) {
        fileURL.disableFileProtection()
        try? FileManager.default.removeItem(at: fileURL)
      }

      existingFileURL.disableFileProtection()
    } catch {
      SentrySDK.capture(error: error) { scope in
        scope.setContext(value: [
          "source": fileURL.path,
          "destination": existingFileURL.path,
          "securityScopedAccess": accessGranted
        ], key: "import")
      }
      SentrySDK.flush(timeout: 2)
      fatalError("Existing book, fail to move file from \(fileURL) to \(existingFileURL). Error: \(error.localizedDescription)")
    }

    return true
  }

  public override func main() {
    self.detectFolderOrganization()
    self.processFile(from: self.files)
  }

  private func detectFolderOrganization() {
    guard files.count > 1 else { return }

    let topLevelImportPaths: Set<String> = [
      DataManager.getDocumentsFolderURL().resolvingSymlinksInPath().path,
      DataManager.getSharedFilesFolderURL().resolvingSymlinksInPath().path,
      DataManager.getInboxFolderURL().resolvingSymlinksInPath().path,
    ]
    var parentFolders = Set<String>()

    for file in files {
        let parentURL = file.deletingLastPathComponent()

        guard !topLevelImportPaths.contains(parentURL.resolvingSymlinksInPath().path) else { continue }

        parentFolders.insert(parentURL.lastPathComponent)
    }

    guard parentFolders.count == 1, let folderName = parentFolders.first else { return }
    suggestedFolderName = folderName
  }

  func processFile(from files: [URL]) {
    var mutableFiles = files
    guard !mutableFiles.isEmpty else {
      return self.finish()
    }

    let currentFile = mutableFiles.removeFirst()

    guard !self.hasExistingBook(currentFile) else {
      return processFile(from: mutableFiles)
    }

    NotificationCenter.default.post(name: .processingFile, object: nil, userInfo: ["filename": currentFile.lastPathComponent])

    if shouldUnzip(currentFile) {
      self.handleZip(file: currentFile, remainingFiles: mutableFiles)
      return
    }

    // Add support for iCloud documents
    let accessGranted = currentFile.startAccessingSecurityScopedResource()

    defer { currentFile.stopAccessingSecurityScopedResource() }

    let destinationURL = self.getNextAvailableURL(for: currentFile)

    do {
      try FileManager.default.copyItem(at: currentFile, to: destinationURL)

      if DataManager.isAppManagedSource(currentFile) {
        currentFile.disableFileProtection()
        try FileManager.default.removeItem(at: currentFile)
      }

      destinationURL.disableFileProtection()
    } catch {
      SentrySDK.capture(error: error) { scope in
        scope.setContext(value: [
          "source": currentFile.path,
          "destination": destinationURL.path,
          "securityScopedAccess": accessGranted
        ], key: "import")
      }
      SentrySDK.flush(timeout: 2)
      fatalError("Fail to move file from \(currentFile) to \(destinationURL). Error: \(error.localizedDescription)")
    }

    // Files land at the processed-folder root, so the landed relativePath is the filename.
    // Later moves (combine-into-volume) re-key this through `migrateMediaServerSources`.
    if let info = zipExtractedSources.removeValue(forKey: currentFile) {
      mediaServerSourceStore?.setSource(info, for: destinationURL.lastPathComponent)
    }

    self.processedFiles.append(destinationURL)
    self.processFile(from: mutableFiles)
  }

  func shouldUnzip(_ file: URL) -> Bool {
    return file.pathExtension == "zip" || file.pathExtension == "lpf"
  }
}
