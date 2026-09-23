# swift-bookmarks — design

Status: implemented, 2026-09-23 (see §15 for where the code differs from this sketch). Inputs: [research](research/README.md).

## 1. Goals

One package for URL bookmarks, so an app doesn't re-derive the same subtle rules and repeat the same bugs.

- **Every bookmark kind:** app-scoped security-scoped (read-write and read-only), document-scoped, regular (implicit scope) for iOS and for XPC handoff, reference-only (`.withoutImplicitSecurityScope`), and alias files.
- **Every supported platform:** macOS, Mac Catalyst, iOS/iPadOS, visionOS. The platform differences live in the library, not in callers.
- **Correct by construction:** access is a lease that owns the resolved URL instance, balances itself, and can't be rebuilt from a path. Stale refresh happens inside the open scope, exactly once. Unresolvable bookmarks are never silently deleted.
- **Never blocks the main thread or the cooperative pool.** Blocking OS calls run on a dedicated executor.
- **Adoptable without data loss:** an app's existing on-disk format keeps working through a persistence adapter. Bookmark bytes stay plain Apple bookmark data with no wrapper.
- **Testable:** every OS call sits behind one protocol, with fakes that model staleness, hangs, refused scopes and unbalanced access.

### Non-goals
- Cross-device bookmark sync. Bookmarks are machine-bound by design (research §7); apps sync paths or ids.
- File coordination and iCloud downloading beyond thin helpers. The library exposes hooks; the app decides when to coordinate.
- Domain concepts: projects, profiles, onboarding, localised copy.

## 2. Rules the library enforces

Each rule comes from the research or from a failure mode the design is meant to rule out.

| # | Rule | Basis |
|---|---|---|
| R1 | `startAccessing…` returning `false` means "nothing to balance", never an error. Only an I/O failure proves lack of access. | research §5 |
| R2 | Start and stop happen on the **resolved URL instance**. The library never lets callers start a URL rebuilt from a path. | research §5 |
| R3 | One OS `start` per bookmark key, refcounted by the library, not by URL equality. | research §5 (kernel limit) |
| R4 | Stale refresh: start → create → stop, compare-and-swap into storage, keep the id, keep old bytes if re-creation fails, deduplicate concurrent refreshes. | research §4 |
| R5 | A failed resolution never deletes the stored bytes unless the caller's policy says so. Unresolved records survive unrelated writes. | design decision |
| R6 | Resolution uses `.withoutUI` always and `.withoutMounting` unless the caller opts into mounting. | research §6, §8 |
| R7 | Blocking calls run off the main actor and off the cooperative thread pool. | research §8 |
| R8 | Picker URLs are adopted according to their origin: panel and drop URLs are already started (take ownership of one stop); `fileImporter` and document-picker URLs are not (start them). | research §5 |
| R9 | Regular bookmarks on macOS are bearer tokens. The library persists only scoped or reference bookmarks on macOS; regular ones are for in-memory handoff. | research §3, §7 |
| R10 | Directory grants cover their subtree. Prefer one lease on a covering ancestor to many per-file leases. | research §5 (kernel limit) |

## 3. Package layout

```
swift-bookmarks/
  Package.swift              // swift-tools 6.2, Swift 6 mode
  Sources/
    Bookmarks/               // core: kinds, engine, resolution, access, store, persistence
    BookmarksUI/             // NSOpenPanel / fileImporter / document picker / drop intake / re-grant
    BookmarksTesting/        // fakes and assertions for app test targets
  Tests/
    BookmarksTests/          // unit tests over FakeBookmarkEngine
    BookmarksSystemTests/    // real engine, unsandboxed (swift test)
  IntegrationHost/           // sandboxed macOS app + iOS app running scenario checks (see §11)
```

Platforms: macOS 15, Mac Catalyst 18, iOS 18, visionOS 2. macOS 15 is the lowest that gives `Synchronization.Mutex`.

Dependencies: none beyond Foundation, os, Synchronization; `BookmarksUI` adds AppKit/UIKit/SwiftUI and UniformTypeIdentifiers.

## 4. Core types

### 4.1 Bookmark data and kinds

