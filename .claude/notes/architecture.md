# Fork architecture notes

> **Status on the 6.0 base (October 2026 catch-up).** Jellyfin Quick Connect
> and Audiobookshelf SSO are upstream now (#1566, #1567) and live in upstream's
> code, not here. The other fork features are being re-ported onto 6.0 one
> slice at a time on `catchup/upstream-6.0`; until a feature's slice lands,
> its section below still describes the July `test/all-changes` code. Each
> slice updates its section. Ported so far: the Audiobookshelf Folders tab,
> share links, the provenance store and the library export fix (slice 1);
> Hummingbird (slice 2); SoundBooth (slice 3); progress sync for downloads
> (slice 4).

The upstream TortugaPower BookPlayer is a local-files audiobook player.
This fork adds the Hummingbird media-server client, the SoundBooth store,
extras for upstream's Jellyfin and Audiobookshelf clients, and a
share-extension web-URL importer on top of that base. Don't assume "local
files only" when reading the code.

## Media-server integrations

They share the `MediaServerKind` enum
(`.jellyfin / .audiobookshelf / .hummingbird / .soundbooth`) that names a
downloaded book's source in the provenance store; see "Progress sync" for
how a downloaded book's position goes back to its server. A `.dodp` kind is
planned — see [dodp-direction.md](dodp-direction.md).

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

### Hummingbird (`Shared/Hummingbird/`, `BookPlayer/Hummingbird/`)

Talks to a self-hosted Hummingbird server (`cobdfamily/hummingbird`, port
8000 by default), which puts accessible libraries (NNELS today) behind one
REST surface through server plugins. 6.0 base since slice 2; its
bookmark sync (reporter and puller) since slice 4, see "Progress sync".

**Where it lives.** The connection data, the library item and
`HummingbirdConnectionService` are in `Shared/Hummingbird/` (both
frameworks, like 6.0's Jellyfin and ABS services) because 6.0's
`IntegrationConnectionStore` and `IntegrationConnectionPayload` are
internal to BookPlayerKit. The screens, the loan scanner and the
delete-return observer are in `BookPlayer/Hummingbird/`.

**Connections.** `IntegrationConnectionStore<HummingbirdConnectionData>`
under the July Keychain key `hummingbird_connection` and active-id key
`hummingbird_active_connection_id`, so July installs keep their servers.
The stored shape is July's six keys (id, url, serverName, userName,
password, customHeaders): the store's `userID` (the user name), `token`
(`"user:password"`, so an empty password isn't dropped as unusable at
launch) and `selectedLibraryId` (always nil) are computed. Auth is HTTP
Basic on every request, custom headers first and `Authorization` last;
login credentials go in the POST body, never the URL (0.3.1 dropped the
query form: it put passwords in access logs). A 401/403 from a saved
connection is `sessionExpired`; the login's 401 is
`URLError(.userAuthenticationRequired)`; the ping only checks for
`{"service": "hummingbird"}`. Every call goes through an injectable
`IntegrationHTTPClient`.

**Sign-in flow.** `HummingbirdConnectionViewModel` is 6.0's
`IntegrationConnectionViewModelProtocol` on the ABS view model's pattern:
`IntegrationConnectionFlowView(kind: .hummingbird)` (port placeholder
8000), password only so Connect goes straight to the password step,
credentials only to the URL Connect pinged, `prepareReauth` from the
session-expired alert, re-auth keeps the connection id. The user name is
trimmed; the password is sent as typed (Basic replays it every request).
`MediaServersView` reads the service from the `hummingbirdService`
environment entry, so upstream's init and its three call sites are
unchanged; `MainCoordinator` injects it at the root.

**Audio-format filter.** `HummingbirdLibraryItem.audioFormatIds` keeps
format ids 1, 2, 4, 10, 11, 13 (DAISY 2.02 / DAISY 3 / MP3 / EPUB 3
text+audio / DAISY 2.02 audio / DAISY 3 audio). The server stays
format-agnostic.

**Downloads** (`HummingbirdLibraryViewModel`). `/resources/{fmt}/{id}`
answers 503 + Retry-After while the server fetches the book; the poll
clamps Retry-After to 1...30 s and gives up after 20 minutes (injectable
sleeper and clock). The resource list and the file requests name the
connection the book was listed on, so switching servers during that wait
can't send one server's files with another's password. Non-audio
resources are dropped. One audio file is a pending download keyed by its
request URL (it lands wherever the download service saves it). Several
take a folder from `MediaServerDownloadFolders.reserveFolder` (shared with
share links): named after the title, "Dune 2" on a clash, recorded as
landed with `shouldBindFolder`. Their files are ordered by `localURI`
(`localizedStandardCompare`, July's order: the server lists zip storage
order, which DAISY doesn't make the reading order), flattened by
`volumeChildFileNames` and numbered ("001 - Disc 1 - 01.mp3"), because the
import orders a folder by name. No playlist file: 6.0's import makes every
file in a folder a part, so July's `playlist.m3u` became a junk part. The
real reading order (NCC / OPF spine) is a server follow-up. The banner
announces each status change to VoiceOver.

**Loans.** `HummingbirdLoanExpiryScanner` (launch and every foreground,
owned by `MainCoordinator`) takes Hummingbird entries whose due date has
passed: returns each to its own connection (failure logged, the delete
still happens), then deletes it like a user's delete (stops the player if
it's the loaded book, `.deep`, rebuilds the parent, schedules the sync
delete) and posts `.libraryItemsRemoved`, which `MainView` answers with a
list reload. A failed delete keeps the entry for the next scan. The entry is
checked again before the return and after it, and only the same entry at the
same path is deleted: a book moved (or another put in its place) while the
return was out is left for the next scan to find where it is now. An expired
copy of a book that another copy still has on loan (borrowed again) is
deleted without a return, since a return ends the book's loan on the server.
NNELS has no due dates, so it does nothing there. A user's delete returns the book
through `MediaServerDeletion` (see the provenance store section) and
`HummingbirdLoanReturns`.

**Bound-book completion.** `MediaServerBoundBookCompleter` binds the
folder into one book once it's in the library (opt-in through
`shouldBindFolder`; Hummingbird, share links and SoundBooth set it).

