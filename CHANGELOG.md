# CHANGELOG

## 5.1.0

### Added: `ChildReference.cachedFiles()`

`Future<List<CachedFile>>` — the cached files directly under a path, sorted by
path, each verified against the disk so every `localPath` opens.

5.0.0 removed `offlineChildren()` on the grounds that a server listing
annotated with `isCached` covers the multi-file case. It does, but only while
the server is reachable: `listChildren()` throws when offline, so at the moment
the cache matters most there was no way to ask what was in it. This is that
read. It is not a listing — it reports what this device holds, makes no claim
about what exists on the server, and never calls `listDirectory`.

One level only, like a listing. Rows whose bytes are absent or incomplete are
omitted rather than returned in a degraded form.

```dart
for (final f in await dir.cachedFiles()) {
  print('${f.path} → ${f.localPath}');
}
```

### Fixed: cache operations on a `CachedFile` read from the cache

The reference carried by a `CachedFile` that was *read* from the cache —
`cachedFile()`, `cachedFiles()`, or `keepCached()` when the bytes were already
complete — was built without the catalog. So `clearCache()`, `refreshCache()`,
`keepCached()`, `cachedFile()` and `checkForUpdate()` all threw `StateError` on
an object obtained from the cache, and `delete()` through one deleted the file
on the server and then silently skipped its local cleanup, leaving the bytes
and the catalog row behind as an orphan that still reported as cached. A
`CachedFile` returned by a download carries the reference you called it on and
was never affected.

It now carries the catalog, and the live-task registry with it: a transfer
started through such a reference is aborted on sign-out, appears on
`transferEvents`, and is findable via `downloadFor` / `uploadFor`.
`uploadPath(..., cache: true)` through one now works too, where it previously
threw `StateError`.

It still carries no upload queue, so `resumeUpload()` throws on it and
`delete()` will not cancel a queued upload for that path — use
`storage.child(path)` when either matters.

**Behaviour change:** `delete()` through a cache-read reference now evicts the
local copy, where before it left the bytes behind. If you were relying on that,
copy the bytes out before deleting — every route to `delete()` now cleans up.

## 5.0.0

Built on `winche_core`. Storage is now bound to whichever identity is signed
in, rather than being handed a token, a namespace and a directory by the app.

**Breaking: this release discards every existing local store.** The on-disk
layout moved from `<dir>/winche_storage_<namespace>/` to
`<root>/winche/<storageKey>/storage/`, and no migration is performed. On first
launch under 5.0 every user starts from an empty cache and **any queued upload
that had not yet reached the server is lost** — silently, with nothing in the UI
to notice it. That is worse here than in a cache-only package: a queued upload
exists nowhere else. Drain the queue before upgrading if that matters — check
`pendingUploads()` and wait for it to empty while 4.x is still installed.

### Requires `winche_core` ^0.2.0

Also raises the Dart SDK floor from `^3.0.0` to `^3.10.0` to match core.

### Breaking: the offline layer is now a file cache

The package cached file *content* but presented it as though it cached the
storage *index*: `getSnapshot`/`listChildren` (server) sat beside
`offlineSnapshot`/`offlineChildren` (cache), same return types, distinguished by
a `fromCache` boolean -- implying the same question answered from two places. It
wasn't. The catalog only ever held files someone explicitly cached, so the
"cache read" was a different question wearing matching clothes.

The scope is now explicit: **this package caches bytes, not the index.** Listings
and metadata are always live. For offline-capable structured data, use
`winche_database`.

