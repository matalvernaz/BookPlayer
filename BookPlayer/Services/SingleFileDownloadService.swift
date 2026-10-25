//
//  DownloadService.swift
//  BookPlayer
//
//  Created by Lysann Tranvouez on 2024-10-29.
//  Copyright © 2024 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Combine

final class SingleFileDownloadService: ObservableObject {
  public enum ErrorKind: Error {
    case general
    case network
  }
  public enum Events {
    case starting(url: URL)
    case progress(task: URLSessionTask, progress: Double)  // (0..1)
    case bytesWritten(task: URLSessionTask, bytesWritten: Int64)
    case finished(task: URLSessionTask)
    case error(ErrorKind, task: URLSessionTask, underlyingError: Error?)
  }

  public var eventsPublisher = PassthroughSubject<Events, Never>()
  /// A finished download's file, now at `destination` under Documents. Sent only after the move
  /// succeeded, so it never reports a failed download (`.finished` is sent for those too).
  public var savedFilesPublisher = PassthroughSubject<(task: URLSessionTask, destination: URL), Never>()
  /// A folder under Documents whose downloads have all ended, sent once the last of them is done
  /// (its file moved, or its failure reported), however each ended. Lets the provenance tracker
  /// release a folder reservation nothing was saved into. Kept in memory like the queue: downloads
  /// still running when the app was killed send nothing.
  public var folderDownloadsEndedPublisher = PassthroughSubject<String, Never>()

  private let networkClient: NetworkClientProtocol
  private var progressDelegate = BPTaskDownloadDelegate()
  private var disposeBag = Set<AnyCancellable>()

  public var isDownloading: Bool { !downloadQueue.isEmpty || currentTask != nil }

  /// Whether a queued or running download saves into `folderName` under Documents
  public func hasQueuedDownloads(inFolder folderName: String) -> Bool {
    currentTask?.folderName == folderName || downloadQueue.contains { $0.folderName == folderName }
  }
  public private(set) var downloadQueue: [(request: URLRequest, folderName: String?, fileName: String?)] = []

  private var currentTask: (task: URLSessionTask, folderName: String?, fileName: String?)?
  /// The running download's task, for tests
  var currentDownloadTask: URLSessionTask? { currentTask?.task }
  private lazy var downloadSession: URLSession = {
    URLSession(
      configuration: URLSessionConfiguration.background(withIdentifier: "SingleFileDownloadService"),
      delegate: progressDelegate,
      delegateQueue: nil
    )
  }()

  public init(networkClient: NetworkClientProtocol) {
    self.networkClient = networkClient

    bindObservers()
  }

  private func sendEvent(_ event: Events) {
    eventsPublisher.send(event)
  }

  public func handleDownload(_ url: URL) {
    handleDownload(URLRequest(url: url))
  }

  public func handleDownload(_ urls: [URL]) {
    handleDownload(urls.map { URLRequest(url: $0) })
  }

  public func handleDownload(_ url: URL, folderName: String) {
    handleDownload(URLRequest(url: url), folderName: folderName)
  }

  public func handleDownload(_ urls: [URL], folderName: String) {
    handleDownload(urls.map { URLRequest(url: $0) }, folderName: folderName)
  }

  public func handleDownload(_ request: URLRequest) {
    downloadQueue.append((request: request, folderName: nil, fileName: nil))
    processNextDownload()
  }

  public func handleDownload(_ requests: [URLRequest]) {
    downloadQueue.append(contentsOf: requests.map { (request: $0, folderName: nil, fileName: nil) })
    processNextDownload()
  }

  public func handleDownload(_ request: URLRequest, folderName: String) {
    downloadQueue.append((request: request, folderName: folderName, fileName: nil))
    processNextDownload()
  }

  public func handleDownload(_ requests: [URLRequest], folderName: String) {
    downloadQueue.append(contentsOf: requests.map { (request: $0, folderName: folderName, fileName: nil) })
    processNextDownload()
  }

  /// Downloads into `folderName`, each file saved under the matching `fileNames` entry instead of
  /// the server's name: for files whose URLs all end the same way, or whose order lives in their
  /// names. `fileNames` lines up 1:1 with `requests`; a request without one keeps the default name.
  public func handleDownload(_ requests: [URLRequest], folderName: String, fileNames: [String]) {
    let items: [(request: URLRequest, folderName: String?, fileName: String?)] =
      requests.enumerated().map { index, request in
        (request: request, folderName: folderName, fileName: index < fileNames.count ? fileNames[index] : nil)
      }
    downloadQueue.append(contentsOf: items)
    processNextDownload()
  }