### SoundBooth (`Shared/SoundBooth/`, `BookPlayer/SoundBooth/`)

Downloads what a SoundBooth Theater (soundbooth.app) account owns: audio
dramas and audiobooks sold as titles and as season bundles. 6.0 base since
slice 3. The API (`api.soundbooththeater.com`) is the private one its web
player speaks, worked out from that player; `SoundBoothAPIClient`'s header
comment lists what it insists on. The client key in
`SoundBoothAPIClient.Configuration.production` is SoundBooth's own public
key from its web player: it names the client, grants nothing without an
account's session, and isn't a secret of ours, so it's in the code rather
than an xcconfig.

**Where it lives.** Models, the API client, the transport, the connection
data and `SoundBoothConnectionService` are in `Shared/SoundBooth/` (6.0's
connection store is internal to BookPlayerKit); the screens and the library
view model are in `BookPlayer/SoundBooth/`.

**Connections.** `IntegrationConnectionStore<SoundBoothConnectionData>`
under the July keys `soundbooth_connection` and
`soundbooth_active_connection_id`. The stored shape is July's five keys (id,
email, userId, jwt, sessionCookie); the store's `url` (the one API address),
`userID` (the account's id) and `token` (the JWT) are computed. A record
with an empty id or JWT is dropped at load, and a sign-in answer without
either is refused. Signing in to the same account again keeps its
connection id, which downloaded books' provenance names; a renewal that
lands on another account adds that one instead.

**Sign-in.** Passwordless: the account's email, then the code SoundBooth
emails to it, verified for a 30-day JWT and the `iglu.sid` cookie the same
answer sets (the data calls want both). Its own small sheet
(`SoundBoothConnectionView`), since the shared flow is built around a
server address and a password. Closing the sheet cancels the request in
flight and the service checks for that before saving. Spaces in a pasted
code are dropped. Once signed in, a 401/403, or the API's code 50230 (sent
with a 200), is `sessionExpired`: the library offers Sign In with the email
filled in. The sign-in calls themselves never say a session expired (there's
none yet): a 401/403 there is a plain refusal. The API's refusals show its
own words ("That code has expired") through `IntegrationError.serverMessage`.

