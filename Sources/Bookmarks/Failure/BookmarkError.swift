import Foundation

/// An error from a bookmark operation, carrying a classified ``BookmarkFailure``.
///
/// The error carries facts for code and logs, not text for users: map ``failure`` to your
/// app's own wording. ``description`` is for logs.
public struct BookmarkError: Error, Sendable, CustomStringConvertible {
    /// The classified failure.
    public let failure: BookmarkFailure
    /// The item's path as recorded in the bookmark, for display and re-grant prompts.
    public let lastKnownPath: String?
    /// The error reported by the system, when there is one.
    public let underlying: (any Error)?

    /// Creates an error.
    public init(_ failure: BookmarkFailure, lastKnownPath: String? = nil, underlying: (any Error)? = nil) {
        self.failure = failure
        self.lastKnownPath = lastKnownPath
        self.underlying = underlying
    }

    public var description: String {
        var text = "BookmarkError(\(failure)"
        if let lastKnownPath {
            text += ", lastKnownPath: \(lastKnownPath)"
        }
        if let underlying {
            let error = underlying as NSError
            text += ", underlying: \(error.domain) \(error.code)"
        }
        return text + ")"
    }
}
