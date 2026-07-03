//
//  SoundBoothModels.swift
//  BookPlayer
//
//  Copyright © 2026 BookPlayer LLC. All rights reserved.
//

import Foundation

// MARK: - Portability note
//
// Everything in this file and in `SoundBoothAPIClient` is deliberately free of any
// BookPlayer dependency (Foundation only). It's the reverse-engineered SoundBooth
// (soundbooth.app / "Soundbooth Theater") API surface, and is meant to be liftable
// into a standalone SoundBooth app later without change. BookPlayer-specific glue
// (Keychain persistence, @Observable state, IntegrationError mapping, progress
// reporting) lives in `SoundBoothConnectionService` and the view models, not here.

// MARK: - Audio quality

/// SoundBooth serves each resource at two fixed bitrates. The values are the literal
/// `quality` query parameter the API expects (recovered from the web player's
/// `resources/play?id=…&quality=…` call); they are not display strings.
public enum SoundBoothQuality: String, Codable, CaseIterable, Sendable {
  case standard = "96k"
  case high = "192k"
}

// MARK: - Response envelope

/// Every SoundBooth endpoint wraps its payload in `{ success, message, code, data }`.
/// A failed call sets `success = false` and carries a human-ish `message` plus a numeric
/// `code` (e.g. `50230` for an invalid session).
struct SoundBoothEnvelope<Payload: Decodable>: Decodable {
  let success: Bool
  let message: String?
  let code: String?
  let data: Payload?
}

/// Envelope used when a call is made only for its `success`/`message` (no data payload),
/// e.g. requesting a login code.
struct SoundBoothStatusEnvelope: Decodable {
  let success: Bool
  let message: String?
  let code: String?
}

/// Shared shape of the paginated list endpoints (`/functions/u/*/list`). `docs` decodes
/// lossily: a single malformed/incomplete entry (e.g. a refunded purchase whose `element` is
/// `null`) is skipped rather than failing the whole list. Paging fields are kept for a future
/// "load more".
struct SoundBoothPage<Doc: Decodable>: Decodable {
  let docs: [Doc]
  let totalDocs: Int?
  let totalPages: Int?
  let page: Int?
  let hasNextPage: Bool?

  enum CodingKeys: String, CodingKey {
    case docs, totalDocs, totalPages, page, hasNextPage
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let raw = try container.decodeIfPresent([FailableDecodable<Doc>].self, forKey: .docs) ?? []
    self.docs = raw.compactMap { $0.value }
    self.totalDocs = try container.decodeIfPresent(Int.self, forKey: .totalDocs)
    self.totalPages = try container.decodeIfPresent(Int.self, forKey: .totalPages)
    self.page = try container.decodeIfPresent(Int.self, forKey: .page)
    self.hasNextPage = try container.decodeIfPresent(Bool.self, forKey: .hasNextPage)
  }
}

/// Decodes `T` when possible, otherwise captures `nil` instead of throwing — an array of these
/// skips individual malformed elements without failing the whole decode.
struct FailableDecodable<T: Decodable>: Decodable {
  let value: T?
  init(from decoder: Decoder) throws {
    self.value = try? T(from: decoder)
  }
}

// MARK: - Session

/// The authenticated session returned by `code/verify`. `jwt` is the 30-day bearer sent
/// as `Authorization: Token <jwt>` on every user-scoped call; `sessionCookie` is the
/// `iglu.sid` cookie the same response sets (kept as a fallback credential). `userId` is
/// the SoundBooth account's own `_id`.
public struct SoundBoothSession: Codable, Equatable, Sendable {
  public let jwt: String
  public let userId: String
  public let email: String
  public let sessionCookie: String?

  public init(jwt: String, userId: String, email: String, sessionCookie: String? = nil) {
    self.jwt = jwt
    self.userId = userId
    self.email = email
    self.sessionCookie = sessionCookie
  }
}

/// Decoded from `code/verify` `data`. Only the fields the client needs are modelled;
/// the response also carries billing/profile/firebase blocks that are intentionally ignored.
struct SoundBoothVerifyResponse: Decodable {
  let id: String
  let email: String
  let jwt: String

  enum CodingKeys: String, CodingKey {
    case id = "_id"
    case email
    case jwt
  }
}

// MARK: - Library

