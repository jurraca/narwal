# Narwal

A Nix binary cache that resolves packages via Nostr + Blossom, and serves them to Nix clients as a standard HTTP binary cache.

You may have a package or software you want to make available to the world.
You push it to one or many Blossom servers with [narwal-cli](https://gitworkshop.dev/julien@krewe-of-keys.fly.dev/relay.ngit.dev/narwal-cli), whichs publishes a Nostr event attesting to the state of your package upload (could be a whole Nix store).
A Narwal server listens for these Nostr events, checks the Blossom servers for the binaries, and then provides them to Nix clients, which know nothing about Nostr or Blossom.
A server can index many users, pointing to many blossom servers, all over the web. No more monolithic cache.

## Architecture

Narwal is a lightweight Plug + Bandit server with no Phoenix and no database.

- **Router** (`lib/narwal/router.ex`) — Presents the Nix Binary Cache HTTP API (`/nix-cache-info`, `/*.narinfo`, `/nar/*`). Hot path reads go through ETS directly with zero GenServer calls.
- **RootResolver** (`lib/narwal/root_resolver.ex`) — A GenServer that subscribes to Nostr relays for `kind: 17091` (or `37091` for named channels) root events from configured publishers. On each event it publishes the new root to ETS immediately, then builds the ETS reverse index (`narinfo_name → {hash, servers}`) asynchronously in a `Task.Supervisor` task — the tree walk does blocking Blossom HTTP fetches and never blocks the GenServer. Only the newest event per publisher is kept (NIP-33 replaceable semantics), and superseded index builds are cancelled mid-flight.
- **TreeCache** (`lib/narwal/tree_cache.ex`) — ETS cache for hashtree manifest nodes and narinfo blob bytes. Content-addressed, never evicts.
- **Blossom** (`lib/narwal/blossom.ex`) — Simple BUD-01 client. Fetches small blobs (manifest nodes, narinfos) by SHA256 with hash verification, and locates large blobs (NARs) via `HEAD /<sha256>` probes so the router can redirect clients to them.
- **Stats** (`lib/narwal/stats.ex`) — ETS counter table for request metrics (hits, misses, 404s).

The publisher side (a separate Rust binary, `nix-blossom-publish`) walks a Nix store staging directory, uploads NARs and narinfos as raw blobs to Blossom servers, builds a hashtree directory manifest from the narinfo files, and publishes the root hash as a Nostr event.

## Installation

A recent version of Elixir (preferably 1.20) and autotools (for libsecp256k1) are required. The Nix shell is recommended for development. A Nix module is provided for easy deployment.

Quick start
```
# enter the dev shell
> nix develop
# get deps
> mix deps.get
# compile
> mix compile
# run the app
> iex -S mix
```

## User Flow Specifics

When a Nix user adds Narwal as a binary cache and tries to build or install a package:

1. **Nix queries** `GET /nix-cache-info` to discover cache priority and store path.
2. **Nix computes** the store path hash for the package it needs (e.g. `hello-2.12`).
3. **Nix requests** `GET /<hash>.narinfo` from Narwal. This is a small metadata file describing the package and its dependencies.
4. **Narwal resolves** the narinfo by looking up the filename in a hashtree directory that was published on Nostr by a cache publisher. The hashtree is a content-addressed Merkle tree stored on Blossom servers.
5. **Narwal fetches** the narinfo blob from a Blossom server and returns it to Nix.
6. **Nix reads** the `URL:` and `FileHash:` fields from the narinfo, then requests the actual archive: `GET /nar/<hash>.nar.xz`.
7. **Narwal HEAD-probes** the Blossom servers for the NAR blob (decoded from the nix32 hash) and **302-redirects** Nix to the server that has it. NAR bytes never pass through Narwal — Nix downloads directly from Blossom.
8. **Nix downloads** the NAR from Blossom, verifies it against the narinfo's `FileHash`, decompresses and unpacks it into `/nix/store`, and the package is ready.

If the narinfo is already cached in Narwal's ETS tables, the Blossom fetch is skipped. NARs are not cached — a NAR can be hundreds of MB, and proxying it would scale Narwal's memory and bandwidth with concurrency for no trust benefit (Nix verifies the download against the narinfo hash itself).
