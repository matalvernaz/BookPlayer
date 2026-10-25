//
//  HummingbirdConnectionViewModelTests.swift
//  BookPlayerTests
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

@testable import BookPlayer
@testable import BookPlayerKit
import XCTest

/// The Hummingbird sign-in flow on the shared integration screens: credentials only go to the URL
/// Connect checked, and the password is sent as typed
@MainActor
final class HummingbirdConnectionViewModelTests: XCTestCase {
  private var keychain: KeychainServiceMock!
  private var defaults: UserDefaults!
  private var suiteName: String!
  private var http: HummingbirdHTTPStub!
  private var service: HummingbirdConnectionService!

  private let pong = HummingbirdHTTPStub.Reply(status: 200, body: #"{"service": "hummingbird"}"#)
  private let signedIn = HummingbirdHTTPStub.Reply(status: 200, body: #"{"authenticated": true, "username": "reader"}"#)

  override func setUp() {
    super.setUp()
    keychain = KeychainServiceMock()
    suiteName = "HummingbirdConnectionViewModelTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    http = HummingbirdHTTPStub()
    service = HummingbirdConnectionService(keychainService: keychain, httpClient: http, defaults: defaults)
    service.setup()
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    keychain = nil
    defaults = nil
    http = nil
    service = nil
    super.tearDown()
  }

  private func loginBody(_ request: URLRequest?) throws -> [String: String] {
    let body = try XCTUnwrap(request?.httpBody)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
  }

  /// No other way in, so Connect goes straight to the password step, on a URL it normalised
  func testConnectGoesToThePasswordStep() async throws {
    let viewModel = HummingbirdConnectionViewModel(connectionService: service, mode: .addServer)
    viewModel.form.serverUrl = "  hb.example.com:8000 "
    http.replies = [pong]

    try await viewModel.handleConnectAction()

    XCTAssertEqual(viewModel.form.serverUrl, "https://hb.example.com:8000")
    XCTAssertEqual(viewModel.signInFlow, .enteringCredentials)
    XCTAssertEqual(viewModel.flowPath, [.password])
    XCTAssertEqual(viewModel.form.serverName, "hb.example.com")
    XCTAssertNil(viewModel.alternativeSignIn)
  }

  /// An edit to the address between Connect and Sign In can't send the password to a server nobody
  /// checked
  func testSignInGoesToTheCheckedURL() async throws {
    let viewModel = HummingbirdConnectionViewModel(connectionService: service, mode: .addServer)
    viewModel.form.serverUrl = "https://hb.example.com"
    http.replies = [pong]
    try await viewModel.handleConnectAction()

    viewModel.form.serverUrl = "https://evil.example.com"
    viewModel.form.username = "reader"
    viewModel.form.password = "pw"
    http.replies = [signedIn]
    try await viewModel.handleSignInAction()

    XCTAssertEqual(http.requests.last?.url?.host, "hb.example.com")
    XCTAssertEqual(service.connection?.url.absoluteString, "https://hb.example.com")
    XCTAssertNotNil(viewModel.signInCompletedAt)
    XCTAssertNil(viewModel.signInFlow)
    XCTAssertEqual(viewModel.flowPath, [])
  }

  func testSignInWithoutConnectSendsNothing() async throws {
    let viewModel = HummingbirdConnectionViewModel(connectionService: service, mode: .addServer)
    viewModel.form.serverUrl = "https://hb.example.com"

    do {
      try await viewModel.handleSignInAction()
      XCTFail("signed in without a checked URL")
    } catch let error as IntegrationError {
      XCTAssertEqual(error, .urlMalformed(nil))
    }
    XCTAssertTrue(http.requests.isEmpty)
  }

  /// Basic auth replays the password on every request, so a trimmed one would fail every time
  /// after sign-in; autocorrect's trailing space on the name is dropped
  func testThePasswordIsSentAsTypedAndTheNameTrimmed() async throws {
    let viewModel = HummingbirdConnectionViewModel(connectionService: service, mode: .addServer)
    viewModel.form.serverUrl = "https://hb.example.com"
    http.replies = [pong]
    try await viewModel.handleConnectAction()

    viewModel.form.username = "reader "
    viewModel.form.password = " spaced pw "
    http.replies = [signedIn]
    try await viewModel.handleSignInAction()

    XCTAssertEqual(try loginBody(http.requests.last), ["username": "reader", "password": " spaced pw "])
    XCTAssertEqual(service.connection?.password, " spaced pw ")
  }

  /// A wrong password keeps the checked URL, so trying again still goes there
  func testAFailedSignInCanBeRetried() async throws {
    let viewModel = HummingbirdConnectionViewModel(connectionService: service, mode: .addServer)
    viewModel.form.serverUrl = "https://hb.example.com"
    http.replies = [pong]
    try await viewModel.handleConnectAction()
    viewModel.form.username = "reader"
    viewModel.form.password = "wrong"

    http.replies = [.init(status: 401, body: "")]
    do {
      try await viewModel.handleSignInAction()
      XCTFail("signed in on a 401")
    } catch {}

    viewModel.form.password = "right"
    http.replies = [signedIn]
    try await viewModel.handleSignInAction()

    XCTAssertEqual(service.connection?.password, "right")
  }

  /// The session-expired alert's Sign In starts from the address with the saved connection filled
  /// in, and signing in again updates that connection instead of adding another
  func testReauthenticationUpdatesTheSavedConnection() async throws {
    let saved = HummingbirdConnectionData(
      id: "saved",
      url: URL(string: "https://hb.example.com")!,
      serverName: "hb.example.com",
      userName: "reader",
      password: "expired",
      customHeaders: ["X-Proxy": "1"]
    )
    try keychain.set([saved], key: .hummingbirdConnection)
    service.setup()
    let viewModel = HummingbirdConnectionViewModel(connectionService: service)

    viewModel.prepareReauth()

    XCTAssertEqual(viewModel.signInFlow, .enteringServerURL)
    XCTAssertEqual(viewModel.form.serverUrl, "https://hb.example.com")
    XCTAssertEqual(viewModel.form.customHeadersDictionary(), ["X-Proxy": "1"])

    viewModel.form.serverUrl = "https://moved.example.com"
    http.replies = [pong]
    try await viewModel.handleConnectAction()
    viewModel.form.username = "reader"
    viewModel.form.password = "fresh"
    http.replies = [signedIn]
    try await viewModel.handleSignInAction()

    XCTAssertEqual(service.connections.map(\.id), ["saved"])
    XCTAssertEqual(service.connection?.url.absoluteString, "https://moved.example.com")
    XCTAssertEqual(service.connection?.password, "fresh")
    XCTAssertEqual(service.connection?.customHeaders, ["X-Proxy": "1"])
  }

  /// The per-server details sheet signs out the server it was opened for, not the active one
  func testSigningOutFromAServersDetailsRemovesThatServer() throws {
    let first = HummingbirdConnectionData(
      id: "first", url: URL(string: "https://one.example.com")!, serverName: "one", userName: "a", password: "1"
    )
    let second = HummingbirdConnectionData(
      id: "second", url: URL(string: "https://two.example.com")!, serverName: "two", userName: "b", password: "2"
    )
    try keychain.set([first, second], key: .hummingbirdConnection)
    defaults.set("first", forKey: "hummingbird_active_connection_id")
    service.setup()
    let viewModel = HummingbirdConnectionViewModel(connectionService: service, mode: .viewDetails, connectionId: "second")

    XCTAssertEqual(viewModel.form.serverName, "two")
    viewModel.handleSignOutAction()

    XCTAssertEqual(service.connections.map(\.id), ["first"])
    XCTAssertEqual(service.connection?.id, "first")
    XCTAssertNil(viewModel.signInFlow)
  }
}
