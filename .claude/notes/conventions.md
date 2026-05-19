# Fork-specific conventions

These are conventions specific to this fork's `test/all-changes` branch.
Upstream TortugaPower doesn't follow them; PRs back upstream would drop
them.

## Commit conventions

### `Release-Notes:` trailer

The TestFlight CI workflow reads a `Release-Notes:` trailer from the
commit body to populate the build's "What to Test" notes. Multi-line is
supported — `awk` reads from the trailer line through the next blank
line:

```
feat(hummingbird): drop ebook formats from search

Release-Notes: Hummingbird/NNELS now hides EPUB, BRF, PDF, and
text-only DAISY editions in the bookshelf and search, since
BookPlayer can't open them. Audio formats only.
```

Not required. A commit without the trailer ships fine and uses the
subject line as its tester notes. Add a trailer when the subject is
too short or too jargon-y for testers.

For multiple commits in one CI-triggering push, only the head commit's
trailer is read (`github.event.head_commit.message`). If you want
combined notes across several commits in one build, squash before
pushing or use a `workflow_dispatch` re-run with a manual `notes` input.

### Commit message style

Follow the conventional-commits-ish style already in `git log`:
`type(scope): short subject`. Common types in this branch: `feat`, `fix`,
`refactor`, `ci`, `chore`. Scopes used so far include `hummingbird`,
`hummingbird-ui`, `bound-book`, `import`, `testflight`, and the major
service names (`jellyfin`, `audiobookshelf`).

## Code conventions

### App Group cross-process state

Uses file-backed JSON at `containerURL(forSecurityApplicationGroupIdentifier:)`,
not `UserDefaults(suiteName:)`. Extension↔host UserDefaults sync is
historically flaky on iOS. Existing stores: `ShareImportFailureStore`,
`ShareCancelStore`.

### Task cancellation

View-level `actionTask?.cancel()` on `onDisappear` AND a
`try Task.checkCancellation()` inside the service immediately before
persisting state — both halves are required. See
[architecture.md](architecture.md) for why.

### VoiceOver announcements on status changes

Matt uses VoiceOver. SwiftUI status banners (the kind that pop into a
view when an `@Published` status changes) are silent to VoiceOver
unless explicitly announced. Pattern:

```swift
@Published var downloadStatus: String? {
  didSet {
    guard let status = downloadStatus, status != oldValue else { return }
    UIAccessibility.post(notification: .announcement, argument: status)
  }
}
```

Without the `didSet`, the banner appears but VO focus stays put — the
blind user has no idea the tap registered.

## What stays out of git

- `bookplayer-deploy/` directory contents (the Linux-side TestFlight
  driver and its secrets). The Mac mirror at `~/bookplayer-deploy/` and
  the `~/.config/bookplayer-deploy/` secrets are also private — they
  hold account identifiers and the Mac login keychain password.
- `BuildConfiguration/Debug.xcconfig` (real bundle IDs and
  `DEVELOPMENT_TEAM`). The repo ships `Debug.template.xcconfig` with
  placeholders.
- App Store Connect API key (`.p8`). Lives at
  `~/.appstoreconnect/private_keys/` on machines that need it.

## Pro-feature bypass policy

TestFlight bypasses are only for local / fork-owned features (icons,
themes, the fork's media-server progress sync). Tortuga's paid-backend
features (cloud sync, data-usage section) stay gated. Bypassing them
would be theft of service AND the server validates entitlement
independently.
