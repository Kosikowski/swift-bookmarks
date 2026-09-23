public import Foundation
import os
import Synchronization

/// Tracks active access per key so each item is started once, however many leases hold it.
///
/// Keys identify items, not URLs: two URLs for the same bookmark share one system start, and a
/// rescan or re-resolve while access is active reuses it instead of starting again. The
/// registry is synchronous and safe to use from any thread.
public final class AccessRegistry<Key: Hashable & Sendable>: Sendable {
    private let engine: any BookmarkEngine
    private let handles = Mutex<[Key: ScopeHandle]>([:])
    private let softLimit: Int
    private let warnedAboutLimit = Atomic<Bool>(false)

    /// Creates a registry.
    ///
    /// - Parameter softLimit: The number of started scopes above which the registry logs a
    ///   warning. The kernel limit is roughly 1,000 to 2,500 per process and can't be queried.
    public init(engine: any BookmarkEngine, softLimit: Int = 500) {
        self.engine = engine
        self.softLimit = softLimit
    }

    /// A new lease on the item's active access, or `nil` when the item isn't currently leased.
    public func activeLease(for key: Key) -> AccessLease? {
        handles.withLock { handles in
            guard let handle = handles[key], !handle.isIdle else { return nil }
            return AccessLease(handle: handle)
        }
    }

    /// A lease on `url` for `key`, reusing the active access for `key` when there is one.
    ///
    /// When `key` is already active, `url` is ignored so the system start isn't repeated.
    ///
    /// - Parameter alreadyStarted: `url` arrived with access started by the system, as panel
    ///   and drop URLs do on macOS. The lease takes ownership of that start.
    public func lease(for key: Key, url: URL, alreadyStarted: Bool = false) -> AccessLease {
        let lease = handles.withLock { handles in
            if let handle = handles[key], !handle.isIdle {
                if alreadyStarted {
                    engine.stopAccessing(url)
                }
                return AccessLease(handle: handle)
            }
            let handle = ScopeHandle(url: url, engine: engine, alreadyStarted: alreadyStarted)
            handle.onIdle { [weak self] idle in
                self?.remove(idle, for: key)
            }
            handles[key] = handle
            return AccessLease(handle: handle)
        }
        warnIfOverLimit()
        return lease
    }

    /// A lease on an active item that contains `url`, or `nil` when none does.
    ///
    /// Leasing a covering directory avoids one system start per file, which exhausts the
    /// kernel's sandbox extension table.
    public func lease(covering url: URL) -> AccessLease? {
        handles.withLock { handles in
            let covering = handles.values
                .filter { !$0.isIdle && PathContainment.contains($0.url, url) }
                .max { PathContainment.normalizedComponents($0.url).count < PathContainment.normalizedComponents($1.url).count }
            return covering.map(AccessLease.init(handle:))
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

    /// The number of items whose system start succeeded and is still held.
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

    private func warnIfOverLimit() {
        let count = startedScopeCount
        if count > softLimit, !warnedAboutLimit.exchange(true, ordering: .relaxed) {
            Log.access.warning("\(count, privacy: .public) security scopes are active; the kernel limit is near")
        }
    }
}