**Transport.** `SoundBoothHTTPClient` keeps no cookies at all: 6.0's shared
client keeps a jar (Audiobookshelf's OIDC needs it), and a stale `iglu.sid`
riding along makes SoundBooth refuse a new sign-in. The session cookie is
sent by hand.

**Library** (`SoundBoothLibraryViewModel`, rules from July, worked out on a
bundle-heavy account and an à-la-carte one). The owned set
(`library-elements/list`) is required; `series/list` and `groups/list`
name and order series and seasons and are best-effort; the catalog
(`items/list`) is asked only when an owned title's series has no name,
since its populated references name the series and seasons the lists leave
out. Top level: series, then season bundles of a series nobody names, then
titles of no series under "Other Titles". A series: its seasons in order
(bundles and seasons owned episode by episode), then titles outside a
season, split into sections by format (audiobook, cinematic, immersion,
bonus, then others by name, then what has none) when it's owned in more
than one. A bundle lists no episodes of its own: they're fetched when the
season opens (`items/list` with its `groupId`) and kept until a refresh.
Episodes not out yet show "Releases <date>" and don't download; release
times parse with and without fractional seconds.

**Downloads.** A title is a folder named "Series - Title" (through
`MediaServerDownloadFolders`, "… 2" on a clash), its chapters
"001 - <chapter>.mp3" numbered by position (SoundBooth's own `number` can
repeat), recorded as landed with `shouldBindFolder` so the completer binds
it into one book. A season downloads its released episodes as one book,
"E001 001 - ….mp3", episodes numbered among those that have chapters.
"Trim Repeated Credits" (on unless turned off, kept in the shared defaults)
keeps only the season's first opening credits and last closing credits; a
credits chapter in an episode's first half counts as opening. A chapter's
audio is where `resources/play` redirects: the redirect is read, not
followed, and never replaced by a URL built here (July saved CacheFly's
HTML 404 page as chapters). Every chapter resolves before anything is
queued, at 192k; the CDN requests carry no credentials. The book starts at
the account's newest saved position the plan can place, plus the length of
the kept chapters before it (`seedTime`, applied once when bound); nothing
under a second, a missing length, or a failure to read the positions means
no seed. Positions are only read: SoundBooth's apps write theirs through
PowerSync. A download, and a season's episode list, goes out with the
account the library on screen was listed for (`listedConnectionId`),
whichever is active at the tap: logging out of the active account makes
another one active, and the screen then reloads that one's library from the
top. Only the latest library load's answer is kept, and a season's episodes
only for the listing they were asked under, so a slow answer for the
previous account can't land after the new one's. An account signed out
meanwhile asks nothing, and is checked once more just before anything is
queued.

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
   builds a download request (`createItemDownloadRequest`), or for a
   one-file Hummingbird book;
2. landed, by path under Documents: `MediaServerSourceTracker` moves it
   there when `SingleFileDownloadService.savedFilesPublisher` reports the
   file saved, with its real destination (never on `.finished`, which is
   sent before the move and for failed downloads too; an error drops only
   the pending entry). A multi-file download into a named folder
   registers the folder as landed up front through
   `MediaServerDownloadFolders.reserveFolder` (share links, Hummingbird).
   When the last download into that folder ends
   (`SingleFileDownloadService.folderDownloadsEndedPublisher`, sent from the
   completion step after that download's own move), the tracker lets go of
   the folder's landed entries if the folder is missing or empty (hidden
   files aside); one that can't be listed keeps them, and the folder itself
   is never deleted (the import may already hold it). `ImportOperation`
   records provenance before it removes a source from Documents, so a
   missing folder never still holds entries the import was about to take;
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

A user's delete (`ItemListViewModel.handleDelete`, two calls around
upstream's delete) reads `MediaServerDeletion.snapshot` first: the entries
at and under each deleted item, minus a folder's own entry on "folder
only". Afterwards, thrown or not, the server items no resolved entry still
names (kind, connection, item id) are posted once each as
`.mediaServerItemsDeleted`. Identity, not path: a "folder only" delete's
moved books, the rest of a batch that failed partway and another copy of
the same book all keep their entries, so none of them is reported. Sync and
the loan scanner delete without it.

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

Audiobookshelf and Jellyfin entries also carry the server's `hostId` (the
connection's `stableHostId`, recorded when the download starts and kept
current by `MainCoordinator`), which is what progress sync needs; see the
next section. The July Tortuga-sync gating that read the store isn't on the
6.0 base: the fork's builds point `BP_API_DOMAIN` at a placeholder, so no
BookPlayer account can sign in and nothing reaches BookPlayer's server.

## Progress sync (6.0 base, slice 4)

Upstream 6.0 already pushes the position of LINKED books (stream imports,
streamed-then-downloaded books, sync-adopted links) to their Audiobookshelf
or Jellyfin server, on every tier with no BookPlayer account:
`LibraryService.updatePlaybackTime` puts providerName/providerId/hostId on
the progress update, `SyncQueueService` queues an `externalUpdate` task in
that provider's lane (10 s throttle, coalescing, retries), and
`ExternalUpdateProgressOperation` finds the connection by `hostId`
(Jellyfin: UserData write; Audiobookshelf: PATCH `api/me/progress`). An
unresolved host is consumed, never retried, so a removed server's updates
are dropped for good, not kept for later.

