/// Whether a bookmark's target can be reached right now, checked without mounting volumes or
/// starting access.
public enum Availability: Sendable, Hashable {
    /// The bookmark resolves.
    case available
    /// The item's volume isn't mounted.
    case volumeUnavailable(name: String?)
    /// The item no longer exists.
    case missing
    /// The bookmark no longer grants access; the user has to pick the item again.
    case needsRegrant
    /// The check didn't give a clear answer.
    case unknown

    init(_ failure: BookmarkFailure) {
        switch failure {
        case .missing:
            self = .missing
        case .volumeUnavailable(let name):
            self = .volumeUnavailable(name: name)
        case .needsRegrant, .denied, .corrupt:
            self = .needsRegrant
        case .unsupported, .timedOut, .cancelled, .other:
            self = .unknown
        }
    }
}
