import Synchronization

extension Task where Failure == Never {
    /// The task's value, or `CancellationError` as soon as the waiting task is cancelled.
    ///
    /// The task itself keeps running, so other callers waiting for it still get its value.
    var valueUnlessCancelled: Success {
        get async throws {
            let waiter = Waiter<Success>()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiter.install(continuation)
                    Task<Void, Never> {
                        waiter.resume(with: .success(await value))
                    }
                }
            } onCancel: {
                waiter.resume(with: .failure(_Concurrency.CancellationError()))
            }
        }
    }
}

private final class Waiter<Value: Sendable>: Sendable {
    private enum State {
        case idle
        case waiting(CheckedContinuation<Value, any Error>)
        case early(Result<Value, any Error>)
        case done
    }

    private let state = Mutex(State.idle)

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        let early: Result<Value, any Error>? = state.withLock { state in
            if case .early(let result) = state {
                state = .done
                return result
            }
            state = .waiting(continuation)
            return nil
        }
        if let early {
            continuation.resume(with: early)
        }
    }

    func resume(with result: Result<Value, any Error>) {
        let continuation: CheckedContinuation<Value, any Error>? = state.withLock { state in
            switch state {
            case .idle:
                state = .early(result)
                return nil
            case .waiting(let continuation):
                state = .done
                return continuation
            case .early, .done:
                return nil
            }
        }
        continuation?.resume(with: result)
    }
}
