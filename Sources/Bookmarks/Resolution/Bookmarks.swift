public import Foundation
import os

/// Creates, resolves and checks bookmarks without storing them.
///
/// Use it directly when your own format stores the bookmark bytes, and through
/// ``BookmarkStore`` otherwise. All system calls run on a ``BlockingExecutor``, never on the
/// caller's thread.
public struct Bookmarks: Sendable {
    /// The engine that talks to the system.
    public let engine: any BookmarkEngine
    /// The executor that runs blocking system calls.
    public let executor: BlockingExecutor
    /// How long to wait for a single system call. `nil` waits indefinitely.
    public var timeout: Duration?

    /// Creates a bookmark service.
    public init(
        engine: any BookmarkEngine = SystemBookmarkEngine(),
        executor: BlockingExecutor = .shared,
        timeout: Duration? = nil
    ) {
        self.engine = engine
        self.executor = executor
        self.timeout = timeout
    }

    /// The environment of the engine.
    public var environment: SandboxEnvironment { engine.environment }

    /// The kind used when a call doesn't specify one.
    public var defaultKind: BookmarkKind { .persistentDefault(for: environment) }

    /// Creates bookmark bytes for a granted URL without giving up the grant.
    ///
    /// Access is started around creation when the grant's origin needs it. The caller keeps
    /// responsibility for any access the system started; see ``relinquish(_:)``. Prefer
    /// ``adopt(_:kind:relativeTo:includingResourceValuesFor:)``, which also resolves the new
    /// bookmark and balances the grant.
    ///
    /// Save-panel URLs point at files that may not exist yet. Write the file before creating
    /// a bookmark to it, or the call fails with ``BookmarkFailure/missing``.
    public func create(
        for grant: Grant,
        kind: BookmarkKind? = nil,
        relativeTo document: URL? = nil,
        includingResourceValuesFor keys: Set<URLResourceKey> = [],
        validators: [any GrantValidator] = [],
        context: ValidationContext = ValidationContext()
    ) async throws(BookmarkError) -> BookmarkData {
        let kind = kind ?? defaultKind
        try checkSupported(kind, document: document)
        let engine = engine
        let classifier = classifier
        let platform = environment.platform
        return try await run { () throws(BookmarkError) -> BookmarkData in
            try Self.createNow(
                grant: grant,
                kind: kind,
                document: document,
                keys: keys,
                engine: engine,
                classifier: classifier,
                platform: platform,
                validation: validators.isEmpty ? nil : Validation(validators: validators, context: context)
            ).data
        }
    }

    /// Creates a bookmark for a granted URL, balances the grant, and resolves the new bookmark.
    ///
    /// This is the recommended way to take in a URL from a panel, importer, picker or drop:
    /// from then on, only the resolved bookmark is used. The grant is relinquished whether or
    /// not adoption succeeds.
    ///
    /// Validators run while access to the item is held, before the bookmark is created. A
    /// refusal fails with ``BookmarkFailure/refused(_:)``.
    public func adopt(
        _ grant: Grant,
        kind: BookmarkKind? = nil,
        relativeTo document: URL? = nil,
        includingResourceValuesFor keys: Set<URLResourceKey> = [],
        validators: [any GrantValidator] = [],
        context: ValidationContext = ValidationContext()
    ) async throws(BookmarkError) -> ResolvedBookmark {
        let kind = kind ?? defaultKind
        do {
            try checkSupported(kind, document: document)
        } catch {
            relinquish(grant)
            throw error
        }
        let engine = engine
        let classifier = classifier
        let platform = environment.platform
        let created = try await run { () throws(BookmarkError) -> Created in
            defer {
                if grant.isStartedBySystem(on: platform) {
                    engine.stopAccessing(grant.url)
                }
            }
            return try Self.createNow(
                grant: grant,
                kind: kind,
                document: document,
                keys: keys,
                engine: engine,
                classifier: classifier,
                platform: platform,
                validation: validators.isEmpty ? nil : Validation(validators: validators, context: context)
            )
        }
        let resolved = try await resolve(created.data, kind: kind, relativeTo: document)
        return ResolvedBookmark(
            kind: kind,
            originalData: created.data,
            wasStale: false,
            refreshedData: nil,
            refreshError: nil,
            recorded: resolved.recorded,
            fileIdentity: created.identity,
            handle: resolved.handle
        )
    }

