@testable import Bookmarks
import Synchronization
import Testing

@Suite("AsyncLock")
struct AsyncLockTests {
    struct Failure: Error {}

    final class Order: Sendable {
        private let labels = Mutex<[String]>([])
        func append(_ label: String) { labels.withLock { $0.append(label) } }
        var values: [String] { labels.withLock { $0 } }
    }

    @Test func serialisesBodiesAcrossSuspensionPoints() async {
        let lock = AsyncLock()
        let inside = Atomic(0)
        let peak = Atomic(0)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await lock.withLock {
                        let now = inside.add(1, ordering: .relaxed).newValue
                        _ = peak.max(now, ordering: .relaxed)
                        await Task.yield()
                        inside.subtract(1, ordering: .relaxed)
                    }
                }
            }
        }

        let observedPeak = peak.load(ordering: .relaxed)
        #expect(observedPeak == 1)
    }

    @Test func releasesTheLockWhenTheBodyThrows() async throws {
        let lock = AsyncLock()

        await #expect(throws: Failure.self) {
            try await lock.withLock { () throws(Failure) in throw Failure() }
        }

        #expect(await lock.withLock { 42 } == 42)
    }

    /// Holds the lock until `release` opens, and returns once it's held.
    func hold(_ lock: AsyncLock, until release: AsyncGate) async -> Task<Void, Never> {
        let held = AsyncGate()
        let holder = Task {
            await lock.withLock {
                held.open()
                await release.wait()
            }
        }
        await held.wait()
        return holder
    }

    /// Starts a task that appends `label` inside the lock, returning once it waits for it.
    func enqueue(_ label: String, on lock: AsyncLock, into order: Order) async -> Task<Bool, Never> {
        let waiting = lock.waiterCount
        let task = Task {
            await lock.withLock {
                order.append(label)
                return Task.isCancelled
            }
        }
        while lock.waiterCount == waiting {
            await Task.yield()
        }
        return task
    }

    @Test(.timeLimit(.minutes(1)))
    func grantsWaitersInArrivalOrder() async {
        let lock = AsyncLock()
        let release = AsyncGate()
        let order = Order()
        let holder = await hold(lock, until: release)

        var waiters: [Task<Bool, Never>] = []
        for label in ["b", "c", "d", "e"] {
            waiters.append(await enqueue(label, on: lock, into: order))
        }
        release.open()
        await holder.value
        for waiter in waiters {
            _ = await waiter.value
        }

        #expect(order.values == ["b", "c", "d", "e"])
        #expect(lock.waiterCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func aCancelledWaiterStillRunsInTurnAndReleases() async {
        let lock = AsyncLock()
        let release = AsyncGate()
        let order = Order()
        let holder = await hold(lock, until: release)
        let cancelled = await enqueue("b", on: lock, into: order)
        let next = await enqueue("c", on: lock, into: order)

        cancelled.cancel()
        release.open()
        await holder.value

        #expect(await cancelled.value)
        #expect(await !next.value)
        #expect(order.values == ["b", "c"])
        #expect(await lock.withLock { 1 } == 1)
    }
}