| removed | replacement |
| --- | --- |
| `offlineSnapshot()` | `cachedFile()` -> `CachedFile?` |
| `offlineChildren()` | none -- listings are annotated instead |
| `makeAvailableOffline()` | `keepCached()` -> `CachedFile` |
| `refreshOfflineCopy()` | `refreshCache()` |
| `removeOfflineCopy()` | `clearCache()` |
| `offlineCopyStatus()` | `checkForUpdate()` |
| `OfflineCopyStatus` | `CacheStatus` |
| `WincheStorage.clearOfflineCache()` | `WincheStorage.clearCache()` |
| `pendingTransfers({kind})` | `pendingUploads()` |
| `resumeTransfers()` | `resumeUploads()` |
| `ChildReference.resumeTransfer()` | `resumeUpload()` |
| `FileSnapshot.fromCache` / `DirectorySnapshot.fromCache` | removed |
| `FileData.isCached` / `FileData.localPath` | moved to `FileSnapshot` |

- **Listings carry cache state.** Every `FileSnapshot` from `listChildren()` and
  `getSnapshot()` now has `isCached` and `localPath`. This replaces the
  documented recipe of calling both `listChildren()` and `offlineChildren()` and
  hand-building a `Set` of paths to cross-reference.

- **`cachedFile()` returns null, not a "missing" snapshot.** "I don't have these
  bytes" and "this file doesn't exist" used to look identical. A returned
  `CachedFile` is verified against the disk, so its `localPath` always opens.

- **`keepCached()` is file-only and idempotent.** It no longer caches a whole
  directory when the path has no file record -- that made one call fetch either
  one file or hundreds depending on a server round-trip the caller couldn't see,
  and it was the cache layer's only use of the storage index. It also returns the
  existing copy instead of silently re-downloading; use `refreshCache()` to force.

- **`FileData` is a pure wire model.** Everything on it came from the server.

### Breaking: downloads are no longer durable

`download(saveTo, enqueue: true)` is gone; `enqueue` leaves `download()`
entirely. An upload is the only copy of something -- lose the queue and the work
is gone. A download is a cache fill whose bytes stay authoritative on the server,
so losing one costs bandwidth and never data. The durable queue is now an upload
outbox.

Range resume is **not** lost: the resume offset comes from the file on disk, not
from the record, so `keepCached()` picks up a partial left by an app exit.
In-session retry for downloads is unchanged.

- `transferEvents` no longer reports durable download progress -- **because
  downloads are no longer durable.** The replacement is `downloadFor(path)` plus
  the task's `stateStream`, not a renamed API.
- `transferEvents` now covers *more* than before: one-shot transfers used to emit
  nothing at all, since only the queue emitted. Every transfer is now visible.
- `downloadFor(path)` is in-session only. `uploadFor(path)` still survives a
  restart.
- `TransferRecord.kind` is gone (records are all uploads). `TransferKind`
  remains, describing events.
- Download rows written by an earlier version are purged on first launch. Left in
  place they would deserialize under the upload-only record shape into an upload
  whose source is the *download destination* -- uploading a partially fetched
  file over the server's copy.

### Fixed

- **A cache fill interrupted by process death could never complete.** The
  `downloading` -> `ready` transition lived in an awaiting stack frame, and
  download records carried no `pinned` flag, so after a restart the bytes landed
  but the row stayed `downloading` forever -- the file occupying disk, invisible,
  and re-downloaded on every attempt. Removing durable downloads eliminates the
  cross-process gap, and `cachedFile()` now verifies bytes rather than trusting
  the row, so any row already stuck self-corrects.

- **A resumed download could silently corrupt the file.** Bytes were appended to
  whatever partial was on disk with no check that the server's content was
  unchanged, producing an old-prefix/new-suffix splice that passes a length
  check. Now guarded by comparing `contentHash` before resuming, with `If-Range`
  as a second layer. The guard is exact rather than best-effort: a download only
  starts when `uploadStatus == complete`, which implies a `contentHash`.

- **`keepCached()` reported server conditions as `StateError`.** A file not being
  on the server is an ordinary runtime condition, not a bug to fix. It is now
  `StorageNotFoundException`, and a record whose bytes have not been uploaded yet
  reports `StorageFailedPreconditionException` -- distinguishing "still
  uploading, try later" from "the upload failed, it must be re-uploaded" --
  instead of falling through to an obscure signed-URL error.

