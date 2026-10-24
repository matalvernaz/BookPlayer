# TestFlight CI

`.github/workflows/testflight.yml` ships every push on `test/all-changes`
to TestFlight via a self-hosted GitHub Actions runner.

## Runner

A self-hosted runner labelled `[self-hosted, macos, bookplayer]` running
on Matt's Apple Silicon Mac. Installed at
`/Users/matt/actions-runner-bookplayer/`, registered as a launchd service
so it survives reboots. Polls GitHub outbound — no inbound port forward
needed.

## Secrets layout (on the Mac, NOT in this repo)

- `~/.config/bookplayer-deploy/secrets.env` (chmod 600) — Mac login
  keychain password and the App Store Connect / Apple Developer
  identifiers (`DEVELOPMENT_TEAM`, `ASC_BUNDLE_ID`, `ASC_BETA_GROUP_ID`,
  `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`). The workflow sources
  this file at the top of every signing step.
- `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8` — App Store
  Connect API key, used both for `xcodebuild -allowProvisioningUpdates`
  and for the post-upload `testflight-add-to-group.py` helper.
- `~/.config/bookplayer-deploy/Debug.xcconfig` (chmod 600) — the real
  config values: bundle IDs, `DEVELOPMENT_TEAM`, API host, RevenueCat and
  Sentry keys (BP_* keys only, despite the name). The workflow copies it
  into the runner's checkout for the Debug configuration, and the Release
  archive applies it with `-xcconfig`, over the placeholders
  (`replace.me`) in the tracked `BuildConfiguration/Release.xcconfig`. The
  in-repo `Debug.template.xcconfig` has `com.replace.me*` placeholders
  that won't pass automatic provisioning.
- `~/bookplayer-deploy/testflight-add-to-group.py` — Python helper that
  polls App Store Connect for processing, sets the localized
  `What to Test` notes, submits for beta review, and attaches to the
  External Testers group.

Nothing crosses GitHub Secrets. Reading the workflow doesn't expose any
identifiers because everything sensitive resolves from the on-Mac
secrets file at runtime.

## Tester notes resolution

The "What to Test" field that testers see is resolved in this order:

1. `workflow_dispatch` input `notes` (manual override from the Actions
   UI when re-running for an existing commit).
2. A `Release-Notes:` trailer in the commit body — `awk` extracts
   everything from the trailer line through the next blank line, so
   multi-line notes work. Use this for non-trivial commits where the
   subject is too short.
3. First line of the commit subject. Default for short commits with no
   trailer.
4. Generic `New build available.` as last-ditch fallback.

Not enforced. A commit without a trailer ships fine and gets the subject
as its note.

## Build configuration and Xcode

TestFlight builds are **Release** builds made with **Xcode 27.1**
(`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, set on the
job, because the Mac's `xcode-select` default can differ while other apps
move over).

From 05-19 to 07-25 every build was archived with `-configuration Debug`,
because the real values only existed in the Debug xcconfig. That shipped
unoptimised builds, left framework and extension dSYMs out (Debug uses
`DEBUG_INFORMATION_FORMAT = dwarf`), and, since `AppEnvironment.isTestFlight`
is `#if DEBUG return false`, turned off every TestFlight-only feature: the
media-server progress sync gate, the icon/theme unlocks, the purchase
block. `.github/scripts/testflight-checks.sh` now guards both ends:
`settings` fails before archiving if the Release settings for the app or
BookPlayerKit would set DEBUG or `-Onone`; `archive` fails after
archiving unless every bundle's `BP_BUNDLE_IDENTIFIER` is the real bundle
id (the tracked Release.xcconfig says `com.replace.me`), and unless the
app and watch app are signed with `group.<bundle id>.files`. The private
`deploy.sh` fallback runs the same script.

`BP_API_DOMAIN`, `BP_REVENUECAT_KEY` and `BP_SENTRY_DSN` are
`replace.me` in the off-repo xcconfig on purpose, and have been in every
build: this fork doesn't use the BookPlayer server, in-app purchases or
BookPlayer's Sentry. The keys only have to exist (the app reads them with
`try!`), not be real.

The Release configuration pins the "Apple Distribution" identity for
manual signing. The archive forces `CODE_SIGN_STYLE=Automatic` and
`CODE_SIGN_IDENTITY="Apple Development"` (automatic archives sign for
development), and `-exportArchive` re-signs for distribution.

iOS 27 SDK trap: an `if`, or more than one statement, inside a `ForEach`
that builds rotor or toolbar content compiles fine but aborts at launch
on iOS 26 and earlier (upstream 5.22.1). Keep that content a single
entry per element and filter the data before the `ForEach` (upstream
`d351aaa7`, cherry-picked here).

## Gotchas

### `xcodebuild archive` and Xcode Accounts

`xcodebuild archive` with `-allowProvisioningUpdates` fails from a
launchd-spawned process with **"No Accounts: Add a new account in
Accounts settings"**. Xcode's GUI-keychain "Accounts" mechanism isn't
reachable outside an interactive login session. The fix is to pass
`-authenticationKeyPath`, `-authenticationKeyID`, and
`-authenticationKeyIssuerID` on the **archive** call too, not only on
`-exportArchive`. Provisioning then refreshes via the App Store Connect
API directly.

### Keychain unlock between archive and export

The login keychain auto-locks between separate shell sessions even with
no idle auto-lock configured, and `codesign` fails with
`errSecInternalComponent`. The workflow's archive + export + upload all
live in one shell step so the unlock survives.

### "Upload Symbols Failed" warnings

These came from the Debug archives: frameworks and extensions built
without dSYMs. Release archives should carry them; if the warnings come
back for BookPlayerKit or the extensions, check that the archive really
ran as Release. They never blocked an upload.

### Build numbering

UTC timestamp `$(date -u +%Y%m%d%H%M%S)`. Monotonically increases per
`MARKETING_VERSION`. Interleaves cleanly with manual deploys that use
the same scheme.

## Apple beta review

External-tester builds need Apple's beta review (~24h) before testers
can install. Rapid commits don't bypass this. The concurrency setting
on the workflow (`cancel-in-progress: true`, group
`testflight-deploy`) ensures rapid commits cancel in-flight builds so
only the latest commit ends up uploaded — but testers still wait on
Apple's review queue.

## Updating an already-shipped build's notes

If a build has already shipped and you need to update its
`What to Test` text after the fact, import the helper as a module and
call `set_tester_notes`:

```python
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "tfg", "/path/to/testflight-add-to-group.py"
)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

jwt = m.generate_jwt(KEY_ID, ISSUER_ID, KEY_PATH)
app_id = m.find_app_id(jwt, BUNDLE_ID)
build_id = m.wait_for_build_to_process(jwt, app_id, BUILD_NUMBER, 2)
m.set_tester_notes(jwt, build_id, "new notes here")
```

`max_iterations=2` is fine for an already-VALID build — the function
returns on the first hit, doesn't wait the full polling budget.
