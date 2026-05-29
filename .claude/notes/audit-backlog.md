# Audit backlog

Open items from the multi-AI audit of `test/all-changes` at commit
`c6ebcb75` (2026-05-17). Critical and most High findings are already
shipped on this branch — the punch list below is what's left.

**Re-verify line numbers before editing any open item.** The branch has
moved since the audit base; references here are starting points, not
ground truth.

## SHIPPED (kept here as a "don't re-audit" record)

- **C1** Centralized Jellyfin client rebuild via `rebuildClient(for:)`;
  preserves customHeaders.
- **C2 minimum** Three-button alert (Sign In / Retry / Cancel) replaces
  auto-push-to-add-form on both Jellyfin and ABS root views.
- **C2 architectural** `IntegrationError.sessionExpired(serverName:)` on
  401/403 from saved connections. SignIn paths preserve existing `id` +
  `selectedLibraryId` on re-auth.
- **C3** Quick Connect cancel: stored `quickConnectCompletionTask`,
  cancel in `handleCancelQuickConnect`, `Task.checkCancellation()` inside
  `signInWithQuickConnect` right after auth round-trip.
- **C7** `ShareImportFailureStore` (file in App Group, not UserDefaults).
  Drained on `scenePhase=.active` in `LibraryRootView`, surfaced as
  persistent alert + `UIAccessibility.post(notification: .announcement)`.
- **H8** `URL.canonicalDedupKey` in `Shared/Extensions/URL+BookPlayer.swift`;
  both services dedup on canonical form.
- **H11** `@State actionTask: Task<Void, Never>?` in
  `IntegrationConnectionView`, cancel `.onDisappear`. Plus
  `try Task.checkCancellation()` inside both services' signIn paths.
- **H14 + H16** `Shared/Services/ShareDownloadSupport.swift` helper.
  UUID-prefixed unique destinations. Layered MIME validation.
- **H15** `Shared/Services/ShareCancelStore.swift` (file-backed App Group
  set). Best-effort `task.cancel()` in extension + durable shareID
  marker.
- **H18 + H19** ABS auto-prepend `https://` when scheme missing, trim
  username/password.
- **H20** `ThemeViewModel.destructiveColor` / `errorColor`. Replaces
  `.red` on destructive UI.

## OPEN — backlog (priority order)

- **H10** — `MediaServersView.swift:70–74`. `ServerRoute` doesn't carry
  id; rapid double-tap race (narrow window). Fix:
  `case jellyfin(id: String) / case audiobookshelf(id: String)`, pass id
  into the root view. Pair with tap-debounce on selection. Real bug,
  narrow window.
