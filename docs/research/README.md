# Apple URL bookmark APIs: technical reference for designing "swift-bookmarks"

Researched on 2026-09-23. Sources: the Xcode 27.0 SDK headers and Swift interfaces (MacOSX27.0, iPhoneOS27.0, XROS27.0), the DocC JSON behind developer.apple.com, the archived App Sandbox Design Guide (through the Wayback Machine, because the live archive URL now redirects), Apple Developer Forums posts by DTS engineers (Quinn "The Eskimo!" and Kevin Elliott), and blog posts.

I also ran my own experiments on macOS 26.6.2 (25G83) with an unsandboxed CLI. Results from those runs are marked **[EXP]**. I could not run a sandboxed experiment: an ad-hoc-signed sandboxed CLI crashed with SIGTRAP at sandbox initialisation, probably because the harness is itself sandboxed. So none of the sandbox-only behaviour below was checked empirically. **[UNVERIFIED]** marks claims I could not confirm.

---

## 1. API surface (Swift)

From the Foundation `.swiftinterface`:

```swift
func bookmarkData(options: URL.BookmarkCreationOptions = [], includingResourceValuesForKeys: Set<URLResourceKey>? = nil, relativeTo: URL? = nil) throws -> Data
init(resolvingBookmarkData: Data, options: URL.BookmarkResolutionOptions = [], relativeTo: URL? = nil, bookmarkDataIsStale: inout Bool) throws
static func resourceValues(forKeys: Set<URLResourceKey>, fromBookmarkData: Data) -> URLResourceValues?
static func writeBookmarkData(_ data: Data, to url: URL) throws          // alias file; Swift overlay drops the options param
static func bookmarkData(withContentsOf url: URL) throws -> Data         // read alias file
init(resolvingAliasFileAt: URL, options: BookmarkResolutionOptions = []) throws   // macOS 10.10 / iOS 8; .withSecurityScope NOT supported
func startAccessingSecurityScopedResource() -> Bool
func stopAccessingSecurityScopedResource()
```

- Both `URL` and `NSURL` are `Sendable`. `NSURL` is marked `NS_SWIFT_SENDABLE` in NSURL.h.
- If the URL is not a file URL, `bookmarkData` returns a bookmark that holds only the URL string and ignores `options` and `keys` (NSURL.h).
- `resourceValues(forKeys:fromBookmarkData:)` returns only the values stored in the bookmark. It can also return custom keys you passed in `includingResourceValuesForKeys`. Use it to show the last known path or name when resolution fails. **[EXP]** A default bookmark stores `path` and `volume*`, but `fileSize` is nil unless you ask for it at creation time. Adding 5 keys grew a bookmark from 1224 to 1412 bytes.
- **File reference URLs** (`file:///.file/id=…`) are not valid across reboots or volume remounts (NSURL.h: "Use a bookmark instead"). **[EXP]** Bridging to Swift `URL` silently turns a reference URL into a path URL: `(url as NSURL).fileReferenceURL()` gives `file:///private/etc/hosts`, and `isFileReferenceURL` is false. Do not base a design on reference URLs in Swift.

## 2. Options and platform availability

Availability below comes from the SDK 27 headers, and I confirmed it by type-checking against each target.

| Option | Raw | macOS | iOS/iPadOS/tvOS/watchOS/visionOS | Mac Catalyst |
|---|---|---|---|---|
| Creation `.minimalBookmark` | 1<<9 | 10.6 | 4.0 | ✓ |
| Creation `.suitableForBookmarkFile` | 1<<10 | 10.6 | 4.0 | ✓ |
| Creation `.withSecurityScope` | 1<<11 | 10.7 (actually 10.7.3) | **unavailable** (compile error, including visionOS) | 13.0 ✓ (compiles for `-macabi`) |
| Creation `.securityScopeAllowOnlyReadAccess` | 1<<12 | 10.7 | unavailable | 13.0 |
| Creation `.withoutImplicitSecurityScope` | 1<<29 | header says 10.7 / iOS 5 | ✓ | ✓ |
| Creation `.preferFileIDResolution` | 1<<8 | deprecated 10.9, no-op | deprecated iOS 7 | — |
| Resolution `.withoutUI` | 1<<8 | 10.6 | 4.0 | ✓ |
| Resolution `.withoutMounting` | 1<<9 | 10.6 | 4.0 | ✓ |
| Resolution `.withSecurityScope` | 1<<10 | 10.7 | unavailable | 13.0 |
| Resolution `.withoutImplicitStartAccessing` | 1<<15 | **11.2** | **iOS 14.2**, tvOS 14.2, watchOS 7.2 | 14.2 |

