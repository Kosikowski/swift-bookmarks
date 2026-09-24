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

    @Test(.timeLimit(.minutes(1)))
    func stopsWaitingWhenTheTimeoutExpires() async throws {
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

        // The abandoned work no longer holds the executor's width, so wait for it directly.
        release.signal()
        while !finished.load(ordering: .relaxed) {
            try await Task.sleep(for: .milliseconds(5))
        }
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
        let gauge = ConcurrencyGauge()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await executor.run {
                        gauge.enter()
                        Thread.sleep(forTimeInterval: 0.01)
                        gauge.leave()
                    }
                }
            }
            try await group.waitForAll()
        }

        let observedPeak = gauge.peak
        #expect((1...2).contains(observedPeak))
    }

    @Test func durationsConvertToDispatchIntervals() {
        #expect(Duration.milliseconds(1500).dispatchInterval == .nanoseconds(1_500_000_000))
        #expect(Duration.zero.dispatchInterval == .nanoseconds(0))
        #expect(Duration.seconds(-1).dispatchInterval == .nanoseconds(0))
    }

    @Test(.timeLimit(.minutes(1)))
    func abandonedWorkDoesNotHoldUpLaterCalls() async throws {
        let executor = BlockingExecutor(label: "test.abandoned", width: 1)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }

        await #expect(throws: BlockingExecutor.TimeoutError.self) {
            try await executor.run(timeout: .milliseconds(20)) { release.wait() }
        }

        #expect(executor.abandonedCount == 1)
        #expect(try await executor.run(timeout: .seconds(10)) { "next" } == "next")
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledRunningWorkIsAbandonedToo() async throws {
        let executor = BlockingExecutor(label: "test.cancelled", width: 1)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }

        let task = Task { try await executor.run { started.signal(); release.wait() } }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { started.wait(); continuation.resume() }
        }
        task.cancel()
        _ = await task.result

        #expect(executor.abandonedCount == 1)
        #expect(try await executor.run { 7 } == 7)
    }

    @Test(.timeLimit(.minutes(1)))
    func theWidthReturnsOnceAbandonedWorkFinishes() async throws {
        let executor = BlockingExecutor(label: "test.recovers", width: 1)
        let release = DispatchSemaphore(value: 0)
        await #expect(throws: BlockingExecutor.TimeoutError.self) {
            try await executor.run(timeout: .milliseconds(20)) { release.wait() }
        }

        release.signal()
        while executor.abandonedCount > 0 {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(executor.abandonedCount == 0)
        #expect(executor.width == 1)
    }

    @Test func workThatFinishesInTimeIsNotAbandoned() async throws {
        let executor = BlockingExecutor(label: "test", width: 1)

        _ = try await executor.run(timeout: .seconds(10)) { 1 }

        #expect(executor.abandonedCount == 0)
    }

    @Test(arguments: [Duration.seconds(Int64.max), .seconds(Int64.max / 1_000_000_000)])
    func timeoutsTooLongToRepresentNeverFire(_ timeout: Duration) {
        #expect(timeout.dispatchInterval == .never)
    }

    @Test func aHugeTimeoutStillReturnsTheResult() async throws {
        let executor = BlockingExecutor(label: "test", width: 1)

        #expect(try await executor.run(timeout: .seconds(Int64.max)) { 3 } == 3)
    }

    @Test func servicesTimeOutByDefault() {
        #expect(BookmarkService().timeout == BookmarkService.defaultTimeout)
        #expect(BookmarkService.defaultTimeout == .seconds(30))
    }

    @Test(.timeLimit(.minutes(1)))
    func finishedCallsDontKeepTheExecutorAlive() async throws {
        var executor: BlockingExecutor? = BlockingExecutor(label: "test.released", width: 1)
        weak let released = executor

        _ = try await executor?.run(timeout: .seconds(3600)) { 1 }
        _ = try await executor?.run(timeout: .seconds(Int64.max)) { 2 }
        executor = nil

        // The finished operations leave the queue shortly after they return.
        while released != nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(released == nil)
    }

    @Test func aTimeoutFiringAfterTheWorkFinishedChangesNothing() async throws {
        let executor = BlockingExecutor(label: "test.late-timeout", width: 1)

        #expect(try await executor.run(timeout: .milliseconds(20)) { 5 } == 5)
        try await Task.sleep(for: .milliseconds(60))

        #expect(executor.abandonedCount == 0)
        #expect(try await executor.run { 6 } == 6)
    }

    @Test(.timeLimit(.minutes(1)))
    func abandonedThreadsAreCapped() async throws {
        let executor = BlockingExecutor(label: "test.capped", width: 1)
        let release = DispatchSemaphore(value: 0)
        let running = Atomic(0)
        let hung = BlockingExecutor.maxAbandoned + 1
        for _ in 0..<hung {
            await #expect(throws: BlockingExecutor.TimeoutError.self) {
                try await executor.run(timeout: .milliseconds(20)) {
                    running.add(1, ordering: .relaxed)
                    release.wait()
                }
            }
        }
        let ran = Atomic(false)

        await #expect(throws: BlockingExecutor.TimeoutError.self) {
            try await executor.run(timeout: .milliseconds(100)) { ran.store(true, ordering: .relaxed) }
        }

        let started = running.load(ordering: .relaxed)
        let queuedRan = ran.load(ordering: .relaxed)
        #expect(executor.abandonedCount == hung)
        #expect(started == hung)
        #expect(!queuedRan)
        for _ in 0..<hung {
            release.signal()
        }
        while executor.abandonedCount > 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try await executor.run(timeout: .seconds(10)) { "free" } == "free")
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationRacingSubmissionSettlesEveryCall() async throws {
        let executor = BlockingExecutor(label: "test.racing-cancel", width: 2)

        for _ in 0..<500 {
            let task = Task { try await executor.run { 1 } }
            task.cancel()
            switch await task.result {
            case .success(let value): #expect(value == 1)
            case .failure(let error): #expect(error is CancellationError)
            }
        }

        while executor.abandonedCount > 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(executor.abandonedCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func abandonedCountSettlesToZeroWhenTimeoutsRaceTheWork() async throws {
        let executor = BlockingExecutor(label: "test.racing-timeouts", width: 4)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<300 {
                group.addTask {
                    _ = try? await executor.run(timeout: .milliseconds(1)) { usleep(1_000) }
                }
            }
        }

        while executor.abandonedCount > 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(executor.abandonedCount == 0)
        #expect(try await executor.run(timeout: .seconds(10)) { 9 } == 9)
    }
}
