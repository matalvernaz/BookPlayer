//
//  ShareViewController.swift
//  BookPlayerShareExtension
//
//  Created by gianni.carlo on 20/11/22.
//  Copyright © 2022 BookPlayer LLC. All rights reserved.
//

import UIKit
import BookPlayerKit
import UniformTypeIdentifiers

@objc(ShareExtensionViewController)
class ShareViewController: UIViewController {
  /// Manual navigation bar
  private lazy var navigationBar: UINavigationBar = {
    let navBar = UINavigationBar()
    navBar.translatesAutoresizingMaskIntoConstraints = false

    let navItem = UINavigationItem(title: "Copy")
    navItem.leftBarButtonItem = closeButton
    navItem.rightBarButtonItem = doneButton

    navBar.setItems([navItem], animated: false)
    return navBar
  }()

  private lazy var closeButton: UIBarButtonItem = {
    let barButton = UIBarButtonItem(
      barButtonSystemItem: .cancel,
      target: self,
      action: #selector(self.didPressCancel)
    )
    barButton.tintColor = defaultTheme.linkColor

    return barButton
  }()

  private lazy var doneButton: UIBarButtonItem = {
    let barButton = UIBarButtonItem(
      barButtonSystemItem: .done,
      target: self,
      action: #selector(self.didPressDone)
    )
    barButton.tintColor = defaultTheme.linkColor

    return barButton
  }()

