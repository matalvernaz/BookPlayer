# Audit backlog

> **Status on the 6.0 base (October 2026 catch-up).** The SHIPPED list
> records fixes made to the July `test/all-changes` code. Several of those
> code paths are now upstream's own (multi-server, Quick Connect, ABS
> token handling) or are being re-ported slice by slice on
> `catchup/upstream-6.0`; re-check an item against the 6.0 code before
> relying on it.

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
  Slice 5 (6.0 base): one file per failure, structured reasons with the
  text made in the app, removed only once shown.
- **H8** `URL.canonicalDedupKey` in `Shared/Extensions/URL+BookPlayer.swift`;
  both services dedup on canonical form.
- **H11** `@State actionTask: Task<Void, Never>?` in
  `IntegrationConnectionView`, cancel `.onDisappear`. Plus
  `try Task.checkCancellation()` inside both services' signIn paths.
- **H14 + H16** `Shared/Services/ShareDownloadSupport.swift` helper.
  UUID-prefixed unique destinations. Layered MIME validation. Slice 5:
  replaced by `ShareDownloads` (same MIME rules; names numbered on a
  clash instead of a uuid prefix; upstream's sanitize).
- **H15** `Shared/Services/ShareCancelStore.swift` (file-backed App Group
  set). Best-effort `task.cancel()` in extension + durable shareID
  marker. RETIRED in slice 5: unreachable. Done calls `loadAndBlock`,
  which disables the extension's window, so Cancel can't follow Done,
  and Cancel before Done has no tasks.
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
- **C6** — Share-extension filename sanitization. Slice 5: upstream's
  `MediaServerFileNames.sanitize` (replaces `<>:"/\|?*`, trims `_` and
  `.`), an extension restored when that took it, 200-byte cap. Revisit
  only if a weird name lands.
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
  of 5 Criticals plus several Highs. On the 6.0 base streamed items carry
  upstream's `ExternalResource`; downloads still use the store (slice 1,
  which also moved its path upkeep into `LibraryService`). Whether
  downloads become `ExternalResource` links is the slice 4 question.
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

---

# 2026-06-19 follow-on: unindexed-FLAC seek audit

Historical (July code on test/all-changes). Not re-ported on the 6.0 base:
see architecture.md "Player clock" for what replaced it.

Focused re-audit of the unindexed-FLAC seek/position path in
`BookPlayer/Player/PlayerManager.swift` (the `unindexedFormats` / `seekTolerance`
/ `beginInitialSeek` / `snapshotPlayerPosition` machinery). Verdict: the
subsystem is sound — the core design (drop the precise-timing flag for
`["flac","ogg","opus","wav"]`, bounded 1s seek tolerance, persist landed-not-
requested time, real `loadGeneration &+= 1` gating) is correct.

## SHIPPED

- **F1 (completes C3)** — C3 gated the `beginInitialSeek` completion on
  `finished` but still cleared `initialSeekInProgress` *before* that guard and
  left the autoplay handoff inline. A user skip during a slow FLAC resume-seek
  superseded the initial seek (`finished=false`), which cleared the gate and
  bailed without resuming — playback could stick silent (or start from the
  pre-skip position) because `jumpTo`'s completion never honored
  `playbackQueued`. Fix: extracted the handoff into
  `resumeQueuedPlaybackIfReady()`, called from the `finished` branch of every
  seek completion (`beginInitialSeek`, `jumpTo`, `handleSmartRewind`); clear
  `initialSeekInProgress` only on `finished`, so whichever seek lands last
  resumes from the landed position. Reasoned, not yet device-reproduced.
- **F2** — removed dead `initializeChapterTime(_:)` (no iOS caller; the only
  caller is the watch's separate `PlayerManager`). It lacked the
  landed-time-persist + generation gate the live seek paths have.

## OPEN — Low (flagged, not fixed)

- **F3** — bound-book chapter-crossing skip calls `loadChapterMetadata` without
  bumping `loadGeneration`, so a stale same-generation seek completion from the
  previous chapter can `snapshotPlayerPosition` against the new chapter. Mostly
  defused by the `playerSeconds.isFinite` guard. Bound books are DAISY MP3 in
  practice, so low FLAC relevance.
- **F4** — `jumpToChapter` uses symmetric ±1s tolerance; on a single-file
  *chaptered* FLAC it can land ~1s before the boundary, in the previous chapter,
  until `updateTime` flips back. Asymmetric (`toleranceBefore=.zero`,
  `toleranceAfter=1s`) avoids it without reintroducing the forward-stall. Only
  matters if chaptered single-file FLAC exists in the library.
- **F5 (test gap)** — the subsystem has no regression tests. A real F1 test
  needs a fake `AVPlayer` (no injection seam today: `audioPlayer` is a
  `private var = AVPlayer()`) AND a fake `AVAudioSession` (else `play()` can hit
  the non-TestFlight `fatalError`). Test-infra investment; deferred.

Related: the 2026-05-29 "Player: `initialSeekInProgress` stuck-true after
`mediaServicesWereReset`" High item — F1 centralizes gate-clearing on every
landed seek, which helps but doesn't fix the reset path (no seek follows a
reset). Still open.