    /// Balances the access the system started for a grant that won't be adopted.
    ///
    /// Does nothing for origins whose access the system didn't start.
    public func relinquish(_ grant: Grant) {
        if grant.isStartedBySystem(on: environment.platform) {
            engine.stopAccessing(grant.url)
        }
    }

    /// Balances the access the system started for grants that won't be adopted, such as the
    /// rejected items of a multi-item drop.
    public func relinquish(_ grants: some Sequence<Grant>) {
        grants.forEach(relinquish)
    }

    func consuming<T>(_ grant: Grant, _ body: () async throws(BookmarkError) -> T) async throws(BookmarkError) -> T {
        defer { relinquish(grant) }
        return try await body()
    }

    /// Resolves bookmark bytes and refreshes them when they are stale.
    ///
    /// Refreshing happens inside the item's scope, as the system requires. A failed refresh
    /// doesn't fail resolution; it's reported through ``ResolvedBookmark/refreshError``.
    public func resolve(
        _ data: BookmarkData,
        kind: BookmarkKind? = nil,
        relativeTo document: URL? = nil,
        policy: ResolutionPolicy = .default
    ) async throws(BookmarkError) -> ResolvedBookmark {
        let kind = kind ?? defaultKind
        try checkSupported(kind, document: document)
        let engine = engine
        let classifier = classifier
        return try await run { () throws(BookmarkError) -> ResolvedBookmark in
            try Self.resolveNow(
                data,
                kind: kind,
                document: document,
                policy: policy,
                engine: engine,
                classifier: classifier
            )
        }
    }

    /// Checks whether the bookmark's target is reachable, without mounting volumes, showing UI
    /// or starting access.
    public func availability(
        of data: BookmarkData,
        kind: BookmarkKind? = nil,
        relativeTo document: URL? = nil
    ) async -> Availability {
        let kind = kind ?? defaultKind
        do {
            try checkSupported(kind, document: document)
            let engine = engine
            let classifier = classifier
            return try await run { () throws(BookmarkError) -> Availability in
                let recorded = engine.recordedValues(in: data)
                do {
                    _ = try engine.resolve(data, options: kind.resolutionOptions(.default), relativeTo: document)
                    return .available
                } catch {
                    return Availability(classifier.classify(error, recorded: recorded))
                }
            }
        } catch {
            return Availability(error.failure)
        }
    }

    /// What the bookmark recorded about its target. Doesn't touch the file system.
    public func recordedValues(in data: BookmarkData) -> RecordedValues? {
        engine.recordedValues(in: data)
    }

    /// Resolves the bookmark, holds access while `body` runs, and ends it afterwards.
    ///
    /// Refreshed bytes aren't reported. Use ``resolve(_:kind:relativeTo:policy:)`` when the
    /// caller persists the bookmark and should replace stale bytes.
    nonisolated(nonsending) public func withAccess<T>(
        to data: BookmarkData,
        kind: BookmarkKind? = nil,
        relativeTo document: URL? = nil,
        policy: ResolutionPolicy = .default,
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let resolved = try await resolve(data, kind: kind, relativeTo: document, policy: policy)
        let lease = resolved.beginAccess()
        defer { lease.end() }
        return try await body(lease.url)
    }
}

extension Bookmarks {
    struct Validation: Sendable {
        let validators: [any GrantValidator]
        let context: ValidationContext

        func check(_ url: URL, engine: any BookmarkEngine) throws(BookmarkError) {
            guard let info = engine.itemInfo(at: url) else {
                throw BookmarkError(.refused(.uninspectable(path: url.path(percentEncoded: false))))
            }
            for validator in validators {
                if let refusal = validator.refusal(for: info, at: url, in: context) {
                    throw BookmarkError(.refused(refusal), lastKnownPath: info.canonicalPath)
                }
            }
        }
    }

    struct Created: Sendable {
        let data: BookmarkData
        let identity: FileIdentity?
    }

    var classifier: FailureClassifier {
        let engine = engine
        return FailureClassifier { engine.itemExists(atPath: $0) }
    }

    func checkSupported(_ kind: BookmarkKind, document: URL?) throws(BookmarkError) {
        if let reason = kind.unsupportedReason(in: environment, relativeTo: document) {
            throw BookmarkError(.unsupported(reason: reason))
        }
    }

