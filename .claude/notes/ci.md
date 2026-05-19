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
- `~/.config/bookplayer-deploy/Debug.xcconfig` (chmod 600) — canonical
  `Debug.xcconfig` with real bundle IDs and `DEVELOPMENT_TEAM`. The
  workflow copies it into the runner's checkout. The in-repo
  `BuildConfiguration/Debug.template.xcconfig` has `com.replace.me*`
  placeholders that won't pass automatic provisioning.
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

Every TestFlight upload emits cosmetic "Upload Symbols Failed" warnings
for embedded frameworks. Noise. Only worry if `EXPORT` itself fails.

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
