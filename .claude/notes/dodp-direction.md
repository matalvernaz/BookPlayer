# Long-term direction: BookPlayer as a DODP client

The Hummingbird integration shipped on this fork is a stepping stone.
The long-term goal is for BookPlayer to be DODP-compliant enough to talk
to ANY DODP / Kolibre-KADOS-compatible library (NNELS, CELA, Bookshare,
Plextalk hardware library backends), not just self-hosted Hummingbird.

## Shape of the future code path

A fourth `MediaServerKind` case `.dodp` alongside `.hummingbird`,
`.jellyfin`, `.audiobookshelf`. **Not** a Hummingbird replacement, **not**
a "Hummingbird collapses into DODP" shim. Both stay first-class:

- **Hummingbird** = easy-mode self-hosted backend with the
  Drupal/Playwright scraper plugins, REST-shaped client, the bound-book
  completer, two-way bookmark sync.
- **DODP** = "talks to any DAISY-Online library" backend, KADOS RPC,
  works without the Hummingbird middle layer.

## What this means for current Hummingbird work

- Bugs in Hummingbird's KADOS RPC surface
  (`/protocols/kados/v1/methods/*`) are **not speculative future debt** —
  they're load-bearing for the eventual `.dodp` source.
- The `openapi-kados` PHP adapter (Hummingbird-side) is the canonical
  "what a DODP backend gets called with" reference when designing the
  client.
- Shared abstractions (`MediaServerSourceStore`,
  `MediaServerProgressDispatcher`, `MediaServerSourceInfo`) need a fourth
  case `.dodp` when the time comes. Plan for it.
- Existing Hummingbird-specific Swift code
  (`HummingbirdConnectionService`, `HummingbirdLibraryViewModel`,
  `HummingbirdProgressReporter`, `HummingbirdLoanExpiryScanner`,
  `BoundBookCompleter`) is **not throwaway**. It stays. The DODP code
  path lives alongside it as a parallel module.

## What to avoid

- Hummingbird-specific solutions when a DODP-shaped solution would work
  for both surfaces. Example: resource auth should be DODP-spec
  compatible (session cookies or signed URLs), not Basic-auth-only.
- Locking in to NNELS-only assumptions. The NNELS plugin lives
  server-side in Hummingbird; the BookPlayer client should not encode
  NNELS-isms.

## Testing ground

`openapis.ca-dodp` (the Hummingbird plugin that consumes upstream DODP)
is the server-side mirror of the future client-side `.dodp` source. Same
protocol, opposite end. Bugs in that plugin block the testing path
because `Hummingbird+openapis.ca-dodp → BookPlayer's .dodp source` lets
you exercise end-to-end DODP without touching a real CELA / Bookshare
account.
