@testable import Bookmarks
import Synchronization
import Testing

@Suite("AsyncLock")
struct AsyncLockTests {
    struct Failure: Error {}

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
}
