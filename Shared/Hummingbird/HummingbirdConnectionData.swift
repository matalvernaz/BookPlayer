//
//  HummingbirdConnectionData.swift
//  BookPlayer
//
//  Created by Matthew Alvernaz on 2026-05-18.
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import Foundation

/// Saved credentials for one Hummingbird server (fork). Hummingbird checks HTTP Basic on every
/// request, so the password is kept in the Keychain to rebuild the header for each call: the
/// connection is a long-lived "I am this user", not a short-lived bearer token like ABS's.
///
/// The Keychain shape is the July 2026 one (`CodingKeys` below). The members
/// `IntegrationConnectionStore` needs are computed, so conforming changes nothing that's stored.
public struct HummingbirdConnectionData: Codable, Identifiable, Equatable {
  public let id: String
  public let url: URL
  public let serverName: String
  public let userName: String
  public let password: String
  public var customHeaders: [String: String] = [:]

  enum CodingKeys: String, CodingKey {
    case id, url, serverName, userName, password, customHeaders
  }

  public init(
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

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = (try? container.decode(String.self, forKey: .id)) ?? UUID().uuidString
    self.url = try container.decode(URL.self, forKey: .url)
    self.serverName = try container.decode(String.self, forKey: .serverName)
    self.userName = try container.decode(String.self, forKey: .userName)
    self.password = try container.decode(String.self, forKey: .password)
    self.customHeaders = try container.decodeIfPresent([String: String].self, forKey: .customHeaders) ?? [:]
  }
}

extension HummingbirdConnectionData: IntegrationConnectionPayload {
  /// Hummingbird accounts are named, not numbered: the name is the identity
  var userID: String { userName }
  /// What authenticates the account: the name and password HTTP Basic sends on every request. Not
  /// the password alone: the store drops a record with an empty token at launch, and a server that
  /// accepted an empty password at sign-in accepts it on every request after
  var token: String { "\(userName):\(password)" }
  /// Hummingbird has no libraries to choose between. Computed so nothing new is stored
  var selectedLibraryId: String? {
    get { nil }
    set {}
  }
}

extension HummingbirdConnectionData: CustomDebugStringConvertible {
  public var debugDescription: String {
    let passwordDebugDesc = password.isEmpty ? "<empty>" : "<redacted>"
    return "HummingbirdConnectionData(\(url), \(serverName), \(userName), \(passwordDebugDesc))"
  }
}
