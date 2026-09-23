/// Why a bookmark operation failed, classified from the underlying Cocoa or POSIX error.
///
/// A failure encodes as an object whose `code` is the case name, which never changes once
/// released. Decoding an unknown code fails, so readers must be ready for cases added later.
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

extension BookmarkFailure {
    private enum CodingKeys: String, CodingKey {
        case code, volumeName, reason, refusal, domain, errorCode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let code = try container.decode(String.self, forKey: .code)
        switch code {
        case "missing": self = .missing
        case "volumeUnavailable": self = .volumeUnavailable(name: try container.decodeIfPresent(String.self, forKey: .volumeName))
        case "needsRegrant": self = .needsRegrant
        case "denied": self = .denied
        case "corrupt": self = .corrupt
        case "refused": self = .refused(try container.decode(GrantRefusal.self, forKey: .refusal))
        case "unsupported": self = .unsupported(reason: try container.decodeIfPresent(String.self, forKey: .reason) ?? "")
        case "timedOut": self = .timedOut
        case "cancelled": self = .cancelled
        case "other":
            self = .other(
                domain: try container.decodeIfPresent(String.self, forKey: .domain) ?? "",
                code: try container.decodeIfPresent(Int.self, forKey: .errorCode) ?? 0
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .code, in: container, debugDescription: "Unknown failure “\(code)”")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(caseName, forKey: .code)
        switch self {
        case .volumeUnavailable(let name):
            try container.encodeIfPresent(name, forKey: .volumeName)
        case .refused(let refusal):
            try container.encode(refusal, forKey: .refusal)
        case .unsupported(let reason):
            try container.encode(reason, forKey: .reason)
        case .other(let domain, let code):
            try container.encode(domain, forKey: .domain)
            try container.encode(code, forKey: .errorCode)
        case .missing, .needsRegrant, .denied, .corrupt, .timedOut, .cancelled:
            break
        }
    }
}