  private lazy var containerDisclaimerLabel: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    /// won't work if set elsewhere
    view.backgroundColor = defaultTheme.systemBackgroundColor
    return view
  }()

  private lazy var disclaimerLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.textAlignment = .center
    label.numberOfLines = 0
    label.text = "When importing folders, make sure to first download the contents locally, as otherwise the cloud items will not be included in the copied folder"
    /// won't work if set elsewhere
    label.textColor = defaultTheme.secondaryColor
    label.font = Fonts.body
    return label
  }()

  private lazy var tableView: UITableView = {
    let tableView = UITableView()
    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.rowHeight = UITableView.automaticDimension
    tableView.estimatedRowHeight = UITableView.automaticDimension
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ShareCellView")
    tableView.delegate = self
    tableView.dataSource = self
    return tableView
  }()

  /// Hard-coded default theme to avoid accessing DB
  private lazy var defaultTheme: SimpleTheme = {
    return SimpleTheme.getDefaultTheme(useDarkVariant: UIScreen.main.traitCollection.userInterfaceStyle == .dark)
  }()

  /// Allowed content types
  let contentType = UTType.url.identifier
  /// Shared folder URL
  let sharedFolder = DataManager.getSharedFilesFolderURL()
  /// In-memory array of shared items
  var sharedItems = [URL]()

  override func viewDidLoad() {
    super.viewDidLoad()

    addSubviews()
    addConstraints()
    handleSharedFiles()
  }

  func addSubviews() {
    view.addSubview(navigationBar)
    view.addSubview(containerDisclaimerLabel)
    containerDisclaimerLabel.addSubview(disclaimerLabel)
    view.addSubview(tableView)
  }

  func addConstraints() {
    let safeLayoutGuide = view.safeAreaLayoutGuide

    NSLayoutConstraint.activate([
      navigationBar.topAnchor.constraint(equalTo: safeLayoutGuide.topAnchor),
      navigationBar.leadingAnchor.constraint(equalTo: safeLayoutGuide.leadingAnchor),
      navigationBar.trailingAnchor.constraint(equalTo: safeLayoutGuide.trailingAnchor),

      containerDisclaimerLabel.topAnchor.constraint(equalTo: navigationBar.bottomAnchor),
      containerDisclaimerLabel.leadingAnchor.constraint(equalTo: safeLayoutGuide.leadingAnchor),
      containerDisclaimerLabel.trailingAnchor.constraint(equalTo: safeLayoutGuide.trailingAnchor),

      disclaimerLabel.topAnchor.constraint(equalTo: containerDisclaimerLabel.topAnchor, constant: 8),
      disclaimerLabel.leadingAnchor.constraint(equalTo: containerDisclaimerLabel.leadingAnchor, constant: 12),
      disclaimerLabel.trailingAnchor.constraint(equalTo: containerDisclaimerLabel.trailingAnchor, constant: -12),
      disclaimerLabel.bottomAnchor.constraint(equalTo: containerDisclaimerLabel.bottomAnchor, constant: -8),

      tableView.topAnchor.constraint(equalTo: containerDisclaimerLabel.bottomAnchor),
      tableView.leadingAnchor.constraint(equalTo: safeLayoutGuide.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: safeLayoutGuide.trailingAnchor),
      tableView.bottomAnchor.constraint(equalTo: safeLayoutGuide.bottomAnchor),
    ])
  }

  func loadAttachments(_ attachments: [NSItemProvider]) {
    var mutableAttachments = attachments
    guard !mutableAttachments.isEmpty else {
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        self.tableView.reloadData()
        LoadingUtils.stopLoading(in: self)
      }
      return
    }

    let provider = mutableAttachments.removeFirst()

    guard provider.hasItemConformingToTypeIdentifier(contentType) else {
      return loadAttachments(mutableAttachments)
    }

    provider.loadItem(
      forTypeIdentifier: contentType,
      options: nil
    ) { [weak self, mutableAttachments] (data, error) in
      defer {
        self?.loadAttachments(mutableAttachments)
      }

      guard error == nil else { return }

      // A file as before, or a web link to an audio file or archive (fork); other links would land as
      // web pages dressed as audiobooks
      if let url = data as? URL, url.isFileURL || ShareDownloads.isDownloadableWebURL(url) {
        self?.sharedItems.append(url)
      }
    }
  }

  func handleSharedFiles() {
    // extracting the path to the URL that is being shared
    guard
      let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
      let attachments = extensionItem.attachments
    else {
      didPressCancel()
      return
    }

    LoadingUtils.loadAndBlock(in: self)
    loadAttachments(attachments)
  }

  @objc func didPressCancel() {
    extensionContext?.cancelRequest(withError: ShareExtensionError.cancelled)
  }

  @objc func didPressDone() {
    LoadingUtils.loadAndBlock(in: self)
    startDownloads(of: sharedItems.filter { !$0.isFileURL })
    saveSharedItems(sharedItems.filter(\.isFileURL))
  }

  /// Downloads the shared web links in a background session of this share's own (fork). The system
  /// runs it after the share sheet closes; whichever process holds the session when a download ends
  /// puts the file in the shared folder for the app's import. The session is recorded before any task
  /// starts, so the app can reconnect to it if this extension is gone before the downloads end
  private func startDownloads(of links: [URL]) {
    guard !links.isEmpty else { return }

    let identifier = ShareDownloads.makeSessionIdentifier()
    let registry = ShareDownloadSessionRegistry.appGroup
    let receiver = ShareDownloadReceiver(
      sessionIdentifier: identifier,
      sharedFolder: sharedFolder,
      failures: ShareImportFailureStore.appGroup,
      registry: registry
    )
    let session = ShareDownloads.makeSession(identifier: identifier, receiver: receiver)
    let tasks = links.map { session.downloadTask(with: $0) }

    // Without the record the downloads still run and iOS still hands them to the app when it wakes
    // it; only the reconnect after the app was force-quit wouldn't know them
    try? registry?.record(
      ShareDownloadSessionRegistry.Session(
        identifier: identifier,
        startedAt: Date(),
        taskIdentifiers: tasks.map(\.taskIdentifier)
      )
    )

    for task in tasks {
      task.resume()
    }
    // Closes once its tasks end; if this process is gone first, the app takes the session over
    session.finishTasksAndInvalidate()
  }

  func saveSharedItems(_ items: [URL]) {
    var mutableItems = items
    guard !mutableItems.isEmpty else {
      DispatchQueue.main.async { [weak self] in
        self?.extensionContext?.completeRequest(returningItems: nil)
      }
      return
    }

    let item = mutableItems.removeFirst()

    let destinationURL = sharedFolder.appendingPathComponent(item.lastPathComponent)
    do {
      try FileManager.default.copyItem(at: item, to: destinationURL)
    } catch {
      // The app shows it next time it's opened: the share sheet is gone by then (fork)
      ShareImportFailureStore.appGroup?.append(
        ShareImportFailure(source: item.lastPathComponent, reason: .copyFailed(detail: error.localizedDescription))
      )
    }

    saveSharedItems(mutableItems)
  }

  func applyDefaultThemeColors() {
    view.backgroundColor = defaultTheme.systemBackgroundColor
    tableView.backgroundColor = defaultTheme.systemBackgroundColor
    tableView.separatorColor = defaultTheme.separatorColor

    navigationBar.barTintColor = defaultTheme.systemBackgroundColor
    navigationBar.tintColor = defaultTheme.linkColor
    navigationBar.titleTextAttributes = [
      NSAttributedString.Key.foregroundColor: defaultTheme.primaryColor
    ]
    navigationBar.largeTitleTextAttributes = [
      NSAttributedString.Key.foregroundColor: defaultTheme.primaryColor
    ]
  }
}

extension ShareViewController: UITableViewDataSource {
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    return sharedItems.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let item = sharedItems[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "ShareCellView", for: indexPath)

    var configuration =  cell.defaultContentConfiguration()
    configuration.text = item.lastPathComponent
    configuration.textProperties.font = Fonts.body
    configuration.textProperties.color = defaultTheme.primaryColor
    let imageName = item.isDirectoryFolder ? "folder" : "waveform"
    configuration.image = UIImage(systemName: imageName)
    configuration.imageProperties.tintColor = defaultTheme.linkColor
    cell.contentConfiguration = configuration
    cell.backgroundColor = defaultTheme.systemBackgroundColor

    return cell
  }
}

extension ShareViewController: UITableViewDelegate {}

enum ShareExtensionError: Error {
  case cancelled
}
