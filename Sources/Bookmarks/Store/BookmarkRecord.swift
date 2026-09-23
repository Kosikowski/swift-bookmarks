public import Foundation

/// Metadata for stores that don't keep any.
public struct NoMetadata: Sendable, Hashable, Codable {
    /// Creates empty metadata.
    public init() {}
}

/// Whether a stored bookmark resolved the last time it was used.
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

/// A stored bookmark with its key, kind, what the store knows about it, and app metadata.
public struct BookmarkRecord<Key: Hashable & Sendable & Codable, Metadata: Sendable & Codable>: Sendable, Codable {
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

extension BookmarkRecord: Equatable where Metadata: Equatable {}
extension BookmarkRecord: Hashable where Metadata: Hashable {}
