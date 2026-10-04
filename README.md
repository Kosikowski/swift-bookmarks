# swift-bookmarks

URL bookmarks and security-scoped access for macOS, Mac Catalyst, iOS/iPadOS and visionOS, done once and correctly: every bookmark kind, balanced access, stale refresh inside the scope, typed failures, pluggable storage and test doubles.

Swift 6, macOS 15 / iOS 18 / visionOS 2 / Mac Catalyst 18.

## Installation

```swift
.package(url: "https://github.com/Kosikowski/swift-bookmarks.git", from: "0.2.1")
```

Then add `Bookmarks`, `BookmarksUI` and `BookmarksTesting` to the targets that need them. `BookmarksTesting` belongs in test targets.

## Products

| Product | What it's for |
|---|---|
| `Bookmarks` | Creating, resolving and storing bookmarks; access leases |
| `BookmarksUI` | Open panel, document picker, SwiftUI importer and drop, re-grant flows |
| `BookmarksTesting` | `FakeBookmarkEngine` for app tests: simulated file system, sandbox rules, access accounting; `ScriptedPersistence` for storage failures |

## Storing folders the user picked

```swift
import BookmarksUI

let store = BookmarkStore<BookmarkID, NoMetadata>(
    persistence: JSONFilePersistence(fileURL: applicationSupport.appending(path: "bookmarks.json")),
    policy: StorePolicy(validators: [.directoryOnly, .notTooBroad, .noOverlap])
)

// Take in a folder from the open panel. The grant is adopted and balanced.
for grant in await OpenPanelPicker.choose(.folder(message: "Choose a projects folder")) {
    try await store.add(grant)
}

// Use it later, from any thread.
try await store.withAccess(to: id) { folder in
    try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
}

// Long-lived access, e.g. for a file watcher. Ending is idempotent; deinit ends it too.
let lease = try await store.lease(id)
defer { lease.end() }
```

`BookmarkStore` is an actor: reads and changes are `async`, and persistence runs off the calling thread. Call `try await store.load()` at launch to read the records early. `store.snapshot` gives the records synchronously, for a view's body, and changes before `updates()` reports a change. Records keep their key when bookmarks are refreshed or re-granted. A record that fails to resolve stays in the store with `status == .unavailable(failure, since:)` unless the policy drops it:

```swift
switch record.status.failure {
case .volumeUnavailable?: // show "disk not connected", retry after VolumeEvents reports a mount
case .needsRegrant?, .denied?: try await store.regrantWithOpenPanel(record.key, message: "Find “\(record.displayName)”")
case .missing?: try await store.forget(record.key)
default: break
}
```

On iOS, visionOS and Mac Catalyst, `store.regrantWithDocumentPicker(key, from: viewController)` does the same with the document picker, and in SwiftUI, on every platform:

```swift
.bookmarkRegrant(of: $regranting, in: store, message: "Find “\(name)”") { result in
    if case .failure(let error) = result { show(error) }
}
```

## Keeping a history of documents

A store can remember every document the app opened: a stable key per document that follows renames and moves, a bookmark when one can be made and the path when it can't, when it was last used, and a pin for documents the app keeps data for.

```swift
let history = BookmarkStore<String, NoMetadata>(
    persistence: JSONFilePersistence(fileURL: applicationSupport.appending(path: "documents.json")),
    // At most 500: gone files first (missing, corrupt or in the Trash), then the least recently
    // used, never a pinned file that still exists.
    policy: StorePolicy(duplicates: .returnExisting, limit: 500, eviction: .goneFirst, recordsLastUse: true)
)

// Clear the app's own data for every record the store drops.
Task {
    for await eviction in history.evictions() { await queries.removeAll(for: eviction.key) }
}

// On open: the document's key, by file identity and then by path, or a new one.
let key = try await history.key(matching: url) ?? UUID().uuidString
do {
    try await history.add(Grant(url: url, origin: .alreadyAccessible), key: key)
} catch {
    try await history.add(pathOnly: url, key: key)   // no bookmark now; one is made when it can be
}

try await history.setPinned(true, for: key)       // it has saved queries
let recent = history.snapshot.records             // synchronous, for the UI
```

A path-only record gets its bookmark the next time it's leased or statuses are refreshed while the app reaches the item, or with `regrant(_:with:)`. `updateLastKnownPath(_:to:)` records where the app saved an item; resolving a bookmark sets it too. `refreshStatuses(includingAvailable: true)` re-checks every record, so a deleted file counts as gone before eviction, and `forget(where:)` removes many records in one save, such as `forget { $0.isGone }`.

## Keeping your own storage format

Use `BookmarkService` directly when bookmark bytes live inside your own documents or settings. The bytes are plain Apple bookmark data, so existing values keep working.

