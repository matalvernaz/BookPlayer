//
//  ImportOperationTests.swift
//  BookPlayerTests
//
//  Created by Gianni Carlo on 9/13/18.
//  Copyright © 2018 BookPlayer LLC. All rights reserved.
//

@testable import BookPlayer
@testable import BookPlayerKit
import XCTest
import ZipArchive

// MARK: - processFiles()

class ImportOperationTests: XCTestCase {
  override func setUp() {
    super.setUp()
    // Put setup code here. This method is called before the invocation of each test method in the class.
    let documentsFolder = DataManager.getDocumentsFolderURL()
    DataTestUtils.clearFolderContents(url: documentsFolder)
    let sharedFolder = DataManager.getSharedFilesFolderURL()
    DataTestUtils.clearFolderContents(url: sharedFolder)
  }

  func testProcessOneFile() {
    let filename = "file.txt"
    let bookContents = "bookcontents".data(using: .utf8)!
    let documentsFolder = DataManager.getDocumentsFolderURL()

    // Add test file to Documents folder
    let fileUrl = DataTestUtils.generateTestFile(name: filename, contents: bookContents, destinationFolder: documentsFolder)

    let promise = XCTestExpectation(description: "Process file")
    let promiseFile = expectation(forNotification: .processingFile, object: nil)
    let dataManager = DataManager(coreDataStack: CoreDataStack(testPath: "/dev/null"))
    let audioMetadataService = AudioMetadataService()
    let libraryService = LibraryService()
    libraryService.setup(dataManager: dataManager, audioMetadataService: audioMetadataService)
    let operation = ImportOperation(files: [fileUrl],
                                    libraryService: libraryService)

    operation.completionBlock = {
      // Test file should no longer be in the Documents folder,
      // but when testing on simulator, the security scope is resolved
      XCTAssert(!FileManager.default.fileExists(atPath: fileUrl.path))

      XCTAssertNotNil(operation.files.first)
      XCTAssertNotNil(operation.processedFiles.first)

      let processedFile = operation.processedFiles.first!

      // Test file exists in new location
      XCTAssert(FileManager.default.fileExists(atPath: processedFile.path))

      let content = FileManager.default.contents(atPath: processedFile.path)!
      XCTAssert(content == bookContents)

      promise.fulfill()
    }

    operation.start()

    wait(for: [promise, promiseFile], timeout: 15)
  }

  func testProcessFileFromSharedFolder() {
    let filename = "shared_file.txt"
    let bookContents = "sharedbookcontents".data(using: .utf8)!
    let sharedFolder = DataManager.getSharedFilesFolderURL()

    // Add test file to the App Group SharedFiles folder (Share-extension drop location)
    let fileUrl = DataTestUtils.generateTestFile(name: filename, contents: bookContents, destinationFolder: sharedFolder)

    let promise = XCTestExpectation(description: "Process shared file")
    let dataManager = DataManager(coreDataStack: CoreDataStack(testPath: "/dev/null"))
    let audioMetadataService = AudioMetadataService()
    let libraryService = LibraryService()
    libraryService.setup(dataManager: dataManager, audioMetadataService: audioMetadataService)
    let operation = ImportOperation(files: [fileUrl], libraryService: libraryService)

    operation.completionBlock = {
      // Source in SharedFiles should be cleaned up after import (isAppManagedSource)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fileUrl.path))

      XCTAssertNotNil(operation.processedFiles.first)
      let processedFile = operation.processedFiles.first!
      XCTAssert(FileManager.default.fileExists(atPath: processedFile.path))
      XCTAssertEqual(FileManager.default.contents(atPath: processedFile.path), bookContents)

      promise.fulfill()
    }

    operation.start()

    wait(for: [promise], timeout: 15)
  }

  func testProcessFileFromInboxFolder() throws {
    let filename = "inbox_file.txt"
    let bookContents = "inboxbookcontents".data(using: .utf8)!
    let inboxFolder = DataManager.getInboxFolderURL()
    try FileManager.default.createDirectory(at: inboxFolder, withIntermediateDirectories: true)

    // Add test file to the Documents/Inbox folder (system inbox for document interactions)
    let fileUrl = DataTestUtils.generateTestFile(name: filename, contents: bookContents, destinationFolder: inboxFolder)

    let promise = XCTestExpectation(description: "Process inbox file")
    let dataManager = DataManager(coreDataStack: CoreDataStack(testPath: "/dev/null"))
    let audioMetadataService = AudioMetadataService()
    let libraryService = LibraryService()
    libraryService.setup(dataManager: dataManager, audioMetadataService: audioMetadataService)
    let operation = ImportOperation(files: [fileUrl], libraryService: libraryService)

    operation.completionBlock = {
      // Source in Inbox (a Documents subfolder) should be cleaned up after import
      XCTAssertFalse(FileManager.default.fileExists(atPath: fileUrl.path))

      XCTAssertNotNil(operation.processedFiles.first)
      let processedFile = operation.processedFiles.first!
      XCTAssert(FileManager.default.fileExists(atPath: processedFile.path))
      XCTAssertEqual(FileManager.default.contents(atPath: processedFile.path), bookContents)

      promise.fulfill()
    }

    operation.start()

    wait(for: [promise], timeout: 15)
  }
}