Downloads ride the same path, one writer by construction: in
`updatePlaybackTime` the link's keys win, and only a book with no streaming
link gets keys from its provenance (`MediaServerSourceStore.pushKeys`). So
a download that refilled a linked book, or adopted a link through sync,
still has exactly one writer. `pushKeys` answers only for an Audiobookshelf
or Jellyfin entry with a `hostId`, and not for the tracks of one multi-file
item (another entry for the same server item in the same folder: a zip
without a wrapping folder lands its tracks as separate books); copies in
different folders each push, as upstream's streamed copies do. It checks
kind and host first and caches its answer per path until the next store
write, because playback asks on every tick. Coalescing in
`SyncQueueRepository` matches (providerName, hostId, providerId), so the
same item id on two servers stays two tasks (upstream matched by id alone).
Hosts stay current: `MainCoordinator.refreshProvenanceHosts` sets each
entry's `hostId` from its connection at launch and whenever the
Audiobookshelf or Jellyfin connections change (observation reports a change
before it lands, so the refresh runs on the next main-actor turn); an entry
whose connection is gone keeps its last host, so adding the same server
again resumes its pushes.

Changes from July for Audiobookshelf/Jellyfin downloads: they push on every
tier (July: TestFlight or Pro), Jellyfin gets UserData writes instead of a
playback session (no "now playing" in its dashboard), and the end of a book
isn't flagged finished on the server (upstream doesn't for streamed books
either; the last position, about 100 %, still goes).

Hummingbird isn't an upstream provider, so it keeps a fork path, July's on
the 6.0 base. `HummingbirdProgressReporter` (owned by `MainCoordinator`)
posts a bookmark `{currentTime, duration, progress, isFinished}` to
`POST /protocols/hummingbird/v1/bookshelf/bookmark/{node_id}` on the
connection the book's provenance names (`reportBookmark`, failing closed
for a removed connection): a `.bookPlaying` tick at most every 15 s per
book, the position on `.bookPaused`, and on `.bookEnd` the book it last
reported, finished or not as the player now says. `.bookEnd` names no book
and 6.0 posts it twice, the second after the next book loaded, so the
reporter never reads `currentItem` then: it forgets the book once its end
is reported and whenever another book is loaded. One bookmark per book is
on its way at a time, the newest waiting. No gate, failures logged.
`HummingbirdBookmarkPuller` (launch, foreground, `.importItemsInserted`)
asks the server (`fetchBookmark`, GET) of each Hummingbird book still at 0,
unfinished and not loaded in the player, once per launch, and applies a
position above 0 (held to the book's length) only if, when the answer
arrives, the same book (uuid) is still at that path with the same
provenance, still unplayed and still not the player's. The player check is
what protects a book the user just started: playback saves its position a
couple of seconds late (`scheduleSaveContext`), and the library's reads
(`getSimpleItem`, a dictionary fetch) see only saved values. Upstream
decided media servers' positions are never pulled; that's about
Audiobookshelf and Jellyfin. The Hummingbird puller (DAISY bookmarks) and
SoundBooth's one-time download seed are fork features outside it.

SoundBooth sends nothing: its apps write positions through PowerSync.

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

## Share-extension web-URL imports (6.0 base, slice 5)

The share extension takes web links as well as files: an http(s) link
to a file BookPlayer imports (`ShareDownloads.supportedFileExtensions`:
the audio formats, mp4/m4v/mov and zip). The activation rule
(`BookPlayerShareExtension/Info.plist`) keeps upstream's four file types
and adds `public.url` without `public.file-url`, so a PDF from Files
still doesn't offer BookPlayer (July's rule did). Any other link the
share sheet hands over is dropped, so an unsupported page shows an empty
list.

Done copies files as upstream does (a failed copy is now recorded) and
starts one background session for the share's links, with an identifier
of its own (`<bundle>.shareext.<uuid>`): a background session may only
be used by one process at a time, and an extension process can take a
second share before it's gone. Both processes build the session from
`ShareDownloads.sessionConfiguration` (shared container = the App
Group, launch events on, serial delegate queue) and hand it the same
delegate, `ShareDownloadReceiver`:

- a finished download is judged and moved into the shared folder
  (`ShareDownloads.finish`): an error status, then July's layered type
  rules (web and error types never; audio, video and archives always;
  the name's extension decides the rest). The name is the server's
  suggestion or the link's, through upstream's
  `MediaServerFileNames.sanitize`, an extension put back when sanitizing
  took it, cut to 200 bytes, numbered on a clash ("Dune 2.m4b"; July
  put a uuid in front of every name, so in the book's title). Upstream's
  shared-folder watcher imports it;
- every task error is a failure, cancellation included (nothing in
  BookPlayer cancels a share's download); a cancellation the system made
  because the app was force-quit says so;
- each task's end is marked done in `ShareDownloadSessionRegistry`
  after its file or failure is written (same serial queue).

Reconnecting: iOS wakes the app for a share's session once the
extension is gone (`BackgroundSessionWakeCoordinator` owns the
`shareext.` prefix: it recreates the session through
`ShareDownloadSessions.activate` and answers when its events finish,
with nothing to settle). iOS never relaunches an app the user
force-quit, so the app also reconnects, at launch and on every
foreground, to registry sessions older than 2 minutes. The margin is
there because the extension may still hold the session just after a
share; it's a margin, not proof. A session is closed
(`finishTasksAndInvalidate`) only once its events are known delivered:
the system's "finished events", or every task the share started marked
done. It's forgotten in `didBecomeInvalidWithError`, after its last
delegate call; the extension forgets the sessions it saw through itself
the same way. A record older than a week is dropped.

Failures (`ShareImportFailure`, with a `Reason`, not text: the extension
bundles no strings, so July's extension-written messages were the raw
keys) wait in the App Group until shown. `LibraryRootView` reads them on
first load and every activation into an alert plus a VoiceOver
announcement, and removes exactly the ones shown when OK is pressed.
The alert's value is cleared and set again on every activation, since
SwiftUI keeps the value of an alert it dropped under a cover and would
never show it.

Cross-process state between the share extension and the app lives in
files in the App Group container, one file per record
(`share-import-failures/<id>.json`, `share-download-sessions/<id>.json`
plus `<id>.done/<task>`), so neither process ever reads, changes and
writes back what the other is writing. July's single-file
`share-import-failures.json` and `share-canceled.json` are deleted at
launch; its `ShareCancelStore` is gone (nothing could ever write it:
Done blocks the extension's window before Cancel could follow it).

## Player clock: the seek in flight and the paused position (6.0 base, slice 6)

Upstream 6.0's `PlayerManager` judges every player reading against the
last position it trusts (`PlayerTimeSample`, from upstream's CarPlay fix
#1605) and seeks back when the player jumps to a file's start on its own.
The fork moved that state out of `PlayerManager` into `PlayerClock`
(`BookPlayer/Player/PlayerClock.swift`, a value type with tests) and added
one state, a seek of ours in flight:

- A user seek (`jumpTo`, the resume seek in `initializeChapterTime`, smart
  rewind) goes through `seekPlayer(to:)`: readings are held back until the
  seek lands (a reading within 1.5 s of the target, or the seek's own
  completion), so a tick that still reads the old position can't become
  the baseline. Without it, restarting a chapter from more than 30 s in
  could be undone (upstream #1641/#1664: the landed 0.1 judged against the
  stale old position read as a snap to the start). Not reproduced on a
  simulator; the code allowed it.
- Bounded: a seek whose completion doesn't come stops holding readings
  back after 3 s, and they're judged against its target as before, so the
  original race can come back after that. A pause inside that window
  takes no snapshot (the seek's own landed save covers it).
- Where a seek lands is saved (book time for bound books). Completions are
  matched by a per-seek id, so a late one can't settle a newer seek, even
  to the same time.
- On pause, before `.bookPaused` is posted, the player's own reading is
  saved when it's on the current chapter's file (and attached to the
  player), nothing of ours is in flight, and the clock takes the reading,
  so listeners (the Hummingbird reporter) don't get the last 1 Hz tick.

Not re-ported from July: the FLAC fast start (loading flac/ogg/opus/wav
without precise timing, the #1504 fix) and the seek-tolerance stack built
to repair what it caused (zero then bounded tolerances, the autoplay gate).
6.0 loads local and cloud files with precise timing and seeks with default
tolerance, so long FLAC books start slowly again, as in upstream.

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
themes). Progress sync needs none: it follows upstream's every-tier gate
(slice 4). Tortuga's paid-backend
features (cloud sync, data-usage section) stay gated — bypassing would
be theft of service AND the server validates entitlement independently
anyway.