---

# 2026-07-12 media-server audit (roundtable: GPT-5 / Gemini Pro / Claude Opus, 3 rounds, all 83 files)

## SHIPPED in this pass

- **Cancellation misclassification (systemic).** `URLError(.cancelled)` now
  treated as cancellation everywhere via `Error.isCancellation`
  (`BP+ErrorAlerts.swift`); all 30 `catch is CancellationError` sites
  converted. This was the "random unreadable dialog": debounced search /
  onDisappear cancelled in-flight requests and surfaced them as errors.
- **`errorAlert` rewrite.** Writable `isPresented` binding (was `.constant`),
  and `LocalizedAlertError` returns nil for cancellations as a backstop.
- **Search races.** Ownership-guarded `defer` (`if !Task.isCancelled`) so a
  superseded fetch can't clobber its replacement's `fetchTask` handle;
  post-await `Task.isCancelled` guards before commits; Jellyfin
  `sortBy.didSet` cancels in-flight fetch + handles global search;
  `dropFirst()` moved ahead of `debounce` in all 6 pipelines (was swallowing
  the first query); ABS empty-page pagination termination.
- **Auth.** Failed sign-in no longer clears `pendingServer`/`pingedURL`
  (retry works); `prepareForReauth()` on JF + ABS VMs (mirrors Hummingbird)
  and root-view recovery buttons route to it — the old path dead-ended in a
  logout-only details view; Quick Connect exchange task tracked + cancelled
  (NOTE: May audit item C3 claims this shipped before — it had regressed);
  SoundBooth auth tasks owned by the VM and cancelled on sheet dismissal;
  connection-form actions disabled while loading; ABS + Hummingbird stop
  trimming passwords (usernames still trimmed); `targetConnectionId`
  retargets after Add Server; JF `send` attributes 401s to the request-time
  connection; deleting a non-active JF connection revokes its token.
- **Cross-server routing.** Hummingbird `fetchBookmark`/`returnBook` take
  `connectionId`; ABS + HB `wrapWithCustomHeaders(_:connection:)` overloads
  so progress reports carry the item's connection headers (was leaking the
  active server's proxy credentials to the originating server).
- **Loan-expiry scanner.** `.deep` delete (`.shallow` promoted chapter files
  to loose items instead of removing them); keeps the source mapping when
  the delete fails so cleanup retries next scan.
