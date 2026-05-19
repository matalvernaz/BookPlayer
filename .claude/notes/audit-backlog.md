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