```swift
/// Plain Apple bookmark bytes. Codable as a single `Data` value (base64 in JSON),
/// so it drops into every existing format unchanged.
public struct BookmarkData: Sendable, Hashable, Codable {
    public let rawValue: Data
}

public enum AccessMode: Sendable, Hashable, Codable { case readWrite, readOnly }

public enum BookmarkKind: Sendable, Hashable, Codable {
    /// macOS/Catalyst app-scoped security-scoped bookmark. Resolvable only by this app.
    case appScoped(AccessMode)
    /// macOS document-scoped bookmark to a *file*, anchored on a document file.
    /// Requires the document-scope entitlement.
    case documentScoped(AccessMode)
    /// Regular bookmark that carries access implicitly.
    /// iOS/visionOS persistence; macOS in-memory handoff to helpers only.
    case implicit
    /// Tracks location only, carries no access (`.withoutImplicitSecurityScope`).
    case reference
    /// Alias-file bookmark (`.suitableForBookmarkFile`). No scope.
    case alias

    /// `.appScoped(.readWrite)` on macOS/Catalyst, `.implicit` elsewhere.
    public static var persistentDefault: BookmarkKind { get }
}
```

`BookmarkKind` maps to creation and resolution options in one place (`BookmarkKind.options`), including the invalid combinations from research §2 (e.g. scope + minimal), which are rejected before reaching the OS.

### 4.2 Engine: the only place that calls the OS

```swift
public protocol BookmarkEngine: Sendable {
    func makeBookmark(for url: URL, kind: BookmarkKind, relativeTo document: URL?,
                      includingResourceValuesFor keys: Set<URLResourceKey>) throws -> BookmarkData
    func resolve(_ data: BookmarkData, kind: BookmarkKind, relativeTo document: URL?,
                 policy: ResolutionPolicy) throws -> (url: URL, isStale: Bool)
    func recordedValues(in data: BookmarkData) -> RecordedValues?   // last known path, volume, name
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
    var environment: SandboxEnvironment { get }                     // sandboxed? platform?
}

public struct ResolutionPolicy: Sendable, Hashable {
    public var mounting: Mounting = .never          // .never → .withoutMounting
    public var allowsUI = false                     // false → .withoutUI
    public var implicitStart = false                // false → .withoutImplicitStartAccessing for .implicit
}
```

`SystemBookmarkEngine` is the real implementation. Everything above it is pure logic that tests run against `FakeBookmarkEngine`.

### 4.3 Blocking executor

```swift
public final class BlockingExecutor: Sendable {
    public static let shared: BlockingExecutor   // dedicated concurrent queue, width 4
    public func run<T: Sendable>(timeout: Duration? = nil,
                                 _ work: @Sendable @escaping () throws -> T) async throws -> T
}
```

OS calls can't be cancelled. On timeout the awaiting caller gets `BookmarkFailure.timedOut` while the work finishes in the background; its result is discarded, and single-flight (§6.3) stops a pile-up of hung resolves on the same bookmark. A caller that is already cancelled never enqueues its work. The store's persistence calls run on the same executor but always to completion, so a cancelled caller can't leave memory and disk out of step.

### 4.4 Failures

```swift
public enum BookmarkFailure: Sendable, Hashable {
    case missing                         // NSFileNoSuchFile (4) on a mounted volume
    case volumeUnavailable(name: String?) // 4 while the recorded volume isn't mounted
    case needsRegrant                    // 259 scope-key mismatch / OS key reset / revoked (iOS)
    case denied                          // 256 "disallowed by security policy", EPERM on start/use
    case corrupt                         // 259 on data that fails the recorded-values probe too
    case unsupported(String)             // invalid option combination, missing entitlement
    case timedOut
    case other(code: Int, domain: String)

    /// Keep, re-grant or drop — a suggestion; the store's policy decides.
    public var recommendation: Recommendation { get }
}

public struct BookmarkError: Error, Sendable {
    public let failure: BookmarkFailure
    public let lastKnownPath: String?    // from recordedValues, for UI and re-grant
    public let underlying: (any Error & Sendable)?
}
```

Classification uses the error code **and** `recordedValues` (does the recorded volume path exist?), so a missing volume is `.volumeUnavailable`, not `.missing`.

## 5. Stateless API

For callers that store bookmark bytes inside their own formats.

