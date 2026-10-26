//
//  SoundBoothConnectionData.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import Foundation

/// One saved SoundBooth account (fork). SoundBooth is one hosted service, so there's no server address
/// to keep: just the session and the account's email to show. Stored in the Keychain under
/// `.soundboothConnection` in the shape the July 2026 builds wrote (`CodingKeys` below); what
/// `IntegrationConnectionStore` reads is computed, so conforming changes nothing that's stored.
public struct SoundBoothConnectionData: Codable, Identifiable, Equatable {
  public let id: String
  public let email: String
  public let userId: String
  public let jwt: String
  public var sessionCookie: String?

  enum CodingKeys: String, CodingKey {
    case id, email, userId, jwt, sessionCookie
  }

  /// The service's name in the shared connection screens: one backend, so the email tells accounts apart
  public var serverName: String { "SoundBooth" }
  public var userName: String { email }

  /// What the API client sends for this account
  public var session: SoundBoothSession {
    SoundBoothSession(jwt: jwt, userId: userId, email: email, sessionCookie: sessionCookie)
  }

  public init(session: SoundBoothSession, id: String = UUID().uuidString) {
    self.id = id
    self.email = session.email
    self.userId = session.userId
    self.jwt = session.jwt
    self.sessionCookie = session.sessionCookie
  }
}

extension SoundBoothConnectionData: IntegrationConnectionPayload {
  /// The one API address stands in for a server's, so the store tells accounts apart by user id alone,
  /// as the July builds did
  var url: URL { SoundBoothAPIClient.Configuration.production.baseURL }
  var userID: String { userId }
  /// What signs the account in. The store drops a record whose user id or token is empty when it
  /// loads, the rule the July builds applied to these records too
  var token: String { jwt }
  /// SoundBooth has no libraries to choose between
  var selectedLibraryId: String? {
    get { nil }
    set {}
  }
  /// Nothing sits between the app and SoundBooth's own servers, so there are no headers to add
  var customHeaders: [String: String] {
    get { [:] }
    set {}
  }
}

extension SoundBoothConnectionData: CustomDebugStringConvertible {
  public var debugDescription: String {
    "SoundBoothConnectionData(\(email), \(userId), jwt<redacted>)"
  }
}
