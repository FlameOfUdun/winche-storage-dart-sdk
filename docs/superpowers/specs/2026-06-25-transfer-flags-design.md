# Robust transfer flags (`enqueue` + `cache`) — Design

**Date:** 2026-06-25
**Status:** Approved (pending spec review)

## Goal

Give the upload/download API two per-call flags that make file transfers robust
without a sync engine:

- **`enqueue`** — make the transfer durable: it's tracked, survives an app
  restart, and retries until it succeeds (so it can be started while offline).
- **`cache`** — keep the file's content available offline (stage the local copy
  first, then transfer through it).

## Non-goals

No local-first reads, no server polling/reconciliation, no conflict resolution.
The existing offline-cache lifecycle (`makeAvailableOffline`/`isStale`/`refresh`/
`evict`) and the signed-URL transport are kept as-is.

## Public API

```dart
UploadTask uploadPath(String localPath, {
  String? mimeType, Map<String, dynamic>? metadata, int? multipartThreshold,
  bool enqueue = false,   // durable + tracked
  bool cache = false,     // keep available offline (stage-first)
});

UploadTask uploadBytes(Uint8List bytes, String mimeType, {
  Map<String, dynamic>? metadata, int? multipartThreshold,
  bool enqueue = false,
  bool cache = false,
});

DownloadTask download(String saveTo, { bool enqueue = false });
```

`cache` replaces the current `makeAvailableOffline:` upload parameter (same
stage-first mechanic). For downloads, the managed-offline-copy equivalent stays
`makeAvailableOffline()`, which also gains `enqueue`.

### Flag semantics

- **`enqueue: false`** (default) — a one-shot, **untracked** transfer straight to
  the server (today's direct `UploadTask.start`/`DownloadTask.start`). If the
  server is unreachable it fails normally.
- **`enqueue: true`** — a **tracked** transfer registered in the durable queue:
  deduped by path, resumed after restart, retried with backoff. Can be started
  offline.
- **`cache: true`** — stage the source into the managed cache first (copy the
  file, or write the bytes to disk), upload *from* that copy, and finalize it
  into the id-keyed offline cache on success. Best-effort: a caching failure
  leaves the upload successful (stale pin recorded).

### Combinations (all valid)

| `enqueue` | `cache` | Behavior |
|---|---|---|
| false | false | Quick direct transfer. |
| false | true | Upload once + keep offline (fails if offline now). |
| true | false | Durable/queued transfer, not kept offline. |
| true | true | Durable **and** offline-kept — the robust combo. |

## Task model

One task type per direction (`UploadTask` / `DownloadTask`); `enqueue` only
changes whether the controller tracks/persists it.

State machine gains a **`queued`** state:

```
queued → running → complete | failed
running ⇄ paused
running → queued        (transient/offline failure → scheduled retry)
```

- Untracked (`enqueue: false`): starts `running`; may end `failed` immediately
  when offline (today's behavior).
- Tracked (`enqueue: true`): starts `queued`; the controller promotes it to
  `running` when it actually starts, bounces it back to `queued` on a transient
  failure, and only reaches terminal **`failed`** on a *permanent* error (retries
  exhausted, permission denied). **`whenDone` resolves on the terminal outcome**
  (final success or permanent failure) — not per attempt — so a caller can
  `await` a tracked transfer started offline and have it complete once online.

The tracked task is a **stable handle**: it is the durable unit *and* the object
the caller holds *and* what survives restart. The existing per-attempt
`UploadTask`/`DownloadTask` execution becomes an internal "run one attempt"
worker that the handle drives; the handle's state/progress/`whenDone` persist
across attempts.

## Controller consolidation

`TransferController` today holds two parallel notions of a transfer — in-memory
`_activeUploads`/`_activeDownloads` maps and the durable `TransferRecord` queue.
Fold these into **one queue of stable handles**, each backed by a durable record:

- **Dedup by path** — `enqueue:true` for a path already tracked returns the
  existing handle (first-in-flight wins; a second call with different content is
  ignored until the first finishes — intended).
- **Lookup by path** — after a restart the caller no longer holds the original
  handle, so expose `uploadFor(path)` / `downloadFor(path)` (and
  `pendingTransfers()` returns the handles) to reattach a progress UI.
- **Rehydrate** — on construction, rebuild handles from the durable records in
  `queued` state and start draining (as `rehydrate()` already does).

## Decided defaults

- A flag whose subsystem is disabled **throws `StateError`**: `enqueue:true`
  requires the durable store (`enableAutoResume`); `cache:true` requires
  `enableOfflineCache`. Predictable over silent degradation.
- "Permanent failure" = retries exhausted (`maxAttempts`) or a non-retryable
  error (e.g. permission denied / not found). Everything else bounces to
  `queued`.
- Names kept as `enqueue` and `cache`.

## Reused / unchanged

Signed-URL upload/download engines, multipart resume via `listParts`, the
offline `OfflineCatalog` + staging mechanic, `pendingTransfers()`, and the
`makeAvailableOffline`/`isStale`/`refresh`/`evict` lifecycle.

## Testing

- Untracked vs tracked: `enqueue:false` returns a one-shot task; `enqueue:true`
  registers a deduped, durable handle.
- State machine: a tracked transfer started offline sits `queued`, transitions
  to `running` then `complete` when the server is reachable; `whenDone` resolves
  only at the terminal outcome (not on the first offline failure).
- `running → queued` on a transient failure; terminal `failed` only when retries
  are exhausted.
- `cache:true` stages the source and finalizes the offline copy (existing
  staging tests extended).
- Flag-without-subsystem throws `StateError`.
- Restart: rehydrated handles come back `queued` and are reattachable via
  `uploadFor`/`downloadFor`.