```swift
public struct BookmarkService: Sendable {
    public init(engine: any BookmarkEngine = SystemBookmarkEngine(),
                executor: BlockingExecutor = .shared, timeout: Duration? = nil)

    public func create(for grant: Grant, kind: BookmarkKind? = nil, …) async throws(BookmarkError) -> BookmarkData
    public func adopt(_ grant: Grant, kind: BookmarkKind? = nil, …) async throws(BookmarkError) -> ResolvedBookmark
    public func resolve(_ data: BookmarkData, kind: BookmarkKind? = nil,
                        policy: ResolutionPolicy = .default) async throws(BookmarkError) -> ResolvedBookmark
    public func availability(of data: BookmarkData, kind: BookmarkKind? = nil) async -> Availability
}

public final class ResolvedBookmark: Sendable {
    public let wasStale: Bool
    /// New bytes when the bookmark was stale and re-creation succeeded; the caller persists them.
    public let refreshedData: BookmarkData?
    /// Set when stale refresh failed. Access still works; keep the old bytes.
    public let refreshError: BookmarkError?
    public var displayPath: String { get }         // for UI only — never for file access
    public func beginAccess() -> AccessLease
}
```

`ResolvedBookmark` deliberately has no public `url`. The URL is reachable only through a lease (R2). The service takes no document anchor: document-scoped bookmarks go through `DocumentBookmarks` (§9.1), so an anchor can't turn another kind into a document-scoped bookmark by accident. The service isn't called `Bookmarks` because a type named like its module breaks module-qualified names such as `Bookmarks.Grant`.

`Availability` is `.available`, `.volumeUnavailable(name)`, `.missing`, `.needsRegrant`, `.unknown`. It resolves with `.withoutMounting` and doesn't start access, so it's cheap enough for tiles and banners.

## 6. Access

### 6.1 Leases

```swift
public final class AccessLease: Sendable {
    /// The resolved URL instance that carries the scope. Derive children with
    /// `appending(path:)`; don't rebuild from `path`.
    public let url: URL
    /// Whether the OS start succeeded. `false` is normal outside the sandbox and for
    /// locations the app already reaches (R1).
    public let didStartScope: Bool
    public func end()          // idempotent; ends on deinit as a safety net
}

extension BookmarkService {
    public func withAccess<T>(to data: BookmarkData, kind: BookmarkKind? = nil,
                              policy: ResolutionPolicy = .default,
                              _ body: (URL) async throws -> T) async throws -> T
}
```

### 6.2 Access registry

`AccessRegistry` is a `Mutex`-protected, synchronous, `Sendable` class, so the main actor and non-isolated code can use it without hopping.

- One OS start per **key**, with an internal refcount of leases (R3). The first lease starts, the last `end()` stops.
- Holds the resolved URL instance for the key so later leases reuse it instead of re-resolving. `lease(for:resolved:)` adopts the scope of a `ResolvedBookmark`, so an implicit start taken during resolution is balanced by the same leases.
- `lease(covering: url)` returns a lease on an already-open ancestor when one exists (R10).
- `activeScopeCount` for diagnostics; logs a warning past a soft limit (default 500).
- `endAll()` for termination, ordered after caller-supplied shutdown hooks.
- Leases stay valid while work is in flight: `forget` on the store marks the key for removal and stops access only when the last lease ends.

### 6.3 Single-flight

Concurrent resolves of the same key share one engine call and one refresh. So a double refresh can't mint a new id, and resolves don't pile up when a file watcher fires repeatedly.

## 7. Store

For apps that want the library to own the keyed collection (most of them).

