//
//  HummingbirdConnectionServiceTests.swift
//  BookPlayerTests
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

@testable import BookPlayer
@testable import BookPlayerKit
import XCTest

/// `@unchecked Sendable`: a test double used from one task at a time
final class HummingbirdHTTPStub: IntegrationHTTPClient, @unchecked Sendable {
  struct Reply {
    var status: Int
    var body: String
    var headers: [String: String] = [:]
  }

  private(set) var requests = [URLRequest]()
  /// Answered in order; the last one repeats
  var replies = [Reply(status: 200, body: "{}")]

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let reply = replies.count > 1 ? replies.removeFirst() : replies[0]
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: reply.status,
      httpVersion: nil,
      headerFields: reply.headers
    )!
    return (Data(reply.body.utf8), response)
  }

  func redirectLocation(for request: URLRequest) async throws -> URL {
    throw URLError(.unsupportedURL)
  }
}

/// The clock the resource poll's budget runs on, moved forward by the poll's own waits
final class HummingbirdPollClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current = Date(timeIntervalSince1970: 1_800_000_000)
  private var recordedWaits = [UInt64]()

  var now: Date { lock.withLock { current } }
  var waits: [UInt64] { lock.withLock { recordedWaits } }

  func wait(_ nanoseconds: UInt64) {
    lock.withLock {
      recordedWaits.append(nanoseconds)
      current = current.addingTimeInterval(Double(nanoseconds) / 1_000_000_000)
    }
  }
}

