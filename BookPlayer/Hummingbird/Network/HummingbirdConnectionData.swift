//
//  HummingbirdConnectionData.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-05-18.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import Foundation

/// Persisted credentials for one Hummingbird server. Hummingbird's REST surface
/// validates HTTP Basic on every request (with a 15-min server-side cache), so
/// we keep the password in the keychain to rebuild the header on every call --
/// the connection is a long-lived "I am this user" handle, not a short-lived
/// bearer token like ABS's.
struct HummingbirdConnectionData: Codable, Identifiable {
  let id: String
  let url: URL
  let serverName: String
  let userName: String
  let password: String
  var customHeaders: [String: String] = [:]

  enum CodingKeys: String, CodingKey {
    case id, url, serverName, userName, password, customHeaders
  }

  init(
    id: String = UUID().uuidString,
    url: URL,
    serverName: String,
    userName: String,
    password: String,
    customHeaders: [String: String] = [:]
  ) {
    self.id = id
    self.url = url
    self.serverName = serverName
    self.userName = userName
    self.password = password
    self.customHeaders = customHeaders
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = (try? container.decode(String.self, forKey: .id)) ?? UUID().uuidString
    self.url = try container.decode(URL.self, forKey: .url)
    self.serverName = try container.decode(String.self, forKey: .serverName)
    self.userName = try container.decode(String.self, forKey: .userName)
    self.password = try container.decode(String.self, forKey: .password)
    self.customHeaders = try container.decodeIfPresent([String: String].self, forKey: .customHeaders) ?? [:]
  }
}

extension HummingbirdConnectionData: CustomDebugStringConvertible {
  var debugDescription: String {
    let passwordDebugDesc = password.isEmpty ? "<empty>" : "<redacted>"
    return "HummingbirdConnectionData(\(url), \(serverName), \(userName), \(passwordDebugDesc))"
  }
}
