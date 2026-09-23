public import Foundation

/// Opaque bookmark bytes exactly as produced by Foundation.
///
/// `BookmarkData` never wraps or annotates the bytes, so values read from and written to
/// existing storage formats stay byte-for-byte compatible. It encodes as a single `Data`
/// value, which JSON represents as a base64 string.
public struct BookmarkData: Sendable, Hashable, Codable, CustomStringConvertible {
    /// The raw bookmark bytes.
    public let rawValue: Data

    /// Wraps bookmark bytes produced by Foundation or read from storage.
    public init(_ rawValue: Data) {
        self.rawValue = rawValue
    }

    /// The number of bytes in the bookmark.
    public var count: Int { rawValue.count }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(Data.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { "BookmarkData(\(rawValue.count) bytes)" }
}
