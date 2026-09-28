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
///
/// A record can also be path-only: it holds no bookmark, because none could be made or the app
/// knows the item only by its path, and ``data`` is empty. The store finds such an item by
/// ``lastKnownPath`` alone and makes a bookmark for it as soon as it can; see
/// ``BookmarkStore/add(pathOnly:key:metadata:)``.
public struct BookmarkRecord<Key: Hashable & Sendable, Metadata: Sendable>: Sendable {
    /// The app's stable identifier. Never changes through refreshes and re-grants.
    public let key: Key
    /// The bookmark bytes, or empty bytes for a path-only record.
    public var data: BookmarkData
    /// The kind the bytes were created with. For a path-only record, the kind its bookmark
    /// will be created with.
    public var kind: BookmarkKind
    /// The item's path when it last resolved, for display and re-grant prompts.
    ///
    /// The store sets it whenever the bookmark resolves, to where it resolved: when the item
    /// is added, re-granted or leased, and when statuses are refreshed. The app can set it
    /// with ``BookmarkStore/updateLastKnownPath(_:to:)``, such as after saving the item under
    /// a new name; for a path-only record it's the only location the store has.
    public var lastKnownPath: String
    /// The item's identity when it last resolved, for duplicate detection.
    public var fileIdentity: FileIdentity?
    /// Whether the bookmark resolved the last time it was used.
    public var status: RecordStatus
    /// When the bookmark was first stored.
    public var createdAt: Date
    /// When the bytes were last replaced by a refresh or a re-grant.
    public var refreshedAt: Date?
    /// When the item was last used: added, re-granted, marked used with
    /// ``BookmarkStore/markUsed(_:)``, or leased when ``StorePolicy/recordsLastUse`` is set.
    /// `nil` for records stored before this was recorded.
    public var lastUsedAt: Date?
    /// Whether eviction keeps the record while its item isn't gone, however long it's unused.
    /// See ``EvictionPolicy``.
    public var isPinned: Bool
    /// App-specific data stored with the bookmark.
    public var metadata: Metadata

    /// Creates a record. Pass empty `data` for a path-only record.
    public init(
        key: Key,
        data: BookmarkData,
        kind: BookmarkKind,
        lastKnownPath: String,
        fileIdentity: FileIdentity? = nil,
        status: RecordStatus = .unknown,
        createdAt: Date,
        refreshedAt: Date? = nil,
        lastUsedAt: Date? = nil,
        isPinned: Bool = false,
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
        self.lastUsedAt = lastUsedAt
        self.isPinned = isPinned
        self.metadata = metadata
    }

    /// The item's name, from its last known path.
    public var displayName: String {
        URL(filePath: lastKnownPath).lastPathComponent
    }

    /// Whether the record holds a bookmark. `false` for a path-only record.
    public var hasBookmark: Bool {
        !data.isEmpty
    }

    /// Whether the item was last seen in a Trash: a `.Trash` folder, as in the home folder and
    /// iCloud Drive, or a volume's `.Trashes`.
    public var isInTrash: Bool {
        NormalizedPath(lastKnownPath).isInTrash
    }

    /// Whether the item is gone as far as the store knows: it no longer exists, its bookmark
    /// records nothing, or it was last seen in a Trash.
    ///
    /// A volume that isn't mounted, a bookmark that needs a re-grant and a timeout may pass,
    /// so they don't count. The status is what the store learned when it last resolved the
    /// item; ``BookmarkStore/refreshStatuses(includingAvailable:)`` brings it up to date.
    public var isGone: Bool {
        switch status.failure {
        case .missing?, .corrupt?: true
        default: isInTrash
        }
    }
}

extension BookmarkRecord: Codable where Key: Codable, Metadata: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case key, data, kind, lastKnownPath, fileIdentity, status, createdAt, refreshedAt, lastUsedAt, isPinned, metadata
    }

    /// The names of the fields this version reads and writes.
    static var fieldNames: Set<String> {
        Set(CodingKeys.allCases.map(\.stringValue))
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(Key.self, forKey: .key)
        // A path-only record has no bytes.
        data = try container.decodeIfPresent(BookmarkData.self, forKey: .data) ?? BookmarkData(Data())
        kind = try container.decode(BookmarkKind.self, forKey: .kind)
        lastKnownPath = try container.decode(String.self, forKey: .lastKnownPath)
        // Identities without a volume UUID, as earlier versions wrote them, aren't unique.
        fileIdentity = (try? container.decodeIfPresent(FileIdentity.self, forKey: .fileIdentity)) ?? nil
        status = try container.decodeIfPresent(RecordStatus.self, forKey: .status) ?? .unknown
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        refreshedAt = try container.decodeIfPresent(Date.self, forKey: .refreshedAt)
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        metadata = try container.decode(Metadata.self, forKey: .metadata)
    }

    /// Encodes the record. A path-only record is written without `data`, so a version that
    /// predates path-only records keeps it unread and unchanged rather than resolving empty
    /// bytes. `lastUsedAt` and `isPinned` are written only when set.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        if hasBookmark {
            try container.encode(data, forKey: .data)
        }
        try container.encode(kind, forKey: .kind)
        try container.encode(lastKnownPath, forKey: .lastKnownPath)
        try container.encodeIfPresent(fileIdentity, forKey: .fileIdentity)
        try container.encode(status, forKey: .status)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(refreshedAt, forKey: .refreshedAt)
        try container.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
        if isPinned {
            try container.encode(isPinned, forKey: .isPinned)
        }
        try container.encode(metadata, forKey: .metadata)
    }
}

extension BookmarkRecord: Equatable where Metadata: Equatable {}
extension BookmarkRecord: Hashable where Metadata: Hashable {}
