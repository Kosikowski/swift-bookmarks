@testable import Bookmarks
import Synchronization
import Testing

@Suite("SingleFlight")
struct SingleFlightTests {
    struct Failure: Error {}

    @Test func concurrentCallersShareOneRun() async throws {
        let flight = SingleFlight<String, Int>()
        let runs = Atomic(0)
        let gate = AsyncGate()

        async let first = flight.run("key") {
            runs.add(1, ordering: .relaxed)
            await gate.wait()
            return 7
        }
        await gate.waitForWaiter()
        async let second = flight.run("key") {
            runs.add(1, ordering: .relaxed)
            return 99
        }
        async let third = flight.run("key") {
            runs.add(1, ordering: .relaxed)
            return 99
        }
        try await Task.sleep(for: .milliseconds(20))
        gate.open()

        let results = try await [first, second, third]
        let runCount = runs.load(ordering: .relaxed)
        #expect(results == [7, 7, 7])
        #expect(runCount == 1)
    }

    @Test func differentKeysRunIndependently() async throws {
        let flight = SingleFlight<String, String>()

        async let a = flight.run("a") { "A" }
        async let b = flight.run("b") { "B" }

        #expect(try await [a, b] == ["A", "B"])
    }

    @Test func runsAgainAfterCompletion() async throws {
        let flight = SingleFlight<String, Int>()
        let runs = Atomic(0)

        for _ in 0..<3 {
            _ = try await flight.run("key") { runs.add(1, ordering: .relaxed).newValue }
        }

        let runCount = runs.load(ordering: .relaxed)
        #expect(runCount == 3)
        #expect(flight.inFlightCount == 0)
    }

    @Test func errorsReachEveryWaiter() async {
        let flight = SingleFlight<String, Int>()
        let gate = AsyncGate()

        let first = Task {
            try await flight.run("key") {
                await gate.wait()
                throw Failure()
            }
        }
        await gate.waitForWaiter()
        let second = Task { try await flight.run("key") { 1 } }
        try? await Task.sleep(for: .milliseconds(20))
        gate.open()

        await #expect(throws: Failure.self) { try await first.value }
        await #expect(throws: Failure.self) { try await second.value }
        #expect(flight.inFlightCount == 0)
    }
}

final class AsyncGate: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>], watchers: [CheckedContinuation<Void, Never>])>((false, [], []))

    func wait() async {
        await withCheckedContinuation { continuation in
            let (resumeNow, watchers) = state.withLock { state -> (Bool, [CheckedContinuation<Void, Never>]) in
                if state.open { return (true, []) }
                state.waiters.append(continuation)
                defer { state.watchers.removeAll() }
                return (false, state.watchers)
            }
            watchers.forEach { $0.resume() }
            if resumeNow { continuation.resume() }
        }
    }

    func waitForWaiter() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Bool in
                if !state.waiters.isEmpty || state.open { return true }
                state.watchers.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }
}
