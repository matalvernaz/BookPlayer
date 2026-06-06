# CLAUDE.md — fork-specific project notes

This is Matt Alvernaz's fork of TortugaPower/BookPlayer, maintained on the
long-lived `test/all-changes` branch and shipped to TestFlight from a
self-hosted GitHub Actions runner. The notes here exist so any Claude
session opening this repo can pick up the project state without re-deriving
it from the diff against upstream.

## Where to look

- [`.claude/notes/architecture.md`](.claude/notes/architecture.md) — fork
  features the upstream code doesn't have: Jellyfin client (password +
  Quick Connect), Audiobookshelf client (password + native OIDC/SSO),
  Hummingbird/NNELS integration, share-extension web-URL imports.
- [`.claude/notes/audit-backlog.md`](.claude/notes/audit-backlog.md) —
  remaining items from the May 2026 multi-AI audit of `test/all-changes`.
  Critical/High items are already shipped; open items are nits and
  defensive cleanups.
- [`.claude/notes/dodp-direction.md`](.claude/notes/dodp-direction.md) —
  long-term plan: BookPlayer should speak DODP directly so it can connect
  to any DAISY-Online library (NNELS, CELA, Bookshare, Plextalk backends),
  not just self-hosted Hummingbird. Hummingbird stays as the easy-mode
  self-hosted backend; DODP joins as a fourth `MediaServerKind`.
- [`.claude/notes/ci.md`](.claude/notes/ci.md) — self-hosted runner setup,
  tester-notes resolution, signing gotchas. No secret IDs — those live in
  `~/.config/bookplayer-deploy/secrets.env` on the Mac that runs the
  runner.
- [`.claude/notes/conventions.md`](.claude/notes/conventions.md) — commit
  conventions specific to this fork: the `Release-Notes:` trailer that the
  TestFlight workflow reads, code-style notes, what stays out of git.

## Quick orientation

- **Deploy branch:** `test/all-changes`. Every push triggers a TestFlight
  build via `.github/workflows/testflight.yml` on the self-hosted Mac
  runner. Concurrency cancels in-flight builds when a newer commit lands.
- **Upstream:** TortugaPower/BookPlayer. The fork does not PR back upstream
  for any of the multi-server work — that's all fork-specific.
- **Secrets layout:** signing certs, ASC API key, and account identifiers
  live on the Mac at `~/.appstoreconnect/private_keys/` and
  `~/.config/bookplayer-deploy/`. Nothing sensitive crosses GitHub Secrets
  or this repo. See `.claude/notes/ci.md` for the inventory.

## Updating these notes

These files are intended as living project memory. When project state
changes (audit items closed, architecture changes, conventions evolve),
update the relevant note in the same commit as the code change. Treat
stale notes as a bug, not as historical record.
