//
//  SoundBoothAPIClientTests.swift
//  BookPlayerTests
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

@testable import BookPlayerKit
import XCTest

/// SoundBooth's API answered by path, so calls made side by side (the library's three fetches) each get
/// their own answer whatever order they arrive in. `@unchecked Sendable`: every field is behind the lock
final class SoundBoothHTTPStub: IntegrationHTTPClient, @unchecked Sendable {
  struct Reply {
    var status = 200
    var body: String
    var headers: [String: String] = [:]
  }

  private let lock = NSLock()
  private var repliesByPath = [String: [Reply]]()
  private var redirectsByResource = [String: Result<URL, Error>]()
  private var recorded = [URLRequest]()
  private var heldPath: String?
  private var heldCall: CheckedContinuation<Void, Never>?

  var requests: [URLRequest] { lock.withLock { recorded } }

  func requests(to path: String) -> [URLRequest] {
    requests.filter { $0.url?.path == path }
  }

  /// Answers `path` with `replies` in order, the last one repeating. A path nobody set answers 404
  func reply(_ path: String, _ replies: Reply...) {
    lock.withLock { repliesByPath[path] = replies }
  }

  /// Answers `path` with a JSON value
  func reply(_ path: String, json: Any, status: Int = 200, headers: [String: String] = [:]) {
    reply(path, Reply(status: status, body: SoundBoothFixtures.text(json), headers: headers))
  }

  /// Where `resources/play` redirects for the chapter `resource`. One nobody set answers without a redirect
  func redirect(resource: String, to url: String) {
    lock.withLock { redirectsByResource[resource] = .success(URL(string: url)!) }
  }

  func failRedirect(resource: String, with error: Error) {
    lock.withLock { redirectsByResource[resource] = .failure(error) }
  }

  /// The next call to `path` waits until `release()`, and doesn't notice its task being cancelled
  /// meanwhile, as a request already on its way doesn't. Its answer is the one set when it was asked, as a
  /// server's would be; later calls to the path aren't held
  func hold(_ path: String) {
    lock.withLock { heldPath = path }
  }

  var isHolding: Bool { lock.withLock { heldCall != nil } }

  func release() {
    let call = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      defer { heldCall = nil }
      return heldCall
    }
    call?.resume()
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let path = request.url?.path ?? ""
    let (reply, holds) = lock.withLock { () -> (Reply, Bool) in
      recorded.append(request)
      let holds = heldPath == path
      if holds {
        heldPath = nil
      }
      guard var replies = repliesByPath[path], let first = replies.first else {
        return (Reply(status: 404, body: ""), holds)
      }
      if replies.count > 1 {
        replies.removeFirst()
        repliesByPath[path] = replies
      }
      return (first, holds)
    }
    if holds {
      await withCheckedContinuation { continuation in
        lock.withLock { heldCall = continuation }
      }
    }
    let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
    return (Data(reply.body.utf8), response)
  }

  func redirectLocation(for request: URLRequest) async throws -> URL {
    let resource = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
      .queryItems?
      .first { $0.name == "id" }?
      .value ?? ""
    let result = lock.withLock { () -> Result<URL, Error>? in
      recorded.append(request)
      return redirectsByResource[resource]
    }
    guard let result else {
      throw SoundBoothAPIError.noRedirect(status: 404)
    }
    return try result.get()
  }
}