- `CacheStatus.unknown` meant two unrelated things: "the server is unreachable"
  and "there is no fingerprint to compare". The second is now `remoteIncomplete`,
  which is what the server actually reports via `uploadStatus`. `notPinned`
  leaves the enum: it is `cachedFile() == null`, answerable locally without a
  round-trip.

### Changed

- **Breaking: `WincheStorage` is a `WincheStorageService`.** Construct the app
  instead, and reach storage through `WincheStorage.instance` (or
  `instanceFor(app)`). `winche_core` builds a session for whichever identity is
  signed in and disposes it on sign-out.

- **Breaking: four fields leave `WincheStorageConfig`.** Each was a way to get
  it wrong; all four now come from core, where they cannot disagree with the
  rest of the stack:

  | 4.x | 5.0 |
  |---|---|
  | `uri` | `WincheOptions.storageEndpoint` |
  | `tokenProvider` | `session.token()` |
  | `namespaceResolver` | `identity.storageKey` |
  | `directoryResolver` | `WincheOptions.directoryResolver` |

  What remains is what storage tunes for itself: `multipartThreshold`,
  `inMemory`, and the four `retry*` knobs. It is set on the instance
  (`WincheStorage.instance.config = ...`) and throws a `StateError` once storage
  has been used.

  Stateless mode survives unchanged: no `directoryResolver` on the app,
  `inMemory` off, native. Durable and offline operations still throw
  `StateError`, now naming both knobs that would enable them.

- **Breaking: `close()` is deleted.** Teardown is core's job — a sign-out tears
  the session down, and `dispose()` releases the service. The order and the
  guarantees are unchanged (one-shot transfers, then the queue, then the store,
  never waiting on the network). `isClosed` is deleted with it.

  A user switch no longer needs sequencing by the app. Core awaits storage's
  teardown before dispatching the next session, so the outgoing identity's store
  is always fully closed before the incoming one opens.

- **Breaking: `resumeDownloads()` is deleted**, along with durable downloads
  themselves (see above). `resumeUploads()` is the single manual nudge, and its
  purpose has changed: sign-in and token rotation now re-drive the queue
  automatically, so it is only for what the SDK cannot observe — the OS
  reporting the network is back, or the app returning to the foreground.

- **Breaking: `WincheStorage.withStore(api, store)` is replaced by
  `debugBindStore(api, store)`**, a `@visibleForTesting` method on the instance.

- **Breaking: `WincheStorageException` extends `WincheException`**, core's root
  for the whole stack. `status`, `message`, `details` and `statusCode` are
  unchanged; only the supertype is new. `on WincheStorageException` still asks
  the narrow question, and `on WincheException` now catches anything from any
  Winche package.

- **Breaking: `child()` no longer throws while unbound.** It returns a reference
  that resolves its api and store when *used*, so building one is always safe —
  including in a widget field or a `build` method, where a throw tears down the
  tree instead of reaching an error branch. The operation you attempt is what
  rejects with `WincheUnboundException`.

  A reference is therefore always about whoever is signed in at the moment you
  use it. One built before sign-in starts working when an identity arrives; one
  built under a previous user reports unbound after they sign out, instead of
  quietly reading a torn-down store.

- **`WincheSessionExpired` now pauses a transfer instead of retrying it.** It
  previously fell into the "not a `WincheStorageException`" default and counted
  an attempt. A transfer that straddles a user switch is about to be aborted by
  teardown anyway, so spending retry budget on a session that no longer exists
  only loses work.

### Removed

- `validateNamespace` and the namespace concept. Core validates the identity,
  and `storageKey` is a digest, so the check became unreachable by construction
  — and a second implementation of a rule core owns is one more place to update.

## 4.0.1

Packaging only — the library code is byte-for-byte identical to 4.0.0.

