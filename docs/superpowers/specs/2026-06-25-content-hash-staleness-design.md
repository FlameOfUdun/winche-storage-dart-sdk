# Content-aware offline staleness (ETag) — Design

**Date:** 2026-06-25
**Status:** Approved (pending spec review)
**Repos:** `.NET/WincheStorage` (backend) + `Dart/winche_storage` (SDK)

## Problem

`ChildReference.isOfflineCopyStale()` returns a `bool` derived from comparing
`version`/`updatedAt`/`sizeBytes`. That's ambiguous: it can't tell a **content
overwrite** (cached bytes now wrong → must re-download) from a **metadata
change** (cached bytes still valid), and `version` actually tracks metadata
mutations, not content. Other clients can overwrite a file's bytes in place
(same `id`), so the SDK needs a real content-change signal.

## Decisions (settled)

- **Fingerprint = the S3 ETag**, not SHA-256. The server never sees the bytes
  (presigned PUTs), but S3 already hands it the object's ETag on the requests it
  already makes at confirm. Any content overwrite yields a new ETag; a
  metadata-only change never touches the object, so the ETag is unchanged. (The
  ETag isn't a true content hash under multipart/SSE-KMS, but for "did the bytes
  change" it's sufficient — a false "changed" only costs a harmless re-download.)
- **`version` stays inert** — no DB migration, no `FileData` change. Staleness is
  ETag-only. (For a cached copy, only the bytes changing or deletion make it
  stale; metadata is always served fresh because reads are remote-first.)
- The SDK exposes **`offlineCopyStatus()`** returning an enum and **removes**
  `isOfflineCopyStale()`.
- When the ETag can't be compared (offline, or a legacy/pre-feature pin whose
  cached record has no `contentHash`) → **`unknown`**.
- **`refreshOfflineCopy()` is unchanged** (always re-downloads); callers check
  `offlineCopyStatus()` first.

## Backend changes (`.NET/WincheStorage`)

The cheapest fingerprint is the S3 ETag the server already fetches but discards.

1. **DDL** — add a nullable column (`SchemaManager.cs`):
   `content_hash TEXT NULL`. Nullable so existing rows backfill lazily (they get
   a hash the next time they're confirmed/overwritten).
2. **`FileRecord`** (`Models/FileRecord.cs`) — add
   `[JsonPropertyName("contentHash")] public string? ContentHash { get; init; }`.
3. **`NpgsqlFileReader.FromReader`** — read the `content_hash` column.
4. **`IArchive`** (`Interfaces/IArchive.cs`) — surface the ETag:
   - `ObjectExistsAsync` → return the object's ETag (and existence) instead of a
     bare `bool`. The single-shot confirm path already does a HEAD
     (`GetObjectMetadataAsync`) whose response carries `.ETag` — stop discarding
     it. No extra S3 round-trip.
   - `CompleteMultipartUploadAsync` → return the final object ETag from the
     `CompleteMultipartUploadResponse` (currently `await`ed and discarded).
   - Strip the surrounding quotes S3 wraps the ETag in before persisting.
5. **`ConfirmUploadAsync`** (`Services/FileStorage.cs`) — capture the ETag from
   the archive and thread it into the DB finalize.
6. **`ConfirmUploadOperation`** — `UPDATE … SET upload_status = @status,
   updated_at = NOW(), content_hash = @hash`. (Do **not** bump `version`.)
7. **`UpdateMetadataOperation`** — unchanged. It must never touch `content_hash`
   — that asymmetry is the whole point.

`setFile`/insert leaves `content_hash` null (set at confirm).

## SDK changes (`Dart/winche_storage`)

1. **`FileData`** — add an **optional** `String? contentHash` field (JSON
   `contentHash`), threaded through `fromJson`/`toJson`/`copyWith`. Optional so
   existing `FileData(...)` constructions (and the many test `_data` helpers) keep
   compiling; it defaults to `null`.
2. **`OfflineCopyStatus`** — a new enum, exported from the barrel:
   ```dart
   enum OfflineCopyStatus { notPinned, upToDate, contentChanged, remoteDeleted, unknown }
   ```
3. **`OfflineCatalog.offlineCopyStatus(path)`** (replaces `isStale`):
   ```
   entry = entryFor(path);            if entry == null            → notPinned
   try remote = api.getFile(path);    on StorageUnavailable       → unknown
   if remote == null                                              → remoteDeleted
   if remote.contentHash == null || entry.data.contentHash == null → unknown
   if remote.contentHash != entry.data.contentHash               → contentChanged
   else                                                          → upToDate
   ```
   Other (non-offline) API errors still propagate (consistent with the old
   `isStale`). The cached `contentHash` is whatever the record had at pin time.
   `id` is intentionally **not** compared: a delete-and-recreate that produced
   byte-identical content (same ETag) leaves the cached bytes valid → `upToDate`.
4. **`ChildReference.offlineCopyStatus()`** — delegates to the catalog; throws
   `StateError` when no store is configured (like the other offline methods).
   `ChildReference.isOfflineCopyStale()` is **removed**.
5. **`refreshOfflineCopy()`** — unchanged (re-downloads, repopulating the cached
   `contentHash`).

## Migration / compatibility

- The backend column and the `FileData.contentHash` field are both nullable.
- A file pinned before this feature has a cached record with `contentHash ==
  null` → `offlineCopyStatus()` returns `unknown` until it's refreshed (which
  repopulates the hash from the now-hash-bearing server record).
- A backend that hasn't deployed the change yet returns `contentHash == null` for
  everything → every status is `unknown` (degrades safely, never a false
  `upToDate`).

## Testing

**Backend:** confirm persists the S3 ETag into `content_hash`; `updateMetadata`
leaves `content_hash` untouched; `getFile`/`listDirectory` surface it.

**SDK:**
- `FileData` JSON round-trips `contentHash` (and omitting it → null).
- `offlineCopyStatus`: `notPinned` (nothing cached); `upToDate` (matching hash);
  `contentChanged` (differing hash); `remoteDeleted` (server 404 → null);
  `unknown` (offline via `StorageUnavailableException`); `unknown` (cached or
  remote `contentHash` null).
- Non-offline API errors propagate.
- `ChildReference.offlineCopyStatus()` throws `StateError` with no store.
