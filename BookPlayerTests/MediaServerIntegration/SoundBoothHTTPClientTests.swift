//
//  SoundBoothHTTPClientTests.swift
//  BookPlayerTests
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

@testable import BookPlayerKit
import Network
import XCTest

/// An HTTP server on the loopback interface, answering each connection's one request from its routes.
/// For what a `URLProtocol` stub can't show: the loading system attaches the jar's cookies, stores a
/// `Set-Cookie` and follows a redirect only for real HTTP. `@unchecked Sendable`: state is behind the lock
final class LoopbackHTTPServer: @unchecked Sendable {
  struct Request {
    let method: String
    /// The path with its query, as the request line had it
    let target: String
    /// Header names lowercased
    let headers: [String: String]
  }

  struct Response {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()
  }

  private let listener: NWListener
  private let queue = DispatchQueue(label: "LoopbackHTTPServer")
  private let lock = NSLock()
  private var routes = [String: Response]()
  private var received = [Request]()
  private var startContinuation: CheckedContinuation<Void, Error>?
  private var boundPort: UInt16 = 0

  init() throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
    listener = try NWListener(using: parameters)
  }

  var requests: [Request] { lock.withLock { received } }

  func route(_ target: String, _ response: Response) {
    lock.withLock { routes[target] = response }
  }

  func url(_ target: String) -> URL {
    URL(string: "http://127.0.0.1:\(lock.withLock { boundPort })\(target)")!
  }

  func start() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      lock.withLock { startContinuation = continuation }
      listener.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        switch state {
        case .ready:
          let continuation = self.lock.withLock { () -> CheckedContinuation<Void, Error>? in
            self.boundPort = self.listener.port?.rawValue ?? 0
            defer { self.startContinuation = nil }
            return self.startContinuation
          }
          continuation?.resume()
        case .failed(let error):
          let continuation = self.lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { self.startContinuation = nil }
            return self.startContinuation
          }
          continuation?.resume(throwing: error)
        default:
          break
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        guard let self else { return }
        connection.start(queue: self.queue)
        self.receive(on: connection, buffer: Data())
      }
      listener.start(queue: queue)
    }
  }

  func stop() {
    listener.cancel()
  }

  private func receive(on connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      var buffer = buffer
      if let data {
        buffer.append(data)
      }
      if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
        self.answer(String(decoding: buffer[..<end.lowerBound], as: UTF8.self), on: connection)
      } else if isComplete || error != nil {
        connection.cancel()
      } else {
        self.receive(on: connection, buffer: buffer)
      }
    }
  }

  private func answer(_ head: String, on connection: NWConnection) {
    let lines = head.components(separatedBy: "\r\n")
    let requestLine = lines.first?.split(separator: " ").map(String.init) ?? []
    var headers = [String: String]()
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    let request = Request(
      method: requestLine.first ?? "",
      target: requestLine.count > 1 ? requestLine[1] : "",
      headers: headers
    )
    let response = lock.withLock { () -> Response in
      received.append(request)
      return routes[request.target] ?? Response(status: 404)
    }

    var head = "HTTP/1.1 \(response.status) \(HTTPURLResponse.localizedString(forStatusCode: response.status))\r\n"
    for (name, value) in response.headers {
      head += "\(name): \(value)\r\n"
    }
    head += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
    var payload = Data(head.utf8)
    payload.append(response.body)
    // Ends the server's side of the stream, then waits for the client to close its own: cancelling
    // straight away can reset the connection before the client has read the answer
    connection.send(content: payload, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
      self?.drain(connection)
    })
  }

  private func drain(_ connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] _, _, isComplete, error in
      if isComplete || error != nil {
        connection.cancel()
      } else {
        self?.drain(connection)
      }
    }
  }
}

/// Canned answers for `SoundBoothHTTPClient`'s session, set on its configuration (never registered
/// globally). A redirect is reported the way the loading system reports one, so following it is the
/// session's own decision: a followed redirect asks for its `Location`, which shows in `loadedURLs`.
final class SoundBoothURLProtocolStub: URLProtocol {
  struct Reply {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var replies = [String: Reply]()
  nonisolated(unsafe) private static var loaded = [URLRequest]()

  static func reset() {
    lock.withLock {
      replies = [:]
      loaded = []
    }
  }

  static func answer(_ url: String, _ reply: Reply) {
    lock.withLock { replies[url] = reply }
  }