    func run<T: Sendable>(_ work: @escaping @Sendable () throws(BookmarkError) -> T) async throws(BookmarkError) -> T {
        do {
            return try await executor.run(timeout: timeout) { try work() }
        } catch let error as BookmarkError {
            throw error
        } catch is BlockingExecutor.TimeoutError {
            throw BookmarkError(.timedOut)
        } catch is CancellationError {
            throw BookmarkError(.cancelled)
        } catch {
            let nsError = error as NSError
            throw BookmarkError(.other(domain: nsError.domain, code: nsError.code), underlying: nsError)
        }
    }

    static func createNow(
        grant: Grant,
        kind: BookmarkKind,
        document: URL?,
        keys: Set<URLResourceKey>,
        engine: any BookmarkEngine,
        classifier: FailureClassifier,
        platform: SandboxEnvironment.Platform,
        validation: Validation? = nil
    ) throws(BookmarkError) -> Created {
        let needsStart = !grant.isStartedBySystem(on: platform) && grant.origin != .alreadyAccessible
        let started = needsStart && engine.startAccessing(grant.url)
        defer {
            if started {
                engine.stopAccessing(grant.url)
            }
        }
        try validation?.check(grant.url, engine: engine)
        do {
            let data = try engine.makeBookmark(
                for: grant.url,
                options: kind.creationOptions,
                includingResourceValuesFor: keys,
                relativeTo: document
            )
            return Created(data: data, identity: engine.fileIdentity(of: grant.url))
        } catch {
            let failure = classifier.classify(error, recorded: nil)
            throw BookmarkError(failure, lastKnownPath: grant.url.path(percentEncoded: false), underlying: error as NSError)
        }
    }

    static func resolveNow(
        _ data: BookmarkData,
        kind: BookmarkKind,
        document: URL?,
        policy: ResolutionPolicy,
        engine: any BookmarkEngine,
        classifier: FailureClassifier
    ) throws(BookmarkError) -> ResolvedBookmark {
        let recorded = engine.recordedValues(in: data)
        let resolution: (url: URL, isStale: Bool)
        do {
            resolution = try engine.resolve(data, options: kind.resolutionOptions(policy), relativeTo: document)
        } catch {
            let failure = classifier.classify(error, recorded: recorded)
            Log.resolution.debug("Resolution failed: \(String(describing: failure), privacy: .public)")
            throw BookmarkError(failure, lastKnownPath: recorded?.path, underlying: error as NSError)
        }

        let startedImplicitly = kind == .implicit && policy.startsImplicitAccess
        var refreshedData: BookmarkData?
        var refreshError: BookmarkError?
        if resolution.isStale {
            do {
                refreshedData = try refresh(
                    resolution.url,
                    kind: kind,
                    document: document,
                    alreadyStarted: startedImplicitly,
                    engine: engine,
                    classifier: classifier
                )
            } catch {
                refreshError = error
            }
        }

        return ResolvedBookmark(
            kind: kind,
            originalData: data,
            wasStale: resolution.isStale,
            refreshedData: refreshedData,
            refreshError: refreshError,
            recorded: recorded,
            fileIdentity: nil,
            handle: ScopeHandle(url: resolution.url, engine: engine, alreadyStarted: startedImplicitly)
        )
    }

    private static func refresh(
        _ url: URL,
        kind: BookmarkKind,
        document: URL?,
        alreadyStarted: Bool,
        engine: any BookmarkEngine,
        classifier: FailureClassifier
    ) throws(BookmarkError) -> BookmarkData {
        let started = kind.carriesAccess && !alreadyStarted && engine.startAccessing(url)
        defer {
            if started {
                engine.stopAccessing(url)
            }
        }
        do {
            return try engine.makeBookmark(
                for: url,
                options: kind.creationOptions,
                includingResourceValuesFor: [],
                relativeTo: document
            )
        } catch {
            let failure = classifier.classify(error, recorded: nil)
            Log.resolution.error("Refreshing a stale bookmark failed: \(String(describing: failure), privacy: .public)")
            throw BookmarkError(failure, lastKnownPath: url.path(percentEncoded: false), underlying: error as NSError)
        }
    }
}
