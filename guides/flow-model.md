# Nix → Rhizome → Blossom Workflow

## Step-by-step flow

```
┌─────────┐
│   Nix   │  1) nix run nixpkgs#hello
│  client │
└────┬────┘
     │ GET /nix-cache-info
     │ (learns cache priority + store path)
     ▼
┌──────────────┐
│   Rhizome    │  static response
│  HTTP proxy  │
└────┬─────────┘
     │
     │ 2) GET /<hash>.narinfo
     │ (Nix computes store-path hash, asks for metadata)
     ▼
┌──────────────┐
│   Rhizome    │  3) resolves via hashtree
│   Router     │     - Nostr root event → htree root hash
│              │     - walk Dir nodes (t=2) → find narinfo link
│              │     - fetch narinfo blob from Blossom by SHA256
└────┬─────────┘
     │ 200 OK, text/x-nix-narinfo
     │ (raw .narinfo bytes)
     ▼
┌─────────┐
│   Nix   │  reads narinfo:
│  client │    URL: nar/<nix32-hash>.nar.xz
│         │    FileHash: sha256:<raw-hash>
└────┬────┘
     │ 4) GET /nar/<nix32-hash>.nar.xz
     ▼
┌──────────────┐
│   Rhizome    │  5) decodes nix32 → raw SHA256
│   Router     │     fetches NAR blob from Blossom by content hash
│              │     (bypasses hashtree entirely — raw blob)
└────┬─────────┘
     │ 200 OK, application/x-nix-nar
     │ (raw .nar.xz bytes, streamed)
     ▼
┌─────────┐
│   Nix   │  6) verifies FileHash, decompresses, unpacks
│  client │     into /nix/store
└─────────┘
```

## What lives where

| Entity | Role | Content |
|--------|------|---------|
| **Nostr** | Mutable root pointer | `kind:17091` event with `htree://<nhash>` tag |
| **Hashtree** | Directory structure | `Dir` nodes (t=2) mapping `*.narinfo` filenames → blob hashes |
| **Blossom** | Blob store | Raw bytes by SHA256: `.narinfo` texts, `.nar.xz` archives |
| **Rhizome** | HTTP proxy + resolver | Serves Nix cache API; walks hashtree; fetches blobs |

## Key notes

- The **hashtree only contains `.narinfo` files** — never NAR archives.
- **NAR files** are raw single-blob uploads to Blossom, fetched by content hash directly.
- **Rhizome** is the only thing Nix talks to. Nix never sees Nostr or Blossom.
- If a directory has > 174 entries, the hashtree is **chunked** into nested `Dir` nodes. Rhizome recurses through them transparently.
