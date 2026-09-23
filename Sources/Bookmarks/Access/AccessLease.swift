public import Foundation
import Synchronization

/// A balanced claim on security-scoped access to a resolved item.
///
/// Use ``url`` for all file access while the lease is active, and derive children from it
/// with `appending(path:)` or ``url(forDescendant:)``. A URL rebuilt from a path string
/// doesn't carry the scope. Ending a lease is idempotent, and a lease that is deallocated
/// without being ended ends itself.
public final class AccessLease: Sendable {
    /// The resolved URL that carries the scope.
    public let url: URL
    /// Whether the system start call succeeded.
    ///
    /// `false` is normal outside the App Sandbox and for locations the app can already reach.
    /// It is not an error: only a failing file operation proves missing access.
    public let didStartScope: Bool

    private let handle: ScopeHandle
    private let cycle: UInt64
    private let ended = Atomic<Bool>(false)

    init(handle: ScopeHandle) {
        let acquisition = handle.acquire()
        self.handle = handle
        url = handle.url
        didStartScope = acquisition.didStart
        cycle = acquisition.cycle
    }

    deinit {
        end()
    }

    /// Releases this claim. Access stops when the last lease on the same item ends.
    public func end() {
        guard !ended.exchange(true, ordering: .acquiringAndReleasing) else { return }
        handle.release(cycle: cycle)
    }

    /// Whether the lease still holds access. It doesn't once ended or after ``AccessRegistry/endAll()``.
    public var isActive: Bool {
        !ended.load(ordering: .acquiring) && handle.isCurrent(cycle: cycle)
    }

    /// Maps a URL inside the leased directory to one derived from ``url``, so it keeps the scope.
    ///
    /// Returns `nil` when `descendant` isn't the leased item or inside it.
    public func url(forDescendant descendant: URL) -> URL? {
        guard let components = PathContainment.relativeComponents(of: descendant, in: url) else {
            return nil
        }
        return components.reduce(url) { partial, component in
            partial.appending(path: component, directoryHint: .inferFromPath)
        }
    }
}

enum PathContainment {
    static func relativeComponents(of candidate: URL, in root: URL) -> [String]? {
        let rootComponents = normalizedComponents(root)
        let candidateComponents = normalizedComponents(candidate)
        guard candidateComponents.starts(with: rootComponents) else { return nil }
        return Array(candidateComponents.dropFirst(rootComponents.count))
    }

    static func contains(_ root: URL, _ candidate: URL) -> Bool {
        relativeComponents(of: candidate, in: root) != nil
    }

    static func normalizedComponents(_ url: URL) -> [String] {
        url.standardizedFileURL.path(percentEncoded: false)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }
}