/// Made-up SoundBooth answers in the shapes the real API sends (the fork is public: no account's real data)
enum SoundBoothFixtures {
  static func text(_ json: Any) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), as: UTF8.self)
  }

  static func decode<T: Decodable>(_ type: T.Type, _ json: Any) throws -> T {
    try JSONDecoder().decode(type, from: Data(text(json).utf8))
  }

  static func ok(_ data: Any) -> [String: Any] {
    ["success": true, "data": data]
  }

  /// A list call's answer
  static func page(_ docs: [Any], hasNextPage: Bool? = nil) -> [String: Any] {
    var data: [String: Any] = ["docs": docs]
    if let hasNextPage {
      data["hasNextPage"] = hasNextPage
    }
    return ok(data)
  }

  static func failure(_ message: String?, code: String?) -> [String: Any] {
    var body: [String: Any] = ["success": false]
    if let message {
      body["message"] = message
    }
    if let code {
      body["code"] = code
    }
    return body
  }

  /// A title, or a season with `subtype` nil. `series` and `group` are an id, or a populated `ref`
  static func element(
    _ id: String,
    _ name: String,
    subtype: String? = "book",
    series: Any? = nil,
    group: Any? = nil,
    format: String? = nil,
    releaseAt: String? = "2025-01-01T00:00:00.000Z"
  ) -> [String: Any] {
    var element: [String: Any] = ["_id": id, "name": name]
    if let subtype {
      element["__t"] = subtype
    }
    if let series {
      element["seriesId"] = series
    }
    if let group {
      element["groupId"] = group
    }
    if let format {
      element["format"] = format
    }
    if let releaseAt {
      element["releaseAt"] = releaseAt
    }
    return element
  }

  static func episode(_ id: String, _ name: String, series: Any?, group: Any?, format: String? = "audiobook", releaseAt: String) -> [String: Any] {
    element(id, name, subtype: "episode", series: series, group: group, format: format, releaseAt: releaseAt)
  }

  /// A reference as `u/items/list` populates it
  static func ref(_ id: String, _ name: String, index: Int? = nil) -> [String: Any] {
    var ref: [String: Any] = ["_id": id, "name": name]
    if let index {
      ref["displayOptions"] = ["index": index]
    }
    return ref
  }

  /// An owned title
  static func owned(_ element: [String: Any]) -> [String: Any] {
    ["_id": "le-\(element["_id"] as? String ?? "")", "type": "Item", "element": element]
  }

  /// An owned season bundle
  static func ownedSeason(_ id: String, _ name: String, series: String?, index: Int? = nil) -> [String: Any] {
    var record = element(id, name, subtype: nil, series: series, releaseAt: nil)
    if let index {
      record["displayOptions"] = ["index": index]
    }
    return ["_id": "le-\(id)", "type": "Group", "element": record]
  }

  static func series(_ id: String, _ name: String) -> [String: Any] {
    ["_id": id, "name": name]
  }

  /// A `groups/list` season, its series populated as that call sends it
  static func season(_ id: String, _ name: String, index: Int?) -> [String: Any] {
    var season: [String: Any] = ["_id": id, "name": name, "seriesId": ["_id": "populated", "name": "Populated"]]
    if let index {
      season["displayOptions"] = ["index": index]
    }
    return season
  }

  static func resource(_ id: String, item: String, number: Int, name: String?, duration: Double? = 60) -> [String: Any] {
    var resource: [String: Any] = ["_id": id, "itemId": item, "number": number, "type": "chapter"]
    if let name {
      resource["name"] = name
    }
    if let duration {
      resource["duration"] = duration
    }
    return resource
  }

  static func progress(item: String, resource: String, position: Double, finished: Bool = false, updatedAt: String) -> [String: Any] {
    [
      "_id": "p-\(resource)-\(updatedAt)",
      "item": item,
      "resource": resource,
      "position": position,
      "finished": finished,
      "updatedAt": updatedAt,
    ]
  }
}

/// The SoundBooth API client: the headers its web player sends, passwordless sign-in, lenient lists that
/// follow their pages, and the redirect that is a chapter's audio
final class SoundBoothAPIClientTests: XCTestCase {
  private var http: SoundBoothHTTPStub!
  private var client: SoundBoothAPIClient!
  private let session = SoundBoothSession(jwt: "jwt-1", userId: "user-1", email: "reader@example.com", sessionCookie: "sid-1")

  override func setUp() {
    super.setUp()
    http = SoundBoothHTTPStub()
    client = SoundBoothAPIClient(configuration: .production, httpClient: http)
  }

  override func tearDown() {
    client = nil
    http = nil
    super.tearDown()
  }

  private func body(_ request: URLRequest) -> [String: Any] {
    guard let data = request.httpBody, let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
    return object as? [String: Any] ?? [:]
  }

  private func assertThrows<T>(
    _ expected: SoundBoothAPIError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> T
  ) async {
    do {
      let value = try await body()
      XCTFail("expected \(expected), got \(value)", file: file, line: line)
    } catch {
      XCTAssertEqual(error as? SoundBoothAPIError, expected, file: file, line: line)
    }
  }

