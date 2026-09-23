/// Controls how a bookmark is resolved.
///
/// The defaults never mount volumes and never show UI, so resolution can't block on a
/// network share or a credentials prompt.
public struct ResolutionPolicy: Sendable, Hashable, Codable {
    /// Whether resolution may mount the volume that holds the item.
    public enum Mounting: String, Sendable, Hashable, Codable {
        /// Fail with ``BookmarkFailure/volumeUnavailable(name:)`` instead of mounting.
        case never
        /// Mount the volume if needed. This can block for a long time.
        case allowed
    }

    /// Whether resolution may mount volumes.
    public var mounting: Mounting
    /// Whether resolution may show UI, such as a network credentials prompt.
    public var allowsUI: Bool
    /// Whether resolving an ``BookmarkKind/implicit`` bookmark starts access immediately.
    ///
    /// Leave this off so access is started by an ``AccessLease``, which balances it.
    public var startsImplicitAccess: Bool

    /// Creates a policy.
    public init(mounting: Mounting = .never, allowsUI: Bool = false, startsImplicitAccess: Bool = false) {
        self.mounting = mounting
        self.allowsUI = allowsUI
        self.startsImplicitAccess = startsImplicitAccess
    }

    /// Never mounts, never shows UI, never starts access implicitly.
    public static let `default` = ResolutionPolicy()

    /// Allows mounting volumes, still without UI.
    public static let allowingMount = ResolutionPolicy(mounting: .allowed)
}
