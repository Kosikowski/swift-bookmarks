import Synchronization

/// Counts how many bodies run at once and the most that ever did.
///
/// A class rather than local atomics, so child tasks can share it without capturing a
/// noncopyable value.
final class ConcurrencyGauge: Sendable {
    private let running = Atomic(0)
    private let highWater = Atomic(0)

    func enter() {
        let now = running.add(1, ordering: .relaxed).newValue
        _ = highWater.max(now, ordering: .relaxed)
    }

    func leave() {
        running.subtract(1, ordering: .relaxed)
    }

    var peak: Int { highWater.load(ordering: .relaxed) }
}
