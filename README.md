# Narwal

A Nix binary cache proxy that resolves packages via Nostr + Hashtree, and serves
them to Nix clients as a standard HTTP binary cache.

## User Flow

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

## Architecture

Narwal is a lightweight Plug + Bandit server with no Phoenix, no Ecto, and no database.

- **Router** (`lib/narwal/router.ex`) — Presents the Nix Binary Cache HTTP API (`/nix-cache-info`, `/*.narinfo`, `/nar/*`). Hot path reads go through ETS directly with zero GenServer calls.
- **RootResolver** (`lib/narwal/root_resolver.ex`) — A GenServer that subscribes to Nostr relays for `kind: 17091` (or `37091` for named channels) root events from configured publishers. On each event it publishes the new root to ETS immediately, then builds the ETS reverse index (`narinfo_name → {hash, servers}`) asynchronously in a `Task.Supervisor` task — the tree walk does blocking Blossom HTTP fetches and never blocks the GenServer. Only the newest event per publisher is kept (NIP-33 replaceable semantics), and superseded index builds are cancelled mid-flight.
- **TreeCache** (`lib/narwal/tree_cache.ex`) — ETS cache for hashtree manifest nodes and narinfo blob bytes. Content-addressed, never evicts.
- **Blossom** (`lib/narwal/blossom.ex`) — Simple BUD-01 client. Fetches small blobs (manifest nodes, narinfos) by SHA256 with hash verification, and locates large blobs (NARs) via `HEAD /<sha256>` probes so the router can redirect clients to them.
- **Stats** (`lib/narwal/stats.ex`) — ETS counter table for request metrics (hits, misses, 404s).
- **Dashboard** (`lib/narwal/dashboard.ex`) — An HTML dashboard served at `/dashboard` with HTMX polling. Shows live stats, cache counts, publisher roots, and a topology graph. A separate `/dashboard/roots` endpoint loads the full hashtree manifest contents on demand.

The publisher side (a separate Rust binary, `nix-blossom-publish`) walks a Nix store staging directory, uploads NARs and narinfos as raw blobs to Blossom servers, builds a hashtree directory manifest from the narinfo files, and publishes the root hash as a Nostr event.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `narwal` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:narwal, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/narwal>.
