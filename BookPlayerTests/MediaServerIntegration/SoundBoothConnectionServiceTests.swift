//
//  SoundBoothConnectionServiceTests.swift
//  BookPlayerTests
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

@testable import BookPlayer
@testable import BookPlayerKit
import XCTest

/// Saved SoundBooth accounts: the July Keychain records, sign-in, which account a call goes out with,
/// and the API's errors as the shared screens show them
@MainActor
final class SoundBoothConnectionServiceTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var keychain: KeychainServiceMock!
  private var http: SoundBoothHTTPStub!
  private var service: SoundBoothConnectionService!

  private let first = SoundBoothConnectionData(
    session: SoundBoothSession(jwt: "jwt-a", userId: "user-a", email: "a@example.com", sessionCookie: "sid-a"),
    id: "a"
  )
  private let second = SoundBoothConnectionData(
    session: SoundBoothSession(jwt: "jwt-b", userId: "user-b", email: "b@example.com", sessionCookie: "sid-b"),
    id: "b"
  )

  override func setUp() {
    super.setUp()
    suiteName = "SoundBoothConnectionServiceTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    keychain = KeychainServiceMock()
    http = SoundBoothHTTPStub()
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    service = nil
    http = nil
    keychain = nil
    defaults = nil
    super.tearDown()
  }

  private func makeService(saved: [SoundBoothConnectionData] = [], active: String? = nil) throws -> SoundBoothConnectionService {
    if !saved.isEmpty {
      try keychain.set(saved, key: .soundboothConnection)
    }
    if let active {
      defaults.set(active, forKey: "soundbooth_active_connection_id")
    }
    let service = SoundBoothConnectionService(
      keychainService: keychain,
      apiClient: SoundBoothAPIClient(configuration: .production, httpClient: http),
      defaults: defaults
    )
    service.setup()
    return service
  }

  private func verifies(as userId: String, email: String, jwt: String, cookie: String? = nil) {
    http.reply(
      "/base/auth/login/code/verify",
      json: SoundBoothFixtures.ok(["_id": userId, "email": email, "jwt": jwt]),
      headers: cookie.map { ["Set-Cookie": "iglu.sid=\($0); Path=/"] } ?? [:]
    )
  }

  private func savedRecords() throws -> [[String: Any]] {
    let data = try XCTUnwrap(keychain.entries[.soundboothConnection])
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
  }

  // MARK: - Keychain records from the July builds

  func testJulyRecordsLoad() throws {
    let july = """
      [{"id":"j1","email":"one@example.com","userId":"u1","jwt":"jwt-1","sessionCookie":"sid-1"},
       {"id":"j2","email":"two@example.com","userId":"u2","jwt":"jwt-2"}]
      """
    keychain.entries[.soundboothConnection] = Data(july.utf8)
    defaults.set("j2", forKey: "soundbooth_active_connection_id")

    service = try makeService()

    XCTAssertEqual(service.connections.map(\.id), ["j1", "j2"])
    XCTAssertEqual(service.connections.first?.session, SoundBoothSession(jwt: "jwt-1", userId: "u1", email: "one@example.com", sessionCookie: "sid-1"))
    XCTAssertNil(service.connections.last?.sessionCookie)
    XCTAssertEqual(service.connection?.id, "j2")
  }

  /// What's written back has exactly the July keys, so a July build still reads it
  func testASavedRecordKeepsTheJulyShape() async throws {
    service = try makeService()
    verifies(as: "user-a", email: "a@example.com", jwt: "jwt-a", cookie: "sid-a")

    try await service.signIn(email: "a@example.com", code: "123456")

    let records = try savedRecords()
    guard records.count == 1 else {
      return XCTFail("expected one saved record, got \(records.count)")
    }
    XCTAssertEqual(Set(records[0].keys), ["id", "email", "userId", "jwt", "sessionCookie"])
    XCTAssertEqual(records[0]["userId"] as? String, "user-a")
    XCTAssertEqual(records[0]["jwt"] as? String, "jwt-a")
    XCTAssertEqual(records[0]["sessionCookie"] as? String, "sid-a")
  }

  /// A record that can't sign in is dropped at launch, as the July builds dropped it
  func testARecordWithoutAJWTOrAnAccountIsDropped() throws {
    let july = """
      [{"id":"kept","email":"one@example.com","userId":"u1","jwt":"jwt-1"},
       {"id":"nojwt","email":"two@example.com","userId":"u2","jwt":""},
       {"id":"nouser","email":"three@example.com","userId":"","jwt":"jwt-3"}]
      """
    keychain.entries[.soundboothConnection] = Data(july.utf8)

    service = try makeService()

    XCTAssertEqual(service.connections.map(\.id), ["kept"])
  }

  func testWhatTheStoreReadsFromAConnection() {
    var connection = first

    XCTAssertEqual(connection.url, SoundBoothAPIClient.Configuration.production.baseURL)
    XCTAssertEqual(connection.userID, "user-a")
    XCTAssertEqual(connection.token, "jwt-a")
    XCTAssertEqual(connection.serverName, "SoundBooth")
    XCTAssertEqual(connection.userName, "a@example.com")
    connection.selectedLibraryId = "library"
    connection.customHeaders = ["X-Proxy": "1"]
    XCTAssertNil(connection.selectedLibraryId)
    XCTAssertEqual(connection.customHeaders, [:])
    XCTAssertFalse(connection.debugDescription.contains("jwt-a"))
  }

  // MARK: - Sign in

  func testSigningInSavesTheAccountAsActive() async throws {
    service = try makeService()
    verifies(as: "user-a", email: "a@example.com", jwt: "jwt-a", cookie: "sid-a")

    try await service.signIn(email: "a@example.com", code: "123456")

    let connection = try XCTUnwrap(service.connection)
    XCTAssertEqual(service.connections.count, 1)
    XCTAssertEqual(connection.session, SoundBoothSession(jwt: "jwt-a", userId: "user-a", email: "a@example.com", sessionCookie: "sid-a"))
    XCTAssertEqual(defaults.string(forKey: "soundbooth_active_connection_id"), connection.id)
  }

  /// The same account again keeps its connection, whose id the downloaded books' provenance names
  func testSigningInToTheSameAccountAgainKeepsItsConnection() async throws {
    service = try makeService(saved: [first], active: "a")
    verifies(as: "user-a", email: "a@example.com", jwt: "jwt-renewed", cookie: "sid-renewed")

    try await service.signIn(email: "a@example.com", code: "123456")

    XCTAssertEqual(service.connections.map(\.id), ["a"])
    XCTAssertEqual(service.connection?.jwt, "jwt-renewed")
    XCTAssertEqual(service.connection?.sessionCookie, "sid-renewed")
  }

  func testAnotherAccountIsAnotherConnection() async throws {
    service = try makeService(saved: [first], active: "a")
    verifies(as: "user-b", email: "b@example.com", jwt: "jwt-b")

    try await service.signIn(email: "b@example.com", code: "123456")

    XCTAssertEqual(service.connections.count, 2)
    XCTAssertEqual(service.connection?.userId, "user-b")
    XCTAssertNotEqual(service.connection?.id, "a")
    XCTAssertEqual(service.connections.first { $0.id == "a" }?.jwt, "jwt-a")
  }

  /// Renewing one account's session but signing in as another doesn't replace the first
  func testRenewingAsAnotherAccountKeepsTheFirst() async throws {
    service = try makeService(saved: [first], active: "a")
    verifies(as: "user-b", email: "b@example.com", jwt: "jwt-b")

    try await service.signIn(email: "b@example.com", code: "123456", replacingID: "a")

    XCTAssertEqual(Set(service.connections.map(\.userId)), ["user-a", "user-b"])
  }

  /// A sign-in whose sheet closed while the code was being checked saves nothing, even though the
  /// answer still arrives
  func testASignInClosedWhileTheCodeIsCheckedSavesNothing() async throws {
    service = try makeService()
    verifies(as: "user-a", email: "a@example.com", jwt: "jwt-a")
    http.hold("/base/auth/login/code/verify")

    let service = self.service!
    let signIn = Task { try await service.signIn(email: "a@example.com", code: "123456") }
    for _ in 0..<200 where !http.isHolding {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertTrue(http.isHolding)
    signIn.cancel()
    http.release()

    let result = await signIn.result
    XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
    XCTAssertTrue(service.connections.isEmpty)
    XCTAssertNil(keychain.entries[.soundboothConnection])
  }

  func testAWrongCodeShowsSoundBoothsWords() async throws {
    service = try makeService()
    http.reply("/base/auth/login/code/verify", json: SoundBoothFixtures.failure("That code has expired", code: "720"))

    do {
      try await service.signIn(email: "a@example.com", code: "1")
      XCTFail("expected an error")
    } catch {
      XCTAssertEqual(error as? IntegrationError, .serverMessage(code: 720, message: "That code has expired"))
    }
    XCTAssertTrue(service.connections.isEmpty)
  }

  // MARK: - Which account a call goes out with

  /// A download goes out with the account its title was listed for, whichever is active now
  func testADownloadUsesTheAccountItWasListedFor() async throws {
    service = try makeService(saved: [first, second], active: "a")
    http.reply("/functions/playlist/item-resources", json: SoundBoothFixtures.ok(["itemResources": [Any]()]))
    http.reply("/functions/user/progresses", json: SoundBoothFixtures.ok([Any]()))
    http.reply("/functions/u/items/list", json: SoundBoothFixtures.page([]))
    http.redirect(resource: "r1", to: "https://cdn.example.com/r1.mp3")

    _ = try await service.fetchItemResources(itemIds: ["b1"], connectionId: "b")
    _ = try await service.fetchProgresses(connectionId: "b")
    _ = try await service.resolvePlaybackURL(resourceId: "r1", connectionId: "b")
    _ = try await service.fetchSeasonItems(groupId: "g1", connectionId: "b")

    XCTAssertEqual(http.requests.count, 4)
    for request in http.requests {
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token jwt-b", request.url?.path ?? "")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "iglu.sid=sid-b", request.url?.path ?? "")
    }
  }

  /// An account signed out since its title was listed asks nothing, rather than another account's
  /// session going out instead
  func testASignedOutAccountAsksNothing() async throws {
    service = try makeService(saved: [first], active: "a")

    await assertSignInRequired { _ = try await self.service.fetchItemResources(itemIds: ["b1"], connectionId: "gone") }
    await assertSignInRequired { _ = try await self.service.fetchProgresses(connectionId: "gone") }
    await assertSignInRequired { _ = try await self.service.resolvePlaybackURL(resourceId: "r1", connectionId: "gone") }
    await assertSignInRequired { _ = try await self.service.fetchSeasonItems(groupId: "g1", connectionId: "gone") }
    XCTAssertTrue(http.requests.isEmpty)
  }

  func testWithoutAnAccountTheLibraryAsksNothing() async throws {
    service = try makeService()

    await assertSignInRequired { _ = try await self.service.fetchLibraryElements() }
    await assertSignInRequired { _ = try await self.service.fetchCatalog() }
    XCTAssertTrue(http.requests.isEmpty)
  }

  /// The library is the active account's
  func testTheLibraryIsTheActiveAccounts() async throws {
    service = try makeService(saved: [first, second], active: "b")
    http.reply("/functions/u/library-elements/list", json: SoundBoothFixtures.page([]))

    _ = try await service.fetchLibraryElements()

    XCTAssertEqual(http.requests.first?.value(forHTTPHeaderField: "Authorization"), "Token jwt-b")
  }

  func testDownloadsAskForTheHigherQuality() async throws {
    service = try makeService(saved: [first], active: "a")
    http.redirect(resource: "r1", to: "https://cdn.example.com/r1.mp3")

    _ = try await service.resolvePlaybackURL(resourceId: "r1", connectionId: "a")

    XCTAssertEqual(
      URLComponents(url: try XCTUnwrap(http.requests.first?.url), resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == "quality" }?.value,
      "192k"
    )
  }

  private func assertSignInRequired(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Void
  ) async {
    do {
      try await body()
      XCTFail("expected a sign-in to be required", file: file, line: line)
    } catch {
      XCTAssertEqual((error as? URLError)?.code, .userAuthenticationRequired, file: file, line: line)
    }
  }

  // MARK: - Connections

  func testRemovingTheLastAccountClearsTheKeychain() throws {
    service = try makeService(saved: [first, second], active: "a")

    service.deleteConnection()
    XCTAssertEqual(service.connections.map(\.id), ["b"])
    XCTAssertEqual(service.connection?.id, "b")

    service.deleteConnection(id: "b")
    XCTAssertNil(service.connection)
    XCTAssertNil(keychain.entries[.soundboothConnection])
  }

  func testActivatingAnAccount() throws {
    service = try makeService(saved: [first, second], active: "a")

    service.activateConnection(id: "b")

    XCTAssertEqual(service.connection?.id, "b")
  }

  // MARK: - Errors

  /// SoundBooth's own words where it gave some; an expired session is a sign-in, not an error
  func testErrorsAsTheSharedScreensShowThem() throws {
    service = try makeService()

    let mapped: [(SoundBoothAPIError, IntegrationError)] = [
      (.sessionInvalid, .sessionExpired(serverName: "SoundBooth")),
      (.http(status: 502), .unexpectedResponse(code: 502)),
      (.noRedirect(status: 200), .unexpectedResponse(code: 200)),
      (.api(message: "That code has expired", code: "720"), .serverMessage(code: 720, message: "That code has expired")),
      (.api(message: "Something went wrong", code: nil), .serverMessage(code: 0, message: "Something went wrong")),
      (.api(message: "", code: "720"), .unexpectedResponse(code: nil)),
      (.api(message: nil, code: "720"), .unexpectedResponse(code: nil)),
      (.decoding, .unexpectedResponse(code: nil)),
      (.malformedURL, .urlMalformed(nil)),
    ]
    for (apiError, expected) in mapped {
      XCTAssertEqual(service.mapError(apiError) as? IntegrationError, expected, "\(apiError)")
    }
    XCTAssertTrue((service.mapError(SoundBoothAPIError.sessionInvalid) as? IntegrationError)?.isSessionExpired == true)
    XCTAssertEqual((service.mapError(URLError(.notConnectedToInternet)) as? URLError)?.code, .notConnectedToInternet)
  }
}

