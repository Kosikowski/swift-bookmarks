public import Bookmarks
public import Foundation
import Synchronization

/// An in-memory ``BookmarkEngine`` that simulates a file system and the sandbox rules that
/// matter for bookmarks.
///
/// Items have identities that follow moves; atomic replaces change the identity at a path;
/// volumes can be unmounted. In a sandboxed environment, creating a bookmark requires
/// access to the item, as the real system does, and every start and stop is counted per path
/// so tests can assert that access is balanced.
public final class FakeBookmarkEngine: FileSystemEngine {
    public let environment: SandboxEnvironment

    private let state = Mutex(FakeFileSystem())

    /// Creates an engine with an empty file system and a mounted boot volume.
    public init(environment: SandboxEnvironment = SandboxEnvironment(platform: .macOS, isSandboxed: true)) {
        self.environment = environment
    }

    // MARK: - File system

    /// Adds an item, creating missing parent directories.
    @discardableResult
    public func addItem(at path: String, isDirectory: Bool = true) -> URL {
        state.withLock { $0.addItem(at: path, isDirectory: isDirectory) }
        return URL(filePath: path, directoryHint: isDirectory ? .isDirectory : .notDirectory)
    }

    /// Adds a symbolic link at `path` that points to `target`.
    public func addSymbolicLink(at path: String, pointingTo target: String) {
        state.withLock { $0.addSymbolicLink(at: path, to: target) }
    }

    /// Removes an item and everything inside it.
    public func removeItem(at path: String) {
        state.withLock { $0.removeItem(at: path) }
    }

    /// Moves an item and everything inside it. Identities follow a move within a volume; a
    /// move to another volume copies and deletes, as the system does, so they change.
    public func moveItem(from source: String, to destination: String) {
        state.withLock { $0.moveItem(from: source, to: destination) }
    }

    /// Replaces the item at `path` with a new one, as an atomic save does. The identity changes.
    public func replaceItem(at path: String) {
        state.withLock { $0.replaceItem(at: path) }
    }

    /// Mounts a volume at `path`, such as `/Volumes/External`.
    public func mountVolume(at path: String) {
        state.withLock { _ = $0.mountedVolumes.insert(path) }
    }

    /// Unmounts the volume at `path`. Items on it become unreachable until it's mounted again.
    public func unmountVolume(at path: String) {
        state.withLock { _ = $0.mountedVolumes.remove(path) }
    }

    /// Makes the volume at `path` ignore case in names, as most Mac volumes do.
    ///
    /// Only the library's path comparisons change: the fake still looks items up by their
    /// exact path. Volumes are case-sensitive until this is called.
    public func makeCaseInsensitive(volumeAt path: String = "/") {
        state.withLock { _ = $0.caseInsensitiveVolumes.insert(path) }
    }

    /// Makes the volume at `path` report no UUID, as some network and FAT volumes do, so its
    /// items have no file identity.
    public func removeVolumeUUID(ofVolumeAt path: String) {
        state.withLock { _ = $0.volumesWithoutUUID.insert(path) }
    }

    /// Marks `path` and everything inside it as reachable without a grant, like the app's container.
    public func makeAccessibleWithoutGrant(_ path: String) {
        state.withLock { _ = $0.freelyAccessible.insert(path) }
    }

    /// Whether an item exists at `path` and its volume is mounted.
    public func containsItem(at path: String) -> Bool {
        state.withLock { $0.item(at: path) != nil }
    }

    // MARK: - Grants

    /// A grant as the system hands it over, recording any access the system starts for it.
    ///
    /// A grant released without being adopted or relinquished stops that access through this
    /// engine, as the library's grants do.
    public func grant(_ path: String, origin: Grant.Origin) -> Grant {
        let url = URL(filePath: path)
        let grant = Grant(url: url, origin: origin, platform: environment.platform) { [self] url in
            stopAccessing(url)
        }
        state.withLock { state in
            state.issued.insert(path)
            if grant.isStartedBySystem {
                state.recordStart(path)
            }
        }
        return grant
    }

    // MARK: - Scripting