  // MARK: - Requests

  func testAUserCallCarriesTheClientKeyAndTheSession() async throws {
    http.reply("/functions/u/series/list", json: SoundBoothFixtures.page([]))

    _ = try await client.series(session: session)

    let request = try XCTUnwrap(http.requests.first)
    XCTAssertEqual(request.url?.absoluteString, "https://api.soundbooththeater.com/functions/u/series/list")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.iglu.v2")
    XCTAssertEqual(request.value(forHTTPHeaderField: "x-iglu-api-key"), "Bearer \(SoundBoothAPIClient.Configuration.production.clientKey)")
    XCTAssertEqual(request.value(forHTTPHeaderField: "x-iglu-time-zone-offset"), "\(TimeZone.current.secondsFromGMT() / 3600)")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://player.soundbooth.app")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://player.soundbooth.app/")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token jwt-1")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "iglu.sid=sid-1")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertTrue(body(request).isEmpty)
  }

  func testASessionWithoutACookieSendsNone() async throws {
    http.reply("/functions/u/series/list", json: SoundBoothFixtures.page([]))

    _ = try await client.series(session: SoundBoothSession(jwt: "jwt-1", userId: "user-1", email: "reader@example.com"))

    XCTAssertNil(try XCTUnwrap(http.requests.first).value(forHTTPHeaderField: "Cookie"))
  }

  // MARK: - Sign in

  func testAskingForACodeSendsTheEmailAndNoSession() async throws {
    http.reply("/base/auth/login/code/link", json: ["success": true])

    try await client.requestLoginCode(email: "reader@example.com")

    let request = try XCTUnwrap(http.requests.first)
    XCTAssertEqual(request.url?.path, "/base/auth/login/code/link")
    XCTAssertEqual(body(request) as? [String: String], ["email": "reader@example.com"])
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNotNil(request.value(forHTTPHeaderField: "x-iglu-api-key"))
  }

  func testARefusedCodeRequestCarriesSoundBoothsWords() async {
    http.reply("/base/auth/login/code/link", json: SoundBoothFixtures.failure("Too many attempts", code: "729"))

    await assertThrows(.api(message: "Too many attempts", code: "729")) {
      try await self.client.requestLoginCode(email: "reader@example.com")
    }
  }

  func testVerifyingReturnsTheSessionAndItsCookie() async throws {
    http.reply(
      "/base/auth/login/code/verify",
      json: SoundBoothFixtures.ok(["_id": "user-9", "email": "Reader@Example.com", "jwt": "jwt-9", "billing": ["plan": "none"]] as [String: Any]),
      headers: ["Set-Cookie": "iglu.sid=sid-9; Path=/; HttpOnly"]
    )

    let verified = try await client.verifyLoginCode(email: "reader@example.com", code: "123456")

    XCTAssertEqual(verified, SoundBoothSession(jwt: "jwt-9", userId: "user-9", email: "Reader@Example.com", sessionCookie: "sid-9"))
    let request = try XCTUnwrap(http.requests.first)
    XCTAssertEqual(body(request) as? [String: String], ["email": "reader@example.com", "code": "123456"])
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
  }

  /// The session cookie is the one the data calls check; others set beside it aren't
  func testOnlyTheSessionCookieIsKept() async throws {
    http.reply(
      "/base/auth/login/code/verify",
      json: SoundBoothFixtures.ok(["_id": "user-9", "email": "reader@example.com", "jwt": "jwt-9"]),
      headers: ["Set-Cookie": "theme=dark; Path=/, iglu.sid=sid-9; Path=/"]
    )

    let verified = try await client.verifyLoginCode(email: "reader@example.com", code: "123456")

    XCTAssertEqual(verified.sessionCookie, "sid-9")
  }

  func testAnAnswerWithoutACookieHasNone() async throws {
    http.reply("/base/auth/login/code/verify", json: SoundBoothFixtures.ok(["_id": "user-9", "email": "reader@example.com", "jwt": "jwt-9"]))

    let verified = try await client.verifyLoginCode(email: "reader@example.com", code: "123456")

    XCTAssertNil(verified.sessionCookie)
  }

