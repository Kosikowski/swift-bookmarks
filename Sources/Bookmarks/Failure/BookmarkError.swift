public import Foundation

/// An error from a bookmark operation, carrying a classified ``BookmarkFailure``.
public struct BookmarkError: Error, Sendable, CustomStringConvertible {
    /// The classified failure.
    public let failure: BookmarkFailure
    /// The item's path as recorded in the bookmark, for display and re-grant prompts.
    public let lastKnownPath: String?
    /// The error reported by the system, when there is one.
    public let underlying: (any Error & Sendable)?

    /// Creates an error.
    public init(_ failure: BookmarkFailure, lastKnownPath: String? = nil, underlying: (any Error & Sendable)? = nil) {
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

extension BookmarkError: LocalizedError {
    public var errorDescription: String? {
        switch failure {
        case .missing:
            "The item no longer exists."
        case .volumeUnavailable(let name):
            if let name {
                "The volume “\(name)” isn't available."
            } else {
                "The item's volume isn't available."
            }
        case .needsRegrant:
            "Access to the item has expired. Choose it again to restore access."
        case .denied:
            "The system denied access to the item."
        case .corrupt:
            "The saved reference to the item is damaged."
        case .refused(let refusal):
            refusal.message
        case .unsupported(let reason):
            reason
        case .timedOut:
            "The item didn't respond in time."
        case .cancelled:
            "The operation was cancelled."
        case .other:
            (underlying as? any LocalizedError)?.errorDescription ?? underlying.map { ($0 as NSError).localizedDescription }
        }
    }
}