    /// Makes resolutions of bookmarks to `path` fail with `error`, `times` times or forever.
    public func failResolution(of path: String, with error: NSError, times: Int? = nil) {
        state.withLock { $0.resolutionFailures[path] = ScriptedFailure(error: error, remaining: times) }
    }

    /// Makes creating bookmarks to `path` fail with `error`, `times` times or forever.
    public func failCreation(of path: String, with error: NSError, times: Int? = nil) {
        state.withLock { $0.creationFailures[path] = ScriptedFailure(error: error, remaining: times) }
    }

    /// Makes the next resolution of a bookmark to `path` report stale bytes, `times` times.
    public func reportStale(_ path: String, times: Int = 1) {
        state.withLock { $0.forcedStale[path, default: 0] += times }
    }

    /// Makes `startAccessing` return `false` for `path`.
    public func refuseAccess(to path: String) {
        state.withLock { _ = $0.refused.insert(path) }
    }

    /// Blocks the next resolution of a bookmark to `path` until the returned gate opens.
    public func holdResolution(of path: String) -> Gate {
        let gate = Gate()
        state.withLock { $0.gates[path, default: []].append(gate) }
        return gate
    }

    /// Blocks the next creation of a bookmark to `path` until the returned gate opens.
    public func holdCreation(of path: String) -> Gate {
        let gate = Gate()
        state.withLock { $0.creationGates[path, default: []].append(gate) }
        return gate
    }

    // MARK: - Observation

    /// Counts of engine calls.
    public var calls: Calls {
        state.withLock { $0.calls }
    }

    /// Every creation request, in order.
    public var creationRequests: [CreationRequest] {
        state.withLock { $0.creationRequests }
    }

    /// Every resolution request, in order.
    public var resolutionRequests: [ResolutionRequest] {
        state.withLock { $0.resolutionRequests }
    }

    /// Outstanding starts per path. Empty when access is balanced.
    public var outstandingAccess: [String: Int] {
        state.withLock { $0.outstanding.filter { $0.value != 0 } }
    }

    /// Stops that had no start to balance.
    public var unbalancedStops: [String] {
        state.withLock { $0.unbalancedStops }
    }

    /// Starts on URLs that were neither granted nor resolved by this engine. They return `false`,
    /// as the system does for URLs that carry no scope.
    public var startsOnUnissuedURLs: [String] {
        state.withLock { $0.unissuedStarts }
    }

    /// Whether every start has been balanced by exactly one stop.
    public var isBalanced: Bool {
        balanceReport.isBalanced
    }

    /// Outstanding starts, unbalanced stops and starts on unissued URLs, in one value that
    /// describes itself, for readable test failures.
    public var balanceReport: BalanceReport {
        state.withLock { state in
            BalanceReport(
                outstanding: state.outstanding.filter { $0.value != 0 },
                unbalancedStops: state.unbalancedStops,
                startsOnUnissuedURLs: state.unissuedStarts
            )
        }
    }

    /// Whether access to `path` is currently held.
    public func isAccessing(_ path: String) -> Bool {
        state.withLock { ($0.outstanding[path] ?? 0) > 0 }
    }

    // MARK: - BookmarkEngine

    public func makeBookmark(
        for url: URL,
        options: URL.BookmarkCreationOptions,
        includingResourceValuesFor keys: Set<URLResourceKey>,
        relativeTo document: URL?
    ) throws -> BookmarkData {
        let path = url.fakePath
        let gate = state.withLock { state -> Gate? in
            guard var gates = state.creationGates[path], !gates.isEmpty else { return nil }
            let gate = gates.removeFirst()
            state.creationGates[path] = gates
            return gate
        }
        gate?.block()
        return try state.withLock { state in
            state.calls.creations += 1
            state.creationRequests.append(CreationRequest(path: path, options: options, document: document?.fakePath))
            if let error = FakeFileSystem.consumeFailure(&state.creationFailures, for: path) {
                throw error
            }
            var flavor = try FakeFlavor(options)
            if case .appScoped(let readOnly) = flavor, document != nil {
                flavor = .documentScoped(readOnly: readOnly)
            }
            if flavor.isScoped, !environment.supportsSecurityScope {
                throw CocoaError.error(.fileReadUnknown)
            }
            if case .documentScoped = flavor {
                guard let document, !state.isDirectory(document.fakePath) else {
                    throw CocoaError.error(.fileReadUnknown)
                }
                guard !state.isDirectory(path) else {
                    throw CocoaError.error(.fileReadUnknown)
                }
            }
            guard let item = state.item(at: path) else {
                throw CocoaError.error(.fileReadNoSuchFile)
            }
            if environment.isSandboxed, !state.hasAccess(to: path) {
                throw CocoaError.error(.fileReadUnknown)
            }
            state.serial += 1
            let payload = FakePayload(
                itemID: item.id,
                path: path,
                isDirectory: item.isDirectory,
                flavor: flavor,
                document: document?.fakePath,
                serial: state.serial
            )
            return BookmarkData(try JSONEncoder().encode(payload))
        }
    }