* The published archive no longer contains `docs/superpowers/`, the design specs
  and implementation plans. They are internal working documents that made up
  roughly half the archive and help nobody consuming the package. They remain in
  the repository. Archive size drops from 382 KB to 341 KB.

## 4.0.0

Identity-scoped local state, a close that can't race the store, and a transfer
queue that survives an expired token. Ports the fixes from `winche_database`
5.0.0, which apply here in a more damaging form because storage persists file
*bytes* alongside its index.

### Added

* **`WincheStorageConfig.namespaceResolver`** — **required** for a persistent
  store; scopes all local state to one identity. Local state is single-tenant:
  the offline catalog, the cached bytes and the durable transfer queue carry no
  identity, so a shared store let a second user on the same device read the
  previous user's pinned files and replay their queued uploads under the new
  token. Each identity now gets its own directory,
  `<dir>/winche_storage_<namespace>/`, holding the sembast index, `cache/` and
  `staging/` (on the web, the IndexedDB database name). Switching users is
  `await storage.close()` plus a new `WincheStorage`; the previous user's queued
  transfers stay on disk and resume when they sign back in. Resolved lazily and
  cached, like `directoryResolver` — it pins the identity for the lifetime of the
  instance. Validated against `[A-Za-z0-9._-]+` rather than sanitised: rewriting a
  user id would collapse two identities onto one store.
* **`WincheStorage.resumeUploads()`** — re-drives every upload halted by a
  pause. Call it after refreshing an auth token instead of waiting out the
  `retryPollInterval` backstop. The `winche_database` `reconnect()` analogue.
* `WincheStorage.isClosed`, `TransferStatus.paused`, `TransferEventType.paused`,
  and `TransferEvent.record`.

### Fixed

* **An expired token no longer destroys queued work.** Every failure was treated
  the same — count an attempt, back off, and after `retryMaxAttempts` fail
  permanently and drop the handle. A 401 therefore burned five attempts in about
  two minutes and silently discarded an un-synced upload. Failures are now split
  three ways: `unauthenticated` and `unavailable` **pause** (record and handle
  survive, **no attempt counted**, `TransferEventType.paused` emitted, probing
  continues on the usual backoff so a brief blip recovers in about a second);
  `internal` / `deadlineExceeded` / `unknown` and non-`WincheStorageException`
  errors **retry** as before; `permissionDenied` / `notFound` /
  `invalidArgument` / `failedPrecondition` are **terminal**.
* **A durable transfer started offline is no longer dropped after ~2.5 minutes.**
  `unavailable` now pauses, which makes the 3.0.0 contract — "retries until it
  succeeds, so it can be started while offline" — actually true.
* **A terminally failed transfer is recoverable.** `TransferEvent` carries the
  dropped `TransferRecord` in `record`; a path and an error alone lost the source
  `localPath`, `mimeType` and `metadata`.
* **`close()` no longer races the local store.** `dispose()` cancelled only the
  poll timer: in-flight drive loops and every scheduled retry `Timer` outlived it
  and wrote into a sembast that had already closed — an uncatchable
  `Bad state: database is closed`. Teardown now runs in dependency order —
  one-shot transfers, then the controller (timers cancelled, in-flight HTTP
  aborted, `running` records reset to `pending`), then the store.
  `LazyStorageLocalStore` degrades to no-ops after close so a straggling callback
  cannot surface a store error, and its `close()` is idempotent.
* In-flight transfers are aborted on close rather than cancelled: `cancel()` on
  an upload deletes the remote file, which closing the SDK should never imply.
* A retry backoff of many doublings no longer overflows its shift (reachable now
  that a paused transfer probes indefinitely).
* **A completed transfer is no longer briefly still in the queue.** The durable
  record was dropped just *after* the handle completed, so `await task.whenDone`
  followed by `pendingUploads()` could still see the finished transfer, and the
  `completed` event could arrive after it. Both now happen in an awaited
  `onBeforeComplete` hook that runs before the handle completes — the same
  contract `cache: true` uploads already had for their pin.
