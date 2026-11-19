# Mist sync relay

Run `npm ci`, then `npx wrangler login` and `npx wrangler deploy` to deploy your own relay.
Paste the HTTPS URL printed by deploy into Mist's Settings ▸ Sync ▸ Server URL.
Set up sync on one Mac, then copy its pairing code to the other Mac's Sync pane.
The relay stores encrypted records only; keep the pairing code private because it contains the group key.

For local development, run `npx wrangler dev --local`. Run `npx vitest run` for relay tests.
The SQLite-backed `SyncRoom` migration works on Workers Free.

The requested `@cloudflare/vitest-pool-workers` package currently requires Vitest 4
and a compatibility date no later than 2026-08-22. Its transitive dependencies are
overridden to patched versions; the relay itself has no npm runtime dependencies.
