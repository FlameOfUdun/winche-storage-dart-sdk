# Pin-on-upload — Design

**Date:** 2026-06-25
**Status:** Approved (pending spec review)

## Problem

A consumer who uploads a file and then wants it available offline currently has to
call `makeAvailableOffline()` (`OfflineCatalog.pin`), which **downloads the file back
from the server**. That is a wasteful roundtrip: the bytes were just on the device.

We want to let the consumer mark a file **pinned at upload time** and populate the
offline cache directly from the source bytes already on hand, skipping the download.

## Goals

- Add a `pinned: true` option to `uploadPath()` and `uploadBytes()`.
- On a pinned upload, place the source bytes into the id-keyed offline cache and record
  a `ready` `CatalogEntry` — without issuing any download.
- Keep the upload robust: it must not fail just because the local caching step fails.
- Work across all upload variants: single-shot, multipart, and durable auto-resume
  (`TransferController`), plus `uploadBytes`.

## Non-goals

- No change to the existing download-based `makeAvailableOffline()` / `pin()` path; it
  remains for files that were not pinned at upload time.
- No change to the cache path scheme, eviction, or staleness rules beyond what is needed
  to land a pinned-on-upload file at its normal id-keyed path.

## Key design decision: stage-first (copy then upload)

Rather than upload-then-copy (which would require retaining a reference to the user's
original local path through the entire upload lifecycle, including durable resume across
app restarts), we **stage the cache copy first and upload *from* that copy**.

1. **Stage** — copy the source (file or in-memory bytes) into the cache directory under a
   `.staging/` subdir and verify it is intact (size match).
2. **Upload from the staged copy** — the staged file is the source of truth for the
   upload.
3. On `confirmUpload`, **finalize** the cache entry.

Benefits:

- **No long-lived reference to the original path.** Once staged, the upload reads from a
  path we own inside the cache dir — stable across an app restart, immune to the user
  moving or deleting their original file mid-upload.
- **Unifies `uploadPath` and `uploadBytes`** — both reduce to "ensure a local file
  exists, then upload it." For `uploadBytes`, the bytes are written to the staging file
  first, so the path-based upload engine handles both variants and there is no in-flight
  in-memory dependency.

### Subtlety: the cache filename is keyed by the server-assigned `id`

The final cache path is `<cacheDir>/<id><ext>`, and `id` is not known until
`confirmUpload` returns. So the file cannot be placed at its final name up front:

- Stage at a **temporary name** derived from the reference path (unique per upload target
  — it is already the catalog key): `<cacheDir>/.staging/<sanitized-path><ext>`.
- After `confirmUpload`, **atomically rename** staging → `<cacheDir>/<id><ext>` (same
  directory, so the rename is cheap and atomic), then write the `CatalogEntry` as
  `ready`.

This lands the pinned-on-upload file at the exact id-keyed path the rest of the system
expects, so `refresh` / `evict` / `isStale` all work identically.

## Public API

```dart
// child_reference.dart
UploadTask uploadPath(String localPath, {
  String? mimeType,
  Map<String, dynamic>? metadata,
  int? multipartThreshold,
  bool pinned = false,        // NEW
});

UploadTask uploadBytes(Uint8List bytes, String mimeType, {
  Map<String, dynamic>? metadata,
  int? multipartThreshold,
  bool pinned = false,        // NEW
});
```

`pinned` is a no-op (with a debug warning) when `enableOfflineCache` is off — there is no
cache to populate.

## Components & responsibilities

- **`ChildReference`** — orchestrates: ask the catalog to stage, run the upload from the
  staged copy, then ask the catalog to finalize. Adds the `pinned` param to both methods.

- **`OfflineCatalog`** — gains the staging lifecycle:
  - `stageForUpload(ref, {String? sourcePath, Uint8List? bytes})` → copies/writes the
    source to a staging path, verifies size, writes a `CatalogEntry(status: downloading)`,
    returns the staging path. Throws on failure (caller falls back).
  - `finalizePin(ref, FileData confirmed)` → atomic rename `staging → <dir>/<id><ext>`,
    rewrite the entry as `ready` with `localPath` set. On failure, mark `stale`.
  - `markPinDeferred(ref, FileData)` → write a `stale` entry when staging never happened
    (the fallback path), so a later `refresh` reconciles it.

- **`local_paths.dart`** — add `stagingFilePath(dir, refPath, {mimeType, sourceName})`
  deriving a unique, sanitized staging name under a `.staging/` subdir.

- **`TransferController` / `TransferRecord`** — carry `pinned` + `stagingPath` so a durable
  resume can call `finalizePin` on completion. This is the only durable-subsystem touch;
  it is small because the staging path is stable.

## Data flow (happy path)

1. `pinned: true` → `catalog.stageForUpload` copies the source into `.staging/`, verifies,
   writes a `downloading` entry.
2. Upload runs from the staged path (for `uploadBytes`, bytes are written to staging
   first, so both variants use the path-based upload engine).
3. `confirmUpload` returns `FileData` with the server `id`.
4. `catalog.finalizePin` renames staging → `<dir>/<id><ext>`, writes a `ready` entry with
   `localPath` set.
5. `whenDone` resolves with a `FileSnapshot` already reflecting `isCached: true`.

## Error handling

| Failure | Result |
|---|---|
| Staging copy fails (disk full, etc.) | Don't abort. Upload from the **original** source; after confirm, write a **stale** entry via `markPinDeferred`. Upload succeeds. |
| Upload fails | Staging file is cleaned up / left for the resume queue; no `ready` entry. Normal upload-failure semantics apply. |
| Rename/finalize fails after a successful upload | Upload succeeds; entry marked **stale** for a later `refresh` to reconcile. |
| App restart mid-upload (auto-resume) | `TransferRecord` carries `pinned` + `stagingPath`; on resumed completion the controller calls `finalizePin`. |

## Edge cases

- **Reconcile / overwrite** of an existing remote file: staging + rename still applies; the
  post-confirm `id` is authoritative for the final name.
- **`pinned: true` but `enableOfflineCache: false`**: no-op + debug warning.
- **Crash between `confirmUpload` and rename**: the durable record knows it confirmed; on
  restart, finalize re-runs the rename only. Finalize is idempotent — staging present →
  rename; final already present → just (re)write the `ready` entry.

## Testing

**Unit**
- `stageForUpload`: copy + verify for both the path source and the bytes source.
- `finalizePin`: rename staging → id-keyed path; entry becomes `ready` with `localPath`.
- Fallback-to-stale when `stageForUpload` throws.
- No-op (+ warning) when `enableOfflineCache` is off.
- `finalizePin` idempotency when the final file already exists.

**Integration** (memory store + temp dir)
- `uploadPath(pinned: true)` ends with a `ready` entry and the bytes present at the
  id-keyed path, **with no download issued**.
- `uploadBytes(pinned: true)` likewise.
- Auto-resume path: after a simulated restart, the controller finalizes the pin.
- Assert no `generateDownloadUrl` / `DownloadTask` call occurs during a pinned upload.
