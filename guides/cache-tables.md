# Rhizome ETS Cache Tables

Rhizome maintains two separate ETS tables with distinct responsibilities. Both are owned by GenServers but are public and accessed directly by other processes (Router, Dashboard) without GenServer calls for performance.

## 1. `:rhizome_roots` — owned by `RootResolver`

This table stores **mutable publisher state** and the **filename-to-hash lookup index**. Its keys are heterogeneous by design.

### Root entries (one per publisher)

Key: `{{:root, "pubkey_hex"}, root_map}`

Value:
```elixir
%{
  root_hash: <<32 bytes>>,
  root_hash_hex: "7656441bad08...",
  blossom_servers: ["https://cdn.example.com"],
  nix_sig_keys: [],
  created_at: ~U[2026-08-13 19:37:28Z],
  event_id: "9b2f5ab5fb7cbd7235a71e6a177d9ffc93c5d1d02c6c39619e1e3cce63869e60",
  link_count: 54,
  total_bytes: 17785516
}
```

- Written when a Nostr `kind:17091` root event is resolved
- Only the **newest** event per publisher is kept (replaceable semantics: higher `created_at`, or larger `event_id` on ties)
- Old narinfo entries are cleared from this table when a new root arrives

### Narinfo reverse index (flattened from the hashtree)

Key: `{{:narinfo, "hello-2.12.narinfo"}, {hash_hex, blossom_servers}}`

- Written by `RootResolver` when it walks the hashtree and discovers each leaf `.narinfo` file
- This is the **hot path** — a single ETS lookup turns a filename into a content hash + server list
- No tree walking needed on the request path

### Blossom server union list

Key: `{:blossom_servers, ["https://cdn.example.com", "https://other.blossom"]}`

- Flat list of all unique Blossom servers from all publishers' root events
- Used by NAR fetches (which bypass the hashtree entirely and fetch raw blobs by hash)

### Narinfo keys tracker (for cleanup)

Key: `{{:narinfo_keys, "pubkey_hex"}, [{:narinfo, "hello-2.12.narinfo"}, ...]}`

- Tracks every `{:narinfo, ...}` key inserted for this publisher
- When a new root event replaces the old one, `RootResolver` iterates this list and deletes all stale narinfo entries before building the new index

## 2. `:rhizome_tree_cache` — owned by `TreeCache`

This table stores **immutable content-addressed blobs and nodes**. Everything in it is keyed by SHA256 hash and never changes or evicts.

### Cached manifest directory nodes

Key: `{{:node, "hash_hex"}, %{t: 2, l: [...]}}`

- Decoded msgpack hashtree nodes (`Dir` nodes with `t: 2`)
- Fetched from Blossom during tree walking, then cached forever
- Next tree walk that hits the same hash skips the HTTP request

### Cached narinfo blob bytes

Key: `{{:narinfo, "hash_hex"}, <<raw bytes>>}`

- The actual `.narinfo` text file content (200-400 bytes typically)
- Fetched from Blossom on first request, then served from ETS forever
- Immutable because content-addressed: the hash is `SHA256(bytes)`

## Why two tables?

| Table | What it stores | Who writes | Who reads | Why separate |
|-------|---------------|-----------|-----------|--------------|
| `:rhizome_roots` | Mutable index + publisher metadata | `RootResolver` on Nostr event | `Router` (narinfo filename lookup), `Dashboard` (publisher list) | Needs to be wiped and rebuilt when a publisher replaces their root |
| `:rhizome_tree_cache` | Immutable content-addressed blobs | `RootResolver` (tree walk), `Router` (cold path miss) | `RootResolver` (tree walk), `Router` (narinfo bytes), `Dashboard` (manifest display) | Never needs eviction — same hash always means same bytes |

## Cache flow example

**First request for a narinfo:**

```
Nix ──GET /hello.narinfo──► Rhizome
  1. Router: ETS lookup in :rhizome_roots
     {:narinfo, "hello.narinfo"} → {"abc123...", ["https://cdn.example.com"]}
  2. Router: TreeCache miss
     {:narinfo, "abc123..."} → not found
  3. Router: Blossom.fetch_blob(servers, "abc123...") → HTTP request
  4. Router: TreeCache insert
     {:narinfo, "abc123..."} → <<raw bytes>>
  5. Router: respond 200 with text/x-nix-narinfo
```

**Second request for the same narinfo:**

```
Nix ──GET /hello.narinfo──► Rhizome
  1. Router: ETS lookup in :rhizome_roots
     {:narinfo, "hello.narinfo"} → {"abc123...", servers}
  2. Router: TreeCache hit
     {:narinfo, "abc123..."} → <<raw bytes>> (zero HTTP requests)
  3. Router: respond 200
```

## Why cache narinfos at all?

- **Frequency**: Nix checks narinfos before every NAR download. A single `nix build` may request dozens.
- **Cost**: Blossom servers may be remote, slow, or rate-limited. The proxy is meant to be local and fast.
- **Immutability**: Content-addressed blobs never change. Safe to cache forever.
- **Size**: Narinfos are tiny (~200-400 bytes). The entire cache for a 10,000-package store is under 4MB.