* A store that cannot open — an unusable namespace, an uncreatable directory — no
  longer escapes as an unhandled async error from the constructor's
  fire-and-forget rehydrate. The failure resurfaces, catchably, on the next store
  access.

### Changed

* **Breaking:** `WincheStorage.dispose()` is renamed **`close()`**. No deprecated
  alias. It stays `Future<void>` and is now idempotent, and it resolves only once
  the store is really closed — await it before opening another `WincheStorage`
  over the same files. Every other member throws `StateError` afterwards.
* **Breaking:** a persistent `WincheStorage` now requires `namespaceResolver`,
  and it must be omitted when `inMemory: true`. Both are `ArgumentError` at
  construction. Required in stateless native mode too (no `directoryResolver`,
  not web), where it is unused — one flat rule rather than a matrix.
* **Breaking:** cached files move from `<dir>/<fileId><.ext>` to
  `<dir>/winche_storage_<ns>/cache/<fileId><.ext>`, staging from `<dir>/.staging/`
  to `<dir>/winche_storage_<ns>/staging/`, and the sembast database from
  `<dir>/winche_storage.db` to `<dir>/winche_storage_<ns>/index.db`.
  **There is no migration.** Pinned files rebuild themselves on next use, but the
  old cache and database are left on disk unreferenced, and **un-synced uploads
  queued in the legacy store are lost** — drain the queue before shipping this
  upgrade if that matters.
* **Breaking:** `TransferStatus` gained `paused` and `TransferEventType` gained
  `paused` — exhaustive `switch`es over either need a new arm.
* `staging/` is a sibling of `cache/` rather than a hidden `.staging/` beside the
  cached files, so `clearOfflineCache()` can empty the cache without disturbing an
  upload that is still in flight.

## 3.0.0

Robust per-call transfer mechanics, simplified config.

* **Breaking — config:** removed `enableOfflineCache` and `enableAutoResume`.
  The durable transfer queue and offline cache now exist whenever a store is
  configured — a `directoryResolver` (native), `inMemory: true`, or web
  (IndexedDB). With none configured on native, the client is stateless and
  durable/offline operations throw `StateError` at call time (no construction
  `ArgumentError`).
* **Breaking — upload/download API:** the `makeAvailableOffline:` parameter on
  `uploadPath`/`uploadBytes` is replaced by `cache:`, and `uploadPath`/`download`
  gain `enqueue:`:
  * `enqueue: true` — durable: the transfer joins the queue, is deduped by path,
    survives a restart, and retries until it succeeds (so it can start offline).
    `download` and file-backed `uploadPath` only; `uploadBytes` is not durable.
  * `cache: true` — stage-first keep-offline (the upload-time pin).
  * Requesting a flag without its subsystem now throws `StateError` (was a silent
    no-op for the old `makeAvailableOffline:` parameter).
  * `download()` is a one-shot by default; pass `enqueue: true` for durable.
* Transfers gained a `queued` state and a **stable-handle** model: a tracked
  transfer is a single handle whose `whenDone` resolves only on the terminal
  outcome and that survives retries/restart — so you can start an upload while
  offline and just `await` it. Pause/resume works on tracked handles.
* `updateMetadata()` now also refreshes a pinned file's **cached** metadata after
  the server write succeeds, so offline reads (`offlineSnapshot`/`offlineChildren`)
  stay current. Only the metadata is synced — the cached content fingerprint is
  preserved, so `offlineCopyStatus()` still detects stale cached *bytes*.
* `makeAvailableOffline()` on a **directory** path now pins every file directly
  under it (one level — the server lists a single level), instead of throwing a
  misleading "not found on server". A genuinely missing path still throws.
