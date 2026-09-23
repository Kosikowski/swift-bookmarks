import Foundation
import Synchronization

final class PickerContinuation: Sendable {
    private let continuation: Mutex<CheckedContinuation<[URL], Never>?>

    init(_ continuation: CheckedContinuation<[URL], Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(returning urls: [URL]) {
        continuation.withLock { $0.take() }?.resume(returning: urls)
    }
}
