//
//  MediaServerDownloadQueueTests.swift
//  BookPlayerTests
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

@testable import BookPlayerKit
import SwiftData
import XCTest

/// A download's progress, keyed from its provenance, goes through upstream's own push queue (fork):
/// on every tier, into the provider's lane, coalescing only with updates for the same item on the same
/// server
final class MediaServerDownloadQueueTests: XCTestCase {
  private var tasksDataManager: TasksDataManager!
  private var repository: SyncQueueRepository!

  override func setUpWithError() throws {
    let schema = Schema([
      UploadTaskModel.self,
      UpdateTaskModel.self,
      MoveTaskModel.self,
      DeleteTaskModel.self,
      DeleteBookmarkTaskModel.self,
      SetBookmarkTaskModel.self,
      RenameFolderTaskModel.self,
      ArtworkUploadTaskModel.self,
      MatchUuidsTaskModel.self,
      UploadExternalResourceTaskModel.self,
      ExternalResourceToDownloadTaskModel.self,
      DeleteExternalResourceTaskModel.self,
      SyncQueueContainer.self,
      QueuedTaskReferenceModel.self,
      ExternalUpdateTaskModel.self,
      UploadFileTaskModel.self,
    ])
    let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    let container = try ModelContainer(for: schema, configurations: config)
    tasksDataManager = TasksDataManager(container: container)
    repository = SyncQueueRepository(tasksDataManager: tasksDataManager)
  }

  override func tearDown() {
    repository = nil
    tasksDataManager = nil
    super.tearDown()
  }

  /// What `LibraryService.updatePlaybackTime` publishes for an Audiobookshelf download
  private func playbackUpdate(providerId: String, hostId: String = "https://abs.example.com") -> [String: Any] {
    [
      "relativePath": "Dune.m4b",
      "currentTime": 30.0,
      "lastPlayDate": 1_800_000_000.0,
      "percentCompleted": 5.0,
      "uuid": UUID().uuidString,
      "providerId": providerId,
      "providerName": "audiobookshelf",
      "hostId": hostId,
    ]
  }

  /// A task as the queue stores it, for the coalescing tests
  private func task(providerId: String = "li_1", hostId: String?) -> [String: Any] {
    var params: [String: Any] = [
      "id": UUID().uuidString,
      "jobType": SyncJobType.externalUpdate.rawValue,
      "queueKey": "audiobookshelf",
      "providerName": "audiobookshelf",
      "providerId": providerId,
      "currentTime": 30.0,
      "percentCompleted": 5.0,
    ]
    if let hostId {
      params["hostId"] = hostId
    }
    return params
  }

  private func waitForTaskCount(_ count: Int, timeout: TimeInterval = 3) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await repository.getAllTasks().count >= count { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTFail("timed out waiting for \(count) task(s)")
  }

  /// Free, plus, lite and pro alike: the push goes to the user's own server, and needs no BookPlayer
  /// account or subscription
  func testADownloadsUpdateQueuesOnEveryTier() async throws {
    let service = SyncQueueService(maxConcurrentTasks: 1)
    service.taskContainer = repository
    let tiers: [AccessLevel] = [.free, .plus, .lite, .pro]

    for (index, tier) in tiers.enumerated() {
      service.updateAccessPolicy(tier)
      service.scheduleMetadataUpdate(params: playbackUpdate(providerId: "li_\(index)"))
      try await waitForTaskCount(index + 1)
    }

    let queued = await repository.getAllTasksWithParams(in: "audiobookshelf")
    XCTAssertEqual(Set(queued.compactMap { $0.parameters["providerId"] as? String }), ["li_0", "li_1", "li_2", "li_3"])
    for task in queued {
      XCTAssertEqual(task.jobType, .externalUpdate)
      XCTAssertEqual(task.parameters["hostId"] as? String, "https://abs.example.com")
    }
  }

  func testTheSameItemOnOneServerCoalesces() async throws {
    try await repository.storeTask(parameters: task(hostId: "https://abs.example.com"))
    try await repository.storeTask(parameters: task(hostId: "https://abs.example.com"))

    let tasks = await repository.getAllTasks()
    XCTAssertEqual(tasks.count, 1)
  }

  /// Two servers can hold items with the same id: an update for one never replaces the other's
  func testTheSameItemIdOnTwoServersStaysTwoTasks() async throws {
    try await repository.storeTask(parameters: task(hostId: "https://home.example.com"))
    try await repository.storeTask(parameters: task(hostId: "https://work.example.com"))

    let queued = await repository.getAllTasksWithParams(in: "audiobookshelf")
    XCTAssertEqual(Set(queued.compactMap { $0.parameters["hostId"] as? String }), ["https://home.example.com", "https://work.example.com"])
  }

  /// A task queued without a host (from before hosts were recorded) coalesces only with others
  /// without one
  func testTasksWithoutAHostCoalesceOnlyWithEachOther() async throws {
    try await repository.storeTask(parameters: task(hostId: nil))
    try await repository.storeTask(parameters: task(hostId: nil))
    var tasks = await repository.getAllTasks()
    XCTAssertEqual(tasks.count, 1)

    try await repository.storeTask(parameters: task(hostId: "https://abs.example.com"))
    tasks = await repository.getAllTasks()
    XCTAssertEqual(tasks.count, 2)
  }
}
