/// Why a bookmark operation failed, classified from the underlying Cocoa or POSIX error.
public enum BookmarkFailure: Sendable, Hashable, Codable {
    /// The item no longer exists on a mounted volume.
    case missing
    /// The volume that holds the item isn't mounted.
    case volumeUnavailable(name: String?)
    /// The bookmark no longer grants access and the user has to pick the item again.
    ///
    /// Caused by bookmarks from another app or signing identity, an OS key reset, or access
    /// revoked in Settings on iOS.
    case needsRegrant
    /// The system refused access to the item.
    case denied
    /// The bookmark bytes are unreadable.
    case corrupt
    /// A validator refused the granted item.
    case refused(GrantRefusal)
    /// The operation isn't possible with this kind, platform or entitlement set.
    case unsupported(reason: String)
    /// The system didn't answer in time. The item may still be reachable later.
    case timedOut
    /// The caller was cancelled before the system answered.
    case cancelled
    /// An error the library doesn't classify.
    case other(domain: String, code: Int)

    /// What a caller should usually do about the failure.
    public enum Recommendation: String, Sendable, Hashable, Codable {
        /// Keep the bookmark and try again later.
        case retryLater
        /// Keep the bookmark and ask the user to pick the item again.
        case regrant
        /// The item is gone; forgetting the bookmark is reasonable.
        case forget
    }

    /// The usual next step for this failure. Stores decide through ``FailureHandling``.
    public var recommendation: Recommendation {
        switch self {
        case .volumeUnavailable, .timedOut, .cancelled, .other:
            .retryLater
        case .needsRegrant, .denied, .corrupt, .refused, .unsupported:
            .regrant
        case .missing:
            .forget
        }
    }

    /// Whether the failure may resolve itself without user action.
    public var isTransient: Bool {
        recommendation == .retryLater
    }
}

extension BookmarkFailure {
    var caseName: String {
        switch self {
        case .missing: "missing"
        case .volumeUnavailable: "volumeUnavailable"
        case .needsRegrant: "needsRegrant"
        case .denied: "denied"
        case .corrupt: "corrupt"
        case .refused: "refused"
        case .unsupported: "unsupported"
        case .timedOut: "timedOut"
        case .cancelled: "cancelled"
        case .other: "other"
        }
    }
}