  static var loadedRequests: [URLRequest] { lock.withLock { loaded } }
  static var loadedURLs: [String] { loadedRequests.map { $0.url?.absoluteString ?? "" } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let reply: Reply? = Self.lock.withLock {
      Self.loaded.append(request)
      return Self.replies[request.url?.absoluteString ?? ""]
    }
    guard let url = request.url, let reply else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
      return
    }
    let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
    if (300...399).contains(reply.status),
      let location = reply.headers["Location"],
      let target = URL(string: location, relativeTo: url)?.absoluteURL
    {
      // Refused by the session's delegate, the redirect itself is the answer; followed, the target loads
      client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: reply.body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

/// The SoundBooth transport: no cookies either way, and `resources/play` read for where it redirects
/// without fetching the audio there
final class SoundBoothHTTPClientTests: XCTestCase {
  private let play = "https://api.soundbooththeater.com/functions/resources/play?id=r1&quality=192k"
  private let audio = "https://cdn.example.com/sb/r1.mp3?token=abc"

  override func setUp() {
    super.setUp()
    SoundBoothURLProtocolStub.reset()
    // Wherever a followed redirect would land: audio
    SoundBoothURLProtocolStub.answer(audio, .init(status: 200, body: Data("ID3 audio".utf8)))
  }

  override func tearDown() {
    SoundBoothURLProtocolStub.reset()
    super.tearDown()
  }

  private func makeClient(_ configuration: URLSessionConfiguration = .ephemeral) -> SoundBoothHTTPClient {
    configuration.protocolClasses = [SoundBoothURLProtocolStub.self]
    return SoundBoothHTTPClient(configuration: configuration, timeout: 5)
  }

  private func request(_ url: String) -> URLRequest {
    URLRequest(url: URL(string: url)!)
  }

  // MARK: - Cookies

  /// A stale `iglu.sid` riding along made SoundBooth refuse signing in again after a sign-out, so the
  /// session keeps no cookie jar, even when the configuration it's given has one
  func testTheSessionKeepsNoCookies() {
    let configuration = URLSessionConfiguration.default
    configuration.httpCookieStorage = HTTPCookieStorage.shared
    configuration.httpShouldSetCookies = true
    configuration.httpCookieAcceptPolicy = .always

    let client = makeClient(configuration)

    XCTAssertNil(client.configuration.httpCookieStorage)
    XCTAssertFalse(client.configuration.httpShouldSetCookies)
    XCTAssertEqual(client.configuration.httpCookieAcceptPolicy, .never)
    XCTAssertEqual(client.configuration.timeoutIntervalForRequest, 5)
  }

  /// The configuration passed in is the caller's: the client changes its own copy
  func testTheCallersConfigurationKeepsItsSettings() {
    let configuration = URLSessionConfiguration.default
    configuration.httpCookieStorage = HTTPCookieStorage.shared
    configuration.httpShouldSetCookies = true
    configuration.timeoutIntervalForRequest = 60

    _ = makeClient(configuration)

    XCTAssertNotNil(configuration.httpCookieStorage)
    XCTAssertTrue(configuration.httpShouldSetCookies)
    XCTAssertEqual(configuration.timeoutIntervalForRequest, 60)
  }

  // MARK: - Plain calls

  /// Statuses are the API client's to judge: an error status comes back with its body
  func testAnErrorStatusComesBackWithItsBody() async throws {
    let url = "https://api.soundbooththeater.com/functions/u/series/list"
    SoundBoothURLProtocolStub.answer(url, .init(status: 500, body: Data("oops".utf8)))

    let (data, response) = try await makeClient().data(for: request(url))

    XCTAssertEqual(response.statusCode, 500)
    XCTAssertEqual(String(decoding: data, as: UTF8.self), "oops")
  }

  // MARK: - Redirects

  /// The audio's URL is where `resources/play` redirects. The redirect isn't followed: following it
  /// would download the whole chapter just to learn its address
  func testTheRedirectIsReadNotFollowed() async throws {
    SoundBoothURLProtocolStub.answer(play, .init(status: 302, headers: ["Location": audio]))

    let location = try await makeClient().redirectLocation(for: request(play))

    XCTAssertEqual(location.absoluteString, audio)
    XCTAssertEqual(SoundBoothURLProtocolStub.loadedURLs, [play])
  }

  func testARelativeLocationIsResolvedAgainstTheRequest() async throws {
    SoundBoothURLProtocolStub.answer(play, .init(status: 307, headers: ["Location": "/media/r1.mp3"]))

    let location = try await makeClient().redirectLocation(for: request(play))

    XCTAssertEqual(location.absoluteString, "https://api.soundbooththeater.com/media/r1.mp3")
  }

  func testEveryRedirectStatusIsRead() async throws {
    for status in [301, 302, 303, 307, 308] {
      SoundBoothURLProtocolStub.answer(play, .init(status: status, headers: ["Location": audio]))

      let location = try await makeClient().redirectLocation(for: request(play))

      XCTAssertEqual(location.absoluteString, audio, "\(status)")
    }
  }

  /// A rejected session is a session to renew, not a missing redirect
  func testARejectedSessionIsAnInvalidSession() async {
    for status in [401, 403] {
      SoundBoothURLProtocolStub.answer(play, .init(status: status))

      await assertRedirectThrows(.sessionInvalid, "\(status)")
    }
  }

  /// Anything but a redirect with somewhere to go means there's no audio URL: July saved CacheFly's
  /// HTML 404 page as the chapter's MP3
  func testAnythingButARedirectHasNoAudioURL() async {
    SoundBoothURLProtocolStub.answer(play, .init(status: 200, body: Data("<html>".utf8)))
    await assertRedirectThrows(.noRedirect(status: 200), "200")

    SoundBoothURLProtocolStub.answer(play, .init(status: 302))
    await assertRedirectThrows(.noRedirect(status: 302), "302 without a Location")

    SoundBoothURLProtocolStub.answer(play, .init(status: 300, headers: ["Location": audio]))
    await assertRedirectThrows(.noRedirect(status: 300), "300 isn't a way to the audio")

    SoundBoothURLProtocolStub.answer(play, .init(status: 404))
    await assertRedirectThrows(.noRedirect(status: 404), "404")
  }

  private func assertRedirectThrows(
    _ expected: SoundBoothAPIError,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      let url = try await makeClient().redirectLocation(for: request(play))
      XCTFail("\(message): expected \(expected), got \(url)", file: file, line: line)
    } catch {
      XCTAssertEqual(error as? SoundBoothAPIError, expected, message, file: file, line: line)
    }
  }
}

/// The same transport over real HTTP on the loopback interface, where the loading system's cookie jar
/// and redirect handling actually run
final class SoundBoothHTTPClientLoopbackTests: XCTestCase {
  private var server: LoopbackHTTPServer!

