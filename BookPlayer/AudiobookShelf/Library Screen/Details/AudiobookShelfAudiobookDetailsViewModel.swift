//
//  AudiobookShelfAudiobookDetailsViewModel.swift
//  BookPlayer
//
//  Created by Gianni Carlo on 11/14/25.
//  Copyright © 2025 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import Foundation

class AudiobookShelfAudiobookDetailsViewModel: IntegrationDetailsViewModelProtocol {

  let item: AudiobookShelfLibraryItem
  let connectionService: AudiobookShelfConnectionService
  @Published var details: AudiobookShelfAudiobookDetailsData?
  @Published var error: Error?
  private var singleFileDownloadService: SingleFileDownloadService

  private var fetchTask: Task<(), any Error>?

  init(
    item: AudiobookShelfLibraryItem,
    connectionService: AudiobookShelfConnectionService,
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
  func beginDownloadAudiobook(_ item: AudiobookShelfLibraryItem) throws {
    let request = try connectionService.createItemDownloadRequest(item)
    connectionService.registerItemDownloadProvenance(request, itemId: item.id)
    singleFileDownloadService.handleDownload(request)
  }
}
