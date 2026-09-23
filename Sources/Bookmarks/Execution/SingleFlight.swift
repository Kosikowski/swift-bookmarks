import Synchronization

/// Shares one in-flight operation between concurrent callers with the same key.
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
            let flight = Flight(id: state.nextID, task: Task { try await operation() })
            state.flights[key] = flight
            return flight
        }
        defer {
            state.withLock { state in
                if state.flights[key]?.id == flight.id {
                    state.flights[key] = nil
                }
            }
        }
        return try await flight.task.value
    }

    var inFlightCount: Int {
        state.withLock { $0.flights.count }
    }
}
