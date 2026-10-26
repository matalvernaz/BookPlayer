//
//  SoundBoothDownloadTests.swift
//  BookPlayerTests
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

@testable import BookPlayer
@testable import BookPlayerKit
import Combine
import XCTest

/// SoundBooth downloads: a title (or a season's released episodes) is a folder of chapters named in play
/// order, recorded to be bound into one book that starts where SoundBooth's own apps left off. Nothing is
/// queued unless every chapter's audio URL resolved.
@MainActor
final class SoundBoothDownloadTests: XCTestCase {
  private typealias F = SoundBoothFixtures
  private typealias Queued = (request: URLRequest, folderName: String?, fileName: String?)

  private var suiteName: String!
  private var defaults: UserDefaults!
  private var store: MediaServerSourceStore!
  private var keychain: KeychainServiceMock!
  private var http: SoundBoothHTTPStub!
  private var service: SoundBoothConnectionService!
  private var downloadService: SingleFileDownloadService!
  private var viewModel: SoundBoothLibraryViewModel!
  private var queueWatch: AnyCancellable?
  /// The download queue as it stood when the banner said the download started. The download service
  /// takes the first request off its queue as soon as the test lets it run
  private var queuedAtStart: [Queued]?
  /// What the tests put in Documents, removed afterwards
  private var leftovers = [URL]()