```swift
let service = BookmarkService()
let resolved = try await service.resolve(savedData)
if resolved.needsPersisting { save(resolved.data) }
let lease = resolved.beginAccess()
```

Or conform your existing store to `BookmarkPersistence` and keep its format byte for byte. If the format has no room for a record's status, identity or dates, return `false` from `storesRecordState` and the store keeps them in memory. `MigratingPersistence` imports legacy records once.

`JSONFilePersistence` can be shared between processes, such as an app and its extensions in an app group: every change is read, merged and written in one coordinated step, and `Task { await store.reload(on: persistence.changes()) }` keeps a store current with what the others save.

## Other scenarios

- `service.documents(anchoredOn:)`: document-scoped bookmarks to files referenced from a document. It's the only way to anchor a bookmark on a document. Their key lives in an extended attribute of the document that a plain atomic write (`Data.write(to:options: .atomic)`) loses, which breaks every bookmark in it. Save with `documents.replaceDocument { url in try data.write(to: url) }`, `FileManager.replaceItemAt` or `NSDocument`, which keep it.
- `service.handoff`: tokens that pass access to an XPC service or helper.
- `service.aliasFiles`: Finder alias files.
- Grants are used once. Adopt the ones you keep and let the others go: a grant released unused balances the access the system started for it.
- `VolumeEvents`: mount and unmount notifications (macOS). `store.refreshStatuses(on: VolumeEvents.stream())` re-resolves unavailable records on every mount.
- `store.lease(covering:)` and `ScopeLedger.shared.lease(covering:)`: reuse a folder's access for files inside it instead of starting one scope per file.
- `store.addAndLease(_:key:metadata:)`: add a granted item and lease it with the resolution adopting it made, so nothing can fail between keeping it and opening it.
- `store.add(copyOf:key:metadata:)`: move a bookmark from one store to another as it is, without resolving it, so an item that can't be reached now moves too.
- `service.withAccess(to: grant) { url in … }` and `service.beginAccess(to:)`: use a picked item once, such as writing into a folder the user just chose, without making a bookmark. The grant's access is balanced and the grant is used up.
- `.bookmarkImporter(isPresented:configuration:onGrants:)` starts in the configuration's `directoryURL` everywhere; on macOS it also shows the `message`, uses `prompt` for the confirm button and shows hidden files when asked. `OpenPanelPicker` honours every option; UIKit's document picker has only a starting folder.

## Testing apps that use it

`FakeBookmarkEngine()` simulates a sandboxed app on the platform the tests run on, so the same tests balance on a Mac and on the iOS simulator. Pass `environment:` to simulate another platform.

```swift
let engine = FakeBookmarkEngine()
engine.addItem(at: "/Users/me/Project")
let store = BookmarkStore<String, NoMetadata>(persistence: InMemoryPersistence(), service: BookmarkService(engine: engine))

try await store.add(engine.grant("/Users/me/Project", origin: .openPanel), key: "project")
engine.moveItem(from: "/Users/me/Project", to: "/Users/me/Renamed")
try await store.lease("project").end()

#expect(engine.isBalanced, "\(engine.balanceReport)")
```

Script failures with `failResolution(of:with:times:)`, `failCreation` and `failReplacement`, and remove them with `clearScriptedFailures(of:)`. The fake models what the App Sandbox does, including a document's bookmark key: `replaceItem(at:)` is a plain atomic write that loses it, `replaceItem(at:keepingExtendedAttributes: true)` a safe save that keeps it.

## Privacy manifest

An app using the library declares two of Apple's required-reason API categories in its `PrivacyInfo.xcprivacy`:

- `NSPrivacyAccessedAPICategoryFileTimestamp`, reason `3B52.1` (files the user granted access to): to tell whether a bookmarked item still exists, the library calls `lstat` and `getattrlist`.
- `NSPrivacyAccessedAPICategoryUserDefaults`, reason `CA92.1` (`1C8F.1` for an app group's suite): `UserDefaultsPersistence` and `MigratingPersistence` keep their data in `UserDefaults`. App Store Connect may find the class in the binary even when the app uses neither, so declare it either way.

It uses no other required-reason API.

## Development

```sh
swift test                      # unit, fake-engine, UI and system tests
xcodebuild test -scheme swift-bookmarks-Package -destination 'platform=iOS Simulator,name=<simulator>'
```

`swift test` isn't sandboxed. The [integration host](IntegrationHost/README.md) runs system tests inside the App Sandbox (`xcodebuild test` on its scheme) and has probes for the questions that need a person at the Finder. See the [changelog](CHANGELOG.md) for what changed.

## Documents

- [Research](docs/research/README.md): how Apple's bookmark APIs behave, with sources and experiments.
- [Design](docs/design.md): the package design and implementation notes.

## License

MIT. See [LICENSE](LICENSE).
