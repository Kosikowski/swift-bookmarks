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
    private let engine: any BookmarkEngine
    private let state: Mutex<State>
    private let idleHandler = Mutex<(@Sendable (ScopeHandle) -> Void)?>(nil)

    /// - Parameter alreadyStarted: The URL arrived with access already started by the system,
    ///   so the first acquisition takes ownership of that start instead of starting again.
    init(url: URL, engine: any BookmarkEngine, alreadyStarted: Bool = false) {
        self.url = url
        self.engine = engine
        state = Mutex(State(adoptsSystemStart: alreadyStarted))
    }

    deinit {
        state.withLock { state in
            if state.adoptsSystemStart {
                engine.stopAccessing(url)
            }
        }
    }

    func onIdle(_ handler: @escaping @Sendable (ScopeHandle) -> Void) {
        idleHandler.withLock { $0 = handler }
    }

    func acquire() -> Acquisition {
        state.withLock { state in
            if state.holders == 0 {
                if state.adoptsSystemStart {
                    state.adoptsSystemStart = false
                    state.didStart = true
                } else {
                    state.didStart = engine.startAccessing(url)
                }
            }
            state.holders += 1
            return Acquisition(didStart: state.didStart, cycle: state.cycle)
        }
    }

    func release(cycle: UInt64) {
        let becameIdle = state.withLock { state -> Bool in
            guard state.cycle == cycle, state.holders > 0 else { return false }
            state.holders -= 1
            guard state.holders == 0 else { return false }
            stopIfStarted(&state)
            return true
        }
        if becameIdle {
            idleHandler.withLock { $0 }?(self)
        }
    }

    /// Stops access regardless of holders. Outstanding leases become inactive.
    func invalidate() {
        state.withLock { state in
            if state.holders > 0 {
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
