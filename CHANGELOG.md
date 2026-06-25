# CHANGELOG

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