// MARK: - Zip provenance carry-through

/// Lives in this file rather than its own because the project file predates
/// filesystem-synchronized groups; new test files need manual pbxproj surgery.
class ImportOperationZipProvenanceTests: XCTestCase {
  let userDefaults = UserDefaults(suiteName: "ImportOperationZipProvenanceTests")!

  override func setUp() {
    super.setUp()
    userDefaults.removePersistentDomain(forName: "ImportOperationZipProvenanceTests")
    let documentsFolder = DataManager.getDocumentsFolderURL()
    DataTestUtils.clearFolderContents(url: documentsFolder)
  }

  func testZipExtractionCarriesProvenanceToAudioFiles() throws {
    let documentsFolder = DataManager.getDocumentsFolderURL()

    // Stage a zip shaped like an ABS multi-file download: tracks plus a sidecar cover
    let stagingDir = documentsFolder.appendingPathComponent("staging-zip-test")
    try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
    _ = DataTestUtils.generateTestFile(name: "track1.mp3", contents: "one".data(using: .utf8)!, destinationFolder: stagingDir)
    _ = DataTestUtils.generateTestFile(name: "track2.mp3", contents: "two".data(using: .utf8)!, destinationFolder: stagingDir)
    _ = DataTestUtils.generateTestFile(name: "cover.jpg", contents: "img".data(using: .utf8)!, destinationFolder: stagingDir)

    let zipUrl = documentsFolder.appendingPathComponent("Some Book.zip")
    XCTAssert(SSZipArchive.createZipFile(atPath: zipUrl.path, withContentsOfDirectory: stagingDir.path))
    try FileManager.default.removeItem(at: stagingDir)

    // Provenance recorded against the archive, the way MediaServerSourceTracker leaves it
    let store = MediaServerSourceStore(userDefaults: userDefaults)
    let info = MediaServerSourceInfo(kind: .audiobookshelf, connectionId: "conn-1", itemId: "abs-item-1")
    store.setSource(info, for: "Some Book.zip")

    let dataManager = DataManager(coreDataStack: CoreDataStack(testPath: "/dev/null"))
    let audioMetadataService = AudioMetadataService()
    let libraryService = LibraryService()
    libraryService.setup(dataManager: dataManager, audioMetadataService: audioMetadataService)
    let operation = ImportOperation(
      files: [zipUrl],
      libraryService: libraryService,
      mediaServerSourceStore: store
    )

    let promise = XCTestExpectation(description: "Process zip")
    operation.completionBlock = {
      // The archive's own entry must not outlive the archive
      XCTAssertNil(store.source(for: "Some Book.zip"))

      // Every extracted track inherits the archive's provenance; the sidecar doesn't
      XCTAssertEqual(store.source(for: "track1.mp3"), info)
      XCTAssertEqual(store.source(for: "track2.mp3"), info)
      XCTAssertNil(store.source(for: "cover.jpg"))

      promise.fulfill()
    }

    operation.start()

    wait(for: [promise], timeout: 15)
  }
}

// MARK: - Folder-level source resolution

class MediaServerSourceStoreResolutionTests: XCTestCase {
  let userDefaults = UserDefaults(suiteName: "MediaServerSourceStoreResolutionTests")!
  var store: MediaServerSourceStore!

  override func setUp() {
    super.setUp()
    userDefaults.removePersistentDomain(forName: "MediaServerSourceStoreResolutionTests")
    store = MediaServerSourceStore(userDefaults: userDefaults)
  }

  private func info(itemId: String) -> MediaServerSourceInfo {
    MediaServerSourceInfo(kind: .audiobookshelf, connectionId: "conn-1", itemId: itemId)
  }

  func testTakeSourceReturnsAndRemoves() {
    store.setSource(info(itemId: "a"), for: "book.zip")

    XCTAssertEqual(store.takeSource(for: "book.zip"), info(itemId: "a"))
    XCTAssertNil(store.source(for: "book.zip"))
    XCTAssertNil(store.takeSource(for: "book.zip"))
  }

  func testUnanimousDescendantSourceAgreement() {
    store.setSource(info(itemId: "a"), for: "Volume/track1.mp3")
    store.setSource(info(itemId: "a"), for: "Volume/track2.mp3")

    XCTAssertEqual(store.unanimousDescendantSource(under: "Volume"), info(itemId: "a"))
  }

  func testUnanimousDescendantSourceDisagreementReturnsNil() {
    store.setSource(info(itemId: "a"), for: "Playlist/book1.mp3")
    store.setSource(info(itemId: "b"), for: "Playlist/book2.mp3")

    XCTAssertNil(store.unanimousDescendantSource(under: "Playlist"))
  }

  func testUnanimousDescendantSourceIgnoresNonDescendants() {
    store.setSource(info(itemId: "a"), for: "Volume/track1.mp3")
    store.setSource(info(itemId: "b"), for: "VolumeTwo/track1.mp3")
    store.setSource(info(itemId: "c"), for: "loose.mp3")

    // "VolumeTwo/…" must not match the "Volume" prefix, and root files don't count
    XCTAssertEqual(store.unanimousDescendantSource(under: "Volume"), info(itemId: "a"))
    XCTAssertNil(store.unanimousDescendantSource(under: "Missing"))
  }
}
