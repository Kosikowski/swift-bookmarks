@testable import Bookmarks
import Foundation
import Synchronization
import Testing

@Suite("BlockingExecutor")
struct BlockingExecutorTests {
    struct Failure: Error, Equatable {}

    @Test func returnsTheResult() async throws {
        let executor = BlockingExecutor(label: "test", width: 1)

        #expect(try await executor.run { 42 } == 42)
    }

    @Test func propagatesErrors() async {
        let executor = BlockingExecutor(label: "test", width: 1)

        await #expect(throws: Failure.self) {
            try await executor.run { () throws -> Int in throw Failure() }
        }
    }

    @Test func runsOnItsOwnQueue() async throws {
        let executor = BlockingExecutor(label: "test.own-queue", width: 1)

        let (name, isMain) = try await executor.run { (OperationQueue.current?.name, Thread.isMainThread) }

        #expect(name == "test.own-queue")
        #expect(!isMain)
    }

    @Test func stopsWaitingWhenTheTimeoutExpires() async throws {
        let executor = BlockingExecutor(label: "test", width: 1)
        let release = DispatchSemaphore(value: 0)
        let finished = Atomic(false)

        await #expect(throws: BlockingExecutor.TimeoutError(timeout: .milliseconds(20))) {
            try await executor.run(timeout: .milliseconds(20)) {
                release.wait()
                finished.store(true, ordering: .relaxed)
            }
        }
        let finishedBeforeRelease = finished.load(ordering: .relaxed)
        #expect(!finishedBeforeRelease)

        release.signal()
        try await executor.run { }
        let finishedAfterRelease = finished.load(ordering: .relaxed)
        #expect(finishedAfterRelease)
    }

    @Test func skipsQueuedWorkWhoseCallerStoppedWaiting() async throws {
        let executor = BlockingExecutor(label: "test", width: 1)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let skippedRan = Atomic(false)
        let blocker = Task {
            try await executor.run {
                started.signal()
                release.wait()
            }
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                started.wait()
                continuation.resume()
            }
        }

        await #expect(throws: BlockingExecutor.TimeoutError(timeout: .milliseconds(20))) {
            try await executor.run(timeout: .milliseconds(20)) {
                skippedRan.store(true, ordering: .relaxed)
            }
        }
        release.signal()
        try await blocker.value
        try await executor.run { }

        let ran = skippedRan.load(ordering: .relaxed)
        #expect(!ran)
    }

    @Test func fastWorkBeatsTheTimeout() async throws {
        let executor = BlockingExecutor(label: "test", width: 1)

        #expect(try await executor.run(timeout: .seconds(10)) { "done" } == "done")
    }

    @Test func stopsWaitingWhenCancelled() async throws {
        let executor = BlockingExecutor(label: "test", width: 1)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        let task = Task {
            try await executor.run {
                started.signal()
                release.wait()
            }
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                started.wait()
                continuation.resume()
            }
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        release.signal()
    }

    @Test func alreadyCancelledCallersSkipTheWork() async throws {
        let executor = BlockingExecutor(label: "test", width: 1)
        let ran = Atomic(false)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await executor.run { ran.store(true, ordering: .relaxed) }
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        try await executor.run {}
        let didRun = ran.load(ordering: .relaxed)
        #expect(!didRun)
    }

    @Test func queuedCallersTimeOutWhileHungWorkHoldsTheQueue() async throws {
        let executor = BlockingExecutor(label: "test", width: 1)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let hung = Task {
            try await executor.run {
                started.signal()
                release.wait()
            }
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                started.wait()
                continuation.resume()
            }
        }

        await #expect(throws: BlockingExecutor.TimeoutError.self) {
            try await executor.run(timeout: .milliseconds(20)) { 1 }
        }

        release.signal()
        try await hung.value
    }

    @Test func performFinishesWorkForCancelledCallers() async throws {
        let executor = BlockingExecutor(label: "test", width: 1)
        let finished = Atomic(false)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await executor.perform { () -> Void in finished.store(true, ordering: .relaxed) }
        }
        await task.value

        let didFinish = finished.load(ordering: .relaxed)
        #expect(didFinish)
    }

    @Test func performPropagatesTypedErrors() async {
        let executor = BlockingExecutor(label: "test", width: 1)

        await #expect(throws: Failure.self) {
            try await executor.perform { () throws(Failure) -> Int in throw Failure() }
        }
    }

    @Test func limitsConcurrencyToItsWidth() async throws {
        let executor = BlockingExecutor(label: "test", width: 2)
        let running = Atomic(0)
        let peak = Atomic(0)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await executor.run {
                        let now = running.add(1, ordering: .relaxed).newValue
                        _ = peak.max(now, ordering: .relaxed)
                        Thread.sleep(forTimeInterval: 0.01)
                        running.subtract(1, ordering: .relaxed)
                    }
                }
            }
            try await group.waitForAll()
        }

        let observedPeak = peak.load(ordering: .relaxed)
        #expect((1...2).contains(observedPeak))
    }

    @Test func durationsConvertToDispatchIntervals() {
        #expect(Duration.milliseconds(1500).dispatchInterval == .nanoseconds(1_500_000_000))
        #expect(Duration.zero.dispatchInterval == .nanoseconds(0))
        #expect(Duration.seconds(-1).dispatchInterval == .nanoseconds(0))
    }
}