```swift
public actor BookmarkStore<Key: Hashable & Sendable & Codable, Metadata: Sendable & Codable> {
    public init(persistence: some BookmarkPersistence<Key, Metadata>,
                kind: BookmarkKind? = nil,
                policy: StorePolicy = .default,
                service: BookmarkService = .init())

    public func load() async throws(BookmarkStoreError<Key>)          // optional; reads load on first use
    public func reload() async throws(BookmarkStoreError<Key>)        // after another process wrote

    // Adding and re-granting
    public func add(_ grant: Grant, key: Key, metadata: Metadata) async throws -> BookmarkRecord<Key, Metadata>
    public func add(_ grant: Grant, metadata: Metadata) async throws -> BookmarkRecord<Key, Metadata> where Key == BookmarkID
    public func regrant(_ key: Key, with grant: Grant) async throws   // same key and metadata, new bytes
    public func forget(_ key: Key) async throws -> Bool

    // Access
    public func lease(_ key: Key) async throws(BookmarkStoreError<Key>) -> AccessLease
    public func lease(covering url: URL) async throws(BookmarkStoreError<Key>) -> AccessLease?
    public func withAccess<T>(to keys: [Key], _ body: ([Key: URL]) async throws -> T) async throws -> T

    // Reading
    public func records() async throws(BookmarkStoreError<Key>) -> [BookmarkRecord<Key, Metadata>]   // includes unresolved ones
    public func record(_ key: Key) async throws -> BookmarkRecord<Key, Metadata>?
    public func key(matching url: URL) async throws -> Key?                  // by file identity, then path
    public func updateMetadata(_ key: Key, _ change: sending (inout Metadata) -> Void) async throws
    public func availability(_ key: Key) async throws -> Availability
    public func refreshStatuses() async throws(BookmarkStoreError<Key>) -> [Key]  // e.g. on volume mount

    // A snapshot, then every change carrying the record as it is after the change.
    public func updates(bufferingPolicy: …= .unbounded) async throws -> AsyncStream<StoreUpdate<Key, Metadata>>
}

public struct BookmarkRecord<Key, Metadata>: Sendable, Codable {
    public let key: Key
    public var data: BookmarkData
    public var kind: BookmarkKind
    public var lastKnownPath: String
    public var fileIdentity: FileIdentity?    // volume UUID + file id, for duplicate detection
    public var status: RecordStatus           // .ok, .unavailable(BookmarkFailure, since: Date)
    public var createdAt: Date
    public var refreshedAt: Date?
    public var metadata: Metadata
}
```

Store behaviour:

- **Stable identity.** The key never changes. Refresh and re-grant replace `data` under the same key. `BookmarkID` (a UUID wrapper) is provided for apps without their own id.
- **Refresh compare-and-swap.** A refresh only writes if the stored bytes are still the ones that were resolved (R4).
- **Failure policy per store** (`StorePolicy.onFailure`): `.keepAndMark` (default), or drop for specific failures. A store of locations the app can't work without can drop what can never come back, while a recents list keeps everything.
- **Unresolved records are first-class.** They're in `records()` with a status and `lastKnownPath`, and every write includes them (R5).
- **Duplicates by file identity**, not case-insensitive path.
- **Optional ordering and limit** (`StorePolicy.limit`) for recents lists.
- **Validators** run on `add` and `regrant` (§9.3).
- **Writes are serialised** and the in-memory state only changes after persistence succeeds. The actor is reentrant at the persistence `await`, so an async lock keeps writes in order; reads see the last saved state and never wait for a save.

### 7.1 Persistence

```swift
public protocol BookmarkPersistence<Key, Metadata>: Sendable {
    associatedtype Key; associatedtype Metadata
    func load() throws -> [BookmarkRecord<Key, Metadata>]
    func save(_ records: [BookmarkRecord<Key, Metadata>]) throws
}
```

Built in:

| Backend | Details |
|---|---|
| `UserDefaultsPersistence(key:suite:)` | JSON; quarantines undecodable values to `<key>.corrupted` |
| `JSONFilePersistence(url:)` | atomic writes, `NSFileCoordinator`, `schemaVersion`, `.last-good` copy, `.corrupt-<timestamp>` quarantine |
| `InMemoryPersistence` | tests, previews, screenshot builds |

**Adapters for existing formats.** An app keeps its current format by writing a small `BookmarkPersistence` that maps its stored shape to `BookmarkRecord` and back. Fields the library adds (status, identity, dates) that the old format can't hold are recomputed at load. This is the compatibility contract: **existing bytes, keys and ids are read and written unchanged.**

`MigratingPersistence` imports legacy records once on load for apps changing format later, and never deletes the legacy value until the migrated value is saved. It requires a `MigrationMarker`, so a store the user empties isn't refilled from legacy data.

The store calls `load()` and `save(_:)` on the blocking executor, one at a time, so adapters can do synchronous I/O.

## 8. Grants: where URLs come from

```swift
public struct Grant: Sendable {
    public let url: URL
    public let origin: Origin
    public enum Origin: Sendable {
        case openPanel, savePanel, appKitDrop, finderOpen   // macOS: already started
        case swiftUIDrop                                    // unverified: the library starts it
        case fileImporter, documentPicker                   // not started
        case implicitBookmark                               // started on resolve
        case alreadyAccessible                              // app already reaches it (unsandboxed, container)
    }
}
```

