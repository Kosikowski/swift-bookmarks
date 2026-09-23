public import Foundation
import Synchronization

/// Tracks active access per key so each item is started once, however many leases hold it.
///
/// Keys identify items, not URLs: two URLs for the same bookmark share one system start, and a
/// rescan or re-resolve while access is active reuses it instead of starting again. The
/// registry is synchronous and safe to use from any thread. Its scopes count towards its
/// ledger, which covers the whole process.
public final class AccessRegistry<Key: Hashable & Sendable>: Sendable {
    /// The ledger the registry's scopes are counted in.
    public let ledger: ScopeLedger
    private let engine: any BookmarkEngine
    private let handles = Mutex<[Key: ScopeHandle]>([:])

    /// Creates a registry.
    public init(engine: any BookmarkEngine, ledger: ScopeLedger = .shared) {
        self.engine = engine
        self.ledger = ledger
    }

    /// A new lease on the item's active access, or `nil` when the item isn't currently leased.
    public func activeLease(for key: Key) -> AccessLease? {
        // Joining only current holders means a handle that went idle, with its stop issued,
        // is never started again this way.
        handles.withLock { handles in
            handles[key].flatMap { AccessLease(activeHandle: $0) }
        }
    }

    /// A lease on the resolved item for `key`, reusing the active access for `key` when there
    /// is one.
    ///
    /// When `key` is already active, `resolved` isn't used, so the system start isn't repeated.
    /// An unused implicit start taken during resolution moves to the registry, so it's
    /// balanced by the registry's leases.
    public func lease(for key: Key, resolved: ResolvedBookmark) -> AccessLease {
        lease(
            for: key,
            url: resolved.url,
            access: resolved.handle.access,
            isCaseSensitive: resolved.handle.path.isCaseSensitive
        ) {
            resolved.handle.transferUnusedStart()
        }
    }

    func lease(
        for key: Key,
        url: URL,
        access: AccessMode? = .readWrite,
        isCaseSensitive: Bool = true,
        alreadyStarted: () -> Bool = { false }
    ) -> AccessLease {
        handles.withLock { handles in
            if let active = handles[key], !active.isIdle {
                return AccessLease(handle: active)
            }
            let handle = ScopeHandle(
                url: url,
                engine: engine,
                ledger: ledger,
                access: access,
                isCaseSensitive: isCaseSensitive,
                alreadyStarted: alreadyStarted()
            ) { [weak self] idle in
                self?.remove(idle, for: key)
            }
            handles[key] = handle
            return AccessLease(handle: handle)
        }
    }

    /// A lease on the deepest active item that contains `url` and grants `access`, or `nil`
    /// when none does.
    ///
    /// Leasing a covering directory avoids one system start per file, which exhausts the
    /// kernel's sandbox extension table. Items from bookmarks that carry no access, such as
    /// reference bookmarks, never match.
    public func lease(covering url: URL, access: AccessMode = .readWrite) -> AccessLease? {
        let target = NormalizedPath(url)
        return handles.withLock { handles in
            handles.values
                .filter { $0.access.map { $0.satisfies(access) } ?? false && $0.path.contains(target) }
                .sorted { $0.path.components.count > $1.path.components.count }
                .lazy
                .compactMap { AccessLease(activeHandle: $0) }
                .first
        }
    }

    /// Stops tracking `key`. Existing leases keep their access until they end; new leases
    /// resolve again.
    public func detach(_ key: Key) {
        handles.withLock { _ = $0.removeValue(forKey: key) }
    }

    /// Stops all access immediately. Outstanding leases become inactive.
    ///
    /// Call this at termination, after anything that reads files, such as watchers, has stopped.
    public func endAll() {
        let all = handles.withLock { handles in
            defer { handles.removeAll() }
            return Array(handles.values)
        }
        for handle in all {
            handle.invalidate()
        }
    }

    /// The keys with at least one active lease.
    public var activeKeys: Set<Key> {
        handles.withLock { Set($0.filter { !$0.value.isIdle }.keys) }
    }

    /// The number of this registry's items whose system start succeeded and is still held.
    /// ``ScopeLedger/startedScopeCount`` counts the whole process.
    public var startedScopeCount: Int {
        handles.withLock { $0.values.count { $0.holdsStartedScope } }
    }

    private func remove(_ handle: ScopeHandle, for key: Key) {
        handles.withLock { handles in
            if let current = handles[key], current === handle, handle.isIdle {
                handles[key] = nil
            }
        }
    }
}
