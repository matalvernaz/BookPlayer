//
//  SoundBoothLibraryTests.swift
//  BookPlayerTests
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

@testable import BookPlayer
@testable import BookPlayerKit
import XCTest

/// The SoundBooth library's levels, worked out in July against a bundle-heavy account and an à-la-carte
/// one, here on made-up data of the same shapes: series, then seasons, then episodes; season bundles
/// listing their episodes when opened; series the list calls leave out named from the catalog; a series
/// owned in several formats split by format
@MainActor
final class SoundBoothLibraryTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var keychain: KeychainServiceMock!
  private var http: SoundBoothHTTPStub!
  private var service: SoundBoothConnectionService!
  private var viewModel: SoundBoothLibraryViewModel!

  private typealias F = SoundBoothFixtures
  private let past = "2025-03-01T00:00:00.000Z"
  private let later = "2025-03-08T00:00:00.000Z"
  private let latest = "2025-03-15T00:00:00Z"
  private let future = "2099-01-01T00:00:00.000Z"

  override func setUpWithError() throws {
    try super.setUpWithError()
    suiteName = "SoundBoothLibraryTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    keychain = KeychainServiceMock()
    try keychain.set(
      [SoundBoothConnectionData(session: SoundBoothSession(jwt: "jwt", userId: "user", email: "reader@example.com"), id: "acct")],
      key: .soundboothConnection
    )
    http = SoundBoothHTTPStub()
    service = SoundBoothConnectionService(
      keychainService: keychain,
      apiClient: SoundBoothAPIClient(configuration: .production, httpClient: http),
      defaults: defaults
    )
    service.setup()
    viewModel = SoundBoothLibraryViewModel(
      connectionService: service,
      singleFileDownloadService: SingleFileDownloadService(networkClient: NetworkClientMock(mockedResponse: Empty())),
      sourceStore: MediaServerSourceStore(userDefaults: defaults)
    )
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    viewModel = nil
    service = nil
    http = nil
    keychain = nil
    defaults = nil
    super.tearDown()
  }

  private func library(_ owned: [[String: Any]], series: [[String: Any]] = [], seasons: [[String: Any]] = []) {
    http.reply("/functions/u/library-elements/list", json: F.page(owned))
    http.reply("/functions/u/series/list", json: F.page(series))
    http.reply("/functions/u/groups/list", json: F.page(seasons))
  }

  private func names(_ sections: [SoundBoothLibrarySection]) -> [[String]] {
    sections.map { $0.rows.map(\.displayName) }
  }

  /// One series with a season bundle, a season owned episode by episode and a standalone book; a season
  /// bundle of a series nobody names; a title of no series
  private func mixedLibrary() {
    library(
      [
        F.ownedSeason("g-s1", "Season 1", series: "s-saga"),
        F.owned(F.episode("e-s2-1", "Season Two Opener", series: "s-saga", group: "g-s2", releaseAt: past)),
        F.owned(F.element("b-prequel", "The Prequel", series: "s-saga", format: "audiobook", releaseAt: past)),
        F.ownedSeason("g-mystery", "Mystery Season", series: "s-unnamed"),
        F.owned(F.element("b-loose", "A Loose Title", format: "audiobook")),
      ],
      series: [F.series("s-saga", "The Saga")],
      seasons: [F.season("g-s2", "Season 2", index: 2), F.season("g-s1", "Season 1", index: 1)]
    )
  }

  // MARK: - The top level

  func testTheTopLevelListsSeriesThenLooseSeasonsThenOtherTitles() async throws {
    mixedLibrary()

    await viewModel.loadLibrary()

    XCTAssertEqual(viewModel.loadState, .loaded)
    let sections = viewModel.sections(for: .root)
    XCTAssertEqual(names(sections), [["The Saga", "Mystery Season"], ["A Loose Title"]])
    XCTAssertEqual(sections.map(\.title), [nil, "soundbooth_other_titles_title".localized])
    guard sections.count == 2 else { return }
    XCTAssertEqual(sections[0].rows.map(\.kind), [.series, .group])
    XCTAssertEqual(sections[1].rows.first?.isDownloadable, true)
    // Every title's series was named, so the catalog wasn't needed
    XCTAssertTrue(http.requests(to: "/functions/u/items/list").isEmpty)
  }

  /// A library of nothing but titles of no series just lists them
  func testALibraryOfLooseTitlesHasNoHeader() async throws {
    library([F.owned(F.element("b1", "Only Title"))])

    await viewModel.loadLibrary()

    let sections = viewModel.sections(for: .root)
    XCTAssertEqual(names(sections), [["Only Title"]])
    XCTAssertEqual(sections.map(\.title), [nil])
  }

  /// `series/list` leaves out some series (free previews and the like); the catalog names them, and
  /// their seasons
  func testASeriesTheListLeavesOutIsNamedFromTheCatalog() async throws {
    library([F.owned(F.episode("e-free", "Free Pilot", series: "s-free", group: "g-free", releaseAt: past))])
    http.reply(
      "/functions/u/items/list",
      json: F.page([
        F.episode(
          "e-free",
          "Free Pilot",
          series: F.ref("s-free", "Free Previews"),
          group: F.ref("g-free", "Pilot Season", index: 1),
          releaseAt: past
        ),
      ])
    )

    await viewModel.loadLibrary()

    XCTAssertEqual(names(viewModel.sections(for: .root)), [["Free Previews"]])
    XCTAssertEqual(names(viewModel.sections(for: .series(id: "s-free", name: "Free Previews"))), [["Pilot Season"]])
    XCTAssertEqual(names(viewModel.sections(for: .season(id: "g-free", name: "Pilot Season"))), [["Free Pilot"]])
  }

  /// The series and season names only nest titles: without them the library still loads, flat
  func testTheLibraryLoadsWithoutSeriesOrSeasonNames() async throws {
    http.reply("/functions/u/library-elements/list", json: F.page([F.owned(F.element("b1", "Title", series: "s1"))]))
    http.reply("/functions/u/series/list", json: ["success": false], status: 500)
    http.reply("/functions/u/groups/list", json: ["success": false], status: 500)

    await viewModel.loadLibrary()

    XCTAssertEqual(viewModel.loadState, .loaded)
    XCTAssertEqual(names(viewModel.sections(for: .root)), [["Title"]])
  }

  func testAnExpiredSessionAsksToSignInAgain() async throws {
    http.reply("/functions/u/library-elements/list", json: ["success": false], status: 401)

    await viewModel.loadLibrary()

    XCTAssertEqual(viewModel.sessionExpiredError, .sessionExpired(serverName: "SoundBooth"))
    guard case .failed = viewModel.loadState else {
      return XCTFail("expected a failed load, got \(viewModel.loadState)")
    }
  }

  func testAFailedLoadSaysWhy() async throws {
    http.reply("/functions/u/library-elements/list", json: ["success": false], status: 502)

    await viewModel.loadLibrary()

    XCTAssertEqual(viewModel.loadState, .failed(message: IntegrationError.unexpectedResponse(code: 502).localizedDescription))
    XCTAssertNil(viewModel.sessionExpiredError)
  }

  // MARK: - A series

  /// Seasons in their order (bundles and seasons owned episode by episode alike), then titles outside
  /// a season
  func testASeriesListsItsSeasonsInOrderThenItsTitles() async throws {
    mixedLibrary()
    await viewModel.loadLibrary()

    let sections = viewModel.sections(for: .series(id: "s-saga", name: "The Saga"))

    XCTAssertEqual(names(sections), [["Season 1", "Season 2"], ["The Prequel"]])
    guard sections.count == 2 else { return }
    XCTAssertEqual(sections[0].rows.map(\.kind), [.group, .group])
    XCTAssertEqual(sections[1].rows.first?.seriesName, "The Saga")
  }

  /// A story sold in several formats, tagged unevenly, gets a section per format; what can't be pinned
  /// to one goes last without a header
  func testASeriesOwnedInSeveralFormatsIsSplitByFormat() async throws {
    library(
      [
        F.owned(F.element("b-audio", "The Story", series: "s-story", format: "audiobook", releaseAt: past)),
        F.owned(F.episode("e-c1", "Part One", series: "s-story", group: "g-cinema", format: "cinematic", releaseAt: past)),
        F.owned(F.episode("e-c2", "Part Two", series: "s-story", group: "g-cinema", format: "cinematic", releaseAt: later)),
        F.owned(F.element("b-extra", "Behind the Scenes", series: "s-story", format: nil, releaseAt: past)),
        F.owned(F.element("b-radio", "Radio Edit", series: "s-story", format: "radio play", releaseAt: past)),
      ],
      series: [F.series("s-story", "The Story")],
      seasons: [F.season("g-cinema", "The Story: Cinematic", index: 1)]
    )
    await viewModel.loadLibrary()

    let sections = viewModel.sections(for: .series(id: "s-story", name: "The Story"))

    XCTAssertEqual(sections.map(\.id), ["format-audiobook", "format-cinematic", "format-radio play", "format-none"])
    XCTAssertEqual(
      sections.map(\.title),
      ["soundbooth_format_audiobook".localized, "soundbooth_format_cinematic".localized, "Radio Play", nil]
    )
    XCTAssertEqual(names(sections), [["The Story"], ["The Story: Cinematic"], ["Radio Edit"], ["Behind the Scenes"]])
  }

  func testFormatsShowInTheStoresOrder() {
    XCTAssertEqual(
      SoundBoothLibraryViewModel.orderedFormats(["bonus", "zine", "immersion", "audiobook", "cinematic", "anthology"]),
      ["audiobook", "cinematic", "immersion", "bonus", "anthology", "zine"]
    )
  }

  // MARK: - A season

  func testASeasonOwnedEpisodeByEpisodeListsThem() async throws {
    mixedLibrary()
    await viewModel.loadLibrary()

    let node = SoundBoothNode.season(id: "g-s2", name: "Season 2")
    await viewModel.loadSeasonIfNeeded(node)

    XCTAssertEqual(names(viewModel.sections(for: node)), [["Season Two Opener"]])
    XCTAssertTrue(http.requests(to: "/functions/u/items/list").isEmpty, "nothing to fetch for it")
  }

  /// A bundle has no episode entries of its own: they're fetched when it's opened, once, and listed
  /// in release order, the unreleased ones shown with their date and not downloadable
  func testASeasonBundleListsItsEpisodesWhenOpened() async throws {
    mixedLibrary()
    await viewModel.loadLibrary()
    http.reply(
      "/functions/u/items/list",
      json: F.page([
        F.episode("e3", "Episode 3", series: "s-saga", group: "g-s1", releaseAt: future),
        F.episode("e2", "Episode 2", series: "s-saga", group: "g-s1", releaseAt: later),
        F.episode("e1", "Episode 1", series: "s-saga", group: "g-s1", releaseAt: past),
      ])
    )
    let node = SoundBoothNode.season(id: "g-s1", name: "Season 1")
    XCTAssertTrue(viewModel.sections(for: node).isEmpty)

    await viewModel.loadSeasonIfNeeded(node)
    await viewModel.loadSeasonIfNeeded(node)

    let rows = try XCTUnwrap(viewModel.sections(for: node).first).rows
    XCTAssertEqual(rows.map(\.displayName), ["Episode 1", "Episode 2", "Episode 3"])
    XCTAssertEqual(rows.map(\.isDownloadable), [true, true, false])
    XCTAssertEqual(rows.map(\.kind), [.episode, .episode, .episode])
    XCTAssertEqual(rows.first?.seriesName, "The Saga")
    let unreleased = try XCTUnwrap(rows.last)
    let releaseLabel = String(
      format: "soundbooth_releases_format".localized,
      try XCTUnwrap(unreleased.releaseDate).formatted(date: .abbreviated, time: .omitted)
    )
    XCTAssertEqual(unreleased.detailLabel, "soundbooth_format_audiobook".localized + " · " + releaseLabel)
    XCTAssertTrue(viewModel.canDownloadSeason(node))
    XCTAssertEqual(viewModel.releasedEpisodeCount(node), 2)

    let fetches = http.requests(to: "/functions/u/items/list")
    XCTAssertEqual(fetches.count, 1, "opened twice, fetched once")
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(fetches.first?.httpBody)) as? [String: String])
    XCTAssertEqual(body, ["groupId": "g-s1"])
  }

  func testRefreshingASeasonBundleFetchesItAgain() async throws {
    mixedLibrary()
    await viewModel.loadLibrary()
    http.reply("/functions/u/items/list", json: F.page([F.episode("e1", "Episode 1", series: "s-saga", group: "g-s1", releaseAt: past)]))
    let node = SoundBoothNode.season(id: "g-s1", name: "Season 1")
    await viewModel.loadSeasonIfNeeded(node)

    http.reply(
      "/functions/u/items/list",
      json: F.page([
        F.episode("e1", "Episode 1", series: "s-saga", group: "g-s1", releaseAt: past),
        F.episode("e2", "Episode 2", series: "s-saga", group: "g-s1", releaseAt: later),
      ])
    )
    await viewModel.refresh(node)

    XCTAssertEqual(names(viewModel.sections(for: node)), [["Episode 1", "Episode 2"]])
    XCTAssertEqual(http.requests(to: "/functions/u/library-elements/list").count, 1, "only the season was asked again")
  }

  func testASeasonWithNothingReleasedCantBeDownloaded() async throws {
    library(
      [F.owned(F.episode("e1", "Soon", series: "s1", group: "g1", releaseAt: future))],
      series: [F.series("s1", "Series")],
      seasons: [F.season("g1", "Season", index: 1)]
    )
    await viewModel.loadLibrary()

    let node = SoundBoothNode.season(id: "g1", name: "Season")
    XCTAssertFalse(viewModel.canDownloadSeason(node))
    XCTAssertEqual(viewModel.releasedEpisodeCount(node), 0)
    XCTAssertFalse(viewModel.canDownloadSeason(.series(id: "s1", name: "Series")))
  }

  // MARK: - Rows

  func testARowsKindAndWhatItOffers() throws {
    let book = SoundBoothLibraryItem(raw: try F.decode(SoundBoothElement.self, F.element("b1", "Book", format: "audiobook")))
    let episode = SoundBoothLibraryItem(raw: try F.decode(SoundBoothElement.self, F.episode("e1", "Episode", series: nil, group: nil, releaseAt: past)))
    let season = SoundBoothLibraryItem(raw: try F.decode(SoundBoothElement.self, F.element("g1", "Season", subtype: nil, format: "audiobook")), isGroup: true)
    let series = SoundBoothLibraryItem(id: "s1", displayName: "Series", kind: .series)

    XCTAssertEqual(book.kind, .book)
    XCTAssertEqual(episode.kind, .episode)
    XCTAssertEqual(season.kind, .group)
    XCTAssertNil(season.format, "a season has no format of its own")
    XCTAssertTrue(book.isDownloadable)
    XCTAssertFalse(season.isDownloadable)
    XCTAssertFalse(series.isDownloadable)
    XCTAssertEqual(series.childNode, .series(id: "s1", name: "Series"))
    XCTAssertEqual(season.childNode, .season(id: "g1", name: "Season"))
    XCTAssertNil(book.childNode)
  }

  func testTheLineUnderATitle() throws {
    let audiobook = SoundBoothLibraryItem(raw: try F.decode(SoundBoothElement.self, F.element("b1", "Book", format: "audiobook")))
    let unformatted = SoundBoothLibraryItem(raw: try F.decode(SoundBoothElement.self, F.element("b2", "Book", format: "")))

    XCTAssertEqual(audiobook.detailLabel, "soundbooth_format_audiobook".localized)
    XCTAssertNil(unformatted.detailLabel)
    XCTAssertNil(unformatted.format)
    XCTAssertEqual(SoundBoothLibraryItem.formatDisplayName("immersion"), "soundbooth_format_immersion".localized)
    XCTAssertEqual(SoundBoothLibraryItem.formatDisplayName("bonus"), "soundbooth_format_bonus".localized)
    XCTAssertEqual(SoundBoothLibraryItem.formatDisplayName("radio play"), "Radio Play")
    XCTAssertNil(SoundBoothLibraryItem.formatDisplayName(nil))
  }

  /// A title already out shows no date, whatever its release field says
  func testATitleThatIsOutHasNoReleaseDate() throws {
    let element = try F.decode(SoundBoothElement.self, F.element("b1", "Book", releaseAt: "2026-06-01T00:00:00.000Z"))

    let before = SoundBoothLibraryItem(raw: element, now: Date(timeIntervalSince1970: 1_780_000_000))
    let after = SoundBoothLibraryItem(raw: element, now: Date(timeIntervalSince1970: 1_790_000_000))

    XCTAssertNotNil(before.releaseDate)
    XCTAssertFalse(before.isDownloadable)
    XCTAssertNil(after.releaseDate)
    XCTAssertTrue(after.isDownloadable)
  }

  /// Rows are the same row when their ids are, whatever else changed since
  func testARowIsItsId() throws {
    let first = SoundBoothLibraryItem(raw: try F.decode(SoundBoothElement.self, F.element("b1", "Old Name")))
    let renamed = SoundBoothLibraryItem(raw: try F.decode(SoundBoothElement.self, F.element("b1", "New Name")))

    XCTAssertEqual(first, renamed)
    XCTAssertEqual(Set([first, renamed]).count, 1)
  }

  // MARK: - Strings

  /// Every key the SoundBooth screens use is in the strings table: a missing one reads aloud as its name
  func testEverySoundBoothStringExists() {
    for key in [
      "soundbooth_account_header", "soundbooth_code_accessibility", "soundbooth_code_footer_format",
      "soundbooth_code_header", "soundbooth_code_label", "soundbooth_code_missing",
      "soundbooth_different_email_button", "soundbooth_download_season_button", "soundbooth_email_accessibility",
      "soundbooth_email_footer", "soundbooth_email_invalid", "soundbooth_format_audiobook",
      "soundbooth_format_bonus", "soundbooth_format_cinematic", "soundbooth_format_immersion",
      "soundbooth_library_empty", "soundbooth_no_chapters", "soundbooth_other_titles_title",
      "soundbooth_preparing_download", "soundbooth_refresh_button", "soundbooth_releases_format",
      "soundbooth_send_code_button", "soundbooth_sign_in_header", "soundbooth_trim_credits_footer",
      "soundbooth_trim_credits_toggle",
      // Shared keys the screens use
      "integration_connection_details_title", "integration_sign_in_button", "integration_retry_button",
      "voiceover_close_button", "download_title", "downloading_file_title", "chapter_number_title",
      "email_title", "logout_title", "settings_title",
    ] {
      XCTAssertNotEqual(key.localized, key, key)
    }
    XCTAssertEqual(String.localizedStringWithFormat("soundbooth_episode_count".localized, 1), "1 episode")
    XCTAssertEqual(String.localizedStringWithFormat("soundbooth_episode_count".localized, 3), "3 episodes")
  }
}