- **Provenance.** `MediaServerSourceStore.moveSources(from:to:)` +
  migration calls at all 4 `ItemListViewModel` move sites (moves used to
  sever progress sync); JF/ABS root-landed downloads re-wired to
  `registerPendingDownload` via `registerItemDownloadProvenance` (the
  "follow-up" both services' comments promised); Hummingbird single-file
  downloads register pending provenance (were never syncing progress).
- **Progress reporting.** All three reporters serialize sends (older
  in-progress request can no longer overwrite a newer pause/finish on the
  server); JF session id cleared only after the Stopped POST; new
  `.bookStopped` notification posted from `PlayerManager.stopPlayback()`
  (direct stop used to discard up to a throttle window of progress);
  `.bookPaused` posted after the position snapshot (was ~1s stale);
  dispatcher throttles before the source-store decode.
- **A11y.** Narrator folded into the details-screen VoiceOver label;
  grid edit-mode selection exposes `.isSelected`; navigable rows get a
  VoiceOver hint; custom-header fields have persistent labels; server
  delete requires confirmation; Hummingbird details sheet restores the
  previously active connection on dismiss; `BPNavigation.dismiss` assigned
  in `.onAppear` (was `.task`, losing early dismiss calls); SoundBooth
  download-error alert attached once at the root (was bound at every
  drill-down level); hardcoded English localized (tabs, details sections,
  SoundBooth season controls, ABS browse categories) — new keys in
  Base + en Localizable.strings.
- **ABS decoding.** List responses decode lossily (`FailableDecodable`) so
  one malformed record doesn't fail the page.

## DEFERRED (deliberate, with reasons)

- **Keychain persist hardening** (swallowed `set` failures; failed remove
  can resurrect an account on relaunch). Failure requires a locked keychain
  under which any fallback write also fails; no meaningful recovery without
  rollback plumbing through every persistence call site. Already logged.
- **ABS/JF folder-download provenance.** `MediaServerSourceTracker`
  predicts root-landed filenames; folder downloads need a folder-aware
  finalize before they can register. Same shape as the old follow-up.
  **Done on the 6.0 base (slice 1):** the landed stage keys a download by
  its real path under Documents and the import resolves it to the name it
  gets in the library; see architecture.md, "Media-server provenance
  store".
- **Bound-book completer batch verification** (promotes on first file
  event). Needs an expected-file-count in the pending record — small data
  model change, do with the folder-provenance work. Still open on the 6.0
  base, and it now covers share-link imports too: a folder imported
  before all its tracks arrived binds what's there, and the late tracks
  land as a second folder.
- **SoundBooth progress write-back** — seed-only by design.
- **Two downloads of the same server item at once** (a double tap, a
  retry before the first finishes) share one pending provenance entry,
  keyed by request URL: the first to land takes it and the other copy gets
  none, silently. Small; would need a per-task key (6.0 base, slice 1
  review).
- **`TagsFlowLayout` infinite-width** on unbounded proposals — latent,
  constrained by the details VStack today.
- **Per-kind row labels** (folder vs author vs series) — shipped a generic
  "opens a folder" hint instead; per-kind needs per-backend cell changes.

# 2026-10-25 catch-up, slice 2 (Hummingbird on the 6.0 base)

## FIXED in the port (July bugs)

- Six string keys the July screens used never existed, so VoiceOver read
  the raw key names (the banner's dismiss button among them). The banner's
  X now uses upstream's `voiceover_close_button`; the rest are new
  `hummingbird_*` keys in every table.
- The active connection was a computed `UserDefaults` passthrough that
  `@Observable` couldn't see, so switching servers didn't refresh views.
  It's 6.0's `IntegrationConnectionStore` now.
- The ping mapped a 401 to "session expired".
- DAISY files were saved under their bare names, so two discs' `01.mp3`
  collided; folders got " (bookId)" appended, which became the book title
  VoiceOver read; a `playlist.m3u` written first became a junk part of the
  bound book. See architecture.md, "Hummingbird".
- A share (or now a DAISY book) whose downloads all failed kept its folder
  reservation, so the next book with that title became "Dune 2" (Sonnet,
  slice 1 review): the folder is let go once its last download ends with
  nothing in it.

## OPEN

- **Relaunch mid-download.** The download queue is in memory, so after the
  app is killed mid-download nothing reports the folder's end and a stale
  reservation survives (the next same-title book becomes "Dune 2").
- **An empty leftover folder still holds its name.** When every move into
  a folder fails, the folder stays (empty) until the import screen
  discards or imports it, and `reserveFolder` treats it as taken. Reusing
  an empty, unreserved folder needs the same care about an import that may
  already hold it.
- **"Delete folder only" on a mapped folder the completer hasn't bound
  yet** leaves loose files with no provenance: the loan isn't returned and
  the scanner can never expire it. The delete dialog only offers "folder
  only" for plain folders, so a bound DAISY book can't get here.
- **Reading order** follows the files' paths in the book (numbers compared
  as numbers), July's order. The real one is the DAISY NCC (2.02) or OPF
  spine (3) through SMIL; best read once on the server, which holds the
  zip. Once the server can say its list is in reading order, the client
  should use the list's order.
- **One-file books take the server's file name** (Content-Disposition, or
  the URL's last component), so an MP3 without a title tag imports as
  "01". July did the same; naming the file after the title needs a
  root-level `fileName` on the single-file download path.


# 2026-10-25 catch-up, slice 3 (SoundBooth on the 6.0 base)

## FIXED in the port (July bugs)

- When `resources/play` didn't redirect, July downloaded a URL it built
  from the chapter id, and CacheFly answers some of those with an HTML 404
  page, which was saved as the chapter's MP3. Now only the redirect's
  `Location` is used (resolved against the request, so a relative one
  works), anything else fails the download before a file is queued, and a
  300 or 304 no longer counts as a redirect.
- Chapter files were named by SoundBooth's `number`, which can repeat, so
  two chapters could get one name and the second was lost. They're
  numbered by position now.
- Two titles with the same name (and series) downloaded into one folder
  and became one book. Folders are reserved now: the second is "… 2".
- A download's provenance named whichever connection was active when it
  finished, not the account the title was listed for, and was written
  under the Documents folder name, which the import can change. It's
  captured at the tap and goes through slice 1's landed stage now.
- Every refusal from the API read "Unexpected server response"; SoundBooth's
  own words show now ("That code has expired").
- The API's invalid-session code (50230, sent with a 200) wasn't treated
  as an expired session.
- With two accounts saved, logging out of the active one from inside the
  library left its titles on screen while the other account became
  active, and a tap went out with the other account's session. Downloads
  now name the account the library was listed for, and the screen reloads
  the new account's library.

## OPEN

- **CDN tokens can run out on a long download.** Every chapter's URL is
  resolved before anything is queued, and each redirect carries a CacheFly
  path token that expires about two hours after it's issued (seen in July;
  an older URL form kept serving past its expiry, this one may not). A big
  season on a slow connection could reach its last chapters after that,
  and those files would fail on their own (the bound book would miss
  them). Resolving each chapter just before its download starts needs a
  hook in `SingleFileDownloadService`.