    public func resolve(
        _ data: BookmarkData,
        options: URL.BookmarkResolutionOptions,
        relativeTo document: URL?
    ) throws -> (url: URL, isStale: Bool) {
        let payload = try? JSONDecoder().decode(FakePayload.self, from: data.rawValue)
        let gate = state.withLock { state -> Gate? in
            state.calls.resolutions += 1
            state.resolutionRequests.append(ResolutionRequest(path: payload?.path, options: options))
            guard let path = payload?.path, var gates = state.gates[path], !gates.isEmpty else { return nil }
            let gate = gates.removeFirst()
            state.gates[path] = gates
            return gate
        }
        gate?.block()

        return try state.withLock { state in
            guard let payload else {
                throw CocoaError.error(.fileReadCorruptFile)
            }
            if let error = FakeFileSystem.consumeFailure(&state.resolutionFailures, for: payload.path) {
                throw error
            }
            try payload.flavor.checkResolution(options: options, document: document?.fakePath, payload: payload)

            let volume = FakeFileSystem.volume(of: payload.path)
            if !state.mountedVolumes.contains(volume) {
                if options.contains(.withoutMounting) {
                    throw CocoaError.error(.fileNoSuchFile)
                }
                state.mountedVolumes.insert(volume)
            }

            var isStale = false
            let path: String
            if let current = state.path(ofItem: payload.itemID) {
                path = current
                isStale = current != payload.path
            } else if state.item(at: payload.path) != nil {
                path = payload.path
                isStale = true
            } else {
                throw CocoaError.error(.fileNoSuchFile)
            }
            if let count = state.forcedStale[payload.path], count > 0 {
                state.forcedStale[payload.path] = count - 1
                isStale = true
            }

            state.issued.insert(path)
            if payload.flavor == .implicit, !options.contains(.withoutImplicitStartAccessing) {
                state.recordStart(path)
            }
            return (URL(filePath: path, directoryHint: payload.isDirectory ? .isDirectory : .notDirectory), isStale)
        }
    }

    public func recordedValues(in data: BookmarkData) -> RecordedValues? {
        guard let payload = try? JSONDecoder().decode(FakePayload.self, from: data.rawValue) else {
            return nil
        }
        let volume = FakeFileSystem.volume(of: payload.path)
        return RecordedValues(
            path: payload.path,
            name: (payload.path as NSString).lastPathComponent,
            volumePath: volume,
            volumeName: volume == "/" ? "Macintosh HD" : (volume as NSString).lastPathComponent,
            isDirectory: payload.isDirectory
        )
    }

    public func startAccessing(_ url: URL) -> Bool {
        let path = url.fakePath
        return state.withLock { state in
            state.calls.starts += 1
            guard !state.refused.contains(path) else { return false }
            guard state.issued.contains(path) else {
                state.unissuedStarts.append(path)
                return false
            }
            state.recordStart(path)
            return true
        }
    }

    public func stopAccessing(_ url: URL) {
        let path = url.fakePath
        state.withLock { state in
            state.calls.stops += 1
            let count = state.outstanding[path] ?? 0
            if count > 0 {
                state.outstanding[path] = count - 1
            } else {
                state.unbalancedStops.append(path)
            }
        }
    }

    public func isVolumeMounted(atPath path: String) -> Bool {
        state.withLock { $0.mountedVolumes.contains(path) }
    }