  func testAnAnswerWithoutTheEmailKeepsTheOneTyped() async throws {
    http.reply("/base/auth/login/code/verify", json: SoundBoothFixtures.ok(["_id": "user-9", "email": "", "jwt": "jwt-9"]))

    let verified = try await client.verifyLoginCode(email: "reader@example.com", code: "123456")

    XCTAssertEqual(verified.email, "reader@example.com")
  }

  /// Nothing signs in with an empty JWT, and an empty account id would let two accounts become one
  /// saved connection
  func testAnAnswerWithoutAnAccountOrAJWTIsRefused() async {
    http.reply("/base/auth/login/code/verify", json: SoundBoothFixtures.ok(["_id": "", "email": "reader@example.com", "jwt": "jwt-9"]))
    await assertThrows(.decoding) { try await self.client.verifyLoginCode(email: "reader@example.com", code: "1") }

    http.reply("/base/auth/login/code/verify", json: SoundBoothFixtures.ok(["_id": "user-9", "email": "reader@example.com", "jwt": ""]))
    await assertThrows(.decoding) { try await self.client.verifyLoginCode(email: "reader@example.com", code: "1") }

    http.reply("/base/auth/login/code/verify", json: SoundBoothFixtures.ok(["_id": "user-9", "email": "reader@example.com"]))
    await assertThrows(.decoding) { try await self.client.verifyLoginCode(email: "reader@example.com", code: "1") }
  }

  func testAWrongCodeCarriesSoundBoothsWords() async {
    http.reply("/base/auth/login/code/verify", json: SoundBoothFixtures.failure("That code has expired", code: "720"))

    await assertThrows(.api(message: "That code has expired", code: "720")) {
      try await self.client.verifyLoginCode(email: "reader@example.com", code: "1")
    }
  }

  /// Before signing in there's no session to expire: a refusal reads as what it is, so the sign-in
  /// screen never says "your session expired"
  func testARefusedCodeRequestIsNotAnExpiredSession() async {
    http.reply("/base/auth/login/code/link", json: ["success": false], status: 401)

    await assertThrows(.http(status: 401)) { try await self.client.requestLoginCode(email: "reader@example.com") }
  }

  func testARefusedSignInIsNotAnExpiredSession() async {
    http.reply("/base/auth/login/code/verify", json: ["success": false], status: 403)

    await assertThrows(.http(status: 403)) { try await self.client.verifyLoginCode(email: "reader@example.com", code: "1") }
  }

  func testTheInvalidSessionCodeAtSignInIsARefusal() async {
    http.reply("/base/auth/login/code/verify", json: SoundBoothFixtures.failure("Invalid session", code: "50230"))

    await assertThrows(.api(message: "Invalid session", code: "50230")) {
      try await self.client.verifyLoginCode(email: "reader@example.com", code: "1")
    }
  }

  // MARK: - Answers

  /// SoundBooth can say the session is invalid with a 200
  func testTheInvalidSessionCodeIsAnInvalidSession() async {
    http.reply("/functions/u/library-elements/list", json: SoundBoothFixtures.failure("Invalid session", code: "50230"))

    await assertThrows(.sessionInvalid) { try await self.client.libraryElements(session: self.session) }
  }

  func testErrorStatuses() async {
    for status in [401, 403] {
      http.reply("/functions/u/groups/list", json: ["success": false], status: status)
      await assertThrows(.sessionInvalid) { try await self.client.groups(session: self.session) }
    }

    http.reply("/functions/u/groups/list", json: ["success": false], status: 502)
    await assertThrows(.http(status: 502)) { try await self.client.groups(session: self.session) }

    http.reply("/functions/u/groups/list", SoundBoothHTTPStub.Reply(body: "<html>Bad gateway</html>"))
    await assertThrows(.decoding) { try await self.client.groups(session: self.session) }
  }

  // MARK: - Lists