@MainActor
final class HummingbirdConnectionServiceTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var keychain: KeychainServiceMock!
  private var http: HummingbirdHTTPStub!
  private var clock: HummingbirdPollClock!
  private var service: HummingbirdConnectionService!

  private let home = HummingbirdConnectionData(
    id: "home",
    url: URL(string: "https://hb.example.com")!,
    serverName: "hb.example.com",
    userName: "reader",
    password: " pass word "
  )
  private let other = HummingbirdConnectionData(
    id: "other",
    url: URL(string: "https://other.example.com:8000")!,
    serverName: "other.example.com",
    userName: "second",
    password: "other-pass",
    customHeaders: ["X-Proxy": "1"]
  )

  override func setUp() {
    super.setUp()
    suiteName = "HummingbirdConnectionServiceTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    keychain = KeychainServiceMock()
    http = HummingbirdHTTPStub()
    clock = HummingbirdPollClock()
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    service = nil
    http = nil
    keychain = nil
    clock = nil
    defaults = nil
    super.tearDown()
  }

  /// A service over `saved` connections stored as the July builds stored them, `active` chosen
  private func makeService(
    saved: [HummingbirdConnectionData] = [],
    active: String? = nil
  ) throws -> HummingbirdConnectionService {
    if !saved.isEmpty {
      try keychain.set(saved, key: .hummingbirdConnection)
    }
    if let active {
      defaults.set(active, forKey: "hummingbird_active_connection_id")
    }
    let clock = self.clock!
    let service = HummingbirdConnectionService(
      keychainService: keychain,
      httpClient: http,
      defaults: defaults,
      waitBeforeRetry: { clock.wait($0) },
      now: { clock.now }
    )
    service.setup()
    return service
  }

  private func basic(_ user: String, _ password: String) -> String {
    "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
  }

  private func item(bookId: Int = 77, format: Int = 11) -> HummingbirdLibraryItem {
    HummingbirdLibraryItem(
      bookId: bookId,
      format: format,
      title: "Dune",
      downloadURL: URL(string: "https://hb.example.com/protocols/hummingbird/v1/download/\(format)/\(bookId)/")!
    )
  }

  private let signedIn = HummingbirdHTTPStub.Reply(status: 200, body: #"{"authenticated": true, "username": "reader"}"#)

  // MARK: - Keychain records from the July builds

  /// The July record shape loads through the shared store, including one saved before custom
  /// headers existed
  func testJulyRecordsLoad() throws {
    let july = """
      [{"id":"j1","url":"https://hb.example.com","serverName":"hb.example.com","userName":"reader","password":"secret","customHeaders":{"X-Proxy":"1"}},
       {"id":"j2","url":"https://old.example.com","serverName":"old","userName":"early","password":"pw"}]
      """
    keychain.entries[.hummingbirdConnection] = Data(july.utf8)

    service = try makeService()

    XCTAssertEqual(service.connections.map(\.id), ["j1", "j2"])
    let first = try XCTUnwrap(service.connections.first)
    XCTAssertEqual(first.userName, "reader")
    XCTAssertEqual(first.password, "secret")
    XCTAssertEqual(first.customHeaders, ["X-Proxy": "1"])
    XCTAssertEqual(service.connections.last?.customHeaders, [:])
  }

  /// What the store writes back has exactly the July keys: `selectedLibraryId` and the store's
  /// `userID` and `token` are computed, so July builds read it as before
  func testASavedRecordKeepsTheJulyShape() throws {
    service = try makeService(saved: [home], active: "home")

    service.updateCustomHeaders(id: "home", ["X-New": "2"])

    let data = try XCTUnwrap(keychain.entries[.hummingbirdConnection])
    let records = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(Set(records[0].keys), ["id", "url", "serverName", "userName", "password", "customHeaders"])
    XCTAssertEqual(records[0]["customHeaders"] as? [String: String], ["X-New": "2"])
  }

  func testTheJulyActiveConnectionIsStillChosen() throws {
    service = try makeService(saved: [home, other], active: "other")

    XCTAssertEqual(service.connection?.id, "other")
  }

  /// The store drops a record with an empty token at launch and rewrites the Keychain without it.
  /// The name and password together are a Hummingbird account's credential, so a server that took
  /// an empty password keeps its connection
  func testAnEmptyPasswordConnectionSurvivesALaunch() throws {
    let open = HummingbirdConnectionData(
      id: "open",
      url: URL(string: "https://open.example.com")!,
      serverName: "open.example.com",
      userName: "guest",
      password: ""
    )

    service = try makeService(saved: [open])

    XCTAssertEqual(service.connections.map(\.id), ["open"])
  }

  func testWhatTheStoreReadsFromAConnection() {
    XCTAssertEqual(home.userID, "reader")
    XCTAssertEqual(home.token, "reader: pass word ")
    XCTAssertNil(home.selectedLibraryId)
  }

  // MARK: - Server probe

  func testThePingRecognisesAHummingbird() async throws {
    service = try makeService()
    http.replies = [.init(status: 200, body: #"{"service": "hummingbird", "version": "0.6.2"}"#)]

    let name = try await service.pingServer(at: "https://hb.example.com:8000", customHeaders: ["X-Proxy": "1"])

    XCTAssertEqual(name, "hb.example.com")
    XCTAssertEqual(http.requests.first?.value(forHTTPHeaderField: "X-Proxy"), "1")
    XCTAssertNil(http.requests.first?.value(forHTTPHeaderField: "Authorization"))
  }

  func testThePingRefusesAnotherServer() async throws {
    service = try makeService()
    http.replies = [.init(status: 200, body: #"{"service": "jellyfin"}"#)]

    do {
      _ = try await service.pingServer(at: "https://hb.example.com")
      XCTFail("took another server for a Hummingbird")
    } catch let error as IntegrationError {
      XCTAssertEqual(error, .unexpectedResponse(code: nil))
    }
  }

  /// A probe before signing in is never "your session expired", whatever server answers
  func testAPing401IsNotAnExpiredSession() async throws {
    service = try makeService(saved: [home], active: "home")
    http.replies = [.init(status: 401, body: "")]

    do {
      _ = try await service.pingServer(at: "https://hb.example.com")
      XCTFail("a 401 ping passed")
    } catch let error as IntegrationError {
      XCTAssertEqual(error, .unexpectedResponse(code: 401))
      XCTAssertFalse(error.isSessionExpired)
    }
  }

  // MARK: - Sign in

  /// hummingbird 0.3.1 dropped the query form: it put passwords in every access log on the way
  func testSignInSendsTheCredentialsInTheBody() async throws {
    service = try makeService()
    http.replies = [signedIn]

    try await service.signIn(
      username: "reader",
      password: " p@ss word ",
      serverUrl: "https://hb.example.com",
      serverName: "hb.example.com",
      customHeaders: ["X-Proxy": "1"]
    )

    let request = try XCTUnwrap(http.requests.first)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.absoluteString, "https://hb.example.com/protocols/hummingbird/v1/login")
    XCTAssertNil(request.url?.query)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Proxy"), "1")
    let body = try XCTUnwrap(request.httpBody)
    let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
    XCTAssertEqual(fields, ["username": "reader", "password": " p@ss word "])
    XCTAssertEqual(service.connection?.userName, "reader")
    XCTAssertEqual(service.connection?.password, " p@ss word ")
    XCTAssertEqual(service.connection?.customHeaders, ["X-Proxy": "1"])
  }

  /// A wrong password at sign-in is a sign-in failure, not an expired session
  func testAWrongPasswordAtSignInSavesNothing() async throws {
    service = try makeService()
    http.replies = [.init(status: 401, body: "")]

    do {
      try await service.signIn(username: "reader", password: "bad", serverUrl: "https://hb.example.com", serverName: "hb")
      XCTFail("signed in on a 401")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .userAuthenticationRequired)
    }
    XCTAssertTrue(service.connections.isEmpty)
  }

  func testAnAnswerThatIsntASignInSavesNothing() async throws {
    service = try makeService()
    http.replies = [.init(status: 200, body: #"{"authenticated": false}"#)]

    do {
      try await service.signIn(username: "reader", password: "pw", serverUrl: "https://hb.example.com", serverName: "hb")
      XCTFail("signed in without authenticated: true")
    } catch let error as IntegrationError {
      XCTAssertEqual(error, .unexpectedResponse(code: nil))
    }
    XCTAssertTrue(service.connections.isEmpty)
  }

  /// Signing in again from an expired session, at an edited URL, updates that connection: its id is
  /// what the downloaded books' provenance names
  func testSigningInAgainKeepsTheConnectionsId() async throws {
    service = try makeService(saved: [home], active: "home")
    http.replies = [signedIn]

    try await service.signIn(
      username: "reader",
      password: "new",
      serverUrl: "https://moved.example.com",
      serverName: "moved.example.com",
      replacingID: "home"
    )

    XCTAssertEqual(service.connections.map(\.id), ["home"])
    XCTAssertEqual(service.connection?.url.absoluteString, "https://moved.example.com")
    XCTAssertEqual(service.connection?.password, "new")
  }

  // MARK: - Bookshelf and search

  func testTheBookshelfKeepsAudioEditionsOnly() async throws {
    service = try makeService(saved: [home], active: "home")
    http.replies = [.init(status: 200, body: """
      {"items": [
        {"id": 77, "title": "Dune (DAISY 2.02 Audio)", "url": "https://hb.example.com/protocols/hummingbird/v1/download/11/77/", "due_date": "2026-11-01T00:00:00+00:00"},
        {"id": 77, "title": "Dune (Braille)", "url": "https://hb.example.com/protocols/hummingbird/v1/download/7/77/"},
        {"id": 88, "title": "Emma (MP3)", "url": "https://hb.example.com/protocols/hummingbird/v1/download/4/88/"}
      ]}
      """)]

    let items = try await service.fetchBookshelf()

    XCTAssertEqual(items.map(\.id), ["77-11", "88-4"])
    XCTAssertEqual(items.first?.dueDate, Date(timeIntervalSince1970: 1_793_491_200))
    XCTAssertNil(items.last?.dueDate)
    let request = try XCTUnwrap(http.requests.first)
    let url = try XCTUnwrap(request.url)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), basic("reader", " pass word "))
    XCTAssertEqual(
      URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
      [URLQueryItem(name: "username", value: "reader")]
    )
  }

  /// Python's `isoformat()` gives fractional seconds or none
  func testDueDatesParseWithOrWithoutFractions() {
    XCTAssertEqual(
      HummingbirdConnectionService.parseISO8601("2026-11-01T00:00:00+00:00"),
      Date(timeIntervalSince1970: 1_793_491_200)
    )
    let fractional = HummingbirdConnectionService.parseISO8601("2026-11-01T00:00:00.250000+00:00")
    XCTAssertEqual(fractional?.timeIntervalSince1970 ?? 0, 1_793_491_200.25, accuracy: 0.001)
    XCTAssertNil(HummingbirdConnectionService.parseISO8601("next tuesday"))
  }

  func testSearchGoesToTheActiveConnection() async throws {
    service = try makeService(saved: [home, other], active: "other")
    http.replies = [.init(status: 200, body: #"{"items": []}"#)]

    _ = try await service.search(query: "  dune  ")

    let request = try XCTUnwrap(http.requests.first)
    let url = try XCTUnwrap(request.url)
    XCTAssertEqual(url.host, "other.example.com")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), basic("second", "other-pass"))
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Proxy"), "1")
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    XCTAssertTrue(query.contains(URLQueryItem(name: "q", value: "dune")))
  }

  /// A custom header named Authorization can't replace the credentials
  func testBasicAuthGoesOnLast() async throws {
    let proxied = HummingbirdConnectionData(
      id: "proxied",
      url: URL(string: "https://proxied.example.com")!,
      serverName: "proxied",
      userName: "reader",
      password: "pw",
      customHeaders: ["Authorization": "Bearer proxy-token", "X-Proxy": "1"]
    )
    service = try makeService(saved: [proxied], active: "proxied")
    http.replies = [.init(status: 200, body: #"{"items": []}"#)]

    _ = try await service.fetchBookshelf()

    XCTAssertEqual(http.requests.first?.value(forHTTPHeaderField: "Authorization"), basic("reader", "pw"))
    XCTAssertEqual(http.requests.first?.value(forHTTPHeaderField: "X-Proxy"), "1")
  }

  /// A 401 or 403 from a saved connection is an expired session, so the UI offers to sign in again
  /// and keeps the connection
  func testAnAuthenticated401Or403IsAnExpiredSession() async throws {
    service = try makeService(saved: [home], active: "home")

    for status in [401, 403] {
      http.replies = [.init(status: status, body: "")]
      do {
        _ = try await service.fetchBookshelf()
        XCTFail("\(status) passed")
      } catch let error as IntegrationError {
        XCTAssertEqual(error, .sessionExpired(serverName: "hb.example.com"))
      }
    }
    XCTAssertEqual(service.connections.map(\.id), ["home"])
  }

  // MARK: - Returns

  func testAReturnGoesToTheNamedConnection() async throws {
    service = try makeService(saved: [home, other], active: "home")

    try await service.returnBook(bookId: "88", connectionId: "other")

    let request = try XCTUnwrap(http.requests.first)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.absoluteString, "https://other.example.com:8000/protocols/hummingbird/v1/bookshelf/remove/88")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), basic("second", "other-pass"))
  }

  /// Servers can reuse numeric ids, so a book whose connection is gone is never returned to another
  func testAReturnToARemovedConnectionSendsNothing() async throws {
    service = try makeService(saved: [home], active: "home")

    do {
      try await service.returnBook(bookId: "88", connectionId: "gone")
      XCTFail("returned to a removed connection")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .userAuthenticationRequired)
    }
    XCTAssertTrue(http.requests.isEmpty)
  }

  // MARK: - Resources

  private let resourcesBody = """
    {"contentId": "77", "format": 11, "resources": [
      {"uri": "https://hb.example.com/protocols/hummingbird/v1/download/11/77/file/01.mp3", "mimeType": "audio/mpeg", "size": 10, "localURI": "01.mp3"},
      {"uri": "https://hb.example.com/protocols/hummingbird/v1/download/11/77/file/ncc.html", "mimeType": "text/html", "size": 2, "localURI": "ncc.html"}
    ]}
    """

  /// A book the server is still fetching answers 503 with Retry-After until it's ready
  func testTheResourcePollWaitsForThePreparedBook() async throws {
    service = try makeService(saved: [home], active: "home")
    http.replies = [
      .init(status: 503, body: "", headers: ["Retry-After": "5"]),
      .init(status: 503, body: "", headers: ["Retry-After": "7"]),
      .init(status: 200, body: resourcesBody),
    ]

    let resources = try await service.fetchResources(item(), connectionId: "home")

    XCTAssertEqual(resources.map(\.localURI), ["01.mp3", "ncc.html"])
    XCTAssertEqual(clock.waits, [5_000_000_000, 7_000_000_000])
    XCTAssertEqual(http.requests.count, 3)
    XCTAssertEqual(
      http.requests.first?.url?.absoluteString,
      "https://hb.example.com/protocols/hummingbird/v1/resources/11/77"
    )
    XCTAssertTrue(http.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == basic("reader", " pass word ") })
  }

  /// A broken or hostile Retry-After can't make the poll spin or stall: 1...30 seconds, 10 when it
  /// isn't a number
  func testRetryAfterIsClampedAtBothEnds() {
    func wait(_ header: String?) -> Int {
      let response = HTTPURLResponse(
        url: URL(string: "https://hb.example.com")!,
        statusCode: 503,
        httpVersion: nil,
        headerFields: header.map { ["Retry-After": $0] } ?? [:]
      )!
      return HummingbirdConnectionService.retryAfterSeconds(response)
    }

    XCTAssertEqual(wait("0"), 1)
    XCTAssertEqual(wait("-5"), 1)
    XCTAssertEqual(wait("12"), 12)
    XCTAssertEqual(wait("999999"), 30)
    XCTAssertEqual(wait("Wed, 21 Oct 2026 07:28:00 GMT"), 10)
    XCTAssertEqual(wait(nil), 10)
  }

  /// The poll gives up once its 20 minutes have passed, on the clock its own waits move
  func testTheResourcePollGivesUpAfterItsBudget() async throws {
    service = try makeService(saved: [home], active: "home")
    http.replies = [.init(status: 503, body: "", headers: ["Retry-After": "30"])]

    do {
      _ = try await service.fetchResources(item(), connectionId: "home")
      XCTFail("polled forever")
    } catch let error as IntegrationError {
      XCTAssertEqual(error, .unexpectedResponse(code: 503))
    }
    let waited = clock.waits.reduce(0, +) / 1_000_000_000
    XCTAssertGreaterThanOrEqual(waited, UInt64(HummingbirdConnectionService.resourcePollBudget))
    XCTAssertLessThanOrEqual(waited, UInt64(HummingbirdConnectionService.resourcePollBudget) + 30)
  }

  /// A cancel that arrives while the poll waits (the banner closed) stops it before it asks again
  func testACancelDuringTheWaitStopsThePoll() async throws {
    try keychain.set([home], key: .hummingbirdConnection)
    defaults.set("home", forKey: "hummingbird_active_connection_id")
    let clock = self.clock!
    let cancelling = HummingbirdConnectionService(
      keychainService: keychain,
      httpClient: http,
      defaults: defaults,
      waitBeforeRetry: { _ in withUnsafeCurrentTask { $0?.cancel() } },
      now: { clock.now }
    )
    cancelling.setup()
    http.replies = [.init(status: 503, body: "", headers: ["Retry-After": "1"])]
    let item = item()

    let poll = Task { try await cancelling.fetchResources(item, connectionId: "home") }

    do {
      _ = try await poll.value
      XCTFail("a cancelled poll finished")
    } catch {
      XCTAssertTrue(error is CancellationError, "\(error)")
    }
    XCTAssertEqual(http.requests.count, 1)
  }

  /// The resource list and the file requests use the connection the book was listed on, whichever is
  /// active by the time the server has the book ready
  func testResourceRequestsCarryTheirOwnConnectionsCredentials() throws {
    service = try makeService(saved: [home, other], active: "home")
    let resource = DODPResource(
      uri: "https://other.example.com:8000/protocols/hummingbird/v1/download/4/88/file/01.mp3",
      mimeType: "audio/mpeg",
      size: 1,
      localURI: "01.mp3"
    )

    let request = try service.createResourceDownloadRequest(resource, connectionId: "other")

    XCTAssertEqual(request.url, URL(string: resource.uri))
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), basic("second", "other-pass"))
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Proxy"), "1")
    XCTAssertThrowsError(try service.createResourceDownloadRequest(resource, connectionId: "gone"))
  }

  func testResourcesFromARemovedConnectionSendNothing() async throws {
    service = try makeService(saved: [home], active: "home")

    do {
      _ = try await service.fetchResources(item(), connectionId: "gone")
      XCTFail("fetched from a removed connection")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .userAuthenticationRequired)
    }
    XCTAssertTrue(http.requests.isEmpty)
  }
}
