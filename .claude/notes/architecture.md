# Fork architecture notes

> **Status on the 6.0 base (October 2026 catch-up).** Jellyfin Quick Connect
> and Audiobookshelf SSO are upstream now (#1566, #1567) and live in upstream's
> code, not here. The other fork features are being re-ported onto 6.0 one
> slice at a time on `catchup/upstream-6.0`; until a feature's slice lands,
> its section below still describes the July `test/all-changes` code. Each
> slice updates its section. Ported so far (slice 1): the Audiobookshelf
> Folders tab, share links, the provenance store and the library export fix.

The upstream TortugaPower BookPlayer is a local-files audiobook player.
This fork adds three media-server clients and a share-extension web-URL
importer on top of that base. Don't assume "local files only" when
reading the code.

## Media-server integrations

All three speak through a shared `MediaServerKind` enum
(`.jellyfin / .audiobookshelf / .hummingbird`) and a shared progress
dispatcher that routes bookmarks back to whichever server an imported
book came from. A fourth `.dodp` kind is planned — see
[dodp-direction.md](dodp-direction.md).

### Jellyfin (`BookPlayer/Jellyfin/`)

Connection screen, library browser, audiobook details, server-side
download. Browses audiobook collections drilling Library → Folder →
Audiobook, plus dedicated Author and Narrator views.

Filters items by `BaseItemDto.type == .audioBook`, which means it
expects Jellyfin **Books**-type libraries with audiobooks enabled.
Music-type libraries return `.audio`, not `.audioBook`, and won't
surface.

Quick Connect support for passwordless sign-in.

### Audiobookshelf (`BookPlayer/AudiobookShelf/`)

Connection screen, library browser, audiobook details, download.
Password **and** native SSO. The "Sign in with SSO" button on the
credentials step runs ABS's own OpenID Connect mobile flow
(`signInWithOIDC` in `AudiobookShelfConnectionService`): PKCE +
`ASWebAuthenticationSession` against `GET /auth/openid` with the
`bookplayer://oauth` redirect, then the `GET /auth/openid/callback`
exchange yields the same `user.token` the password path stores.
Server-side prerequisite: the ABS OIDC config must whitelist
`bookplayer://oauth` as a mobile redirect URI. OIDC-only servers now
work without keeping a `local` method active.

**Folders tab** (6.0 base): browses the library's on-disk folder tree,
built client-side from each item's `relPath` (ABS has no folder-browse
endpoint). The model is in `Shared/AudiobookShelf/` (6.0 moved it there):
`AudiobookShelfLibraryItem.Kind.folder`, its `relPath`, and the
`.folders(libraryID:path:)` source. The app view model fetches the whole
library (limit 0) per level through its `loadFolderItems` seam and groups
it in `folderLevelItems`: subfolders (book counts at any depth, a
stringsdict plural) first, then the books directly at that level, both in
`localizedStandardCompare` name order. `.folder` rows drill down through
the `.library` destination. Sort preferences are hidden for folder levels
and `sortItems` passes them through, so disk order survives a search.
Unlike 6.0's other fetches, the folder fetch keeps its handle only while
it's current (a cancelled fetch that still gets its answer stays silent
and leaves its replacement's handle alone) and treats `URLError.cancelled`
as a cancellation. Stream from a folder level goes through the same
`onStreamTapped` gate as everywhere else (paid streaming stays gated).
The tab title is upstream's `folders_title`.

### Hummingbird (`BookPlayer/Hummingbird/`)

Talks to a self-hosted Hummingbird server
(`cobdfamily/hummingbird` docker image) which fronts NNELS via a
Playwright-based scraper plugin. REST surface for browse + search;
DODP-shaped `/resources` endpoint for multi-file DAISY downloads with
503+Retry-After auto-prefetch.

**Audio-format filter:** `HummingbirdLibraryItem.audioFormatIds` keeps
only format ids 1, 2, 4, 10, 11, 13 (DAISY 2.02 / DAISY 3 / MP3 / EPUB 3
Full-Text+Audio / DAISY 2.02 Audio / DAISY 3 Audio). EPUB, BRF, PDF,
AZW3, text-only DAISY, and braille editions are dropped at the client
boundary because BookPlayer can't play them. Server stays
format-agnostic so future DODP-aware clients can still see the full
catalog.