* A pinned (`cache: true`) tracked (`enqueue: true`) upload now finalizes its
  offline copy **before** `whenDone` resolves — the same contract as a direct
  pinned upload — so a completed upload guarantees the file is cached. (Previously
  the controller committed the pin just *after* `whenDone`, so an immediate cache
  read could miss it.)
* Added `WincheStorage.uploadFor(path)` / `downloadFor(path)` to reattach a
  progress UI to a tracked transfer after a restart.
* **Breaking — retry config flattened:** the `TransferRetryConfig` object is no
  longer part of the public API. Its knobs are now top-level fields on
  `WincheStorageConfig` (and `WincheStorage.withStore`): `retryBaseDelay`,
  `retryMaxDelay`, `retryMaxAttempts`, `retryPollInterval`.
* **Breaking — `ChildReference` renames** for self-describing names:
  `get()` → `getSnapshot()`, `list()` → `listChildren()`,
  `refresh()` → `refreshOfflineCopy()`,
  `evict()` → `removeOfflineCopy()`, `resume()` → `resumeTransfer()`.
  `makeAvailableOffline()` is unchanged.
* Offline staleness is now content-aware: the old `isStale()` bool is
  replaced by `offlineCopyStatus()` returning `OfflineCopyStatus`
  (`upToDate`/`contentChanged`/`remoteDeleted`/`notPinned`/`unknown`), driven by a
  new server content fingerprint exposed as `FileData.contentHash`.
* **Breaking — reads split into server vs cache.** `getSnapshot()` and
  `listChildren()` are now **server-only** (they no longer fall back to the cache
  or annotate results with `isCached`/`localPath`, and throw
  `StorageUnavailableException` when offline). New `offlineSnapshot()` and
  `offlineChildren()` read the local cache only (`fromCache: true`). Compose them
  for the old remote-first-with-fallback behavior.
* **Breaking:** `ChildReference.list()` now returns a `DirectorySnapshot` instead
  of `List<FileSnapshot>`. Read the files via `.files`. The snapshot adds
  directory-level metadata (`fromCache`, `name`, `length`, `isEmpty`).
* `list()` is now offline-aware: when the server is unreachable it returns the
  locally pinned files directly under the path with `fromCache: true` (a partial,
  pinned-only view) instead of throwing. With offline cache off it still throws.
* Upload-time pinning: `uploadPath` / `uploadBytes` accept
  `makeAvailableOffline: true` to place the uploaded bytes straight into the
  offline cache — no download roundtrip. Best-effort: a caching failure leaves
  the upload successful and records a stale pin for a later `refresh()`.
* `isStale()` now returns `false` when the server is unreachable (offline) rather
  than throwing; other API errors still propagate.
* `delete()` now cleans up local state after a successful server delete: it
  evicts any offline copy (local file + catalog entry) and drops any queued or
  in-flight transfer for the path, so a deleted file leaves no orphan behind.
* Added `WincheStorage.pendingTransfers({TransferKind? kind})` — a snapshot of
  the durable queue (pending/running/failed records), optionally filtered by
  kind (e.g. uploads only).

## 2.0.0

* Added the opt-in **offline cache**: pin files for offline use, remote-first
  reads with a local cache fallback, and on-demand freshness checks.
* Added the opt-in **auto-resume** layer: a durable transfer queue that survives
  app restarts and self-retries failed transfers with exponential backoff.

## 1.1.0

* Uploading to an existing path now overwrites a completed file when the size or
  MIME type differs, and discards an interrupted attempt for different content
  instead of throwing — a previously failed upload no longer blocks the path.
* Files at or below `multipartThreshold` now upload in a single request via the
  backend's single-shot upload endpoint; only larger files use multipart. This
  also fixes empty (0-byte) uploads, which previously failed.
* Downloads now verify the written byte count against the remote record size and
  fail on a truncated transfer, deleting the partial file before reporting.

## 1.0.0

* Initial Release