    public func fileIdentity(of url: URL) -> FileIdentity? {
        let path = url.fakePath
        let volume = FakeFileSystem.volume(of: path)
        return state.withLock { state in
            guard !state.volumesWithoutUUID.contains(volume) else { return nil }
            return state.item(at: path).map { FileIdentity(volumeUUID: volume, fileID: $0.id) }
        }
    }

    public func namesAreCaseSensitive(at url: URL) -> Bool {
        let volume = FakeFileSystem.volume(of: url.fakePath)
        return state.withLock { !$0.caseInsensitiveVolumes.contains(volume) }
    }

    public func itemInfo(at url: URL) -> ItemInfo? {
        let path = url.fakePath
        return state.withLock { state in
            guard let item = state.item(at: path) else { return nil }
            let canonical = state.canonicalPath(path)
            // Like the system, a link describes itself, not its target.
            return ItemInfo(
                isDirectory: item.linkTarget == nil && item.isDirectory,
                isSymbolicLink: item.linkTarget != nil,
                canonicalPath: canonical,
                namesAreCaseSensitive: !state.caseInsensitiveVolumes.contains(FakeFileSystem.volume(of: canonical))
            )
        }
    }

    public func writeAliasFile(_ data: BookmarkData, to url: URL) throws {
        guard
            let payload = try? JSONDecoder().decode(FakePayload.self, from: data.rawValue),
            payload.flavor == .alias
        else {
            throw CocoaError.error(.fileWriteUnknown)
        }
        let path = url.fakePath
        state.withLock { state in
            state.addItem(at: path, isDirectory: false)
            state.aliasFiles[path] = data
        }
    }

    public func aliasFileData(at url: URL) throws -> BookmarkData {
        let path = url.fakePath
        return try state.withLock { state in
            guard state.item(at: path) != nil, let data = state.aliasFiles[path] else {
                throw CocoaError.error(.fileReadNoSuchFile)
            }
            return data
        }
    }
}

extension FakeBookmarkEngine {
    /// Counts of engine calls.
    public struct Calls: Sendable, Equatable {
        public var creations = 0
        public var resolutions = 0
        public var starts = 0
        public var stops = 0
    }

    /// A recorded creation request.
    public struct CreationRequest: Sendable, Equatable {
        public let path: String
        public let options: URL.BookmarkCreationOptions
        public let document: String?
    }

    /// A recorded resolution request.
    public struct ResolutionRequest: Sendable, Equatable {
        public let path: String?
        public let options: URL.BookmarkResolutionOptions
    }

    /// Holds a blocked resolution until opened.
    public final class Gate: Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let state = Mutex<(reached: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

        /// Lets the blocked resolution continue.
        public func open() {
            semaphore.signal()
        }

        /// Returns once a resolution is blocked on this gate.
        public func waitUntilReached() async {
            await withCheckedContinuation { continuation in
                let reached = state.withLock { state in
                    if !state.reached {
                        state.waiters.append(continuation)
                    }
                    return state.reached
                }
                if reached {
                    continuation.resume()
                }
            }
        }

        func block() {
            let waiters = state.withLock { state in
                state.reached = true
                defer { state.waiters.removeAll() }
                return state.waiters
            }
            waiters.forEach { $0.resume() }
            semaphore.wait()
        }
    }
}

/// Errors the real system reports, for scripting failures.
public enum FakeErrors {
    /// `NSFileNoSuchFileError` (4): the item or its volume is gone.
    public static var noSuchFile: NSError { CocoaError.error(.fileNoSuchFile) as NSError }
    /// `NSFileReadCorruptFileError` (259): unreadable bytes or a scope key mismatch.
    public static var corrupt: NSError { CocoaError.error(.fileReadCorruptFile) as NSError }
    /// `NSFileReadUnknownError` (256): the sandbox refused.
    public static var denied: NSError { CocoaError.error(.fileReadUnknown) as NSError }
    /// `EPERM` from the kernel.
    public static var notPermitted: NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)) }
    /// An error the library doesn't classify.
    public static var unexpected: NSError { NSError(domain: "FakeBookmarkEngine", code: 42) }
}

extension URL {
    var fakePath: String {
        path(percentEncoded: false).trimmingTrailingSlashes
    }
}

extension String {
    var trimmingTrailingSlashes: String {
        var path = self
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
