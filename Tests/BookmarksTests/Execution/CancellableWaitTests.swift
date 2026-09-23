@testable import Bookmarks
import Synchronization
import Testing

@Suite("Task.valueUnlessCancelled")
struct CancellableWaitTests {
    @Test func returnsTheValue() async throws {
        let task = Task { 7 }

        #expect(try await task.valueUnlessCancelled == 7)
    }

    @Test func cancelledWaitersStopWhileTheTaskKeepsRunning() async throws {
        let gate = AsyncGate()
        let work = Task { () -> Int in
            await gate.wait()
            return 5
        }
        await gate.waitForWaiter()

        let waiter = Task { try await work.valueUnlessCancelled }
        waiter.cancel()

        await #expect(throws: CancellationError.self) { try await waiter.value }
        gate.open()
        #expect(try await work.valueUnlessCancelled == 5)
    }

    @Test func alreadyCancelledWaitersDontWait() async {
        let gate = AsyncGate()
        let work = Task { () -> Int in
            await gate.wait()
            return 1
        }

        let waiter = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await work.valueUnlessCancelled
        }

        await #expect(throws: CancellationError.self) { try await waiter.value }
        gate.open()
        _ = await work.value
    }

    @Test(.timeLimit(.minutes(1)))
    func racingCancellationResumesEveryWaiterOnce() async throws {
        let gate = AsyncGate()
        let work = Task { () -> Int in
            await gate.wait()
            return 5
        }
        await gate.waitForWaiter()

        let waiters = (0..<100).map { _ in Task { try await work.valueUnlessCancelled } }
        for (index, waiter) in waiters.enumerated() where index.isMultiple(of: 2) {
            waiter.cancel()
            if index == 50 {
                gate.open()
            }
        }

        for waiter in waiters {
            switch await waiter.result {
            case .success(let value): #expect(value == 5)
            case .failure(let error): #expect(error is CancellationError)
            }
        }
        for waiter in waiters.enumerated().filter({ !$0.offset.isMultiple(of: 2) }).map(\.element) {
            #expect(try await waiter.value == 5)
        }
    }

    @Test func cancellingAfterTheValueArrivedStillReturnsIt() async throws {
        let work = Task { 3 }
        _ = await work.value

        let waiter = Task { try await work.valueUnlessCancelled }
        let value = try await waiter.value
        waiter.cancel()

        #expect(value == 3)
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
