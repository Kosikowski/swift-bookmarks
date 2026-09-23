# swift-bookmarks

URL bookmarks and security-scoped access for macOS, Mac Catalyst, iOS/iPadOS and visionOS, done once and correctly: every bookmark kind, balanced access, stale refresh inside the scope, typed failures, pluggable storage and test doubles.

Swift 6, macOS 15 / iOS 18 / visionOS 2 / Mac Catalyst 18.

## Products

| Product | What it's for |
|---|---|
| `Bookmarks` | Creating, resolving and storing bookmarks; access leases |
| `BookmarksUI` | Open panel, document picker, SwiftUI importer and drop, re-grant flow |
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

`BookmarkStore` is an actor: reads and changes are `async`, and persistence runs off the calling thread. Call `try await store.load()` at launch to read the records early. Records keep their key when bookmarks are refreshed or re-granted. A record that fails to resolve stays in the store with `status == .unavailable(failure, since:)` unless the policy drops it:

```swift
switch record.status.failure {
case .volumeUnavailable?: // show "disk not connected", retry after VolumeEvents reports a mount
case .needsRegrant?, .denied?: try await store.regrantWithOpenPanel(record.key, message: "Find “\(record.displayName)”")
case .missing?: try await store.forget(record.key)
default: break
}
```

## Keeping your own storage format

Use `BookmarkService` directly when bookmark bytes live inside your own documents or settings. The bytes are plain Apple bookmark data, so existing values keep working.

```swift
let service = BookmarkService()
let resolved = try await service.resolve(savedData)
if resolved.needsPersisting { save(resolved.data) }
let lease = resolved.beginAccess()
```

Or conform your existing store to `BookmarkPersistence` and keep its format byte for byte. `MigratingPersistence` imports legacy records once.

`JSONFilePersistence` can be shared between processes, such as an app and its extensions in an app group: every change is read, merged and written in one coordinated step, and `Task { await store.reload(on: persistence.changes()) }` keeps a store current with what the others save.

## Other scenarios

- `service.documents(anchoredOn:)`: document-scoped bookmarks to files referenced from a document. It's the only way to anchor a bookmark on a document.
- `service.handoff`: tokens that pass access to an XPC service or helper.
- `service.aliasFiles`: Finder alias files.
- Grants are used once. Adopt the ones you keep and let the others go: a grant released unused balances the access the system started for it.
- `VolumeEvents`: mount and unmount notifications (macOS). `store.refreshStatuses(on: VolumeEvents.stream())` re-resolves unavailable records on every mount.
- `store.lease(covering:)` and `ScopeLedger.shared.lease(covering:)`: reuse a folder's access for files inside it instead of starting one scope per file.
- `store.addAndLease(_:key:metadata:)`: add a granted item and lease it with the resolution adopting it made, so nothing can fail between keeping it and opening it.
- `store.add(copyOf:key:metadata:)`: move a bookmark from one store to another as it is, without resolving it, so an item that can't be reached now moves too.

## Testing apps that use it

```swift
let engine = FakeBookmarkEngine()
engine.addItem(at: "/Users/me/Project")
let store = BookmarkStore<String, NoMetadata>(persistence: InMemoryPersistence(), service: BookmarkService(engine: engine))

try await store.add(engine.grant("/Users/me/Project", origin: .openPanel), key: "project")
engine.moveItem(from: "/Users/me/Project", to: "/Users/me/Renamed")
try await store.lease("project").end()

#expect(engine.isBalanced, "\(engine.balanceReport)")
```

## Development

```sh
swift test                      # unit, fake-engine, UI and system tests
```

`swift test` isn't sandboxed. The [integration host](IntegrationHost/README.md) checks sandbox behaviour in a real app.

## Documents

- [Research](docs/research/README.md): how Apple's bookmark APIs behave, with sources and experiments.
- [Design](docs/design.md): the package design and implementation notes.