  func testAListFollowsItsPages() async throws {
    http.reply(
      "/functions/u/series/list",
      .init(body: SoundBoothFixtures.text(SoundBoothFixtures.page([SoundBoothFixtures.series("s1", "One")], hasNextPage: true))),
      .init(body: SoundBoothFixtures.text(SoundBoothFixtures.page([SoundBoothFixtures.series("s2", "Two")], hasNextPage: false)))
    )

    let all = try await client.series(session: session)

    XCTAssertEqual(all.map(\.id), ["s1", "s2"])
    let bodies = http.requests.map(body)
    guard bodies.count == 2 else {
      return XCTFail("expected two requests, got \(bodies.count)")
    }
    XCTAssertNil(bodies[0]["page"], "the first request is the web player's")
    XCTAssertEqual(bodies[1]["page"] as? Int, 2)
  }

  func testAPageThatDoesntSayThereIsMoreIsTheLast() async throws {
    http.reply("/functions/u/series/list", json: SoundBoothFixtures.page([SoundBoothFixtures.series("s1", "One")]))

    let all = try await client.series(session: session)

    XCTAssertEqual(all.map(\.id), ["s1"])
    XCTAssertEqual(http.requests.count, 1)
  }

  func testAListThatNeverEndsStopsAtTheCap() async throws {
    http.reply("/functions/u/series/list", json: SoundBoothFixtures.page([SoundBoothFixtures.series("s", "Again")], hasNextPage: true))

    let all = try await client.series(session: session)

    XCTAssertEqual(http.requests.count, SoundBoothAPIClient.maxPages)
    XCTAssertEqual(all.count, SoundBoothAPIClient.maxPages)
    XCTAssertEqual(body(try XCTUnwrap(http.requests.last))["page"] as? Int, SoundBoothAPIClient.maxPages)
  }

  func testASeasonsEpisodesAreAskedForByItsGroup() async throws {
    http.reply("/functions/u/items/list", json: SoundBoothFixtures.page([]))

    _ = try await client.items(inGroup: "g1", session: session)

    XCTAssertEqual(body(try XCTUnwrap(http.requests.first)) as? [String: String], ["groupId": "g1"])
  }

  /// A refunded purchase comes back with a null element: it's skipped, not the whole library
  func testABrokenEntryDoesntSinkTheList() async throws {
    http.reply(
      "/functions/u/library-elements/list",
      json: SoundBoothFixtures.page([
        SoundBoothFixtures.owned(SoundBoothFixtures.element("b1", "Kept")),
        ["_id": "le-null", "type": "Item", "element": NSNull()] as [String: Any],
        ["_id": "le-nameless", "type": "Item", "element": ["_id": "b2"]] as [String: Any],
      ])
    )

    let owned = try await client.libraryElements(session: session)

    XCTAssertEqual(owned.map(\.element.id), ["b1"])
    XCTAssertEqual(owned.first?.isGroup, false)
  }

  /// `u/items/list` populates the series and season, other calls send their ids: both decode, and a
  /// populated one keeps its name, which names series the list calls leave out
  func testReferencesArriveAsIdsOrAsObjects() async throws {
    http.reply(
      "/functions/u/items/list",
      json: SoundBoothFixtures.page([
        SoundBoothFixtures.element("b1", "Bare", series: "s1", group: "g1"),
        SoundBoothFixtures.element(
          "b2",
          "Populated",
          series: SoundBoothFixtures.ref("s2", "Orphan Series"),
          group: SoundBoothFixtures.ref("g2", "Season 2", index: 2)
        ),
        SoundBoothFixtures.element("b3", "Odd name", series: ["_id": "s3", "name": 42] as [String: Any]),
      ])
    )

    let items = try await client.items(session: session)

    XCTAssertEqual(items.map(\.id), ["b1", "b2", "b3"])
    guard items.count == 3 else { return }
    XCTAssertEqual(items[0].seriesId, "s1")
    XCTAssertNil(items[0].seriesName)
    XCTAssertEqual(items[0].groupId, "g1")
    XCTAssertNil(items[0].groupIndex)
    XCTAssertEqual(items[1].seriesId, "s2")
    XCTAssertEqual(items[1].seriesName, "Orphan Series")
    XCTAssertEqual(items[1].groupId, "g2")
    XCTAssertEqual(items[1].groupName, "Season 2")
    XCTAssertEqual(items[1].groupIndex, 2)
    // A malformed name costs the name, not the reference
    XCTAssertEqual(items[2].seriesId, "s3")
    XCTAssertNil(items[2].seriesName)
  }

