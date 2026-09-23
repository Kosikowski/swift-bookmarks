import Synchronization

/// Shares one in-flight operation between concurrent callers with the same key.
///
/// A cancelled caller stops waiting immediately; the shared operation keeps running for the
/// other callers.
final class SingleFlight<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private struct Flight {
        let id: UInt64
        let task: Task<Value, any Error>
    }

    private struct State {
        var nextID: UInt64 = 0
        var flights: [Key: Flight] = [:]
    }

    private let state = Mutex(State())

    func run(_ key: Key, _ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let flight = state.withLock { state in
            if let flight = state.flights[key] {
                return flight
            }
            state.nextID += 1
            let id = state.nextID
            let task = Task { [weak self] in
                defer { self?.finish(key, id: id) }
                return try await operation()
            }
            let flight = Flight(id: id, task: task)
            state.flights[key] = flight
            return flight
        }
        return try await Self.wait(for: flight.task)
    }

    var inFlightCount: Int {
        state.withLock { $0.flights.count }
    }

    private func finish(_ key: Key, id: UInt64) {
        state.withLock { state in
            if state.flights[key]?.id == id {
                state.flights[key] = nil
            }
        }
    }

    private static func wait(for task: Task<Value, any Error>) async throws -> Value {
        let waiter = Waiter<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                Task {
                    waiter.resume(with: await task.result)
                }
            }
        } onCancel: {
            waiter.resume(with: .failure(CancellationError()))
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