Intake follows the pattern recommended by Apple DTS: bookmark the system URL immediately, balance its start according to its origin (R8), resolve the new bookmark, and use only the resolved URL from then on. Whether the system started access depends on where the URL came from, and the integration host verifies each origin (§11).

Save panels return URLs for files that don't exist yet; bookmark creation fails with 260 until the file is written. `Grant.savePanel` bookmarks the parent directory's scope, or defers creation until `commitWrite()`.

## 9. Scenarios

### 9.1 Document-scoped bookmarks (macOS)
`DocumentBookmarks(document: URL)` creates and resolves `.documentScoped` bookmarks to files referenced from a document, and is the only API that takes a document anchor. It checks the rules it can up front (targets must be files; the anchor must be a file) and fails with `.unsupported` or `.refused`. A missing document-scope entitlement surfaces as `.denied`, the system's 256. The docs note that tools stripping extended attributes break these.

### 9.2 Handoff to helpers and extensions
- `Handoff.makeToken(for lease: AccessLease) -> BookmarkData` creates an `.implicit` bookmark for sending to an XPC service or login item. It's a bearer token valid until reboot, so it's never persisted (R9).
- `Handoff.receive(_ data:) -> AccessLease` resolves with implicit start and returns a lease that stops on end.
- With `NSXPCConnection`, sending the lease's `url` directly also carries scope; documented as the alternative.

### 9.3 Validators
`GrantValidator` protocol plus built-ins:

- `.notTooBroad` — rejects `/`, `/Users`, `/Volumes`, the real home and its ancestors
- `.directoryOnly`, `.fileOnly`
- `.noSymlink`
- `.noOverlap(with: store)` — duplicate, parent or child of an existing record
- `.covers(_ target: URL)`

Validators return typed refusals; the app supplies the copy.

### 9.4 Aliases
`AliasFile.write(for: URL, to: URL)` and `AliasFile.resolve(at: URL)`. No scope, per research §3.

### 9.5 Environment awareness
`SandboxEnvironment.current` reports sandboxed/unsandboxed and platform. When unsandboxed (direct-distribution builds, test runners), the default kind becomes `.reference` for move tracking only, and `didStartScope == false` is expected.

### 9.6 Volumes
`VolumeEvents` (macOS) is an `AsyncStream` of mount and unmount notifications. `BookmarkStore.refreshStatuses()` re-resolves every record not known to be available, typically when a volume mounts.

## 10. UI helpers (`BookmarksUI`)

- `OpenPanelPicker.choose(_:attachedTo:) async -> [Grant]` on macOS and `DocumentPicker.choose(_:from:) async -> [Grant]` on iOS, configured by `PickerConfiguration`.
- `.bookmarkImporter(isPresented:configuration:onGrants:onFailure:)`: SwiftUI `fileImporter` wrapper that produces `Grant`s with the right origin.
- `.bookmarkDropDestination(onDrop:)`: drop wrapper with origin `.swiftUIDrop`.
- `BookmarkStore.regrantWithOpenPanel(_:message:prompt:attachedTo:)`: opens the panel at the record's last known location, with a message the app supplies, and calls `store.regrant`. `StorePolicy.requiresSameItemOnRegrant` checks that the user picked the same file identity.

## 11. Testing

`BookmarksTesting`:

- `FakeBookmarkEngine`: bookmark bytes are the path; scriptable stale, failure per path, hangs with gates, sandboxed/unsandboxed mode. It only accepts `start` on URLs it issued from `resolve` or intake, and records every start and stop.
- `engine.isBalanced` and `engine.balanceReport` show whether every start has one stop; the report describes outstanding starts, unbalanced stops and starts on unissued URLs, so `#expect(engine.isBalanced, "\(engine.balanceReport)")` fails readably. The package doesn't import `Testing`.
- `engine.grant(_:origin:)` stands in for pickers in UI-flow tests; `InMemoryPersistence` for stores.

`IntegrationHost` is a sandboxed macOS app (and an iOS app) with a scenario runner. It exists to answer, on real signed builds, the questions the research couldn't verify:

1. Does `start` on an already-started panel/drop URL return `true` (refcount) or `false`? Is a `.dropDestination(for: URL.self)` URL started?
2. Is the refcount per URL object or per path? Does a URL rebuilt with `URL(filePath:)` lose the scope?
3. Which error does `.withoutMounting` give for an unmounted volume versus a deleted file?
4. Does a read-only app with `.securityScopeAllowOnlyReadAccess` create scoped bookmarks?
5. Does an atomic save next to a file-scoped bookmark need the parent's scope?
6. iOS: does an app extension resolve a regular bookmark created by its host app through an app group?

The answers feed back into `Grant` intake and the fake engine, so unit tests stay accurate.

## 12. Concurrency summary

- Public types are `Sendable`. `BookmarkStore` is an actor; `AccessRegistry` stays a `Mutex`-protected class so leases can start and end synchronously from any context.
- Blocking OS calls go through `BlockingExecutor`, never the store's lock and never the main actor (R7).
- After every await, the store re-checks a per-key generation counter, so a `forget` or `regrant` that lands mid-resolve isn't undone. Single-flight is keyed by key and generation, so a caller never joins a resolution of bytes that were replaced.
- Closure parameters are `sending` or `@Sendable` as appropriate; no `@unchecked Sendable` in public API.

## 13. Logging and privacy

`os.Logger` with a subsystem set through `BookmarkLogging.subsystem`, defaulting to the main bundle identifier plus `.bookmarks`. Failure case names are public; paths, volume names and underlying errors are `.private`. The library never logs bookmark bytes.

## 14. Open questions

- **Minimum OS:** raising the floor above macOS 15 would allow dropping some availability checks.
- **Actor vs Mutex for the store.** Settled: the store is an actor, so its reads are `async`.
- **Whether `BookmarksUI` should wrap `NSDocument`/recent documents.** Nothing needs it yet; `recentDocumentURLs` leaks extensions (research §5), so a helper would have to avoid it.

## 15. Implementation notes

Where the code differs from the sketches above:

- **Engine:** `BookmarkEngine` takes Foundation's option sets rather than kinds and policies; `BookmarkKind` maps itself to options. It also inspects items (`itemInfo(at:)`, `fileIdentity(of:)`, `itemExists(atPath:)`) and reads and writes alias files, so every file system call goes through one seam. Engines must not call back into the library, because starts and stops run under its locks.
- **Default kind:** `BookmarkKind.persistentDefault(for:)` takes the environment; the static property uses the current process.
- **Failures:** `BookmarkFailure` also has `.refused(GrantRefusal)` for validator refusals and `.cancelled` for callers that stop waiting.
- **Validators** run inside `BookmarkService.adopt` and `create`, while access to the item is held, through `validators:` and `context:` parameters. They inspect items through `BookmarkEngine.itemInfo(at:)`. `.notTooBroad` refuses every top-level folder, other users' homes and second-level system folders as well as the home folder and its ancestors.
- **Grant origins:** `Grant.isStartedBySystem(on:)` takes the platform, so tests can check every platform on one machine.
- **Store:** an actor whose bookkeeping lives in an internal `RecordTable` value type. Errors are `BookmarkStoreError<Key>`. Resolution uses `StorePolicy.mounting` and `StorePolicy.allowsUI`, not a per-call argument; the store never lets resolution start implicit access, so the policy has no field for it. A lease whose record keeps changing during resolution fails with `BookmarkStoreError.changedDuringAccess` rather than `.notFound`. `lease(covering:)` falls back to a shallower stored folder when the deepest one doesn't resolve.
- **Grants consumed by helpers:** `DocumentBookmarks.create(for:)` and `AliasFiles.write(aliasTo:at:)` relinquish their grant whether or not they succeed, like `adopt`. `BookmarkService.relinquish(_:)` also takes a sequence, for the rejected items of a multi-item drop or panel.
- **Implicit starts:** a resolved bookmark whose implicit start was never taken over by a lease stops it when released.
- **Save panels:** there is no `commitWrite()`. Callers write the file first, then create or adopt the bookmark.
- **Unsandboxed builds** default to `.reference` bookmarks.
- **System engine:** resource values are read without `URL`'s cache, because cached values hid identity changes after atomic saves.
- **UI:** `OpenPanelPicker`, `DocumentPicker`, `RegrantConfiguration`, `GrantMapping`, `bookmarkImporter` and `bookmarkDropDestination`. The document picker resumes with no grants when it's dismissed without a delegate callback.
- **Integration host:** `IntegrationHost/` is an XcodeGen project; see its README for the probes.
