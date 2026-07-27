# CHANGELOG

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
* **`WincheStorage.resumeTransfers()`** — re-drives every transfer halted by a
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
  followed by `pendingTransfers()` could still see the finished transfer, and the
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