Notes:

- **`.withoutImplicitSecurityScope`**: the header back-dates it to 10.7 and iOS 5. Mothers' Ruin reports that it was published around macOS 12, matching an internal flag that has existed since 10.7. **[UNVERIFIED]** It probably works at runtime on old OSes because the bit predates publication.
- **`.withSecurityScope` combinations**: it cannot be combined with `.minimalBookmark` or `.suitableForBookmarkFile` (DocC). **[EXP]** Both fail with NSCocoaErrorDomain 256: "kCFURLBookmarkCreationMinimalBookmarkMask cannot be used with scoped bookmarks" and "kCFURLBookmarkCreationSuitableForBookmarkFile cannot be used with scoped bookmarks".
- **`.minimalBookmark`**: in practice it is not smaller. **[EXP]** It came out at 1248 bytes against 1224 for a plain bookmark. Kevin Elliott says "I don't think they're actually any smaller and never have been" ([797469](https://developer.apple.com/forums/thread/797469?page=2)). Apple's iOS directory sample still uses it ([Providing access to directories](https://developer.apple.com/documentation/uikit/providing-access-to-directories)).
- **Mac Catalyst**: older SDKs marked the security-scope options unavailable, so Catalyst code had to use the raw values 1<<11, 1<<12 and 1<<10 ([steipete gist](https://gist.github.com/steipete/40a367b64b57bfd0b44fa8d158fc016c)). Current headers declare `macCatalyst(13.0)`.
- **DocC wording**: the text for `withoutImplicitStartAccessing` contradicts itself. The header wording is the correct one: resolution does *not* start access, and you call start yourself. The option does not apply to security-scoped bookmarks.

## 3. Bookmark kinds

1. **Regular (implicit-scope) bookmark**, created with `options: []`.
   - Contains a newly issued sandbox extension token that is not tied to a process: an HMAC-signed capability with the path and inode ([Mothers' Ruin](https://www.mothersruin.com/software/Archaeology/reverse/bookmarks.html)). NSURL.h says this "implicit ephemeral security scope… is valid until reboot at the latest, and confers access to the resource to *any other process* that resolves the bookmark."
   - Resolving it **implicitly starts access**, unless you pass `.withoutImplicitStartAccessing`. The receiver must therefore call `stop` ([Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)).
   - This is the documented way to hand access to XPC services and launch agents.
   - **[EXP]** It was the largest bookmark (1224 bytes) because of the embedded extension.
2. **Bookmark without implicit scope** (`.withoutImplicitSecurityScope`).
   - Grants no access. It is a reference only: "other processes can't call startAccessing… on the resolved URL", and the bookmark is smaller. **[EXP]** 912 bytes.
   - Use it for pure location tracking and for anything persisted in a place other processes can read.
3. **App-scoped security-scoped bookmark** (`.withSecurityScope`, `relativeTo: nil`; macOS and Catalyst only).
   - Holds no extension. The prolog carries a 32-byte HMAC-SHA256 "security scope cookie" computed by `ScopedBookmarksAgent` with a key derived from the app's **code-signing identifier** and a per-user secret stored in the keychain ([Mothers' Ruin](https://www.mothersruin.com/software/Archaeology/reverse/bookmarks.html)).
   - Only the creating app can resolve it: "an app scoped, security scoped bookmark is ONLY valid within the app that created it" ([66259](https://developer.apple.com/forums/thread/66259)). Kevin Elliott says the same holds for helpers: "a bookmark created by your main app can't be resolved by your helper process" ([798402](https://developer.apple.com/forums/thread/798402)).
   - Resolve it with `.withSecurityScope`. Resolution does **not** start access, so you must call `start`.
   - **[EXP]** Resolving it *without* `.withSecurityScope` succeeds but gives a URL with no scope. Resolving a plain bookmark *with* `.withSecurityScope` fails with 259.
4. **Read-only app scope** (`.withSecurityScope` plus `.securityScopeAllowOnlyReadAccess`).
   - Needed when the app has only `user-selected.read-only`. One blog reports that creating a scoped bookmark failed with read-only, and they switched to read-write ([TrozWare](https://troz.net/post/2026/playing_mac_sandbox/)). **[UNVERIFIED]** I believe the right fix is to pass this flag.
5. **Document-scoped bookmark** (`.withSecurityScope`, `relativeTo: documentURL`; macOS only). It requires the `com.apple.security.files.bookmarks.document-scope` entitlement.
   - Any app that has the bookmark data *and* access to the document can resolve it. That makes it portable, including to another user or Mac.
   - Restrictions:
     - The target must be a **file, not a folder**.
     - The target must not be in system locations such as `/private` or `/Library` (App Sandbox Design Guide). Kevin Elliott adds that the "anchor" must also be a file.
   - The key is stored in the document's extended attribute `com.apple.security.private.scoped-bookmark-key` (Mothers' Ruin). So **anything that strips xattrs from the document breaks every bookmark inside it**, including some copy tools, archives and non-Apple sync services. **[UNVERIFIED]** I did not test the exact failure mode.
   - **[EXP]** Unsandboxed and without the entitlement, creation fails with 256 "The file couldn't be opened."
   - Forum reports describe 256 "Item URL disallowed by security policy" even *with* the entitlement on macOS 26 ([798402 p.2](https://developer.apple.com/forums/thread/798402?page=2)).
6. **Alias files** (`.suitableForBookmarkFile`, `URL.writeBookmarkData`, `bookmarkData(withContentsOf:)`, `URL(resolvingAliasFileAt:)`).
   - **[EXP]** The alias is written without an extension if you give a bare name, and `isAliasFile == true`.
   - **[EXP]** Writing a bookmark created without `.suitableForBookmarkFile` fails with 512 (NSFileWriteUnknownError).
   - Security scope is unsupported for alias files.
7. **iOS, iPadOS and visionOS "security-scoped" bookmarks.** These do not exist as a type.
   - Quinn: "Technically, iOS doesn't support security-scoped bookmarks… if you have access to a resource then you should be able to persist that access using a regular bookmark" ([766646](https://developer.apple.com/forums/thread/766646)).
   - Kevin Elliott: on iOS "it's very difficult (impossible?) to get a URL out of ANY API that doesn't have a security scope attached", and a regular bookmark restores that implicit scope ([793561](https://developer.apple.com/forums/thread/793561)).
   - Procedure:
     1. Call `start` on the picker URL.
     2. Create the bookmark with `[]` (or `.minimalBookmark`).
     3. Call `stop`.
     4. Later, resolve with `[]`, then call `start` and `stop` yourself.
   - If you create the bookmark without calling `start` first, the log shows `getattrlist(...) = 1` ([797469](https://developer.apple.com/forums/thread/797469)).
   - Users can revoke access in Settings › Privacy › Files and Folders, so resolution and `start` must be allowed to fail ([Providing access to directories](https://developer.apple.com/documentation/uikit/providing-access-to-directories)).

## 4. Staleness

**Meaning.** `bookmarkDataIsStale == true` means the bookmark resolved, but through a fallback path or with data that is out of date. Apple's instruction is to "create a new bookmark using the returned URL and use it in place of any stored copies" (NSURL.h).

**Observed triggers [EXP]** (unsandboxed, APFS):

| Scenario | Result |
|---|---|
| Rename or move within the volume | resolves to new path, stale=true |
| Parent directory renamed | child bookmark resolves, stale=true |
| Atomic replace at the *same* path (new inode) | resolves by path, stale=true |
| File moved *and* then atomically replaced at the new path | **fails**, NSCocoaErrorDomain 4. The recorded path is gone and the inode is gone ([Krzyżanowski](https://blog.krzyzanowskim.com/2019/12/05/url-bookmark-yes-and-no/) describes the same thing) |
| Hard link: bookmark made via link name, link name removed (inode still reachable via other name) | **fails**; resolution does not find the other name |
| Symlink | bookmark refers to the **link itself**, not its target |
| Refresh after stale (start → create → stop) | new bookmark resolves with stale=false |

**Known OS-level invalidations:**

- **iOS 13 → 14.** Apple (FB8481000): "Existing bookmarks are force-expired at the update to iOS 14… nothing the user/developer can do" ([657988](https://developer.apple.com/forums/thread/657988)).
- **macOS 13.7.5, 14.7.5 and 15.4** (CVE-2025-31191 fix). The scoping key moved from the file keychain to the data-protection keychain. Users who skipped the transitional update lost every app-scoped bookmark: 259 "isn't in the correct format", with the log line "app-scope or collection-scope key doesn't match the key in the bookmark". The system self-repairs, so new bookmarks work ([779247](https://developer.apple.com/forums/thread/779247), [Microsoft](https://www.microsoft.com/en-us/security/blog/2025/05/01/analyzing-cve-2025-31191-a-macos-security-scoped-bookmarks-based-sandbox-escape/)).
  - Kevin Elliott advises keeping a parallel **non-scoped bookmark** so you can still show the path and offer "reselect" when this happens.
- **Bookmark format change.** macOS 26.1, 15.7.2 and 14.8.2 changed the format to version 0x10050000, which adds a 10-byte team-ID field. The field is almost always null so far (Mothers' Ruin).

**App identity changes.**

- The app-scope key derives from the code-signing identifier, so **changing the bundle ID / signing identifier will almost certainly break app-scoped bookmarks**. **[Inferred from Mothers' Ruin; UNVERIFIED]**
- For team transfer, Apple only documents that sandbox-container access may prompt when the designated requirement changes (macOS 14+) ([Accessing files…](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)). Bookmark behaviour after a transfer is **[UNVERIFIED]**.
- Normal app updates that keep the same identifier and team keep working.

**Refresh procedure.** On macOS, creating a `.withSecurityScope` bookmark requires the process to currently have access. So:

1. Resolve with `.withSecurityScope`.
2. Call `start`.
3. Create the new bookmark.
4. Call `stop`, but only if `start` returned true.
5. Save the new bookmark atomically, replacing *every* stored copy.

Apple's docs list "recreate" before "start", but creating a scoped bookmark while not in scope fails inside a sandbox with 256 plus a "deny file-read/write" log ([797469](https://developer.apple.com/forums/thread/797469)).

Pitfalls:

- Stale does not mean inaccessible, and not-stale does not mean accessible. Always handle a failing `start` or a failing I/O call.
- Never overwrite a good bookmark with the result of a failed refresh. Keep the old one if re-creation throws.
- Refresh on a background queue. Deduplicate concurrent refreshes of the same bookmark.

## 5. Security-scoped access semantics

**Balancing.**

- Every `start` that returned **true** needs exactly one `stop`. If `start` returns false, do not call `stop` ("no harm, no foul": DTS in [798402](https://developer.apple.com/forums/thread/798402?page=2); [741560](https://developer.apple.com/forums/thread/741560)).
- The last balanced `stop` removes access immediately. `stop` on a URL you have no access to does nothing (NSURL.h).
- The 2012 Sandbox Design Guide said "Calls to start and stop access are not nested." The current docs say "balance each call… for a given security-scoped URL… last balanced call." So nesting is now reference-counted per URL. Whether that count is per *object* or per *resource* is **[UNVERIFIED]**.
- Scope lives on the URL object returned by resolution. A copy of that URL keeps the scope (NSURL.h). A URL rebuilt from `path` or `absoluteString` does **not** have it.
- A common bug is calling `start` on the *original* URL instead of the resolved one ([124687](https://developer.apple.com/forums/thread/124687)).
- **Library implication:** keep the resolved URL instance alive and hold your own reference count per bookmark ID. Call the OS `start` once and `stop` when your count reaches zero.

**Implicit starts.**

- macOS URLs from `NSOpenPanel`, `NSSavePanel`, drag-and-drop and Dock drops are **already started**. You must still call `stop` exactly once for them ([Accessing files…](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)).
- iOS `UIDocumentPickerViewController` URLs are **not** started ([804886](https://developer.apple.com/forums/thread/804886)).
- SwiftUI `.fileImporter` is **not** auto-started, even on macOS. Quinn says SwiftUI chose consistency across platforms ([749333](https://developer.apple.com/forums/thread/749333)).
- Regular bookmarks auto-start on resolution unless you pass `.withoutImplicitStartAccessing`.
- Resolving a `.withSecurityScope` bookmark never auto-starts.
- Kevin Elliott's recommendation: immediately bookmark the "magic" URL from the system, re-resolve it, and use only the resolved URL, so the app has a single code path ([798402](https://developer.apple.com/forums/thread/798402)).
- On macOS, after bookmarking a panel URL, call `stop` once more to release the panel's implicit start ([804886](https://developer.apple.com/forums/thread/804886)).

**Sub-paths.**

- Access to a directory covers its whole subtree, recursively, including items created later. Protected sub-locations are the exception, for example `~/Library/Mail`.
- Children do not need their own `start`. Bracket the loop once on the parent ([Providing access to directories](https://developer.apple.com/documentation/uikit/providing-access-to-directories); [793561](https://developer.apple.com/forums/thread/793561); [84951](https://developer.apple.com/forums/thread/84951)).
- Calling `start` and `stop` per file across 764 files ran into `sandbox_extension_consume error=[12: Cannot allocate memory]` after about 340 files.

**Kernel limit.**

- Extensions live in kernel memory. There is no API to query how many are outstanding ([756108](https://developer.apple.com/forums/thread/756108)).
- The limit is not fixed and depends on RAM and system-wide use ([Buckley](https://buckleyisms.com/blog/anecdotes-about-the-macos-sandbox-file-limit/)). Developers report roughly **1,000–2,500** per app on various platforms ([804886](https://developer.apple.com/forums/thread/804886)).
- When you hit it, `start` returns false, and Powerbox, bookmarks and the recent-documents list stop granting access until the app relaunches (NSURL.h).
- `NSDocumentController.recentDocumentURLs` leaks one extension per call, so do not poll it ([19934](https://developer.apple.com/forums/thread/19934)).
- A bookmark failing only after long uptime and working again after relaunch is the signature of a leak ([764435](https://developer.apple.com/forums/thread/764435?page=2)).

**Not sandboxed.**

- **[EXP]** On macOS, `start` returned **true** even for `URL(fileURLWithPath: "/etc/hosts")` and for every resolved bookmark. `.withSecurityScope` create and resolve both work.
- Inside a sandbox, a plain path URL returns false.
- `start` also returns false on locations the app can already reach, such as entitlement folders or its own container ([Scheirman](https://benscheirman.com/2019/10/troubleshooting-appkit-file-permissions)), and in iCloud Drive via `fileImporter`, which is normal ([741560](https://developer.apple.com/forums/thread/741560)).
- So **treat false as "nothing to balance"**, not as an error. Only an I/O failure proves you lack access.

**File coordination.** Apple's iOS sample wraps every read or write of picked content in `NSFileCoordinator` ([Providing access to directories](https://developer.apple.com/documentation/uikit/providing-access-to-directories)). This matters for File Provider and iCloud items: coordination triggers download of dataless files. On macOS, an `NSFilePresenter` with `primaryPresentedItemURL` plus `NSIsRelatedItemType` extends the sandbox to "related items" with the same name and a different extension.

**Entitlements (macOS).**

- **User-selected files:** `com.apple.security.files.user-selected.read-only` or `.read-write`, plus `.executable` if the app writes executables.
- **Standard folders:**
  - `com.apple.security.files.downloads.read-write`
  - `com.apple.security.assets.{music,movies,pictures}.{read-only,read-write}`
  - There is no Desktop or Documents entitlement. Use a panel plus a bookmark ([749714](https://developer.apple.com/forums/thread/749714)).
- **`bookmarks.app-scope`:** in practice not required, because `user-selected.*` is accepted too. Kevin Elliott says it is for helpers that create or resolve bookmarks without presenting panels ([798402](https://developer.apple.com/forums/thread/798402); FB7405463).
- **`bookmarks.document-scope`:** required. It was called `…collection-scope` in 10.7.3 ([Entitlement Key Reference](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html)).
- **Temporary exceptions:** `com.apple.security.temporary-exception.files.{absolute-path,home-relative-path}.{read-only,read-write}`. These face App Store review scrutiny.
- **Launch agents:** a sandboxed launch agent needs the `user-selected` capability to talk to ScopedBookmarksAgent at all ([798402](https://developer.apple.com/forums/thread/798402)).

## 6. Failure modes and error codes (NSCocoaErrorDomain)

| Code | Constant | When |
|---|---|---|
| 4 | `NSFileNoSuchFileError` | Target deleted, or not locatable **[EXP]**. Volume not mounted and `.withoutMounting` passed **[EXP]** |
| 256 | `NSFileReadUnknownError` | Scope or security problems: "Failed to retrieve app-scope key" (ScopedBookmarksAgent hang, macOS 15.0–15.1, r.140342863). "Couldn't issue sandbox extension for the resolved URL" (`/System/Volumes/Data/...`, FB9843248, [697939](https://developer.apple.com/forums/thread/697939)). "Item URL disallowed by security policy". Invalid option combinations **[EXP]**. Document-scope entitlement missing |
| 259 | `NSFileReadCorruptFileError` | Garbage data **[EXP]**. Scope-key mismatch (bookmark from another app or signing identity, or the 14.7.5 key reset). Plain bookmark resolved with `.withSecurityScope` **[EXP]** |
| 260 | `NSFileReadNoSuchFileError` | *Creating* a bookmark for a file that does not exist **[EXP]**. Save-panel URLs before the file is written ([756502](https://developer.apple.com/forums/thread/756502)) |
| 512 | `NSFileWriteUnknownError` | `writeBookmarkData` with non-alias data **[EXP]** |
| 257 / POSIX 1 (EPERM) | | Access denied by sandbox or MAC *after* resolving. BSD permissions give EACCES (13). Check `NSUnderlyingErrorKey` ([Quinn, On File System Permissions](https://developer.apple.com/forums/thread/678819)) |

Notes on specific environments:

- **Volumes.**
  - **[EXP]** Resolving without `.withoutMounting` *mounted a detached DMG* synchronously, at `/Volumes/<name>` rather than the original mount point, and did not report it stale.
  - Network volumes can prompt for credentials unless you pass `.withoutUI`.
  - SMB remount during resolution was broken until macOS 26.1 ([798402](https://developer.apple.com/forums/thread/798402)).
  - On **iOS**, bookmarks to external or USB volumes break permanently after the volume remounts (r.102995804, [797469](https://developer.apple.com/forums/thread/797469)).
  - A File Provider directory can enumerate empty on the first call; retry (r.150542999).
- **iCloud Drive and File Provider.**
  - Dataless items resolve fine because the placeholder exists. Reading needs coordination or a download. **[UNVERIFIED]** whether resolution itself ever fails for evicted items.
  - A **deleted** item gives 4.
- **TCC and MAC (macOS).**
  - Desktop, Documents, Downloads, removable and network volumes, app containers (14+) and group containers (15+) are protected by MAC. Denial surfaces as EPERM, not as a bookmark error.
  - A user selection in a panel implies consent.
  - Ad-hoc-signed builds re-prompt because TCC cannot identify them ([678819](https://developer.apple.com/forums/thread/678819)).
- **macOS 26 bugs.**
  - Bookmarks to `/` and to `/System/Volumes/Data` fail (r.157722315). 26.1 returns `/.nofollow/` paths, and the issue is fixed in 26.2.
  - Expect `/.nofollow/…` paths from resolution. They are canonical, and you should not "clean" them ([798402](https://developer.apple.com/forums/thread/798402)).
  - `.nofollow` was also reported on 15.7.2.
- **Package directories.** `start` fails on folders containing `Package.swift`. SwiftPM's own sandbox may be involved, root cause unknown ([717919](https://developer.apple.com/forums/thread/717919)).

## 7. Sharing and persistence

**App and helper, XPC service, launch agent (macOS).**

- Option 1: send a **regular bookmark** (implicit scope, valid until reboot). The receiver resolves it and calls `stop` when done.
- Option 2: send the security-scoped `URL` over **`NSXPCConnection`**, whose NSURL coder transfers scope, even for save-panel URLs of files that don't exist yet. The C `xpc_session` API cannot do this ([756502](https://developer.apple.com/forums/thread/756502)).
- App-scoped bookmarks **cannot** be shared. Each process must create its own while it holds live access, or use document scope ([66259](https://developer.apple.com/forums/thread/66259)).
- **App groups:** data can be shared, but app-scoped bookmarks still only resolve in their creator.
- **iOS app and extension** sharing a regular bookmark through an app group: reports conflict, and the one thread I found is unresolved ([134120](https://developer.apple.com/forums/thread/134120)). **[UNVERIFIED]**
- **Cross-device (iCloud):** security-scoped bookmarks do **not** work on another device, by design, because portability would be a security hole ([127729](https://developer.apple.com/forums/thread/127729)).
  - The scoping key is bound to the machine's data-protection keychain ([779247](https://developer.apple.com/forums/thread/779247)).
  - Only document-scoped bookmarks, carried inside the document, travel.
  - Sync paths or identifiers, not bookmarks.
- **Storage.**
  - Bookmarks are about 0.9–1.4 KB each **[EXP]**.
  - `UserDefaults` is fine for a handful. For collections, use a file or database written atomically. Apple's sample writes the bookmark to a file.
  - A Keychain is unnecessary for app-scoped data, which is useless to other apps.
  - **However**, a **regular bookmark on macOS is a bearer token** until reboot: any process that reads it gains access. Persist regular bookmarks only with `.withoutImplicitSecurityScope`, or keep them in the container. Do not write them to shared or world-readable locations.
  - Store metadata next to each bookmark: kind, creation options, last known path, a volume hint, and a created/refreshed date.

## 8. Concurrency and performance

- The APIs are synchronous and can block for a long time:
  - **mounting volumes** (observed with a DMG)
  - network I/O and authentication UI (without `.withoutUI`)
  - XPC to `ScopedBookmarksAgent`, which hung on macOS 15.0–15.1 when the keychain was locked
- **Never call them on the main actor.** Because they block, also avoid the cooperative thread pool when resolving network or removable volume bookmarks. Use a dedicated serial or concurrent `DispatchQueue` or thread bridged with continuations. The calls cannot be cancelled.
- **[EXP] Cost**, local APFS on Apple silicon, unsandboxed, per call:

| Operation | Cost |
|---|---|
| Create plain bookmark | ~0.24 ms |
| Create `.withSecurityScope` bookmark | ~1.1 ms (XPC to the agent) |
| Resolve plain bookmark | ~0.03 ms |
| Resolve `.withSecurityScope` bookmark | ~0.6 ms |

  Sandboxed numbers are likely higher. **[UNVERIFIED]**
- Thread safety: `URL` and `NSURL` are `Sendable`, and I found no documented thread restrictions for create or resolve. `start` and `stop` change process-global kernel state, so a library should serialise its own bookkeeping in an actor or lock, while doing the blocking I/O outside that actor.

## 9. More quirks, and testing

- Bookmarks survive app updates as long as the signing identifier is unchanged. They do not survive an OS keychain reset (the 14.7.5 case) or the iOS 14 force-expiry.
- Safe-save (`NSDocument` or `Data.write(atomically:)`) changes the inode. Bookmarks survive through the path fallback and report stale. They fail if the file is also moved (see the table in section 4).
- **Testing.**
  - `swift test` and SPM test runners are **not sandboxed**, so `start` is always true and app-scope works [EXP]. Real sandbox semantics can't be seen there.
  - Document-scope creation fails there with 256 [EXP].
  - The iOS Simulator has broader sandbox exceptions than devices ([793561](https://developer.apple.com/forums/thread/793561)).
  - Bookmark resolution in the iPad and visionOS simulators was reported flaky ([767535](https://developer.apple.com/forums/thread/767535), unanswered).
  - Kevin Elliott advises testing after a reboot and on real macOS ([797469](https://developer.apple.com/forums/thread/797469)).
  - Use a sandboxed host-app test target plus a VM for TCC.
  - During development, `killall ScopedBookmarksAgent` clears agent hangs.
- **Library design:** put the OS calls behind a protocol, for example `BookmarkEngine` with `create`, `resolve`, `start` and `stop`, so the logic can be unit-tested with fakes.

## 10. Existing open-source libraries

| Library | Design | Notes |
|---|---|---|
| [dagronf/Bookmark](https://github.com/dagronf/Bookmark) (MIT) | `Bookmark` class wrapping the data. `resolved()` / `resolving {}`. `Codable` | macOS 10.11+, iOS 11+, tvOS, watchOS. Mostly location-tracking; light on scope handling |
| [mz2/BookmarkStorage](https://github.com/mz2/BookmarkStorage) (MIT) | `BookmarkStore` with a storage-delegate protocol (UserDefaults implementation). `URLAccess` protocol. Prompts with `NSOpenPanel` when access is missing, and can group requests by parent folder | macOS; Carthage era; little maintenance |
| [smart-byte/SecureBookmarkStore](https://github.com/smart-byte/SecureBookmarkStore) (MIT, 2026) | Swift 6 `actor`. Auto-renews stale bookmarks while in scope. Symmetric start/stop. NSKeyedArchiver file written atomically | macOS 13+ only. Resolving inside an actor blocks it |
| [StikImporter](https://github.com/StephenDev0/StikImporter) | SwiftUI `fileImporter` wrapper that handles start/stop | No persistence |
| [Daniel Tull pattern](https://danieltull.co.uk/blog/2018/09/09/wrapping-urls-security-scoped-resource-methods/) | `url.accessSecurityScopedResource { }` with generic `rethrows` | Warns that a `defer` inside an `if` runs too early. Also calls `stop` when `start` returned false, which is harmless |
| Others | Flutter [macos_secure_bookmarks](https://github.com/authpass/macos_secure_bookmarks), [Tauri iOS plugin](https://github.com/alasdairpan/tauri-plugin-ios-bookmark), [Go wrapper](https://pkg.go.dev/github.com/deploymenttheory/go-macos-sandbox/bookmark) | Cross-runtime bridges |

What these libraries don't handle, and a new package could: per-platform strategy (scoped on macOS and Catalyst, implicit on iOS and visionOS); reference-counted scope leases; balancing the macOS picker's implicit start; document scope; implicit bookmarks for XPC; `.withoutMounting` and `.withoutUI` policy; non-blocking resolution off the cooperative pool; typed errors that map 4/256/259/260; fallback to a non-scoped "last known path" bookmark; testability behind a protocol.

## Could not verify

- Whether reference counting is per URL object or per resource, and the exact extension limit.
- Sandboxed resolution and creation timings.
- The iOS app↔extension bookmark-sharing outcome.
- Bookmark behaviour after an App Store team transfer or bundle-ID change (inferred to break).
- The real OS introduction of `.withoutImplicitSecurityScope`.
- Resolution of evicted iCloud items.
- Document-scope xattr-stripping failures.
- Whether any iOS 17 or 18 specific bookmark regressions exist. I found none documented beyond r.102995804 and r.150542999.