- **July's "row disappeared" report** (a library row gone after a
  download) was never reproduced, on July's code or on this port.
- **A release time that doesn't parse** counts as released, so a preorder
  episode with an odd timestamp would offer a download that then fails.
  Both formats SoundBooth sends parse.
- **No progress write-back** (seed only, decided): SoundBooth's apps write
  positions through PowerSync. Slice 4 gives the dispatcher a no-op
  SoundBooth reporter.
- **The end of a downloaded book isn't flagged finished on its server**
  (slice 4): Audiobookshelf and Jellyfin downloads use upstream's push,
  which sends positions only (streamed books have the same gap). July's
  reporters sent `isFinished`. A follow-up for both.
- **A removed server's progress is dropped, not kept**: the push consumes
  an update whose host doesn't resolve (upstream's rule), so positions
  played while a server is removed never reach it if it's added again. An
  edited address loses at most one update (about 10 s) before the host
  refresh picks it up.
- **6.0 posts `.bookEnd` twice** (`PlayerManager`: in `markAsCompleted` and
  again after `playNextItem`, when the next book is already loaded; marking
  a book unfinished posts it too). The Hummingbird reporter guards against
  it; worth fixing upstream (carry the item, or post once).
- **No flush on stop**: `stopPlayback()` posts nothing, so a Hummingbird
  book loses up to one 15 s tick when playback is stopped rather than
  paused. (Slice 6 snapshots the paused position before `.bookPaused`, so
  the pause report is no longer a tick behind.)
- **An API refusal with a message but no numeric code** reads "The server
  responded with 0: …" (`serverMessage(code: 0, …)`). Every refusal seen
  from SoundBooth carries a code; a SoundBooth-specific error type would be
  the fix if one ever doesn't (panel, slice 3).
- **Hummingbird has the stale-list gap SoundBooth fixed** (slice 2 code):
  with two servers saved, logging out of the active one from inside its
  bookshelf leaves that bookshelf on screen while the other server becomes
  active, and a download then asks the other server for the first one's
  book. Same fix: remember the connection the bookshelf (and a search) was
  listed for, and reload on a switch.
- **Share links, slice 5, still open:** a link BookPlayer doesn't
  download (a web page) shows an empty list with no message; a download
  can't be cancelled once Done is tapped (no UI, July had none either);
  the app's reconnect waits 2 minutes after a share as a margin against
  the extension still holding the session, which an extension iOS keeps
  suspended longer could still hit; a share made while the App Group
  can't be reached has no registry record, so only iOS's wake brings its
  downloads to the app. Device tests owed: a link shared with BookPlayer
  force-quit (imports at next open, or reports "stopped"), one with
  BookPlayer in the background, and a bad link (the alert shows).
- **Player, slice 6, still open:** long FLAC/Ogg/Opus/WAV books start
  slowly (July's fast start is the #1504 fix, out of the catch-up; it would
  come back together with a tolerance policy). The seek guard is bounded
  (3 s), so a seek slower than that can still be undone by the old race.
  Device test owed: in a book made of one file per chapter, play a chapter
  past 30 s, press previous chapter, and check it restarts.