  /// SoundBooth sends release times with and without fractional seconds. One that didn't parse would
  /// read as released and let a preorder episode be downloaded
  func testReleaseTimesParseWithAndWithoutFractions() throws {
    let plain = try SoundBoothFixtures.decode(SoundBoothElement.self, SoundBoothFixtures.element("e1", "Plain", releaseAt: "2099-05-01T10:00:00Z"))
    let fractional = try SoundBoothFixtures.decode(SoundBoothElement.self, SoundBoothFixtures.element("e2", "Fraction", releaseAt: "2099-05-01T10:00:00.250Z"))
    let past = try SoundBoothFixtures.decode(SoundBoothElement.self, SoundBoothFixtures.element("e3", "Past", releaseAt: "2020-05-01T10:00:00.000Z"))
    let undated = try SoundBoothFixtures.decode(SoundBoothElement.self, SoundBoothFixtures.element("e4", "Undated", releaseAt: nil))

    XCTAssertEqual(plain.releaseDate, Date(timeIntervalSince1970: 4_081_312_800))
    XCTAssertEqual(try XCTUnwrap(fractional.releaseDate).timeIntervalSince1970, 4_081_312_800.25, accuracy: 0.001)
    XCTAssertFalse(plain.isReleased)
    XCTAssertFalse(fractional.isReleased)
    XCTAssertTrue(past.isReleased)
    XCTAssertTrue(undated.isReleased)
    XCTAssertEqual(undated.releaseSortKey, "\u{FFFF}", "an undated title sorts last")
  }

  func testProgressesSkipEntriesThatDontDecode() async throws {
    http.reply(
      "/functions/user/progresses",
      json: SoundBoothFixtures.ok([
        SoundBoothFixtures.progress(item: "b1", resource: "r1", position: 12, updatedAt: "2026-10-01T00:00:00.000Z"),
        ["_id": "broken"],
      ])
    )

    let progresses = try await client.progresses(session: session)

    XCTAssertEqual(progresses.map(\.resource), ["r1"])
    XCTAssertEqual(progresses.first?.position, 12)
  }

  func testChaptersAreAskedForByItem() async throws {
    http.reply(
      "/functions/playlist/item-resources",
      json: SoundBoothFixtures.ok([
        "itemResources": [
          SoundBoothFixtures.resource("r1", item: "b1", number: 0, name: "Opening Credits"),
          ["_id": "broken"],
        ],
      ])
    )

    let resources = try await client.itemResources(itemIds: ["b1", "b2"], session: session)

    XCTAssertEqual(resources.map(\.id), ["r1"])
    XCTAssertEqual(body(try XCTUnwrap(http.requests.first))["itemIds"] as? [String], ["b1", "b2"])
  }

  // MARK: - Audio

  func testThePlayEndpointNamesTheChapterAndTheQuality() throws {
    XCTAssertEqual(
      try client.playbackEndpointURL(resourceId: "r1", quality: .high).absoluteString,
      "https://api.soundbooththeater.com/functions/resources/play?id=r1&quality=192k"
    )
    XCTAssertEqual(
      try client.playbackEndpointURL(resourceId: "r1", quality: .standard).absoluteString,
      "https://api.soundbooththeater.com/functions/resources/play?id=r1&quality=96k"
    )
  }

  /// The audio's URL is where the play endpoint redirects, asked for with the account's session
  func testAChaptersAudioIsWhereThePlayEndpointRedirects() async throws {
    http.redirect(resource: "r1", to: "https://cdn.example.com/sb/r1.mp3?token=abc")

    let url = try await client.resolvePlaybackURL(resourceId: "r1", quality: .high, session: session)

    XCTAssertEqual(url.absoluteString, "https://cdn.example.com/sb/r1.mp3?token=abc")
    let request = try XCTUnwrap(http.requests.first)
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertEqual(request.url?.absoluteString, "https://api.soundbooththeater.com/functions/resources/play?id=r1&quality=192k")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token jwt-1")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "iglu.sid=sid-1")
    XCTAssertNotNil(request.value(forHTTPHeaderField: "x-iglu-api-key"))
  }
}
