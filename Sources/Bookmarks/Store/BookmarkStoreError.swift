public import Foundation

/// An error from a ``BookmarkStore``.
public enum BookmarkStoreError<Key: Hashable & Sendable>: Error, Sendable {
    /// Creating or resolving the bookmark failed.
    case bookmark(BookmarkError)
    /// The item is already stored under another key.
    case duplicate(of: Key)
    /// No record exists for the key.
    case notFound(Key)
    /// A re-grant picked a different item than the one stored.
    case differentItem(Key)
    /// Loading or saving the records failed.
    case persistence(PersistenceError)
    /// The record kept changing while it was being resolved. Try again.
    case changedDuringAccess(Key)

    /// The bookmark failure, when the error comes from creating or resolving a bookmark.
    public var bookmarkFailure: BookmarkFailure? {
        if case .bookmark(let error) = self { error.failure } else { nil }
    }
}

extension BookmarkStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .bookmark(let error): error.errorDescription
        case .duplicate: "The item has already been added."
        case .notFound: "The item isn't stored."
        case .differentItem: "A different item was chosen."
        case .persistence(let error): error.errorDescription
        case .changedDuringAccess: "The item changed while it was being opened. Try again."
        }
    }
}

/// An error from loading or saving stored records.
public struct PersistenceError: Error, Sendable, CustomStringConvertible {
    /// What went wrong.
    public enum Reason: Sendable, Hashable {
        /// The stored data couldn't be decoded.
        case unreadable
        /// The data was written by a newer version with an unknown schema.
        case unsupportedSchemaVersion(Int)
        /// Reading failed.
        case readFailed
        /// Writing failed.
        case writeFailed
    }

    /// What went wrong.
    public let reason: Reason
    /// The underlying error.
    public let underlying: (any Error & Sendable)?

    /// Creates an error.
    public init(_ reason: Reason, underlying: (any Error & Sendable)? = nil) {
        self.reason = reason
        self.underlying = underlying
    }

    public var description: String {
        "PersistenceError(\(reason)\(underlying.map { ", underlying: \($0)" } ?? ""))"
    }
}

extension PersistenceError: LocalizedError {
    public var errorDescription: String? {
        switch reason {
        case .unreadable: "The saved locations are damaged."
        case .unsupportedSchemaVersion: "The saved locations were written by a newer version of the app."
        case .readFailed: "The saved locations couldn't be read."
        case .writeFailed: "The locations couldn't be saved."
        }
    }
}