  private func processNextDownload() {
    Task { @MainActor in
      guard currentTask == nil, !downloadQueue.isEmpty else { return }

      let downloadItem = downloadQueue.removeFirst()
      /// Every `handleDownload` overload wraps a known URL, so `request.url` is non-nil.
      /// A nil here would break dedupe (task description collides) — crash early instead.
      let url = downloadItem.request.url!
      sendEvent(.starting(url: url))

      let task = await networkClient.download(
        request: downloadItem.request,
        taskDescription: "SingleFileDownload-\(url.absoluteString)",
        session: downloadSession
      )
      currentTask = (task: task, folderName: downloadItem.folderName, fileName: downloadItem.fileName)
    }
  }

  private func bindObservers() {
    progressDelegate.downloadProgressUpdated = { [weak self] task, progress in
      self?.sendEvent(.progress(task: task, progress: progress))
    }

    progressDelegate.downloadBytesWrittenUpdated = { [weak self] task, bytesWritten in
      self?.sendEvent(.bytesWritten(task: task, bytesWritten: bytesWritten))
    }

    progressDelegate.didFinishDownloadingTask = { [weak self] task, fileURL, error in
      self?.downloadEnded(task, fileURL: fileURL, error: error)
    }
  }

  /// A download's end as the session delegate reports it. Internal so tests can drive it.
  func downloadEnded(_ task: URLSessionTask, fileURL: URL?, error: Error?) {
    guard fileURL != nil || error != nil else { return }

    finishDownload(
      task,
      fileURL: fileURL,
      error: error,
      folderName: currentTask?.folderName,
      fileName: currentTask?.fileName
    )

    if task === currentTask?.task {
      Task { @MainActor in
        let endedFolder = self.currentTask?.folderName
        self.currentTask = nil
        if let folder = Self.folderToRelease(ended: endedFolder, queued: self.downloadQueue.map(\.folderName)) {
          self.folderDownloadsEndedPublisher.send(folder)
        }
        self.processNextDownload()
      }
    }
  }

  /// The folder to report as finished when a download that saved into `ended` stops: when nothing
  /// left in the queue saves there. How it stopped (saved, failed, cancelled) doesn't matter: the
  /// delegate hands every end of a download to the same step, once, after `finishDownload` has
  /// moved its file or reported its failure.
  static func folderToRelease(ended: String?, queued: [String?]) -> String? {
    guard let ended, !queued.contains(ended) else { return nil }
    return ended
  }

  /// What a finished download does: `.finished`, then `.error` or the move into Documents.
  /// Internal so tests can drive it without a session.
  func finishDownload(
    _ task: URLSessionTask,
    fileURL: URL?,
    error: Error?,
    folderName: String?,
    fileName: String?
  ) {
    sendEvent(.finished(task: task))
    if let error {
      sendEvent(.error(.network, task: task, underlyingError: error))
    } else if let fileURL {
      handleSingleDownloadTaskFinished(task, fileURL: fileURL, folderName: folderName, fileName: fileName)
    }
  }

  private func handleSingleDownloadTaskFinished(
    _ task: URLSessionTask,
    fileURL: URL,
    folderName: String?,
    fileName: String?
  ) {
    let filename =
      fileName
      ?? task.response?.suggestedFilename
      ?? task.originalRequest?.url?.lastPathComponent
      ?? fileURL.lastPathComponent

    var destinationURL: URL
    if let folderName {
      let folderURL = DataManager.getDocumentsFolderURL().appendingPathComponent(folderName)
      destinationURL = folderURL.appendingPathComponent(filename)

      do {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true, attributes: nil)
      } catch {
        destinationURL = DataManager.getDocumentsFolderURL().appendingPathComponent(filename)
      }
    } else {
      destinationURL = DataManager.getDocumentsFolderURL().appendingPathComponent(filename)
    }

    do {
      try FileManager.default.moveItem(at: fileURL, to: destinationURL)
    } catch {
      sendEvent(.error(.general, task: task, underlyingError: error))
      return
    }

    savedFilesPublisher.send((task: task, destination: destinationURL))
  }
}
