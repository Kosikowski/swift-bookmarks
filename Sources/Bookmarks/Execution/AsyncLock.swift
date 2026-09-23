import Synchronization

final class AsyncLock: Sendable {
    private struct State {
        var isLocked = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// The number of callers waiting for the lock.
    var waiterCount: Int {
        state.withLock { $0.waiters.count }
    }

    nonisolated(nonsending) func withLock<T, E: Error>(_ body: () async throws(E) -> T) async throws(E) -> T {
        await lock()
        defer { unlock() }
        return try await body()
    }

    private func lock() async {
        await withCheckedContinuation { continuation in
            let acquired = state.withLock { state in
                guard state.isLocked else {
                    state.isLocked = true
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if acquired {
                continuation.resume()
            }
        }
    }

    private func unlock() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.waiters.isEmpty else {
                state.isLocked = false
                return nil
            }
            return state.waiters.removeFirst()
        }
        next?.resume()
    }
}
