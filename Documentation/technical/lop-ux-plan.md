# LOP UX: Seamless clone/fetch, push offload, and trace-verified data paths

## Problem

Using Large-Object Promisors (LOPs) is clunky for end users. Today you must juggle partial-clone filters, promisor remotes, and server quirks. Push is worse: servers keep all blobs locally even when policy says "large blobs live in a LOP."

## Goal

Make LOPs "just work":

1. Clone/Fetch UX: a single, simple clone that sets up one or more promisor remotes and fetch filters correctly. Subsequent fetches continue to respect those filters without user babysitting.
2. Commit/Push Offload (Server-side): when a client pushes, the server automatically offloads blobs that match policy to the configured LOP(s) instead of storing them locally.
3. Verification: tests and trace instrumentation prove that only the expected objects cross the wire and that routing/offload happens as intended.

## Scope (v1)

- Client: quality-of-life around `--filter`, multi-promisor routing metadata, and predictable fetch behavior.
- Server: an offload path that routes matching blobs to LOP storage using the new ODB interface.
- Tests: end-to-end `sh` tests that assert both behavior and packet/trace content.

**Non-goals (v1):** protocol changes, on-disk format changes, re-implementing LFS, or Gerrit/JGit integration.

## Design

### 1. Client UX: "one-line" partial clone with LOPs

A single clone sets up multiple promisor remotes and accepts server-provided objects from any of them once the user has opted in via `promisor.acceptFromServer=all` (for example in a global config).

```
git clone \
  --branch=main \
  file:///.../server.git client
```

**Behavioral guarantees**

- Subsequent `git fetch` continues to honor the server-advertised `blob:none`
  filter and pulls missing blobs on demand from any configured promisor
  remote.
- If a promisor is unreachable, fetch falls back gracefully (trees/commits always, blobs on-demand later).
- When multiple promisors advertise different blob limits, the client adopts
  the strictest (smallest) limit so that no blob which should live in a LOP is
  downloaded eagerly during the initial clone.

### 2. Server-side offload on push

When a client pushes a pack that contains blobs matching a promisor remote’s
partial-clone filter, the server:

1. Uses the advertised `remote.<name>.partialCloneFilter` values (for example
   `blob:none` or `blob:limit=<size>`) to decide whether an incoming blob should
   live in that LOP repository.
2. Writes matching blobs into the LOP ODB via the new ODB interface
   (plugin/aux ODB).
3. Keeps trees/commits (and any non-matching blobs) locally.
4. Records promisor metadata so downstream partial clones can retrieve those
   blobs from the LOP.

**Policy sources (v1)**

- Promisor remote filters: `remote.<name>.partialCloneFilter = blob:none`,
  `blob:limit=<bytes>`, or other supported list-objects filters. The server
  interprets the same filters it advertises to clients, so no bespoke policy
  syntax is required.

### 3. Trace-verified data paths

We rely on packet and Trace2 to prove behavior in tests and in the field.

- `GIT_TRACE_PACKET=1` to assert filter negotiation, e.g. filter `blob:none`.
- `GIT_TRACE2_EVENT=/path/trace.json` with custom categories:
  - `lop/router`: chosen promisor for on-demand blob
  - `lop/offload`: server offloaded N blobs to `<lopName>`
  - `lop/match`: policy matched `<blob>` by size/path/type

## Configuration (new/used keys)

**Client**

- `promisor.acceptFromServer = all|listed|none` (we use `all`)
- No manual `remote.<lop>.promisor` configuration; the client accepts the
  server-advertised LOP inventory and filter metadata.

**Server**

- `receive.lop.enable = true`
- `promisor.sendFields = partialCloneFilter`
- `remote.<lop>.promisor = true`
- `remote.<lop>.partialCloneFilter = blob:none|blob:limit=<size>`

These are existing knobs: enabling LOPs simply causes `receive-pack` to obey
the same promisor filters it already advertises to clients.

## Components (proposed file/map)

- ODB integration: `promisor-odb.c`, `promisor-odb.h` (adapter to the new ODB interface for storing/serving offloaded blobs)
- Server receive path hook-in: `receive-pack.c` (calls into lop/offload when `receive.lop.enable`)
- Docs: `Documentation/technical/lop.txt`, `Documentation/config/lop.txt`
- Tests: `t/t571x-lop-offload.sh`, `t/t571x-lop-multipromisor.sh`

## Tests

We add end-to-end `sh` tests that set up:

- `server.git` (primary), `lop-small.git`, `lop-large.git` (promisors)
- Client clones with `promisor.acceptFromServer=all` and relies on the
  server-advertised filter metadata.

**Test cases**

1. Clone advertises filter automatically. Assert `GIT_TRACE_PACKET` contains
   `filter blob:none`.
2. On-demand blob fetch. Checkout forces missing blobs; trace shows `lop/router` picking correct promisor.
3. Push offload by size. Push pack with >1 MiB blobs → server emits `lop/offload` and those blobs land in `lop-large.git`.
4. Mixed thresholds. Configure `remote.lopSmall.partialCloneFilter=blob:limit=1k` and
   `remote.lopLarge.partialCloneFilter=blob:limit=1m`; verify mid-sized blobs
   land in the small promisor while very large payloads route to the large one.
5. Negative coverage. Offload disabled → server keeps everything local; traces
   confirm no offload.
6. Negative paths. Offload disabled → server keeps everything local; traces confirm no offload.
7. Resilience. LOP temporarily unavailable → push is rejected with actionable error in server logs; no partial writes.

**Assertions**

- Packet filter negotiation: `test_i18ngrep -e 'packet:.*(clone|fetch)>\s*filter blob:none' trace.filt`
- Trace2 JSON has `lop/offload` events with counts and target remote.
- `git cat-file -t` against promisor repos confirms object placement.

## User Experience

**End user**

- Clones with one command. Doesn’t learn internals. Things “just fetch” on demand.

**Server operator**

- Enables offload and declares policy once. No new protocol. Uses existing ODB plug-points.

**Failure modes**

- Misrouted or missing promisor: clear error; local store remains consistent; retries are safe.

## Compatibility & Migration

- 100% compatible with existing partial clone and promisor remotes.
- If `receive.lop.enable=false`, we behave like today: the server stores everything locally.
- No repo reformat needed. Offload metadata leverages promisor semantics already present.

## Performance & Safety

- Offload runs in the receive path after validation to avoid accepting bad packs.
- Batching minimizes round-trips to LOP backends.
- Integrity is identical to normal Git: hashes don’t change; only storage location does.

## Future Work (post-v1)

- Smarter heuristics (delta-aware decisions, content-type sniffing via file headers).
- Push-time hints from client (optional) to pre-seed offload routing.
- Admin visibility: `git lop status` and `git lop verify` commands.
- Native multi-promisor advertisement to reduce cold misses.

## TL;DR

We make LOPs boring: one-line filtered clone, fetch that keeps honoring filters, and server-side push that offloads matching blobs to the right LOP automatically. Tests and traces prove the data path is correct.
