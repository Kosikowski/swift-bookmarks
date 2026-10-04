# Changelog

## 0.2.1

### Changed

- `ItemInspecting.itemExists(withIdentity:)` reads the volume's filesystem ID with `getattrlist` (`ATTR_CMN_FSID`) instead of `statfs`. Apple lists `statfs` among the disk-space APIs an app's privacy manifest has to give a reason for, and none of those reasons covers reading a filesystem ID, so an app using the library had no accurate reason to declare. `getattrlist` is in the file timestamp category, which `itemExists(atPath:)`'s `lstat` already puts an app in. The README says what an app declares for the library.
- The README's installation snippet points at 0.2.1.

## 0.2.0

What an app needs to keep a history of its documents in a `BookmarkStore`, one-shot use of picked items, re-granting on every platform, and fixes found by running the tests on the iOS simulator and inside the App Sandbox.

### Added

- **Path-only records.** `BookmarkStore.add(pathOnly:key:metadata:)` stores an item without a bookmark, when making one failed or the app knows only the path. Leasing the record or refreshing statuses makes the bookmark as soon as the app reaches the item; `regrant(_:with:)` makes one from a grant. Their `data` is `nil`, and `BookmarkRecord.hasBookmark` tells them apart.
- **Eviction policies.** `StorePolicy.eviction` decides which records go past `limit`: `.storeOrder` (the previous behaviour and the default), `.leastRecentlyUsed`, `.goneFirst` (missing, corrupt or in a Trash first, then the least recently used), or `EvictionPolicy(protects:evictsFirst:)` over `EvictionCandidate`. Pinned records are kept while their item isn't gone.
- **Last use and pinning.** `BookmarkRecord.lastUsedAt`, set by adds, re-grants, `markUsed(_:)` and, with `StorePolicy.recordsLastUse`, by leases, except one that joins an active lease; `BookmarkRecord.isPinned`, set with `setPinned(_:for:)` and kept by `add(copyOf:)`. `isInTrash` and `isGone` describe the item as the store last saw it.
- **Eviction reports.** `BookmarkStore.evictions(bufferingPolicy:)`, `nonisolated`, yields a `StoreEviction` (record and reason: `.limit` or `.failure(_:)`) for every record the store removes on its own.
- **Synchronous reads.** `BookmarkStore.snapshot`, a `StoreSnapshot` updated after every load and saved change, before `updates()` reports it.
- `BookmarkStore.updateLastKnownPath(_:to:)`, `forget(where:)`, and `refreshStatuses(includingAvailable:)` to re-check records believed available.
- **One use of a grant.** `BookmarkService.beginAccess(to:)` and `withAccess(to:_:)` use a picked item's access without making a bookmark, balanced, using the grant up.
- **Saving documents with document-scoped bookmarks.** `DocumentBookmarks.replaceDocument(_:)` and `replaceDocument(with:)` replace the anchor atomically and keep the key its bookmarks need, through the new `ItemReplacing` engine protocol.
- **Re-granting on every platform.** `BookmarkStore.regrantWithDocumentPicker(_:from:fileTypes:)` (iOS, visionOS, Mac Catalyst) and the SwiftUI `bookmarkRegrant(of:in:message:prompt:fileTypes:onCompletion:)` modifier, with the same results as `regrantWithOpenPanel`; `regrantConfiguration(for:message:prompt:fileTypes:)` and `regrant(_:withFirstOf:)` for custom pickers.
- `bookmarkImporter` has an `onCancel` callback.
- `FakeBookmarkEngine`: `hostEnvironment`, `clearScriptedFailures(of:)`, `failReplacement(of:with:times:)`, `replaceItem(at:keepingExtendedAttributes:)`, `stripExtendedAttributes(at:)`, `refuseInspection(of:)`, `itemExists(atPath:)`, `itemExists(withIdentity:)` and `calls.replacements`. It models the key of document-scoped bookmarks.
- `ItemInspecting.itemExists(atPath:)` and `itemExists(withIdentity:)`, with default implementations; the second asks `fsgetpath` on macOS.
- Sandboxed system tests in the integration host, system tests with real files on macOS and the iOS simulator, and a disk-image volume test.

### Changed

- `bookmarkImporter` honours the configuration's `directoryURL` everywhere and, on macOS, its `message`, `prompt` and `showsHiddenFiles`. The design document lists what each picker supports.
- `FakeBookmarkEngine()` simulates a sandboxed app on the platform the tests run on, not always a Mac. On a Mac nothing changes.
- The library and the fake spell the security-scope options by their bits, so a fake simulating macOS behaves the same on an iOS host.
- In a sandboxed environment, the fake reports a deleted item behind a security-scoped bookmark with 259, and a document-scoped bookmark resolved against a document without a key with 256, as the system does. A moved anchor keeps its bookmarks working.
- `regrantWithOpenPanel` shares the new helpers; for a path-only record it asks the item at the path whether it's a folder.

### Fixed

- **Deleted items inside the App Sandbox are `.missing`.** The system fails a scoped bookmark to a deleted item with 259 there, which was classified `.needsRegrant`, so `FailureHandling.dropMissing` never dropped it. A 259 with nothing at the recorded path is now `.missing` (or `.volumeUnavailable`), unless a store finds the item elsewhere by its file identity: then it moved and lost its key, and stays `.needsRegrant`.
- The fake's access accounting was unbalanced on the iOS simulator when it simulated macOS, the default: app-scoped bookmarks were taken for implicit ones and their implicit starts never stopped.
- `failResolution(of:with:times: 0)` and `failCreation(of:with:times: 0)` failed once; they now script nothing and clear an earlier script.
- The test targets didn't build for iOS, and a handoff timeout test passed or failed by timing.

### Compatibility

Nothing is removed and every new parameter has a default. Code written for 0.1.0 compiles unchanged, except where it reads `BookmarkRecord.data`, which is now optional: `nil` for a path-only record, so passing a record's bytes to the service needs an unwrap, and `BookmarkRecord.init` takes `BookmarkData?`. Behaviour that changes:

- Engines conforming to `FileSystemEngine` now also conform to `ItemReplacing` and implement `itemExists(atPath:)` and `itemExists(withIdentity:)`. The default implementations use the real file system; an engine that simulates one should override them, as `FakeBookmarkEngine` does.
- Sandboxed apps see `.missing` rather than `.needsRegrant` for deleted items, which changes what `FailureHandling` drops and what an app offers the user. A scope key that doesn't match an item that's still there stays `.needsRegrant`.
- Tests on iOS, visionOS or Mac Catalyst hosts that relied on `FakeBookmarkEngine()` simulating a Mac must pass `environment: SandboxEnvironment(platform: .macOS, isSandboxed: true)`.
- The JSON format keeps its schema version. Records gain optional `lastUsedAt` and `isPinned` fields, which 0.1.0 keeps unread and writes back. Path-only records are written without `data`, so 0.1.0 can't decode them and keeps them verbatim; records with a bookmark are written as before.
