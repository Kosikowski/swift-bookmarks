import Foundation
import Synchronization

/// Runs blocking work on dedicated threads, away from the main actor and the cooperative pool.
///
/// Bookmark calls can block on volume mounts, network shares and system agents, and can't be
/// cancelled. When a caller is cancelled or its timeout expires, it stops waiting and the work
/// finishes in the background with its result discarded.
public final class BlockingExecutor: Sendable {
    /// Thrown to the waiting caller when the timeout expires first.
    public struct TimeoutError: Error, Sendable, Equatable {
        public let timeout: Duration
    }

    /// A shared executor running up to four operations at a time.
    public static let shared = BlockingExecutor(label: "swift-bookmarks.blocking", width: 4)

    private let queue: OperationQueue

    /// Creates an executor that runs up to `width` operations at a time.
    public init(label: String, width: Int) {
        precondition(width > 0, "BlockingExecutor needs a width of at least 1")
        let queue = OperationQueue()
        queue.name = label
        queue.maxConcurrentOperationCount = width
        queue.qualityOfService = .userInitiated
        self.queue = queue
    }

    /// Runs `work` and waits for its result, its timeout or the caller's cancellation.
    public func run<T: Sendable>(
        timeout: Duration? = nil,
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let resumer = OneShot<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                resumer.install(continuation)
                queue.addOperation {
                    resumer.resume(with: Result { try work() })
                }
                if let timeout {
                    let deadline = DispatchTime.now() + timeout.dispatchInterval
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: deadline) {
                        resumer.resume(with: .failure(TimeoutError(timeout: timeout)))
                    }
                }
            }
        } onCancel: {
            resumer.resume(with: .failure(CancellationError()))
        }
    }

    /// Runs `work` and waits for it to finish, even when the caller is cancelled.
    func perform<T: Sendable, E: Error>(_ work: @escaping @Sendable () throws(E) -> T) async throws(E) -> T {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, E>, Never>) in
            queue.addOperation {
                continuation.resume(returning: Result(catching: work))
            }
        }
        return try result.get()
    }
}

private final class OneShot<T: Sendable>: Sendable {
    private enum State {
        case idle
        case waiting(CheckedContinuation<T, any Error>)
        case pending(Result<T, any Error>)
        case finished
    }

    private let state = Mutex<State>(.idle)

    func install(_ continuation: CheckedContinuation<T, any Error>) {
        let early: Result<T, any Error>? = state.withLock { state in
            switch state {
            case .idle:
                state = .waiting(continuation)
                return nil
            case .pending(let result):
                state = .finished
                return result
            case .waiting, .finished:
                preconditionFailure("Continuation installed twice")
            }
        }
        if let early {
            continuation.resume(with: early)
        }
    }

    func resume(with result: Result<T, any Error>) {
        let continuation: CheckedContinuation<T, any Error>? = state.withLock { state in
            switch state {
            case .idle:
                state = .pending(result)
                return nil
            case .waiting(let continuation):
                state = .finished
                return continuation
            case .pending, .finished:
                return nil
            }
        }
        continuation?.resume(with: result)
    }
}

extension Duration {
    var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        let nanoseconds = seconds * 1_000_000_000 + attoseconds / 1_000_000_000
        return .nanoseconds(Int(clamping: max(nanoseconds, 0)))
    }
}
