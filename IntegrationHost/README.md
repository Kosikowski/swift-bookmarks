# Integration host

A sandboxed macOS app that answers the questions unit tests can't: `swift test` runs outside the App Sandbox, so it never sees how the system treats grants, scopes and failures in a real app. The questions are listed in [docs/design.md §11](../docs/design.md).

## Running

```sh
cd IntegrationHost
xcodegen generate
open BookmarksIntegrationHost.xcodeproj
```

Run the `BookmarksIntegrationHost` scheme. The app is ad-hoc signed and sandboxed with user-selected read-write, app-scope and document-scope bookmark entitlements.

## Probes

| Button | Question | What to do |
|---|---|---|
| 1. Panel start state / Importer start state / drop / Finder open | Does the system start access for panel, importer, SwiftUI drop and Finder-opened URLs, and what does another start return? | Pick or drop a folder outside the container, or open one with the app (`open -a <app> <folder>`). The answer for drops decided `Grant.Origin.swiftUIDrop` (research §5). |

Observations are also printed to standard output, so a run launched from a terminal (`BookmarksIntegrationHost.app/Contents/MacOS/BookmarksIntegrationHost > host.log`) can be read without the window.
| 2. Rebuilt URL | Does a URL rebuilt from the resolved path carry the scope? | Pick a folder. |
| 3. Save bookmark, then Resolve saved | Which failure comes back for a deleted item versus an ejected volume? | Save a folder, delete it or eject its disk, then resolve. |
| 4. Read-only scope | Can a read-only app-scoped bookmark be created and used? | Pick a folder. To test a read-only app, switch the entitlement to `user-selected.read-only`. |
| 5. Atomic save | Does an atomic save work with a bookmark to the file alone? | Pick a text file you don't mind rewriting with the same contents. |
| 7. In-place drop zone | Does the system start access for a folder an `NSItemProvider` hands over in place (`.onDrop` with `loadInPlaceFileRepresentation`)? | Drop a folder from the Finder onto the grey zone. Unreadable after the last stop means the system started access and the drop owes one stop. |

Record the observations in `docs/research/README.md` and adjust `Grant.Origin` handling or the fake engine if the system behaves differently from the documentation.
