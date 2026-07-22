# Fork architecture notes

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
audio files plus an `.m3u`. A bound-book completer waits for the queue
to drain then binds the folder into a single audiobook entry. Opt-in
via `MediaServerSourceInfo.shouldBindFolder = true` (Hummingbird,
SoundBooth, and ABS share-link imports set it; Jellyfin / ABS folder
imports stay folder-shaped).

## ABS public share links (universal links)

Share a book to people with no account on the server. Sharer side:
"Share Link" in the item options (ABS-sourced items only,
`ShareLinkSheetView`) mints an ABS public share (`POST
/api/share/mediaitem`, admin-gated, one active share per item) against
the item's *originating* connection, with picked expiry, and hands out
the web share page URL `https://<server>/share/<slug>`. Minted links
are cached in UserDefaults (`MintedShareLinkCache`) for reuse/revoke.

Recipient side: the URL is a universal link
(`applinks:audiobooks.thealvernaz.space` in **both** entitlements
files; AASA served by an nginx sidecar in the `audiobookshelf` stack on
dockge). With BookPlayer installed the link opens in-app:
`CommandParser.parseUniversalLink` → `Command.sharedImport` →
`SharedLinkImportService`, which GETs `/public/share/<slug>` (carrying
the `share_session_id` cookie ABS sets — track/cover URLs 404 without
it), fans the tracks out through `SingleFileDownloadService` with
zero-padded filenames, and registers the folder `shouldBindFolder` with
sentinel `connectionId = "public-share-link"` so progress reporting
stays off. Sharer tapping their own link gets the existing library copy
opened instead (dedupe by ABS library item id). Without the app, the
link lands on ABS's own share page, which streams in the browser.

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