**Bound-book completion:** DAISY 2.02 / 3 archives arrive as multiple
audio files plus an `.m3u`. `MediaServerBoundBookCompleter` (ported in
slice 1 for share links, `BookPlayer/Services/`) binds the folder into a
single audiobook entry once it's in the library. Opt-in
via `MediaServerSourceInfo.shouldBindFolder = true` (Hummingbird,
SoundBooth, and ABS share-link imports set it; Jellyfin / ABS folder
imports stay folder-shaped).

## ABS public share links (universal links)

Share a book with people who have no account on the server (6.0 base).

Sharer side: "Share Link" in the item options (`shareLinkOption` in
`ItemListView`, 6.0's `for items:` + select-before-acting style) opens
`ShareLinkSheetView`. Which server book it is comes from
`ShareLinkSource.resolve`, in this order: the item's own Audiobookshelf
stream link (an upstream `ExternalResource`, its saved connection found by
`hostId` through `IntegrationHostResolver`), the provenance recorded for
its downloaded file, the provenance a folder's files agree on
(`unanimousDescendantSource`, for a volume assembled from one multi-file
download), and with none of those plus an active ABS connection, a title
search on that server (exact match preferred; the sheet shows
"Title – Author" and records the match as provenance on the first
successful mint). Recorded provenance counts only when its server is saved
here: a download from a server that's since been removed is searched for
by title like a book with no provenance. An item that streams from or was
downloaded from another kind of server, streams from an ABS server not
saved here, or came in through someone else's share link (the
`public-share-link` sentinel) gets no row.

