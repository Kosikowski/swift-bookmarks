# Integration host

A sandboxed macOS app that answers the questions unit tests can't: `swift test` runs outside the App Sandbox, so it never sees how the system treats grants, scopes and failures in a real app. The questions are listed in [docs/design.md §11](../docs/design.md).

## Sandboxed system tests

```sh
cd IntegrationHost
xcodegen generate
xcodebuild test -project BookmarksIntegrationHost.xcodeproj -scheme BookmarksIntegrationHost -destination 'platform=macOS'
```

`BookmarksIntegrationHostTests` is hosted by the app, so its tests run inside the App Sandbox with the app's entitlements. They need no one at the keyboard: each works in its own folder in `~/Downloads`, which the app reaches through `com.apple.security.files.downloads.read-write`, and removes it afterwards. The container and the temporary folder won't do, because the system refuses document-scoped bookmarks to items there.

| Suite | What it checks |
|---|---|
| Document-scoped bookmarks in the sandbox | Which saves of the anchor keep the bookmarks' key (in-place writes, moves, copies, `replaceItemAt`, `NSDocument`, `DocumentBookmarks.replaceDocument`) and which lose it (a plain atomic write); other anchors; stale targets and their refresh; deleted targets; container targets |
| App-scoped bookmarks in the sandbox | Deleted items are `.missing`, a store drops and reports them; renamed folders are followed and refreshed; gone-first eviction; path-only records get a bookmark; one use of a grant |

Xcode gives hosted tests read access to every path (a temporary exception for `/`), so these tests can check what the sandbox does to bookmarks but not whether it denies reads.

## Running the probes

```sh
cd IntegrationHost
xcodegen generate
open BookmarksIntegrationHost.xcodeproj
```

Run the `BookmarksIntegrationHost` scheme. The app is ad-hoc signed and sandboxed with user-selected read-write, Downloads read-write, app-scope and document-scope bookmark entitlements.

## Probes

| Button | Question | What to do |
|---|---|---|
| 1. Panel start state / Importer start state / drop / Finder open | Does the system start access for panel, importer, SwiftUI drop and Finder-opened URLs, and what does another start return? | Pick or drop a folder outside the container, or open one with the app (`open -a <app> <folder>`). The answer for drops decided `Grant.Origin.swiftUIDrop` (research §5). |
| 2. Rebuilt URL | Does a URL rebuilt from the resolved path carry the scope? | Pick a folder. |
| 3. Save bookmark, then Resolve saved | Which failure comes back for a deleted item versus an ejected volume? | Save a folder, delete it or eject its disk, then resolve. |
| 4. Read-only scope | Can a read-only app-scoped bookmark be created and used? | Pick a folder. To test a read-only app, switch the entitlement to `user-selected.read-only`. |
| 5. Atomic save | Does an atomic save work with a bookmark to the file alone? | Pick a text file you don't mind rewriting with the same contents. |
| 7. In-place drop zone | Does the system start access for a folder an `NSItemProvider` hands over in place (`.onDrop` with `loadInPlaceFileRepresentation`)? | Drop a folder from the Finder onto the grey zone. Unreadable after the last stop means the system started access and the drop owes one stop. |

Observations are also printed to standard output, so a run launched from a terminal (`BookmarksIntegrationHost.app/Contents/MacOS/BookmarksIntegrationHost > host.log`) can be read without the window.

Record the observations in `docs/research/README.md` and adjust `Grant.Origin` handling or the fake engine if the system behaves differently from the documentation.