- **C5** — Custom-header CRLF / RFC 7230 token validation at the form
  level (`IntegrationConnectionFormViewModel`'s `normalized` field). Real
  CFNetwork already rejects invalid values at request time, so this is
  defensive input validation, not a vulnerability.
- **C6** — Share-extension filename sanitization beyond what
  `ShareDownloadSupport.sanitizedFilename` already does. Currently strips
  `..`, leading dots, `/`, `\`, NUL; caps length. Probably already
  sufficient; revisit if a user reports a weird filename landing.
- **H21** — ABS keychain not versioned. Argued against the audit's
  recommended envelope: doesn't improve live downgrade (App Store builds
  still can't decode array), current code already silent-version-detects
  array → single. Revisit only when format changes again.
- **N+1** — `AudiobookShelfConnectionService.applyCustomHeaders` doesn't
  skip Authorization case-insensitive. Currently safe by call ordering
  (`applyAuthenticatedHeaders` overwrites with Bearer). Defensive
  symmetry with Jellyfin's injector.
- **N+2** — ABS `handleSignInAction` doesn't normalize 400-499 like
  Jellyfin does (which maps to `IntegrationError.clientError`).
  Inconsistent error messages.
- **N+3** — ABS `pingServer` returns literal `"Unknown"` when /ping
  response isn't JSON. Should throw `unexpectedResponse`.
- **C4 cosmetic** — `MediaServersView.swift:295–308, 326–338`
  AddServerSheet inits. Refuted as a bug (cross-AI verified); cosmetic
  cleanup: wrap side effect inside the `@StateObject` autoclosure.
- **H9** — `ServerItem.id` namespacing across services. Downgraded to nit
  (both services use UUIDs, collision ~2⁻¹²²); fix is
  `"\(type.rawValue):\(id)"` if you ever ship it.
- **H12** — `handleCancelAddServerAction` forces `.connected`
  unconditionally. Downgraded — sheet dismisses before bad state
  observed; user-visible impact is a brief flicker during dismiss
  animation.
- **H13** — `handleSignOutAction()` doesn't clear Quick Connect.
  Downgraded — states are mutually exclusive in UI; would only matter
  under contrived flows.

## How to apply

Pick items from the open list when you want a focused improvement
session, but verify line numbers and current code shape first — these
references are starting points, not authoritative locations.

---

# 2026-05-29 audit (Claude Opus 4.7 + Gemini Pro + GPT-5)

Eleven parallel deep-readers covering both previously-audited surfaces
(Jellyfin/ABS/share-ext at `c6ebcb75`+11 days of drift) and previously-
unaudited surfaces (Hummingbird/DODP client, FLAC + import races,
Hummingbird Python server, NNELS plugin, openapis.ca-dodp plugin, watch,
sync/CoreData/SwiftData, widgets/intents, player/library/coordinators).
Then a two-round roundtable with Gemini 2.5 Pro + GPT-5 on the
security-critical Python surfaces.

## Architectural meta-findings

- **META-1**: `MediaServerSourceStore` should disappear; provenance moves
  onto `LibraryItem` as `originAuthority: MediaOrigin` + `externalId:
  String?`. Both AIs converged independently. Fixes the structural cause
  of 5 Criticals plus several Highs.
- **META-2**: VoiceOver silence is architectural — replace per-screen
  `UIAccessibility.post` patches with one `.announceStateChanges(of:)`
  modifier hooked into `.onChange(of: viewModel.state)`. Collapses ~8
  separate findings.

## SHIPPED in this audit

- **C11 + SY-H4 (Tortuga vs media-server)**: SyncService now holds an
  optional `MediaServerSourceStore` reference, set via
  `setMediaServerSourceStore` after `MainCoordinator` builds the store.
  - `scheduleMetadataUpdate` returns early for media-server items so
    progress ticks don't cross-talk Tortuga's record.
  - `scheduleDelete` partitions and only queues Tortuga jobs for
    locally-sourced items; media-server cleanup (e.g. Hummingbird's
    `returnBook` to NNELS) is owned by `handleMediaServerCleanup`.
  - `processContentsResponse`'s "remove items missing from Tortuga"
    pass now unions the keep-set with `mediaServerSourceStore
    .allResolved.keys` so a list-sync doesn't silently nuke every
    Hummingbird/Jellyfin/ABS item the user owns.
  Watch / previews / tests pass `nil` for the store and the gate
  short-circuits to "treat everything as Tortuga-owned" -- their old
  behavior.
- **C6 (session-expired re-auth dead-end)**: `prepareForReauth()` added
  to `IntegrationConnectionViewModelProtocol` as a default-impl
  extension. Each root view (Jellyfin / ABS / Hummingbird) now calls
  it before presenting the connection sheet from the session-expired
  alert, forcing the VM out of its init-locked `.connected` state into
  `.foundServer` so the existing `IntegrationServerFoundView` renders
  the password field. CustomHeaders / selectedLibraryId / serverName
  / URL are preserved. Applied to all three integrations because the
  same trap existed in all three. Audit had this as Jellyfin-specific.
- **C7 (ABS token in URL query)**: `AudiobookShelfConnectionService.createItemDownloadUrl`
  no longer appends `?token=<apiToken>`. The bearer is now carried by
  `applyAuthenticatedHeaders` (`Authorization: Bearer`) on the request
  alongside the custom headers. `MediaServerSourceStore` keys, background
  URLSession task descriptions, and proxy access logs no longer carry
  the token.
- **C9 (Watch KVO main-thread)**: `BookPlayerWatch/.../PlayerManager.swift`
  `observeValue` body now dispatches to `DispatchQueue.main.async`
  before mutating `observeStatus`/`playerItem`/`playbackQueued`. Closes
  the "AVPlayerItem deallocated while KVO still registered" crash
  signature. Phone-side has the same shape but no observed crashes —
  left untouched.
- **C1 (tracker collision)**: `MediaServerSourceTracker.finalize` was
  promoting per-file pending entries with bare `suggestedFilename` as
  the relativePath key, while library items use `<folderName>/<file>`.
  Two DAISY books with overlapping chapter filenames collided. Fix:
  `HummingbirdConnectionService.createResourceDownloadRequest` no
  longer calls `registerPendingDownload` — folder-level provenance from
  `setSource` is the only Hummingbird mapping. `BookmarkPuller` /
  `LoanExpiryScanner` lookups now resolve correctly.
- **C2 (Retry-After)**: `HummingbirdConnectionService` 503-poll Sleep
  clamped to `[1, 30]` seconds. Negative `Retry-After` no longer traps
  `UInt64`; huge value no longer pins the Task ~11 days.
- **C3 (player autoplay-finished)**: `PlayerManager.beginInitialSeek`
  completion now gates BOTH snapshot and queued-autoplay on `finished`.
  Superseded seeks no longer fire `play(autoPlayed:)` from the
  pre-supersession position (most audible on FLAC).
- **C10 (SwiftData try!)**: `SyncJobScheduler.handleFinishedTask`
  catches the persistence error, logs, and continues the queue rather
  than crashing the app.
- **C12 (delete cleanup return-on-error)**: `ItemListViewModel.handleDelete`
  bails before media-server cleanup runs when the local delete throws.
  Was the only Critical with real data-loss semantics: Hummingbird's
  `returnBook` would POST to NNELS (removing the loan) while the book
  still existed locally and lost its source mapping.

## OPEN — Critical

- **C4 (KADOS unbounded sessions)** — `hummingbird/protocols/kados/router.py:40`.
  Plain dict, no TTL/cap/reaper. Fix: `cachetools.TTLCache(maxsize=1024,
  ttl=86400)` + refresh on access. Same shape in `auth._VALIDATED`.
- **C5 (NNELS SessionExpired)** — `nnels/src/nnels/fetcher.py`. Centralize
  Drupal login-form detection in `Fetcher.get_raw`; raise `SessionExpired`
  rather than letting parser-returns-empty propagate. Remove catch-all
  `except Exception` at `metadata.py:172`.
- **C6 (Jellyfin re-auth dead-end)** — `JellyfinRootView.swift:108-116`
  + `IntegrationConnectionView.swift:107-117, 176-178`. Session-expired
  alert routes user to a `.connected` view with no password field, no
  sign-in button. Fix: introduce `.reauthRequired` state or split "has
  saved connection" from "currently authenticated."
- **C7 (ABS token in URL query)** — `AudiobookShelfConnectionService.swift:495-506`.
  Bearer token leaks into background URLSession task descriptions
  (on-disk), `MediaServerSourceStore` plist key (on-disk), every proxy
  log on the user's path. Fix: switch to `Authorization: Bearer` on
  download; re-key store by `(connectionId, itemId)`.
- **C9 (Watch KVO main-thread)** — `BookPlayerWatch/.../PlayerManager.swift:983-1015`.
  Mirror phone-side `DispatchQueue.main.async` wrap. Removes the
  `AVPlayerItem was deallocated while KVO still registered` crash.
- **C11 / SY-H4 (Tortuga vs media-server)** — `SyncService.swift:194-202, 312`
  + `ItemListViewModel.swift:483`. Tortuga delete/metadata-update fires
  for media-server items. Gate every Tortuga enqueue on
  `mediaServerSourceStore.source(for:) == nil` until META-1 lands.
- **DODP-C1 (log_on fail-open)** — `openapis_ca_dodp/client.py:_unwrap_body`
  first-child fallback + `_result_bool` default-True combine to
  authenticate against any 200 SOAP body with no Fault. For auth-shaped
  methods (`log_on`, `issue_content`, etc.), require the exact namespaced
  `<method>Response>` wrapper and the exact `<method>Result>` element.
- **WC-C1 / WC-C2 (Watch connectivity silent drops)** — GPT-5 disputes
  Critical → High; user-visible "I tapped pause but it kept playing" is
  trust-breaking. Fix: `WCSession.isReachable` guard + error handlers
  on every send; mutate watch UI only on reply/ack.

## OPEN — High

Approximately 30+ High findings across the eleven surfaces. See the
synthesized audit conversation for the full punch list; major themes:
- DODP/Hummingbird Python server hardening: defusedxml, KADOS rate
  limit on anonymous `authenticate`, `hmac.compare_digest` on API key,
  generic 500 instead of `str(e)`, JSON-body size cap, split-timeout
  `httpx.Timeout(connect/read/write/pool)`, concurrency semaphore.
- DODP plugin auth-fault classification fragility (substring matching on
  English `faultstring`; ignores HTTP 401/403 and `faultcode`).
- Bookmark sync last-writer-wins with no `updatedAt`.
- Multiple VoiceOver gaps (Jellyfin Quick Connect status, ABS module,
  watch loading overlays, widget BarView accessibility) — all subsumed
  by META-2.
- Jellyfin sortBy race + missing URL normalization + Quick Connect
  subscription survives sheet dismiss.
- Sync: `pruneStalePending` never implemented; SwiftData V1→V2 migration
  not crash-safe; `TasksDataManager.updateTaskModel` silently drops
  speed updates (Float/Double cast mismatch).
- Player: `initialSeekInProgress` stuck-true after `mediaServicesWereReset`;
  audio-session recovery has no global retry cap.

## OPEN — Medium / Low

Captured in the per-agent reports. Bulk are:
- defensive-symmetry items from the prior audit downgraded backlog
- VoiceOver gaps absorbed by META-2
- format/timeout/concurrency nits with no current user-visible impact
