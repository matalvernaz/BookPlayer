//
//  AudioMetadataServiceTests.swift
//  BookPlayerTests
//
//  Copyright © 2025 BookPlayer LLC. All rights reserved.
//

import AVFoundation
@testable import BookPlayer
@testable import BookPlayerKit
import XCTest

final class AudioMetadataServiceTests: XCTestCase {
  var sut: AudioMetadataService!

  override func setUp() {
    super.setUp()
    sut = AudioMetadataService()
  }

  private func fixtureURL(_ name: String, _ ext: String) throws -> URL {
    let url = Bundle(for: Self.self).url(forResource: name, withExtension: ext)
    return try XCTUnwrap(url, "Missing fixture \(name).\(ext)")
  }

  // MARK: - extractMetadata (native-first, with manual fallbacks)

  func testExtractMetadata_wellFormedM4B_returnsChaptersViaNative() async throws {
    let url = try fixtureURL("m4b_WELLFORMED", "m4b")
    let metadata = await sut.extractMetadata(from: url)
    XCTAssertEqual(metadata?.chapters?.count, 4)
    XCTAssertEqual(metadata?.chapters?.first?.title, "Chapter One – Intro")
  }

  func testExtractMetadata_mp3WithCTOC_returnsChaptersViaNative() async throws {
    let url = try fixtureURL("mp3_WITH_toc", "mp3")
    let metadata = await sut.extractMetadata(from: url)
    XCTAssertEqual(metadata?.chapters?.count, 4)
  }

  func testExtractMetadata_malformedM4B_recoversViaQuickTimeFallback() async throws {
    // AVFoundation reports no chapters for this file; extractMetadata must fall through to the
    // manual QuickTime text-track parser.
    let url = try fixtureURL("m4b_MALFORMED", "m4b")
    let metadata = await sut.extractMetadata(from: url)
    XCTAssertEqual(metadata?.chapters?.count, 4)
  }

  func testExtractMetadata_mp3WithoutCTOC_recoversViaID3Fallback() async throws {
    // No CTOC frame, so AVFoundation exposes nothing; the ID3 CHAP parser recovers them.
    let url = try fixtureURL("mp3_NO_toc_v23", "mp3")
    let metadata = await sut.extractMetadata(from: url)
    XCTAssertEqual(metadata?.chapters?.count, 4)
  }

  func testExtractMetadata_noChapters_returnsNilChapters() async throws {
    let url = try fixtureURL("mp3_NO_chapters", "mp3")
    let metadata = await sut.extractMetadata(from: url)
    XCTAssertNil(metadata?.chapters)
  }

  // MARK: - extractManualChapters (bypasses AVFoundation native)

  func testExtractManualChapters_malformedM4B() async throws {
    let url = try fixtureURL("m4b_MALFORMED", "m4b")
    let chapters = await sut.extractManualChapters(from: url)
    XCTAssertEqual(chapters?.count, 4)
  }

  func testExtractManualChapters_mp3NoCTOC_v23() async throws {
    let url = try fixtureURL("mp3_NO_toc_v23", "mp3")
    let chapters = await sut.extractManualChapters(from: url)
    XCTAssertEqual(chapters?.count, 4)
  }

  func testExtractManualChapters_mp3NoCTOC_v24() async throws {
    let url = try fixtureURL("mp3_NO_toc_v24", "mp3")
    let chapters = await sut.extractManualChapters(from: url)
    XCTAssertEqual(chapters?.count, 4)
  }

  func testExtractManualChapters_wellFormedM4B_isChronologicalAndTitled() async throws {
    let url = try fixtureURL("m4b_WELLFORMED", "m4b")
    let parsed = await sut.extractManualChapters(from: url)
    let chapters = try XCTUnwrap(parsed)
    XCTAssertEqual(chapters.count, 4)
    XCTAssertEqual(chapters.map(\.start), chapters.map(\.start).sorted())
    XCTAssertFalse(chapters.contains { $0.title.isEmpty })
  }

  func testExtractManualChapters_noChapters_returnsNil() async throws {
    let url = try fixtureURL("mp3_NO_chapters", "mp3")
    let chapters = await sut.extractManualChapters(from: url)
    XCTAssertNil(chapters)
  }

  // MARK: - Title and author (fork, upstream #1665)

  /// The common keys AVFoundation gives the file's tags. The tests below first check the tag they read
  /// has none, so only the lookup by identifier can find it
  private func commonKeys(in url: URL) async throws -> [AVMetadataKey] {
    try await AVURLAsset(url: url).load(.metadata).compactMap(\.commonKey)
  }

  /// #1665: an m4b whose only author tag is its album artist (aART) imported as "Unknown author"
  func testAnM4BsAlbumArtistIsItsAuthor() async throws {
    let url = try fixtureURL("m4b_aART_only", "m4b")
    let keys = try await commonKeys(in: url)
    XCTAssertFalse(keys.contains(.commonKeyArtist), "the fixture has no ©ART")
    XCTAssertFalse(keys.contains(.commonKeyAuthor))

    let metadata = await sut.extractMetadata(from: url)
    XCTAssertEqual(metadata?.artist, "Album Artist Only")
    XCTAssertEqual(metadata?.title, "Album Artist Test")
  }

  /// The same for an MP3 tagged only with TPE2 (the ID3 album artist) and, for its title, only TOAL
  /// (the original album)
  func testAnMP3sAlbumArtistAndOriginalAlbumAreItsAuthorAndTitle() async throws {
    let url = try fixtureURL("mp3_TPE2_TOAL_only", "mp3")
    let keys = try await commonKeys(in: url)
    XCTAssertFalse(keys.contains(.commonKeyArtist), "the fixture has no TPE1")
    XCTAssertFalse(keys.contains(.commonKeyAuthor))
    XCTAssertFalse(keys.contains(.commonKeyTitle), "the fixture has no TIT2")
    XCTAssertFalse(keys.contains(.commonKeyAlbumName), "the fixture has no TALB")

    let metadata = await sut.extractMetadata(from: url)
    XCTAssertEqual(metadata?.artist, "Band Only")
    XCTAssertEqual(metadata?.title, "Original Album Only")
  }

  /// Files the common keys already read keep what they had
  func testTagsWithCommonKeysReadAsBefore() async throws {
    let m4b = await sut.extractMetadata(from: try fixtureURL("m4b_WELLFORMED", "m4b"))
    XCTAssertEqual(m4b?.title, "Chapter Test (M4B)")
    XCTAssertEqual(m4b?.artist, "Test")

    let mp3 = await sut.extractMetadata(from: try fixtureURL("mp3_WITH_toc", "mp3"))
    XCTAssertEqual(mp3?.title, "Chapter Test (MP3)")
    XCTAssertEqual(mp3?.artist, "", "no author tag at all")
  }
}
