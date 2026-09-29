import Foundation
import Synchronization

final class ScopeHandle: Sendable {
    struct Acquisition {
        let didStart: Bool
        let cycle: UInt64
    }

    private struct State {
        var holders = 0
        var didStart = false
        var cycle: UInt64 = 0
        var adoptsSystemStart: Bool
    }

    let url: URL
    /// The URL's path, comparing by the rules of its volume.
    let path: NormalizedPath
    /// The access the scope grants, or `nil` for bookmarks that carry none.
    let access: AccessMode?
    private let engine: any BookmarkEngine
    private let ledger: ScopeLedger?
    private let startsAccess: Bool
    private let state: Mutex<State>
    private let onIdle: (@Sendable (ScopeHandle) -> Void)?

    /// - Parameters:
    ///   - alreadyStarted: The URL arrived with access already started by the system, so the
    ///     first acquisition takes ownership of that start instead of starting again.
    ///   - startsAccess: Whether acquiring starts access. `false` for locations the app
    ///     reaches without a scope.
    init(
        url: URL,
        engine: any BookmarkEngine,
        ledger: ScopeLedger? = nil,
        access: AccessMode? = .readWrite,
        isCaseSensitive: Bool = true,
        alreadyStarted: Bool = false,
        startsAccess: Bool = true,
        onIdle: (@Sendable (ScopeHandle) -> Void)? = nil
    ) {
        self.url = url
        self.ledger = ledger
        self.access = access
        self.startsAccess = startsAccess
        path = NormalizedPath(url, isCaseSensitive: isCaseSensitive)
        self.engine = engine
        self.onIdle = onIdle
        state = Mutex(State(adoptsSystemStart: alreadyStarted))
    }

    deinit {
        state.withLock { state in
            if state.adoptsSystemStart {
                engine.stopAccessing(url)
            }
        }
    }

    /// Gives up a system start that no lease has taken over, so another handle can own it.
    func transferUnusedStart() -> Bool {
        state.withLock { state in
            guard state.holders == 0, state.adoptsSystemStart else { return false }
            state.adoptsSystemStart = false
            return true
        }
    }

    func acquire() -> Acquisition {
        state.withLock { state in
            if state.holders == 0 {
                if state.adoptsSystemStart {
                    state.adoptsSystemStart = false
                    state.didStart = true
                } else {
                    state.didStart = startsAccess && engine.startAccessing(url)
                }
                ledger?.activated(self, started: state.didStart)
            }
            state.holders += 1
            return Acquisition(didStart: state.didStart, cycle: state.cycle)
        }
    }

    /// Joins the current holders, or returns `nil` when there are none, so an idle handle is
    /// never started again this way.
    func acquireIfActive() -> Acquisition? {
        state.withLock { state in
            guard state.holders > 0 else { return nil }
            state.holders += 1
            return Acquisition(didStart: state.didStart, cycle: state.cycle)
        }
    }

    func release(cycle: UInt64) {
        let becameIdle = state.withLock { state -> Bool in
            guard state.cycle == cycle, state.holders > 0 else { return false }
            state.holders -= 1
            guard state.holders == 0 else { return false }
            ledger?.deactivated(self)
            stopIfStarted(&state)
            return true
        }
        if becameIdle {
            onIdle?(self)
        }
    }

    /// Stops access regardless of holders. Outstanding leases become inactive.
    func invalidate() {
        state.withLock { state in
            if state.holders > 0 {
                ledger?.deactivated(self)
                stopIfStarted(&state)
            } else if state.adoptsSystemStart {
                state.adoptsSystemStart = false
                engine.stopAccessing(url)
            }
            state.holders = 0
            state.cycle += 1
        }
    }

    func isCurrent(cycle: UInt64) -> Bool {
        state.withLock { $0.cycle == cycle && $0.holders > 0 }
    }

    var isIdle: Bool {
        state.withLock { $0.holders == 0 }
    }

    var holdsStartedScope: Bool {
        state.withLock { $0.holders > 0 && $0.didStart }
    }

    private func stopIfStarted(_ state: inout State) {
        if state.didStart {
            engine.stopAccessing(url)
        }
        state.didStart = false
        state.cycle += 1
    }
}