/// The sign-in screen: an email, then the code SoundBooth emails to it
@MainActor
final class SoundBoothConnectionViewModelTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var keychain: KeychainServiceMock!
  private var http: SoundBoothHTTPStub!
  private var service: SoundBoothConnectionService!
  private var viewModel: SoundBoothConnectionViewModel!

  override func setUp() {
    super.setUp()
    suiteName = "SoundBoothConnectionViewModelTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    keychain = KeychainServiceMock()
    http = SoundBoothHTTPStub()
    http.reply("/base/auth/login/code/link", json: ["success": true])
    http.reply("/base/auth/login/code/verify", json: SoundBoothFixtures.ok(["_id": "user-a", "email": "a@example.com", "jwt": "jwt-a"]))
  }

  override func tearDown() {
    viewModel?.cancelPendingAuth()
    defaults.removePersistentDomain(forName: suiteName)
    viewModel = nil
    service = nil
    http = nil
    keychain = nil
    defaults = nil
    super.tearDown()
  }

  private func makeViewModel(saved: [SoundBoothConnectionData] = []) throws {
    if !saved.isEmpty {
      try keychain.set(saved, key: .soundboothConnection)
    }
    service = SoundBoothConnectionService(
      keychainService: keychain,
      apiClient: SoundBoothAPIClient(configuration: .production, httpClient: http),
      defaults: defaults
    )
    service.setup()
    viewModel = SoundBoothConnectionViewModel(connectionService: service)
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

  private func body(_ request: URLRequest?) -> [String: String] {
    guard let data = request?.httpBody, let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
    return object as? [String: String] ?? [:]
  }

  func testAnAddressWithoutAnAtIsRefusedBeforeAnyRequest() async throws {
    try makeViewModel()
    viewModel.email = "reader.example.com"

    viewModel.sendCode()
    try await waitUntil { viewModel.errorMessage != nil }

    XCTAssertEqual(viewModel.errorMessage, "soundbooth_email_invalid".localized)
    XCTAssertEqual(viewModel.step, .enteringEmail)
    XCTAssertTrue(http.requests.isEmpty)
  }

  func testSendingACodeMovesToTheCodeStep() async throws {
    try makeViewModel()
    viewModel.email = "  a@example.com \n"

    viewModel.sendCode()
    try await waitUntil { viewModel.step == .enteringCode }

    XCTAssertEqual(viewModel.email, "a@example.com")
    XCTAssertEqual(body(http.requests(to: "/base/auth/login/code/link").first), ["email": "a@example.com"])
    XCTAssertFalse(viewModel.isBusy)
  }

  /// A pasted "123 456" is the code 123456
  func testTheCodeIsSentWithoutItsSpaces() async throws {
    try makeViewModel()
    viewModel.email = "a@example.com"
    viewModel.sendCode()
    try await waitUntil { viewModel.step == .enteringCode }
    viewModel.code = " 123 456\n"

    viewModel.verify()
    try await waitUntil { viewModel.signInCompletedAt != nil }

    XCTAssertEqual(body(http.requests(to: "/base/auth/login/code/verify").first), ["email": "a@example.com", "code": "123456"])
    XCTAssertEqual(service.connection?.userId, "user-a")
  }

  func testAnEmptyCodeAsksForIt() async throws {
    try makeViewModel()
    viewModel.code = "   "

    viewModel.verify()
    try await waitUntil { viewModel.errorMessage != nil }

    XCTAssertEqual(viewModel.errorMessage, "soundbooth_code_missing".localized)
    XCTAssertTrue(http.requests.isEmpty)
  }

  func testAWrongCodeSaysWhy() async throws {
    try makeViewModel()
    http.reply("/base/auth/login/code/verify", json: SoundBoothFixtures.failure("That code has expired", code: "720"))
    viewModel.email = "a@example.com"
    viewModel.code = "1"

    viewModel.verify()
    try await waitUntil { viewModel.errorMessage != nil }

    XCTAssertEqual(viewModel.errorMessage, IntegrationError.serverMessage(code: 720, message: "That code has expired").localizedDescription)
    XCTAssertNil(viewModel.signInCompletedAt)
    XCTAssertFalse(viewModel.isBusy)
  }

  /// An expired session is renewed with the account's email filled in, and keeps its connection
  func testRenewingASessionKeepsTheAccountsConnection() async throws {
    let saved = SoundBoothConnectionData(
      session: SoundBoothSession(jwt: "jwt-old", userId: "user-a", email: "a@example.com"),
      id: "kept"
    )
    try makeViewModel(saved: [saved])
    viewModel.email = "typed@example.com"
    viewModel.code = "999"

    viewModel.prepareReauth()

    XCTAssertEqual(viewModel.email, "a@example.com")
    XCTAssertEqual(viewModel.code, "")
    XCTAssertEqual(viewModel.replacingID, "kept")
    XCTAssertEqual(viewModel.step, .enteringEmail)

    viewModel.sendCode()
    try await waitUntil { viewModel.step == .enteringCode }
    viewModel.code = "123456"
    viewModel.verify()
    try await waitUntil { viewModel.signInCompletedAt != nil }

    XCTAssertEqual(service.connections.map(\.id), ["kept"])
    XCTAssertEqual(service.connection?.jwt, "jwt-a")
  }

  func testUsingAnotherEmailGoesBack() async throws {
    try makeViewModel()
    viewModel.email = "a@example.com"
    viewModel.sendCode()
    try await waitUntil { viewModel.step == .enteringCode }
    viewModel.code = "12"

    viewModel.editEmail()

    XCTAssertEqual(viewModel.step, .enteringEmail)
    XCTAssertEqual(viewModel.code, "")
    XCTAssertNil(viewModel.errorMessage)
  }
}