  private let past = "2025-03-01T00:00:00.000Z"
  private let later = "2025-03-08T00:00:00.000Z"
  private let future = "2099-01-01T00:00:00.000Z"

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "SoundBoothDownloadTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    store = MediaServerSourceStore(userDefaults: defaults)
    keychain = KeychainServiceMock()
    // Two accounts, the first active; each test starts with the library listed for it
    try keychain.set(
      [
        SoundBoothConnectionData(session: SoundBoothSession(jwt: "jwt", userId: "user", email: "reader@example.com"), id: "acct"),
        SoundBoothConnectionData(session: SoundBoothSession(jwt: "jwt-other", userId: "other", email: "other@example.com"), id: "other"),
      ],
      key: .soundboothConnection
    )
    http = SoundBoothHTTPStub()
    service = SoundBoothConnectionService(
      keychainService: keychain,
      apiClient: SoundBoothAPIClient(configuration: .production, httpClient: http),
      defaults: defaults
    )
    service.setup()
    downloadService = SingleFileDownloadService(networkClient: NetworkClientMock(mockedResponse: Empty()))
    viewModel = SoundBoothLibraryViewModel(
      connectionService: service,
      singleFileDownloadService: downloadService,
      sourceStore: store
    )
    let downloadService = self.downloadService!
    queueWatch = viewModel.$downloadStatus.sink { [weak self] status in
      // Published before it's set, straight after the requests were queued
      guard let status, status != "soundbooth_preparing_download".localized else { return }
      self?.queuedAtStart = downloadService.downloadQueue
    }
    XCTAssertEqual(service.connection?.id, "acct", "precondition: the first saved account starts active")
    await listTheLibrary()
  }

  /// The owned set as the first account sees it (empty unless a test says otherwise), so downloads have
  /// a listing to go out with
  private func listTheLibrary(owned: [[String: Any]] = [], series: [[String: Any]] = [], seasons: [[String: Any]] = []) async {
    http.reply("/functions/u/library-elements/list", json: F.page(owned))
    http.reply("/functions/u/series/list", json: F.page(series))
    http.reply("/functions/u/groups/list", json: F.page(seasons))
    await viewModel.loadLibrary()
  }

  override func tearDown() {
    for url in leftovers {
      try? FileManager.default.removeItem(at: url)
    }
    leftovers = []
    queueWatch = nil
    queuedAtStart = nil
    defaults.removePersistentDomain(forName: suiteName)
    viewModel = nil
    downloadService = nil
    service = nil
    http = nil
    keychain = nil
    store = nil
    defaults = nil
    super.tearDown()
  }

  private func resources(_ json: [[String: Any]]) throws -> [SoundBoothItemResource] {
    try json.map { try F.decode(SoundBoothItemResource.self, $0) }
  }

  private func elements(_ json: [[String: Any]]) throws -> [SoundBoothElement] {
    try json.map { try F.decode(SoundBoothElement.self, $0) }
  }

  private func progress(item: String, resource: String, position: Double, finished: Bool = false, updatedAt: String) throws -> SoundBoothProgress {
    try F.decode(SoundBoothProgress.self, F.progress(item: item, resource: resource, position: position, finished: finished, updatedAt: updatedAt))
  }

  private func title(_ id: String, _ name: String, series: String?) throws -> SoundBoothLibraryItem {
    SoundBoothLibraryItem(raw: try F.decode(SoundBoothElement.self, F.element(id, name, format: "audiobook")), seriesName: series)
  }

  /// A title's two chapters, and where each one's audio is
  private func chapters(of item: String) {
    http.reply(
      "/functions/playlist/item-resources",
      json: F.ok([
        "itemResources": [
          F.resource("\(item)-r2", item: item, number: 1, name: "Chapter 1", duration: 600),
          F.resource("\(item)-r1", item: item, number: 0, name: "Opening Credits", duration: 60),
        ],
      ])
    )
    http.redirect(resource: "\(item)-r1", to: "https://cdn.example.com/\(item)-r1.mp3?token=1")
    http.redirect(resource: "\(item)-r2", to: "https://cdn.example.com/\(item)-r2.mp3?token=2")
  }

  private func savedPosition(item: String, resource: String, position: Double) {
    http.reply(
      "/functions/user/progresses",
      json: F.ok([F.progress(item: item, resource: resource, position: position, updatedAt: "2026-10-01T00:00:00.000Z")])
    )
  }

  /// A folder name under Documents whatever an earlier run left there, cleared again afterwards
  private func clearDocuments(_ name: String) {
    let url = DataManager.getDocumentsFolderURL().appendingPathComponent(name)
    try? FileManager.default.removeItem(at: url)
    leftovers.append(url)
  }

  private func waitUntil(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
  ) async throws {
    for _ in 0..<400 where !condition() {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertTrue(condition(), file: file, line: line)
  }

  // MARK: - A title's chapters

  /// Numbered by position, not by SoundBooth's `number`, which can repeat: two chapters under one name
  /// would lose the second
  func testATitlesChaptersArePositionNumbered() throws {
    let plan = SoundBoothLibraryViewModel.titlePlan(try resources([
      F.resource("r-b", item: "b1", number: 1, name: "Chapter One"),
      F.resource("r-c", item: "b1", number: 2, name: "Closing Credits"),
      F.resource("r-o", item: "b1", number: 0, name: "Opening Credits"),
      F.resource("r-a", item: "b1", number: 1, name: "Chapter One"),
    ]))

    XCTAssertEqual(plan.all.map(\.id), ["r-o", "r-a", "r-b", "r-c"])
    XCTAssertEqual(plan.kept.map(\.resource.id), ["r-o", "r-a", "r-b", "r-c"])
    XCTAssertEqual(
      plan.kept.map(\.fileName),
      ["001 - Opening Credits.mp3", "002 - Chapter One.mp3", "003 - Chapter One.mp3", "004 - Closing Credits.mp3"]
    )
  }

  func testANamelessChapterIsNamedByItsPosition() throws {
    let plan = SoundBoothLibraryViewModel.titlePlan(try resources([
      F.resource("r1", item: "b1", number: 0, name: nil),
      F.resource("r2", item: "b1", number: 1, name: "   "),
    ]))

    XCTAssertEqual(
      plan.kept.map(\.fileName),
      [
        "001 - " + String(format: "chapter_number_title".localized, 1) + ".mp3",
        "002 - " + String(format: "chapter_number_title".localized, 2) + ".mp3",
      ]
    )
  }

  func testAChaptersNameIsMadeSafeForAFile() {
    XCTAssertEqual(SoundBoothLibraryViewModel.chapterFileName(position: 7, name: "Part 1/2: The Return?"), "007 - Part 1_2_ The Return.mp3")
  }

  // MARK: - A season's chapters

  /// Episodes are numbered among those that have chapters, so the numbers have no gaps
  func testASeasonIsNumberedAmongItsEpisodesWithChapters() throws {
    let episodes = try elements([
      F.episode("e1", "One", series: nil, group: "g", releaseAt: past),
      F.episode("e2", "Two", series: nil, group: "g", releaseAt: past),
      F.episode("e3", "Three", series: nil, group: "g", releaseAt: later),
    ])

    let plan = SoundBoothLibraryViewModel.seasonPlan(
      episodes: episodes,
      resources: try resources([
        F.resource("e3-r1", item: "e3", number: 1, name: "Story"),
        F.resource("e1-r1", item: "e1", number: 1, name: "Story"),
      ]),
      trimCredits: true
    )

    XCTAssertEqual(plan.kept.map(\.resource.id), ["e1-r1", "e3-r1"])
    XCTAssertEqual(plan.kept.map(\.fileName), ["E001 001 - Story.mp3", "E002 001 - Story.mp3"])
  }

  /// Three episodes, each with its own credits ("Credits" serving for both in the middle one): one book
  /// keeps the season's first opening credits and its last closing credits
  private func creditedSeason() throws -> (episodes: [SoundBoothElement], resources: [SoundBoothItemResource]) {
    let episodes = try elements([
      F.episode("e1", "One", series: nil, group: "g", releaseAt: past),
      F.episode("e2", "Two", series: nil, group: "g", releaseAt: past),
      F.episode("e3", "Three", series: nil, group: "g", releaseAt: later),
    ])
    var chapters = [[String: Any]]()
    for episode in ["e1", "e2", "e3"] {
      let opening = episode == "e2" ? "Credits" : "Opening Credits"
      let closing = episode == "e2" ? "Credits" : "Closing Credits"
      chapters.append(F.resource("\(episode)-open", item: episode, number: 0, name: opening, duration: 10))
      chapters.append(F.resource("\(episode)-story", item: episode, number: 1, name: "Story", duration: 100))
      chapters.append(F.resource("\(episode)-close", item: episode, number: 2, name: closing, duration: 20))
    }
    return (episodes, try resources(chapters))
  }

  func testTrimmingKeepsTheSeasonsFirstOpeningAndLastClosingCredits() throws {
    let season = try creditedSeason()

    let plan = SoundBoothLibraryViewModel.seasonPlan(episodes: season.episodes, resources: season.resources, trimCredits: true)

    XCTAssertEqual(plan.all.count, 9)
    XCTAssertEqual(plan.kept.map(\.resource.id), ["e1-open", "e1-story", "e2-story", "e3-story", "e3-close"])
    XCTAssertEqual(
      plan.kept.map(\.fileName),
      [
        "E001 001 - Opening Credits.mp3", "E001 002 - Story.mp3", "E002 002 - Story.mp3", "E003 002 - Story.mp3",
        "E003 003 - Closing Credits.mp3",
      ]
    )
  }

  func testWithoutTrimmingEveryChapterStays() throws {
    let season = try creditedSeason()

    let plan = SoundBoothLibraryViewModel.seasonPlan(episodes: season.episodes, resources: season.resources, trimCredits: false)

    XCTAssertEqual(plan.kept.map(\.resource.id), plan.all.map(\.id))
    XCTAssertEqual(plan.kept.count, 9)
  }

  /// An episode that is nothing but its credits keeps them: there'd be nothing left of it
  func testAnEpisodeThatIsOnlyCreditsKeepsThem() throws {
    let episodes = try elements([
      F.episode("e1", "One", series: nil, group: "g", releaseAt: past),
      F.episode("e2", "Two", series: nil, group: "g", releaseAt: later),
    ])

    let plan = SoundBoothLibraryViewModel.seasonPlan(
      episodes: episodes,
      resources: try resources([
        F.resource("e1-only", item: "e1", number: 0, name: "Credits"),
        F.resource("e2-open", item: "e2", number: 0, name: "Opening Credits"),
        F.resource("e2-story", item: "e2", number: 1, name: "Story"),
        F.resource("e2-close", item: "e2", number: 2, name: "Closing Credits"),
      ]),
      trimCredits: true
    )

    XCTAssertEqual(plan.kept.map(\.resource.id), ["e1-only", "e2-open", "e2-story", "e2-close"])
  }

  /// The first episode may have no opening credits of its own: the first ones in the season stay
  func testTheFirstOpeningCreditsMayComeLater() throws {
    let episodes = try elements([
      F.episode("e1", "One", series: nil, group: "g", releaseAt: past),
      F.episode("e2", "Two", series: nil, group: "g", releaseAt: later),
    ])

    let plan = SoundBoothLibraryViewModel.seasonPlan(
      episodes: episodes,
      resources: try resources([
        F.resource("e1-story", item: "e1", number: 0, name: "Story"),
        F.resource("e1-close", item: "e1", number: 1, name: "Closing Credits"),
        F.resource("e2-open", item: "e2", number: 0, name: "Opening Credits"),
        F.resource("e2-story", item: "e2", number: 1, name: "Story"),
        F.resource("e2-close", item: "e2", number: 2, name: "Closing Credits"),
      ]),
      trimCredits: true
    )

    XCTAssertEqual(plan.kept.map(\.resource.id), ["e1-story", "e2-open", "e2-story", "e2-close"])
  }

  func testWhatCountsAsCredits() {
    XCTAssertTrue(SoundBoothLibraryViewModel.isCreditsChapter("Opening Credits"))
    XCTAssertTrue(SoundBoothLibraryViewModel.isCreditsChapter("CREDITS"))
    XCTAssertTrue(SoundBoothLibraryViewModel.isCreditsChapter("End credit"))
    XCTAssertFalse(SoundBoothLibraryViewModel.isCreditsChapter("Chapter 1"))
    XCTAssertFalse(SoundBoothLibraryViewModel.isCreditsChapter(nil))
  }

  // MARK: - Where the book starts

  /// A title of three chapters: 60, 100 and 200 seconds
  private func threeChapters(firstDuration: Double? = 60) throws -> SoundBoothDownloadPlan {
    SoundBoothLibraryViewModel.titlePlan(try resources([
      F.resource("r1", item: "b1", number: 0, name: "One", duration: firstDuration),
      F.resource("r2", item: "b1", number: 1, name: "Two", duration: 100),
      F.resource("r3", item: "b1", number: 2, name: "Three", duration: 200),
    ]))
  }

  private func offset(_ progresses: [SoundBoothProgress], plan: SoundBoothDownloadPlan, itemIds: Set<String> = ["b1"]) -> Double? {
    SoundBoothLibraryViewModel.resumeOffset(progresses: progresses, itemIds: itemIds, plan: plan)
  }

  func testThePositionIsTheChaptersBeforeItPlusTheWayIn() throws {
    let plan = try threeChapters()

    XCTAssertNil(offset([], plan: plan))
    XCTAssertEqual(try offset([progress(item: "b1", resource: "r2", position: 30, updatedAt: "1")], plan: plan), 90)
    XCTAssertEqual(try offset([progress(item: "b1", resource: "r2", position: 30, finished: true, updatedAt: "1")], plan: plan), 160)
    XCTAssertEqual(try offset([progress(item: "b1", resource: "r2", position: 500, updatedAt: "1")], plan: plan), 160, "held to the chapter")
    XCTAssertEqual(try offset([progress(item: "b1", resource: "r2", position: -5, updatedAt: "1")], plan: plan), 60)
  }

  /// No resume beats a wrong one, and the very start isn't a resume
  func testNoPositionWhenThereIsNothingToResume() throws {
    let plan = try threeChapters()

    XCTAssertNil(try offset([progress(item: "b1", resource: "r1", position: 0, updatedAt: "1")], plan: plan))
    XCTAssertNil(try offset([progress(item: "b1", resource: "r1", position: 0.5, updatedAt: "1")], plan: plan))
    XCTAssertNil(try offset([progress(item: "b1", resource: "r2", position: 30, updatedAt: "1")], plan: try threeChapters(firstDuration: nil)))
    XCTAssertNil(try offset([progress(item: "b2", resource: "r2", position: 30, updatedAt: "1")], plan: plan), "another title's")
  }

  /// The newest position the plan can place: a newer one on another title, or on a chapter that isn't
  /// in the plan, doesn't hide it
  func testTheNewestPositionThePlanCanPlaceWins() throws {
    let plan = try threeChapters()

    let positions = try [
      progress(item: "b1", resource: "r1", position: 10, updatedAt: "2026-10-01T00:00:00.000Z"),
      progress(item: "b1", resource: "r3", position: 20, updatedAt: "2026-10-02T00:00:00.000Z"),
      progress(item: "b2", resource: "x1", position: 99, updatedAt: "2026-10-03T00:00:00.000Z"),
      progress(item: "b1", resource: "gone", position: 99, updatedAt: "2026-10-04T00:00:00.000Z"),
    ]

    XCTAssertEqual(offset(positions, plan: plan), 180)
  }

  /// A trimmed credits chapter takes no time in the book: a position on one starts the next chapter kept
  func testTrimmedCreditsTakeNoTime() throws {
    let season = try creditedSeason()
    let plan = SoundBoothLibraryViewModel.seasonPlan(episodes: season.episodes, resources: season.resources, trimCredits: true)
    let episodes: Set<String> = ["e1", "e2", "e3"]

    XCTAssertEqual(try offset([progress(item: "e2", resource: "e2-open", position: 5, updatedAt: "1")], plan: plan, itemIds: episodes), 110)
    XCTAssertEqual(try offset([progress(item: "e2", resource: "e2-story", position: 30, updatedAt: "1")], plan: plan, itemIds: episodes), 140)
  }

  // MARK: - Queuing a title

  func testATitleDownloadsAsOneBookFromWhereSoundBoothLeftOff() async throws {
    let folder = "The Series - The Title"
    clearDocuments(folder)
    chapters(of: "b1")
    savedPosition(item: "b1", resource: "b1-r2", position: 30)

    viewModel.downloadItem(try title("b1", "The Title", series: "The Series"))
    try await waitUntil { queuedAtStart != nil }

    let queued = try XCTUnwrap(queuedAtStart)
    XCTAssertEqual(queued.map(\.folderName), [folder, folder])
    XCTAssertEqual(queued.map(\.fileName), ["001 - Opening Credits.mp3", "002 - Chapter 1.mp3"])
    XCTAssertEqual(
      queued.map { $0.request.url?.absoluteString },
      ["https://cdn.example.com/b1-r1.mp3?token=1", "https://cdn.example.com/b1-r2.mp3?token=2"]
    )
    for entry in queued {
      // The CDN URL carries its own token; the account's session stays with SoundBooth's API
      XCTAssertNil(entry.request.value(forHTTPHeaderField: "Authorization"))
      XCTAssertNil(entry.request.value(forHTTPHeaderField: "Cookie"))
    }
    XCTAssertEqual(
      store.takeLandedSource(at: folder),
      MediaServerSourceInfo(kind: .soundbooth, connectionId: "acct", itemId: "b1", shouldBindFolder: true, seedTime: 90)
    )
    XCTAssertEqual(viewModel.downloadStatus, String.localizedStringWithFormat("downloading_file_title".localized, 2))
    XCTAssertNil(viewModel.downloadError)
    let asked = try XCTUnwrap(http.requests(to: "/functions/playlist/item-resources").first?.httpBody)
    XCTAssertEqual((try JSONSerialization.jsonObject(with: asked) as? [String: [String]]), ["itemIds": ["b1"]])
  }

  /// A title of no series is named by itself
  func testATitleOfNoSeriesIsNamedAlone() async throws {
    clearDocuments("Loose Title")
    chapters(of: "b1")

    viewModel.downloadItem(try title("b1", "Loose Title", series: nil))
    try await waitUntil { queuedAtStart != nil }

    XCTAssertEqual(queuedAtStart?.first?.folderName, "Loose Title")
    XCTAssertNil(store.takeLandedSource(at: "Loose Title")?.seedTime, "no saved position")
  }

  /// Every chapter's URL comes before anything is queued: July queued what had resolved and saved
  /// CacheFly's 404 page for the rest
  func testAChapterThatWontResolveQueuesNothing() async throws {
    clearDocuments("The Series - The Title")
    chapters(of: "b1")
    http.failRedirect(resource: "b1-r2", with: SoundBoothAPIError.noRedirect(status: 200))

    viewModel.downloadItem(try title("b1", "The Title", series: "The Series"))
    try await waitUntil { viewModel.downloadError != nil }

    XCTAssertEqual(viewModel.downloadError, IntegrationError.unexpectedResponse(code: 200).localizedDescription)
    XCTAssertNil(viewModel.downloadStatus)
    XCTAssertNil(queuedAtStart)
    XCTAssertTrue(downloadService.downloadQueue.isEmpty)
    XCTAssertNil(downloadService.currentDownloadTask)
    XCTAssertFalse(store.hasLandedSource(at: "The Series - The Title"))
  }

  func testATitleWithNoChaptersSaysSo() async throws {
    http.reply("/functions/playlist/item-resources", json: F.ok(["itemResources": [Any]()]))

    viewModel.downloadItem(try title("b1", "Empty", series: nil))
    try await waitUntil { viewModel.downloadError != nil }

    XCTAssertEqual(viewModel.downloadError, "soundbooth_no_chapters".localized)
    XCTAssertNil(viewModel.downloadStatus)
    XCTAssertTrue(downloadService.downloadQueue.isEmpty)
    XCTAssertTrue(http.requests(to: "/functions/resources/play").isEmpty)
  }

  /// The positions only decide where the book starts: failing to read them doesn't stop the download
  func testUnreadablePositionsDontStopTheDownload() async throws {
    clearDocuments("Title")
    chapters(of: "b1")
    http.reply("/functions/user/progresses", json: ["success": false], status: 500)

    viewModel.downloadItem(try title("b1", "Title", series: nil))
    try await waitUntil { queuedAtStart != nil }

    XCTAssertEqual(queuedAtStart?.count, 2)
    let info = try XCTUnwrap(store.takeLandedSource(at: "Title"))
    XCTAssertNil(info.seedTime)
    XCTAssertEqual(info.shouldBindFolder, true)
  }

  func testAPositionAtTheVeryStartSeedsNothing() async throws {
    clearDocuments("Title")
    chapters(of: "b1")
    savedPosition(item: "b1", resource: "b1-r1", position: 0)

    viewModel.downloadItem(try title("b1", "Title", series: nil))
    try await waitUntil { queuedAtStart != nil }

    XCTAssertNil(try XCTUnwrap(store.takeLandedSource(at: "Title")).seedTime)
  }

  /// Two titles with one name get two folders, as two books, the second numbered
  func testTwoTitlesWithOneNameGetTwoFolders() async throws {
    clearDocuments("Series - Same")
    clearDocuments("Series - Same 2")
    chapters(of: "b1")
    viewModel.downloadItem(try title("b1", "Same", series: "Series"))
    try await waitUntil { queuedAtStart != nil }
    queuedAtStart = nil

    chapters(of: "b2")
    viewModel.downloadItem(try title("b2", "Same", series: "Series"))
    try await waitUntil { queuedAtStart != nil }

    XCTAssertEqual(store.takeLandedSource(at: "Series - Same")?.itemId, "b1")
    XCTAssertEqual(store.takeLandedSource(at: "Series - Same 2")?.itemId, "b2")
  }

  /// A signed-out account's title asks nothing more and queues nothing
  func testASignedOutAccountQueuesNothing() async throws {
    chapters(of: "b1")
    http.hold("/functions/playlist/item-resources")
    viewModel.downloadItem(try title("b1", "Title", series: nil))
    try await waitUntil { http.isHolding }

    service.deleteConnection(id: "acct")
    http.release()
    try await waitUntil { viewModel.downloadError != nil }

    XCTAssertTrue(http.requests(to: "/functions/resources/play").isEmpty)
    XCTAssertNil(queuedAtStart)
    XCTAssertFalse(store.hasLandedSource(at: "Title"))
  }

  // MARK: - The account a download goes out with

  /// Logging out of one account makes another active while the first one's library is still on screen.
  /// A title tapped then goes out with the account it was listed for, never the one active now
  func testATitleGoesOutWithTheAccountItWasListedFor() async throws {
    clearDocuments("Title")
    chapters(of: "b1")
    service.activateConnection(id: "other")

    viewModel.downloadItem(try title("b1", "Title", series: nil))
    try await waitUntil { queuedAtStart != nil }

    let asked = http.requests.filter { $0.url?.path != "/functions/u/library-elements/list" && $0.url?.path != "/functions/u/series/list" && $0.url?.path != "/functions/u/groups/list" }
    XCTAssertFalse(asked.isEmpty)
    for request in asked {
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token jwt", request.url?.path ?? "")
    }
    XCTAssertEqual(store.takeLandedSource(at: "Title")?.connectionId, "acct")
  }

  func testASeasonGoesOutWithTheAccountItWasListedFor() async throws {
    clearDocuments("The Series - Season One")
    let node = await openSeasonOne()
    service.activateConnection(id: "other")

    viewModel.downloadSeason(node, trimCredits: true)
    try await waitUntil { queuedAtStart != nil }

    let resources = try XCTUnwrap(http.requests(to: "/functions/playlist/item-resources").first)
    XCTAssertEqual(resources.value(forHTTPHeaderField: "Authorization"), "Token jwt")
    XCTAssertEqual(store.takeLandedSource(at: "The Series - Season One")?.connectionId, "acct")
  }

  /// The account the library was listed for is gone: nothing goes out with another one instead
  func testALoggedOutAccountsTitleAsksNothing() async throws {
    chapters(of: "b1")
    service.deleteConnection(id: "acct")
    XCTAssertEqual(service.connection?.id, "other", "precondition: the other account is active now")

    viewModel.downloadItem(try title("b1", "Title", series: nil))
    try await waitUntil { viewModel.downloadError != nil }

    XCTAssertTrue(http.requests(to: "/functions/playlist/item-resources").isEmpty)
    XCTAssertNil(queuedAtStart)
  }

  /// Logged out while SoundBooth's saved positions were read: they only decide where the book starts,
  /// but nothing is queued for an account that's gone
  func testALogOutWhileThePositionsAreReadQueuesNothing() async throws {
    clearDocuments("Title")
    chapters(of: "b1")
    savedPosition(item: "b1", resource: "b1-r2", position: 30)
    http.hold("/functions/user/progresses")
    viewModel.downloadItem(try title("b1", "Title", series: nil))
    try await waitUntil { http.isHolding }

    service.deleteConnection(id: "acct")
    http.release()
    try await waitUntil { viewModel.downloadError != nil }

    XCTAssertEqual(http.requests(to: "/functions/resources/play").count, 2, "precondition: the chapters resolved before the log-out")
    XCTAssertNil(queuedAtStart)
    XCTAssertTrue(downloadService.downloadQueue.isEmpty)
    XCTAssertFalse(store.hasLandedSource(at: "Title"))
  }

  // MARK: - Answers that arrive after a switch

  private func rows(_ node: SoundBoothNode) -> [[String]] {
    viewModel.sections(for: node).map { $0.rows.map(\.displayName) }
  }

  /// The first account's library answer arrives after the other account's library has loaded: it's
  /// dropped, and downloads stay with the other account
  func testALibraryAnswerThatArrivesAfterASwitchIsDropped() async throws {
    http.reply("/functions/u/library-elements/list", json: F.page([F.owned(F.element("a1", "First Account's Title"))]))
    http.hold("/functions/u/library-elements/list")
    let viewModel = self.viewModel!
    let firstLoad = Task { await viewModel.loadLibrary() }
    try await waitUntil { http.isHolding }

    service.activateConnection(id: "other")
    http.reply("/functions/u/library-elements/list", json: F.page([F.owned(F.element("b1", "Other Account's Title"))]))
    await viewModel.loadLibrary()
    XCTAssertEqual(rows(.root), [["Other Account's Title"]], "precondition")

    http.release()
    await firstLoad.value

    XCTAssertEqual(rows(.root), [["Other Account's Title"]])
    XCTAssertEqual(viewModel.listedConnectionId, "other")
    XCTAssertEqual(viewModel.loadState, .loaded)
    XCTAssertEqual(
      http.requests(to: "/functions/u/library-elements/list").suffix(2).map { $0.value(forHTTPHeaderField: "Authorization") },
      ["Token jwt", "Token jwt-other"]
    )
  }

  /// A season's episodes asked for under the first account's listing arrive after the other account's
  /// listing: they're dropped, and the season asks again with the other account
  func testASeasonAnswerThatArrivesAfterASwitchIsDropped() async throws {
    let owned = [F.ownedSeason("g1", "Season One", series: "s1")]
    let series = [F.series("s1", "The Series")]
    let seasons = [F.season("g1", "Season One", index: 1)]
    await listTheLibrary(owned: owned, series: series, seasons: seasons)
    let node = SoundBoothNode.season(id: "g1", name: "Season One")
    http.reply("/functions/u/items/list", json: F.page([F.episode("e1", "First Account's Episode", series: "s1", group: "g1", releaseAt: past)]))
    http.hold("/functions/u/items/list")
    let viewModel = self.viewModel!
    let firstFetch = Task { await viewModel.loadSeasonIfNeeded(node) }
    try await waitUntil { http.isHolding }

    service.activateConnection(id: "other")
    await listTheLibrary(owned: owned, series: series, seasons: seasons)
    http.release()
    await firstFetch.value

    XCTAssertEqual(rows(node), [], "the first account's answer isn't the other's")
    http.reply("/functions/u/items/list", json: F.page([F.episode("e1", "Other Account's Episode", series: "s1", group: "g1", releaseAt: past)]))
    await viewModel.loadSeasonIfNeeded(node)
    XCTAssertEqual(rows(node), [["Other Account's Episode"]])
    XCTAssertEqual(
      http.requests(to: "/functions/u/items/list").map { $0.value(forHTTPHeaderField: "Authorization") },
      ["Token jwt", "Token jwt-other"]
    )
  }

  /// Another account is active, but the library on screen is still the first one's: its season opens
  /// with the first account
  func testASeasonOpensWithTheAccountTheLibraryWasListedFor() async throws {
    await listTheLibrary(
      owned: [F.ownedSeason("g1", "Season One", series: "s1")],
      series: [F.series("s1", "The Series")],
      seasons: [F.season("g1", "Season One", index: 1)]
    )
    let node = SoundBoothNode.season(id: "g1", name: "Season One")
    service.activateConnection(id: "other")
    http.reply("/functions/u/items/list", json: F.page([F.episode("e1", "Episode 1", series: "s1", group: "g1", releaseAt: past)]))

    await viewModel.loadSeasonIfNeeded(node)

    XCTAssertEqual(http.requests(to: "/functions/u/items/list").first?.value(forHTTPHeaderField: "Authorization"), "Token jwt")
    XCTAssertEqual(rows(node), [["Episode 1"]])
  }

  // MARK: - Queuing a season

  /// The first account's library: one season bundle of three episodes, the middle one not out yet, and
  /// the first and last episodes' chapters. Returns the season, opened
  private func openSeasonOne() async -> SoundBoothNode {
    await listTheLibrary(
      owned: [F.ownedSeason("g1", "Season One", series: "s1")],
      series: [F.series("s1", "The Series")],
      seasons: [F.season("g1", "Season One", index: 1)]
    )
    http.reply(
      "/functions/u/items/list",
      json: F.page([
        F.episode("e1", "Episode 1", series: "s1", group: "g1", releaseAt: past),
        F.episode("e2", "Episode 2", series: "s1", group: "g1", releaseAt: future),
        F.episode("e3", "Episode 3", series: "s1", group: "g1", releaseAt: later),
      ])
    )
    let node = SoundBoothNode.season(id: "g1", name: "Season One")
    await viewModel.loadSeasonIfNeeded(node)
    http.reply(
      "/functions/playlist/item-resources",
      json: F.ok([
        "itemResources": [
          F.resource("e3-r1", item: "e3", number: 1, name: "Story"),
          F.resource("e1-r1", item: "e1", number: 1, name: "Story"),
        ],
      ])
    )
    http.redirect(resource: "e1-r1", to: "https://cdn.example.com/e1-r1.mp3")
    http.redirect(resource: "e3-r1", to: "https://cdn.example.com/e3-r1.mp3")
    return node
  }

  /// A season bundle's released episodes become one book; one not out yet leaves no gap in the numbers
  func testAnUnreleasedEpisodeLeavesNoGap() async throws {
    let folder = "The Series - Season One"
    clearDocuments(folder)
    let node = await openSeasonOne()

    viewModel.downloadSeason(node, trimCredits: true)
    try await waitUntil { queuedAtStart != nil }

    let queued = try XCTUnwrap(queuedAtStart)
    XCTAssertEqual(queued.map(\.fileName), ["E001 001 - Story.mp3", "E002 001 - Story.mp3"])
    XCTAssertEqual(queued.map(\.folderName), [folder, folder])
    XCTAssertEqual(queued.map { $0.request.url?.lastPathComponent }, ["e1-r1.mp3", "e3-r1.mp3"])
    let asked = try XCTUnwrap(http.requests(to: "/functions/playlist/item-resources").first?.httpBody)
    XCTAssertEqual((try JSONSerialization.jsonObject(with: asked) as? [String: [String]]), ["itemIds": ["e1", "e3"]])
    XCTAssertEqual(
      store.takeLandedSource(at: folder),
      MediaServerSourceInfo(kind: .soundbooth, connectionId: "acct", itemId: "g1", shouldBindFolder: true)
    )
  }

  // MARK: - Into the library

  /// End to end: the chapters land in their folder, the import gives it another name because a book
  /// already has that one, and the folder still becomes one book starting at the seed
  func testTheDownloadedFolderBecomesOneBookAtItsSeed() async throws {
    let folder = "The Series - The Title"
    DataTestUtils.clearFolderContents(url: DataManager.getProcessedFolderURL())
    clearDocuments(folder)
    defer { DataTestUtils.clearFolderContents(url: DataManager.getProcessedFolderURL()) }
    let libraryService = LibraryService()
    libraryService.setup(
      dataManager: DataManager(coreDataStack: CoreDataStack(testPath: "/dev/null")),
      audioMetadataService: AudioMetadataService()
    )
    _ = libraryService.getLibrary()
    // Something in Processed already has the name
    _ = try DataTestUtils.generateTestFolder(name: folder, destinationFolder: DataManager.getProcessedFolderURL())

    chapters(of: "b1")
    savedPosition(item: "b1", resource: "b1-r2", position: 30)
    viewModel.downloadItem(try title("b1", "The Title", series: "The Series"))
    try await waitUntil { queuedAtStart != nil }
    let fileNames = try XCTUnwrap(queuedAtStart).compactMap(\.fileName)

    // What the download service saves: each file under its name, in the folder it was given
    let landed = try DataTestUtils.generateTestFolder(name: folder, destinationFolder: DataManager.getDocumentsFolderURL())
    for name in fileNames {
      _ = DataTestUtils.generateTestFile(name: name, contents: Data("audio".utf8), destinationFolder: landed)
    }

    let operation = ImportOperation(files: [landed], libraryService: libraryService, mediaServerSourceStore: store)
    let done = XCTestExpectation(description: "import finished")
    operation.completionBlock = { done.fulfill() }
    operation.start()
    await fulfillment(of: [done], timeout: 15)
    XCTAssertEqual(operation.processedFiles.map(\.lastPathComponent), ["\(folder)-1"])
    _ = await libraryService.insertItems(from: operation.processedFiles)

    let completer = MediaServerBoundBookCompleter(
      sourceStore: store,
      libraryService: libraryService,
      downloadService: downloadService
    )
    completer.sweep()
    // The seed is saved on the library's short delay, as playback positions are
    libraryService.dataManager.saveContext()

    let book = try XCTUnwrap(libraryService.getSimpleItem(with: "\(folder)-1"))
    XCTAssertEqual(book.type, .bound)
    XCTAssertEqual(book.currentTime, 90, accuracy: 0.001)

    // The seed is applied once: a position moved since stays when the completer sweeps again
    libraryService.updatePlaybackTime(relativePath: "\(folder)-1", time: 200, date: Date(), scheduleSave: false)
    completer.sweep()
    libraryService.dataManager.saveContext()
    XCTAssertEqual(try XCTUnwrap(libraryService.getSimpleItem(with: "\(folder)-1")).currentTime, 200, accuracy: 0.001)
    let parts = try XCTUnwrap(libraryService.fetchContents(at: "\(folder)-1", limit: nil, offset: nil))
    XCTAssertEqual(parts.map { ($0.relativePath as NSString).lastPathComponent }, fileNames)
    XCTAssertNil(store.source(for: folder), "the item that already had the name isn't this download")
  }
}
