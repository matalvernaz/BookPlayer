//
//  JellyfinAudiobookDetailsViewModel.swift
//  BookPlayer
//
//  Created by Lysann Tranvouez on 2024-11-26.
//  Copyright © 2024 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Foundation
import JellyfinAPI

struct JellyfinAudiobookDetailsData: IntegrationDetailsDataProtocol {
  let artist: String?
  let filePath: String?
  let fileSize: Int?
  let overview: String?
  let runtimeInSeconds: TimeInterval?
  let genres: [String]?
  let tags: [String]?

  var fileSizeString: String {
    if let fileSize {
      ByteCountFormatter.string(
        fromByteCount: Int64(fileSize),
        countStyle: ByteCountFormatter.CountStyle.file
      )
    } else {
      "file_size_unknown".localized
    }
  }

  var runtimeString: String {
    if let runtimeInSeconds {
      return TimeParser.formatTotalDuration(runtimeInSeconds)
    } else {
      return "runtime_unknown".localized
    }
  }
}

class JellyfinAudiobookDetailsViewModel: IntegrationDetailsViewModelProtocol {

  let item: JellyfinLibraryItem
  let connectionService: JellyfinConnectionService
  @Published var details: JellyfinAudiobookDetailsData?
  @Published var error: Error?
  private var singleFileDownloadService: SingleFileDownloadService

  private var fetchTask: Task<(), any Error>?

  init(
    item: JellyfinLibraryItem,
    connectionService: JellyfinConnectionService,
    singleFileDownloadService: SingleFileDownloadService
  ) {
    self.item = item
    self.connectionService = connectionService
    self.singleFileDownloadService = singleFileDownloadService
  }

  @MainActor
  func fetchData() {
    guard fetchTask == nil else {
      return
    }

    fetchTask = Task { @MainActor in
      defer { if !Task.isCancelled { self.fetchTask = nil } }

      do {
        let details = try await connectionService.fetchItemDetails(for: item.id)

        guard !Task.isCancelled else { return }
        self.details = details
      } catch let error where error.isCancellation {
        // ignore
      } catch {
        // Assign inline (not via a detached Task) so `cancelFetchData()` on
        // the way out of the screen also suppresses the error alert.
        guard !Task.isCancelled else { return }
        self.error = error
      }
    }
  }

  @MainActor
  func cancelFetchData() {
    fetchTask?.cancel()
    fetchTask = nil
  }

  @MainActor
  func beginDownloadAudiobook(_ item: JellyfinLibraryItem) throws {
    let request = try connectionService.createItemDownloadRequest(item)
    connectionService.registerItemDownloadProvenance(request, itemId: item.id)
    singleFileDownloadService.handleDownload(request)
  }
}
