# CHANGELOG

## 4.0.0

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

## 3.0.0

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
