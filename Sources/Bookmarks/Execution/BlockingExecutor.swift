import Foundation
import Synchronization

/// Runs blocking work on dedicated threads, away from the main actor and the cooperative pool.
///
/// Bookmark calls can block on volume mounts, network shares and system agents, and can't be
/// cancelled. When a caller is cancelled or its timeout expires, it stops waiting. Work that
/// has started finishes in the background with its result discarded, and no longer counts
/// towards the executor's width, so calls that hang don't hold up the ones after them. Work
/// still queued is skipped.
public final class BlockingExecutor: Sendable {
    /// Thrown to the waiting caller when the timeout expires first.
    public struct TimeoutError: Error, Sendable, Equatable {
        public let timeout: Duration
    }

    /// A shared executor running up to four operations at a time.
    public static let shared = BlockingExecutor(label: "swift-bookmarks.blocking", width: 4)

    /// The most threads an executor adds for abandoned work, so a volume that hangs every
    /// call can't create threads without bound.
    static let maxAbandoned = 32

    /// How many operations run at a time, not counting abandoned ones.
    public let width: Int
    private let queue: OperationQueue
    private let abandoned = Mutex(0)

    /// Creates an executor that runs up to `width` operations at a time.
    public init(label: String, width: Int) {
        precondition(width > 0, "BlockingExecutor needs a width of at least 1")
        let queue = OperationQueue()
        queue.name = label
        queue.maxConcurrentOperationCount = width
        queue.qualityOfService = .userInitiated
        self.queue = queue
        self.width = width
    }

    /// The number of operations still running after their callers stopped waiting.
    public var abandonedCount: Int {
        abandoned.withLock { max($0, 0) }
    }

    /// Runs `work` and waits for its result, its timeout or the caller's cancellation.
    public func run<T: Sendable>(
        timeout: Duration? = nil,
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let call = Call<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                call.install(continuation)
                queue.addOperation { [self] in
                    guard call.begin() else { return }
                    if call.finish(with: Result { try work() }) {
                        adjustAbandoned(by: -1)
                    }
                }
                if let timeout, case let interval = timeout.dispatchInterval, interval != .never {
                    // Weak, so a pending timer doesn't keep a finished call or the executor alive.
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + interval) { [weak self, weak call] in
                        guard let self, let call else { return }
                        giveUp(call, with: TimeoutError(timeout: timeout))
                    }
                }
            }
        } onCancel: { [self] in
            giveUp(call, with: CancellationError())
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

    private func giveUp<T>(_ call: Call<T>, with error: any Error) {
        if call.abandon(with: error) {
            adjustAbandoned(by: 1)
        }
    }

    private func adjustAbandoned(by delta: Int) {
        abandoned.withLock { count in
            // An operation can finish between its caller giving up and the increment, so the
            // count may dip below zero for a moment.
            count += delta
            queue.maxConcurrentOperationCount = width + min(max(count, 0), Self.maxAbandoned)
        }
    }
}

/// One caller waiting for one operation.
private final class Call<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, any Error>?
        var early: Result<T, any Error>?
        var isSettled = false
        var isRunning = false
    }

    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<T, any Error>) {
        let early: Result<T, any Error>? = state.withLock { state in
            precondition(state.continuation == nil, "Continuation installed twice")
            guard state.isSettled else {
                state.continuation = continuation
                return nil
            }
            return state.early.take()
        }
        if let early {
            continuation.resume(with: early)
        }
    }

    /// Marks the work started. Returns `false` when the caller already stopped waiting.
    func begin() -> Bool {
        state.withLock { state in
            guard !state.isSettled else { return false }
            state.isRunning = true
            return true
        }
    }

    /// Delivers the work's result. Returns whether the caller had stopped waiting while the
    /// work ran, so the work was abandoned.
    func finish(with result: Result<T, any Error>) -> Bool {
        let (continuation, wasAbandoned) = state.withLock { state -> (CheckedContinuation<T, any Error>?, Bool) in
            state.isRunning = false
            guard !state.isSettled else { return (nil, true) }
            return (settle(&state, with: result), false)
        }
        continuation?.resume(with: result)
        return wasAbandoned
    }

    /// Stops the caller waiting with `error`. Returns whether this abandons running work.
    func abandon(with error: any Error) -> Bool {
        let result = Result<T, any Error>.failure(error)
        let (continuation, abandonsWork) = state.withLock { state -> (CheckedContinuation<T, any Error>?, Bool) in
            guard !state.isSettled else { return (nil, false) }
            return (settle(&state, with: result), state.isRunning)
        }
        continuation?.resume(with: result)
        return abandonsWork
    }

    private func settle(_ state: inout State, with result: Result<T, any Error>) -> CheckedContinuation<T, any Error>? {
        state.isSettled = true
        guard let continuation = state.continuation.take() else {
            state.early = result
            return nil
        }
        return continuation
    }
}

extension Duration {
    /// The duration as a dispatch interval, `.never` when it's too long to represent.
    var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        guard seconds < Int64.max / 1_000_000_000 else { return .never }
        let nanoseconds = seconds * 1_000_000_000 + attoseconds / 1_000_000_000
        return .nanoseconds(Int(clamping: max(nanoseconds, 0)))
    }
}
