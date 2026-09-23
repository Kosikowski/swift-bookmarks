public import Foundation
import os

/// Creates, resolves and checks bookmarks without storing them.
///
/// Use it directly when your own format stores the bookmark bytes, and through
/// ``BookmarkStore`` otherwise. All system calls run on a ``BlockingExecutor``, never on the
/// caller's thread. Document-scoped bookmarks go through ``DocumentBookmarks``.
public struct BookmarkService: Sendable {
    /// The engine that talks to the system.
    public let engine: any FileSystemEngine
    /// The executor that runs blocking system calls.
    public let executor: BlockingExecutor
    /// How long to wait for a single system call. `nil` waits indefinitely.
    public var timeout: Duration?

    /// Creates a bookmark service.
    public init(
        engine: any FileSystemEngine = SystemBookmarkEngine(),
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
    /// ``adopt(_:kind:includingResourceValuesFor:validators:context:)``, which also resolves
    /// the new bookmark and balances the grant.
    ///
    /// Save-panel URLs point at files that may not exist yet. Write the file before creating
    /// a bookmark to it, or the call fails with ``BookmarkFailure/missing``.
    public func create(
        for grant: Grant,
        kind: BookmarkKind? = nil,
        includingResourceValuesFor keys: Set<URLResourceKey> = [],
        validators: [any GrantValidator] = [],
        context: ValidationContext = ValidationContext()
    ) async throws(BookmarkError) -> BookmarkData {
        try await create(
            for: grant,
            kind: kind ?? defaultKind,
            document: nil,
            keys: keys,
            validation: Validation(validators: validators, context: context)
        )
    }

    /// Creates a bookmark for a granted URL, balances the grant, and resolves the new bookmark.
    ///
    /// This is the recommended way to take in a URL from a panel, importer, picker or drop:
    /// from then on, only the resolved bookmark is used. The grant is relinquished whether or
    /// not adoption succeeds, so write a save-panel file before adopting its grant.
    ///
    /// Validators run while access to the item is held, before the bookmark is created. A
    /// refusal fails with ``BookmarkFailure/refused(_:)``.
    public func adopt(
        _ grant: Grant,
        kind: BookmarkKind? = nil,
        includingResourceValuesFor keys: Set<URLResourceKey> = [],
        validators: [any GrantValidator] = [],
        context: ValidationContext = ValidationContext()
    ) async throws(BookmarkError) -> ResolvedBookmark {
        try await adopt(
            grant,
            kind: kind ?? defaultKind,
            document: nil,
            keys: keys,
            validation: Validation(validators: validators, context: context)
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

    /// Resolves bookmark bytes and refreshes them when they are stale.
    ///
    /// Refreshing happens inside the item's scope, as the system requires. A failed refresh
    /// doesn't fail resolution; it's reported through ``ResolvedBookmark/refreshError``.
    public func resolve(
        _ data: BookmarkData,
        kind: BookmarkKind? = nil,
        policy: ResolutionPolicy = .default
    ) async throws(BookmarkError) -> ResolvedBookmark {
        try await resolve(data, kind: kind ?? defaultKind, document: nil, policy: policy)
    }

    /// Checks whether the bookmark's target is reachable, without mounting volumes, showing UI
    /// or starting access.
    public func availability(of data: BookmarkData, kind: BookmarkKind? = nil) async -> Availability {
        await availability(of: data, kind: kind ?? defaultKind, document: nil)
    }

    /// What the bookmark recorded about its target. Doesn't touch the file system.
    public func recordedValues(in data: BookmarkData) -> RecordedValues? {
        engine.recordedValues(in: data)
    }

    /// Resolves the bookmark, holds access while `body` runs, and ends it afterwards.
    ///
    /// Refreshed bytes aren't reported. Use ``resolve(_:kind:policy:)`` when the caller
    /// persists the bookmark and should replace stale bytes.
    nonisolated(nonsending) public func withAccess<T>(
        to data: BookmarkData,
        kind: BookmarkKind? = nil,
        policy: ResolutionPolicy = .default,
        _ body: (URL) async throws -> T
    ) async throws -> T {
        try await withAccess(to: data, kind: kind ?? defaultKind, document: nil, policy: policy, body)
    }
}

extension BookmarkService {
    struct Validation: Sendable {
        let validators: [any GrantValidator]
        let context: ValidationContext

        init?(validators: [any GrantValidator], context: ValidationContext) {
            guard !validators.isEmpty else { return nil }
            self.validators = validators
            self.context = context
        }

        func check(_ url: URL, inspector: any ItemInspecting) throws(BookmarkError) {
            guard let info = inspector.itemInfo(at: url) else {
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

    func create(
        for grant: Grant,
        kind: BookmarkKind,
        document: URL?,
        keys: Set<URLResourceKey>,
        validation: Validation?
    ) async throws(BookmarkError) -> BookmarkData {
        try checkSupported(kind, document: document)
        return try await createNow(grant, kind: kind, document: document, keys: keys, validation: validation).data
    }

    func adopt(
        _ grant: Grant,
        kind: BookmarkKind,
        document: URL?,
        keys: Set<URLResourceKey>,
        validation: Validation?
    ) async throws(BookmarkError) -> ResolvedBookmark {
        let created = try await consuming(grant) { () throws(BookmarkError) -> Created in
            try checkSupported(kind, document: document)
            return try await createNow(grant, kind: kind, document: document, keys: keys, validation: validation)
        }
        let resolved = try await resolve(created.data, kind: kind, document: document, policy: .default)
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

    func resolve(
        _ data: BookmarkData,
        kind: BookmarkKind,
        document: URL?,
        policy: ResolutionPolicy
    ) async throws(BookmarkError) -> ResolvedBookmark {
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

    func availability(of data: BookmarkData, kind: BookmarkKind, document: URL?) async -> Availability {
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

    nonisolated(nonsending) func withAccess<T>(
        to data: BookmarkData,
        kind: BookmarkKind,
        document: URL?,
        policy: ResolutionPolicy,
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let resolved = try await resolve(data, kind: kind, document: document, policy: policy)
        let lease = resolved.beginAccess()
        defer { lease.end() }
        return try await body(lease.url)
    }

    func consuming<T>(_ grant: Grant, _ body: () async throws(BookmarkError) -> T) async throws(BookmarkError) -> T {
        defer { relinquish(grant) }
        return try await body()
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

    private func createNow(
        _ grant: Grant,
        kind: BookmarkKind,
        document: URL?,
        keys: Set<URLResourceKey>,
        validation: Validation?
    ) async throws(BookmarkError) -> Created {
        let engine = engine
        let classifier = classifier
        let platform = environment.platform
        return try await run { () throws(BookmarkError) -> Created in
            let needsStart = !grant.isStartedBySystem(on: platform) && grant.origin != .alreadyAccessible
            let started = needsStart && engine.startAccessing(grant.url)
            defer {
                if started {
                    engine.stopAccessing(grant.url)
                }
            }
            try validation?.check(grant.url, inspector: engine)
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
            Log.resolution.debug("Resolution failed: \(failure.caseName, privacy: .public)")
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
            Log.resolution.error("Refreshing a stale bookmark failed: \(failure.caseName, privacy: .public)")
            throw BookmarkError(failure, lastKnownPath: url.path(percentEncoded: false), underlying: error as NSError)
        }
    }
}
