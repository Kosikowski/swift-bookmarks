import Foundation

struct FailureClassifier: Sendable {
    let isVolumeMounted: @Sendable (String) -> Bool
    /// Whether an item exists at a path, `nil` when that can't be told.
    let itemExists: @Sendable (String) -> Bool?

    init(isVolumeMounted: @escaping @Sendable (String) -> Bool, itemExists: @escaping @Sendable (String) -> Bool? = { _ in nil }) {
        self.isVolumeMounted = isVolumeMounted
        self.itemExists = itemExists
    }

    func classify(_ error: any Error, recorded: RecordedValues?) -> BookmarkFailure {
        let error = error as NSError
        switch (error.domain, error.code) {
        case (NSCocoaErrorDomain, NSFileNoSuchFileError),
             (NSCocoaErrorDomain, NSFileReadNoSuchFileError):
            return missingOrUnmounted(recorded)
        case (NSCocoaErrorDomain, NSFileReadCorruptFileError):
            guard let recorded else { return .corrupt }
            // Inside the App Sandbox, a security-scoped bookmark to an item that was deleted
            // fails with this code too, not with NSFileNoSuchFileError. Nothing at the recorded
            // path tells a deleted item from a scope key that doesn't match.
            if let path = recorded.path, itemExists(path) == false {
                return missingOrUnmounted(recorded)
            }
            return .needsRegrant
        case (NSCocoaErrorDomain, NSFileReadNoPermissionError),
             (NSCocoaErrorDomain, NSFileWriteNoPermissionError):
            return .denied
        case (NSCocoaErrorDomain, NSFileReadUnknownError):
            // Foundation's generic read error: the sandbox's refusal, unless it wraps a more
            // specific error, such as a network volume's timeout.
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                let nested = classify(underlying, recorded: recorded)
                if case .other = nested {
                    return .denied
                }
                return nested
            }
            return .denied
        case (NSPOSIXErrorDomain, Int(EPERM)), (NSPOSIXErrorDomain, Int(EACCES)):
            return .denied
        case (NSPOSIXErrorDomain, Int(ENOENT)):
            return missingOrUnmounted(recorded)
        case (NSPOSIXErrorDomain, Int(ETIMEDOUT)):
            return .timedOut
        default:
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                let nested = classify(underlying, recorded: recorded)
                if case .other = nested {
                    return .other(domain: error.domain, code: error.code)
                }
                return nested
            }
            return .other(domain: error.domain, code: error.code)
        }
    }

    private func missingOrUnmounted(_ recorded: RecordedValues?) -> BookmarkFailure {
        guard let recorded, !recorded.isOnBootVolume, let volumePath = recorded.volumePath else {
            return .missing
        }
        return isVolumeMounted(volumePath) ? .missing : .volumeUnavailable(name: recorded.volumeName)
    }
}