The server calls are in the Shared ABS service
(`AudiobookShelfConnectionService`, "Public share links (fork)"): the
media-item id lookup, `POST /api/share/mediaitem` (downloadable, expiry in
epoch ms or null), revoke, and the share page URL
`https://<server>/share/<slug>` (router base path kept). They use the
service's injectable `httpClient` and go to the item's *originating*
connection, and fail without a request when that connection is gone: no
other server is ever sent its item id. The active connection is used only
when no connection is named. Status mapping: 409 already
shared, 403 not permitted (sharing is admin-only; never "session
expired"), 401 session expired. Minted links are cached in standard
defaults (`MintedShareLinkCache`, `userSettingsMintedShareLinks`) for reuse
and revoke.

Recipient side: the URL is a universal link
(`applinks:audiobooks.thealvernaz.space` in both entitlements files; the
fork signs with `BookPlayer-NoCarPlay.entitlements`, picked by
`BP_ENTITLEMENTS` in the Mac's off-repo xcconfig; AASA served by an nginx
sidecar in the `audiobookshelf` stack on dockge, appID
`BJG744KCUJ.ca.cobd.bookplayer`, paths `/share/*` and
`/audiobookshelf/share/*`). `CommandParser.parse(activity)` turns a
`NSUserActivityTypeBrowsingWeb` activity for `…/share/<slug>` into
`Command.sharedImport`; the `bookplayer://` URL scheme refuses that
command, so a web page can't start a download from any server.
`SceneDelegate` passes a cold-launch web activity on, and
`ActionParserService` queues it like any action until the services
exist. `SharedLinkImportService` GETs `/public/share/<slug>` (keeping the
`share_session_id` cookie ABS sets; track URLs 404 without it), downloads
the tracks into one folder with zero-padded names (`001 - <title>.<ext>`,
an extension only when it's really an audio type, else from the MIME
type) through `SingleFileDownloadService`'s `fileNames` overload, and only
from the share's own scheme, host and port, since each request carries the
cookie. Folder and track names go through upstream's
`MediaServerFileNames.sanitize` and a 200-byte cap. Each share takes a
folder nobody else holds (`reserveFolder`: not in Documents, not filled by
a queued download, not recorded by another import), so two shares with the
same title become `Dune` and `Dune 2`; no random suffix, because the
folder's name becomes the book's title. The folder's
provenance is registered as landed, bind-on-complete, with the sentinel
`connectionId = "public-share-link"` (no server to report progress to), so
`MediaServerBoundBookCompleter` (`BookPlayer/Services/`) binds it once
it's imported. A sharer tapping their own link gets their copy opened
instead (dedupe by ABS library item id in the store). Without the app, the
link lands on ABS's own share page, which plays in the browser.

## Media-server provenance store

`MediaServerSourceStore` (`Shared/Services/MediaServer/`, both frameworks)
remembers which library items were downloaded from a media server and from
which server item. Streamed items don't need it: 6.0 links them with
`ExternalResource`. An entry moves through three stages:

1. pending, by request URL: registered when the ABS or Jellyfin service
   builds a download request (`createItemDownloadRequest`);
2. landed, by path under Documents: `MediaServerSourceTracker` moves it
   there when `SingleFileDownloadService.savedFilesPublisher` reports the
   file saved, with its real destination (never on `.finished`, which is
   sent before the move and for failed downloads too; an error drops only
   the pending entry). A multi-file download into a named folder
   registers the folder as landed up front (`registerLandingSource`);
3. resolved, by library `relativePath`: `ImportOperation` brings landed
   entries (a folder's with its contents) to the name the import really
   gave the item (`x-1.m4b` on a clash); a downloaded zip's entry goes to
   each extracted audio file or wrapping folder (sidecars skipped); a
   refilled missing book gets the entry at its own path. A file discarded
   on the import screen drops its landed entry (`ImportManager.removeFile`).

Resolved entries follow the library in `LibraryService`, where 6.0 also
keeps its other path-keyed stores: per item inside `moveItems` (from the
item's old path, prefix-aware, only for items that really moved), once in
`renameFolder`, per item inside `delete` (local and sync deletes both pass
there). It is not transactional with Core Data: it changes as each file
operation succeeds, so a failed library save afterwards (a `fatalError`
anyway) could leave them out of step.

`AppServices` owns the one instance and gives it to `LibraryService` at
setup (background launches too); `MainCoordinator` wires it into
`ImportManager`, the ABS and Jellyfin services, the tracker, the
completer and the environment. Reads are cached in memory until the next
write, with a per-folder summary for `unanimousDescendantSource`, because
the library's item menus ask about every row on screen. So the app has one
store, `MediaServerSourceStore.shared`: `AppServices` holds it and the
environment key defaults to it (not a placeholder, unlike the other
`@Entry` defaults), and the initializer takes its defaults explicitly so a
second app instance can't appear by accident. Tests make their own on a
suite. Keys and shapes `MediaServerSourceStore.resolved`
and `.pending` are the July ones (JSON data in standard defaults), so July
installs keep their entries; the landed stage is a new key.

Not in slice 1: progress reporting and the Tortuga-sync gating that read
the store (slice 4).

## Library export

The item options' Export (`shareOption`, `SimpleLibraryItem`'s
`Transferable` in `SimpleLibraryItem+SwiftUI.swift`): a book goes as its
real audio file (`.audio`, the original file, no staging copy), a folder or
bound book as a zip named after its title (`ShareExportArchiver`,
`NSFileCoordinator`'s `.forUploading`), both with a suggested file name
(the Mac's Save to Files needs one). Export is dimmed unless the file is
on this device (a book's file exists; a folder's books are all
downloaded), and the share sheet's preview shows the title. The dead
UIKit `BookActivityItemProvider` is gone.

## Share-extension web-URL imports

The share extension accepts plain URLs (not just local files). When the
host app comes back to the foreground, a `ShareImportFailureStore` (file
in App Group, NOT UserDefaults — cross-process sync there is unreliable)
gets drained and any failures surface as a persistent alert with a
VoiceOver announcement.

Cross-process state between the share extension and the host app uses
file-backed JSON at `containerURL(forSecurityApplicationGroupIdentifier:)`,
not `UserDefaults(suiteName:)`. Existing stores: `ShareImportFailureStore`,
`ShareCancelStore`.

MIME validation on downloads is layered: hard-reject
`text/html|text/plain|application/json|application/xml|application/problem+json`;
accept `audio/*` and the zip/m3u family; fall back to filename
extension for `application/octet-stream` or `application/download` or
missing types.

## Session-expired vs sign-in 401

Sign-in 401 = wrong credentials (different UX path). A mid-session
401/403 from a saved connection = `IntegrationError.sessionExpired`,
which only fires when `connection != nil`. The RootView alerts
special-case via `IntegrationError.isSessionExpired`.

## Task cancellation pattern

View-level `actionTask?.cancel()` on `onDisappear` AND
`try Task.checkCancellation()` inside the service immediately before
`connections.append` / `saveConnections` — both halves are required.
The inner check is load-bearing; without it, the in-flight sign-in
completes against a torn-down view and persists state for a connection
the user already cancelled.

## Pro-feature bypass policy

TestFlight bypasses are only for local/fork-owned features (icons,
themes, the fork's media-server progress sync). Tortuga's paid-backend
features (cloud sync, data-usage section) stay gated — bypassing would
be theft of service AND the server validates entitlement independently
anyway.
