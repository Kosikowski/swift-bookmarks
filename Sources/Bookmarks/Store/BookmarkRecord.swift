public import Foundation

/// Metadata for stores that don't keep any.
public struct NoMetadata: Sendable, Hashable, Codable {
    /// Creates empty metadata.
    public init() {}
}

/// Whether a stored bookmark resolved the last time it was used.
///
/// A status is only a hint, so decoding never fails: a state or failure written by a newer
/// version decodes as ``unknown``.
public enum RecordStatus: Sendable, Hashable, Codable {
    /// Not resolved since the store loaded it.
    case unknown
    /// Resolved successfully.
    case available
    /// Failed to resolve.
    case unavailable(BookmarkFailure, since: Date)

    /// The failure, when the record is unavailable.
    public var failure: BookmarkFailure? {
        if case .unavailable(let failure, _) = self { failure } else { nil }
    }
}

extension RecordStatus {
    private enum CodingKeys: String, CodingKey {
        case state, failure, since
    }

    public init(from decoder: any Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        switch try? container?.decode(String.self, forKey: .state) {
        case "available":
            self = .available
        case "unavailable":
            if let failure = try? container?.decode(BookmarkFailure.self, forKey: .failure),
               let since = try? container?.decode(Date.self, forKey: .since) {
                self = .unavailable(failure, since: since)
            } else {
                self = .unknown
            }
        default:
            self = .unknown
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unknown:
            try container.encode("unknown", forKey: .state)
        case .available:
            try container.encode("available", forKey: .state)
        case .unavailable(let failure, let since):
            try container.encode("unavailable", forKey: .state)
            try container.encode(failure, forKey: .failure)
            try container.encode(since, forKey: .since)
        }
    }
}

/// A stored bookmark with its key, kind, what the store knows about it, and app metadata.
public struct BookmarkRecord<Key: Hashable & Sendable, Metadata: Sendable>: Sendable {
    /// The app's stable identifier. Never changes through refreshes and re-grants.
    public let key: Key
    /// The bookmark bytes.
    public var data: BookmarkData
    /// The kind the bytes were created with.
    public var kind: BookmarkKind
    /// The item's path when it last resolved, for display and re-grant prompts.
    public var lastKnownPath: String
    /// The item's identity when it last resolved, for duplicate detection.
    public var fileIdentity: FileIdentity?
    /// Whether the bookmark resolved the last time it was used.
    public var status: RecordStatus
    /// When the bookmark was first stored.
    public var createdAt: Date
    /// When the bytes were last replaced by a refresh or a re-grant.
    public var refreshedAt: Date?
    /// App-specific data stored with the bookmark.
    public var metadata: Metadata

    /// Creates a record.
    public init(
        key: Key,
        data: BookmarkData,
        kind: BookmarkKind,
        lastKnownPath: String,
        fileIdentity: FileIdentity? = nil,
        status: RecordStatus = .unknown,
        createdAt: Date,
        refreshedAt: Date? = nil,
        metadata: Metadata
    ) {
        self.key = key
        self.data = data
        self.kind = kind
        self.lastKnownPath = lastKnownPath
        self.fileIdentity = fileIdentity
        self.status = status
        self.createdAt = createdAt
        self.refreshedAt = refreshedAt
        self.metadata = metadata
    }

    /// The item's name, from its last known path.
    public var displayName: String {
        URL(filePath: lastKnownPath).lastPathComponent
    }
}

extension BookmarkRecord: Codable where Key: Codable, Metadata: Codable {
    private enum CodingKeys: String, CodingKey {
        case key, data, kind, lastKnownPath, fileIdentity, status, createdAt, refreshedAt, metadata
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(Key.self, forKey: .key)
        data = try container.decode(BookmarkData.self, forKey: .data)
        kind = try container.decode(BookmarkKind.self, forKey: .kind)
        lastKnownPath = try container.decode(String.self, forKey: .lastKnownPath)
        fileIdentity = try container.decodeIfPresent(FileIdentity.self, forKey: .fileIdentity)
        status = try container.decodeIfPresent(RecordStatus.self, forKey: .status) ?? .unknown
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        refreshedAt = try container.decodeIfPresent(Date.self, forKey: .refreshedAt)
        metadata = try container.decode(Metadata.self, forKey: .metadata)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(data, forKey: .data)
        try container.encode(kind, forKey: .kind)
        try container.encode(lastKnownPath, forKey: .lastKnownPath)
        try container.encodeIfPresent(fileIdentity, forKey: .fileIdentity)
        try container.encode(status, forKey: .status)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(refreshedAt, forKey: .refreshedAt)
        try container.encode(metadata, forKey: .metadata)
    }
}

extension BookmarkRecord: Equatable where Metadata: Equatable {}
extension BookmarkRecord: Hashable where Metadata: Hashable {}
