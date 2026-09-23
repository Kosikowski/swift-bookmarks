public import Foundation

/// A stable identifier for a stored bookmark, for apps that have no identifier of their own.
///
/// The identifier never changes when the bookmark is refreshed or re-granted, so it is safe
/// to use as a foreign key in other records.
public struct BookmarkID: Sendable, Hashable, Codable, CustomStringConvertible {
    /// The underlying UUID.
    public let rawValue: UUID

    /// Creates a new random identifier.
    public init() {
        rawValue = UUID()
    }

    /// Wraps an existing UUID.
    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// Parses a UUID string, returning `nil` when it is malformed.
    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        rawValue = uuid
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue.uuidString }
}