/// One entry in the owned library (`/functions/u/library-elements/list`). `type` is
/// `"Group"` (a season/bundle) or `"Item"` (a single book or episode). The playable and
/// display data lives on the nested `element`.
public struct SoundBoothLibraryElement: Decodable, Identifiable, Sendable {
  public let id: String
  public let type: String
  public let element: SoundBoothElement

  public var isGroup: Bool { type == "Group" }

  enum CodingKeys: String, CodingKey {
    case id = "_id"
    case type
    case element
  }
}

/// The product an owned entry (or catalog row) points at. `subtype` (`__t`) distinguishes
/// `"book"` from `"episode"` for Items; Groups leave it nil.
public struct SoundBoothElement: Decodable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let subtype: String?
  public let seriesId: String?
  public let displayOptions: SoundBoothDisplayOptions?

  /// Best available cover art for this element, preferring the full image over the thumbnail.
  public var coverURL: URL? {
    displayOptions?.image?.attachment?.bestURL
  }

  enum CodingKeys: String, CodingKey {
    case id = "_id"
    case name
    case subtype = "__t"
    case seriesId
    case displayOptions
  }
}

public struct SoundBoothDisplayOptions: Decodable, Sendable {
  public let image: SoundBoothImage?
}

public struct SoundBoothImage: Decodable, Sendable {
  public let attachment: SoundBoothAttachment?
}

/// A stored asset (cover art). URLs point at SoundBooth's DigitalOcean Spaces bucket.
public struct SoundBoothAttachment: Decodable, Sendable {
  public let url: URL?
  public let thumbURL: URL?

  /// Prefer the full-resolution URL, falling back to the thumbnail.
  public var bestURL: URL? { url ?? thumbURL }

  enum CodingKeys: String, CodingKey {
    case url
    case thumbURL = "thumbUrl"
  }
}

// MARK: - Resources (chapters)

/// One playable chapter of an item (`/functions/playlist/item-resources`). `number` is the
/// running order (0 = opening credits). `duration` is seconds. `lowResSize`/`highResSize`
/// are byte sizes for the 96k/192k renditions — useful for download progress and picking a
/// tier, but the playable URL is resolved separately (see `SoundBoothAPIClient.streamURL`).
public struct SoundBoothItemResource: Decodable, Identifiable, Sendable {
  public let id: String
  public let itemId: String
  public let number: Int
  public let name: String?
  public let duration: Double?
  public let type: String?
  public let lowResSize: Int?
  public let highResSize: Int?

  /// Byte size for the given quality tier, when the API reported it.
  public func size(for quality: SoundBoothQuality) -> Int? {
    switch quality {
    case .standard: return lowResSize
    case .high: return highResSize
    }
  }

  enum CodingKeys: String, CodingKey {
    case id = "_id"
    case itemId
    case number
    case name
    case duration
    case type
    case lowResSize
    case highResSize
  }
}

struct SoundBoothItemResourcesResponse: Decodable {
  let itemResources: [SoundBoothItemResource]

  enum CodingKeys: String, CodingKey { case itemResources }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let raw = try container.decodeIfPresent([FailableDecodable<SoundBoothItemResource>].self, forKey: .itemResources) ?? []
    self.itemResources = raw.compactMap { $0.value }
  }
}

// MARK: - Progress

/// A per-resource playback position (`/functions/user/progresses`). `position` is seconds
/// into `resource`. Used to seed resume points and, in reverse, to push progress back so the
/// user's SoundBooth apps stay in sync.
public struct SoundBoothProgress: Decodable, Identifiable, Sendable {
  public let id: String
  public let item: String
  public let resource: String
  public let position: Double
  public let finished: Bool
  public let speed: String?
  public let group: String?
  public let series: String?

  enum CodingKeys: String, CodingKey {
    case id = "_id"
    case item
    case resource
    case position
    case finished
    case speed
    case group
    case series
  }
}

// MARK: - Errors

/// Errors surfaced by `SoundBoothAPIClient`. Kept BookPlayer-free; the connection service
/// maps these onto `IntegrationError` for the shared UI.
public enum SoundBoothAPIError: Error, Equatable {
  /// The server returned `success: false`. Carries the API's `message` and numeric `code`.
  case api(message: String?, code: String?)
  /// A non-2xx HTTP status.
  case http(status: Int)
  /// The session token was rejected (invalid/expired user session).
  case sessionInvalid
  /// The response body wasn't the shape we expected.
  case decoding
  /// A URL could not be constructed from the configured base + path.
  case malformedURL
}