  override func setUp() async throws {
    try await super.setUp()
    server = try LoopbackHTTPServer()
    try await server.start()
  }

  override func tearDown() async throws {
    server.stop()
    server = nil
    clearLoopbackCookies()
    try await super.tearDown()
  }

  private func clearLoopbackCookies() {
    for cookie in HTTPCookieStorage.shared.cookies(for: URL(string: "http://127.0.0.1/")!) ?? [] {
      HTTPCookieStorage.shared.deleteCookie(cookie)
    }
  }

  /// SoundBooth refused a new sign-in while an old `iglu.sid` rode along. Given a configuration whose
  /// jar holds one, the client sends no cookie, and the cookie a sign-in answer sets isn't kept for the
  /// next call either: the API client sends the session's cookie itself
  func testNoCookieGoesOutAndNoneIsKept() async throws {
    clearLoopbackCookies()
    let stale = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "iglu.sid", .value: "stale"]))
    HTTPCookieStorage.shared.setCookie(stale)
    server.route("/base/auth/login/code/verify", .init(status: 200, headers: ["Set-Cookie": "iglu.sid=fresh; Path=/"], body: Data("{}".utf8)))
    server.route("/functions/u/series/list", .init(status: 200, body: Data("{}".utf8)))
    let configuration = URLSessionConfiguration.default
    configuration.httpCookieStorage = HTTPCookieStorage.shared
    configuration.httpShouldSetCookies = true
    configuration.httpCookieAcceptPolicy = .always
    let client = SoundBoothHTTPClient(configuration: configuration, timeout: 5)

    let (_, signIn) = try await client.data(for: URLRequest(url: server.url("/base/auth/login/code/verify")))
    _ = try await client.data(for: URLRequest(url: server.url("/functions/u/series/list")))

    XCTAssertEqual(signIn.value(forHTTPHeaderField: "Set-Cookie"), "iglu.sid=fresh; Path=/", "the answer still carries it for the API client")
    XCTAssertEqual(server.requests.map(\.target), ["/base/auth/login/code/verify", "/functions/u/series/list"])
    XCTAssertEqual(server.requests.map { $0.headers["cookie"] }, [nil, nil])
    XCTAssertEqual(
      (HTTPCookieStorage.shared.cookies(for: URL(string: "http://127.0.0.1/")!) ?? []).map(\.value),
      ["stale"],
      "the answer's cookie wasn't stored"
    )
  }

  /// A real 302: the client reads where it goes and never asks for it
  func testARealRedirectIsReadNotFollowed() async throws {
    server.route("/functions/resources/play?id=r1&quality=192k", .init(status: 302, headers: ["Location": "/cdn/r1.mp3?token=abc"]))
    server.route("/cdn/r1.mp3?token=abc", .init(status: 200, headers: ["Content-Type": "audio/mpeg"], body: Data("ID3 audio".utf8)))
    let client = SoundBoothHTTPClient(configuration: .ephemeral, timeout: 5)

    let location = try await client.redirectLocation(for: URLRequest(url: server.url("/functions/resources/play?id=r1&quality=192k")))

    XCTAssertEqual(location, server.url("/cdn/r1.mp3?token=abc"))
    XCTAssertEqual(server.requests.map(\.target), ["/functions/resources/play?id=r1&quality=192k"])
  }
}
