//
//  SoundBoothConnectionData.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import Foundation

/// Persisted SoundBooth account connection. Unlike the other media-server clients there's no
/// per-connection server URL (SoundBooth is a single hosted backend), so this is really just the
/// authenticated session plus the account's email for display. Stored in the Keychain under
/// `.soundboothConnection`.
struct SoundBoothConnectionData: Codable, Identifiable {
  let id: String
  let email: String
  let userId: String
  let jwt: String
  var sessionCookie: String?

  /// Display label for the shared connection UI. SoundBooth has one backend, so the account
  /// email is the meaningful distinguisher between connections.
  var serverName: String { "SoundBooth" }
  var userName: String { email }

  /// The credential bundle the standalone API client consumes.
  var session: SoundBoothSession {
    SoundBoothSession(jwt: jwt, userId: userId, email: email, sessionCookie: sessionCookie)
  }

  init(session: SoundBoothSession, id: String = UUID().uuidString) {
    self.id = id
    self.email = session.email
    self.userId = session.userId
    self.jwt = session.jwt
    self.sessionCookie = session.sessionCookie
  }
}

extension SoundBoothConnectionData: CustomDebugStringConvertible {
  var debugDescription: String {
    "SoundBoothConnectionData(\(email), \(userId), jwt<redacted>)"
  }
}
