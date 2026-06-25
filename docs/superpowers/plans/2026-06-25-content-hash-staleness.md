# Content-aware offline staleness (ETag) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist the S3 ETag as a per-file content fingerprint so the SDK can tell a content overwrite from a metadata-only change, via a new `offlineCopyStatus()` returning `OfflineCopyStatus`.

**Architecture:** The backend captures the object's ETag (already returned by the S3 HEAD on single-shot confirm and the complete-multipart response, both currently discarded), stores it in a nullable `content_hash` column at `confirmUpload`, and never touches it on `updateMetadata`. The SDK adds an optional `FileData.contentHash`, and `offlineCopyStatus()` compares the cached vs remote hash (`unknown` when either is null or offline).

**Tech Stack:** Backend — C#/.NET 10, ASP.NET Minimal API, Npgsql (raw SQL), AWS S3, xUnit. SDK — Dart, `package:test`.

**Source spec:** `docs/superpowers/specs/2026-06-25-content-hash-staleness-design.md`.

## Two independent parts

The two repos are separately testable and can be built/verified independently:
- **Part A — Backend** (`C:\Users\Ehsan Rashidi\Desktop\Winche\.NET\WincheStorage`): persist the ETag. Verified by `dotnet build` + `dotnet test` (xUnit surface tests; the project has **no** Postgres/S3 integration harness, so DB/S3 *behavior* is verified out-of-band — each task notes this honestly).
- **Part B — SDK** (`C:\Users\Ehsan Rashidi\Desktop\Winche\Dart\winche_storage`): consume `contentHash` and expose `offlineCopyStatus()`. Full TDD; degrades to `unknown` when the backend returns no hash, so it's testable before/without the backend deploy.

Do Part A first (so a real backend can populate hashes), but Part B does not block on it.

---

# Part A — Backend (.NET)

### Task A1: Persist `content_hash` (schema, model, reader)

**Files:**
- Modify: `src/Winche.Storage/Services/SchemaManager.cs`
- Modify: `src/Winche.Storage/Models/FileRecord.cs`
- Modify: `src/Winche.Storage/Infrastructure/NpgsqlFileReader.cs`
- Test: `tests/Winche.Storage.Tests/ContentHashSurfaceTests.cs` (create)

- [ ] **Step 1: Write the failing surface test**

Create `tests/Winche.Storage.Tests/ContentHashSurfaceTests.cs`:

```csharp
using System.Threading.Tasks;
using Winche.Storage.Interfaces;
using Winche.Storage.Models;
using Xunit;

namespace Winche.Storage.Tests;

public class ContentHashSurfaceTests
{
    [Fact]
    public void FileRecord_exposes_nullable_ContentHash_string()
    {
        var prop = typeof(FileRecord).GetProperty("ContentHash");
        Assert.NotNull(prop);
        Assert.Equal(typeof(string), prop!.PropertyType);
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run (from the backend repo root): `dotnet test tests/Winche.Storage.Tests --filter ContentHashSurfaceTests`
Expected: FAIL — `FileRecord` has no `ContentHash` property (assertion `Assert.NotNull(prop)` fails).

- [ ] **Step 3: Add the column** — in `SchemaManager.cs`, add `content_hash` to the `CREATE TABLE` body and an idempotent `ALTER` for existing databases. Change the `CREATE TABLE` columns to end with:

```sql
                upload_status SMALLINT  NOT NULL,
                upload_id     TEXT       NULL,
                content_hash  TEXT       NULL
            );

            ALTER TABLE {{WincheTables.Files}} ADD COLUMN IF NOT EXISTS content_hash TEXT;
```

(Keep the existing `CREATE INDEX` statements after that.)

- [ ] **Step 4: Add the model field** — in `FileRecord.cs`, after the `UploadId` property:

```csharp
    [JsonPropertyName("uploadId")]
    public string? UploadId { get; init; }

    [JsonPropertyName("contentHash")]
    public string? ContentHash { get; init; }
```

- [ ] **Step 5: Read the column** — in `NpgsqlFileReader.cs`, add to the `FromReader` object initializer (after the `UploadId` line):

```csharp
        UploadId = reader.IsDBNull(reader.GetOrdinal("upload_id")) ? null : reader.GetString(reader.GetOrdinal("upload_id")),
        ContentHash = reader.IsDBNull(reader.GetOrdinal("content_hash")) ? null : reader.GetString(reader.GetOrdinal("content_hash")),
```

- [ ] **Step 6: Run tests + build**

Run: `dotnet build` then `dotnet test tests/Winche.Storage.Tests`
Expected: build succeeds; the new surface test passes; all existing tests still pass.
Note: the actual round-trip through Postgres (column read/write) has no automated test in this repo — verify against a real DB when deploying.

- [ ] **Step 7: Commit**

```bash
git add src/Winche.Storage/Services/SchemaManager.cs src/Winche.Storage/Models/FileRecord.cs src/Winche.Storage/Infrastructure/NpgsqlFileReader.cs tests/Winche.Storage.Tests/ContentHashSurfaceTests.cs
git commit -m "Add content_hash column + FileRecord.ContentHash"
```

---

### Task A2: Capture the S3 ETag at confirm

**Files:**
- Modify: `src/Winche.Storage/Interfaces/IArchive.cs`
- Modify: `src/Winche.Storage.S3/Archives/S3Archive.cs`
- Modify: `src/Winche.Storage/Services/FileStorage.cs` (`ConfirmUploadAsync`)
- Modify: `src/Winche.Storage/Operations/ConfirmUploadOperation.cs`
- Test: `tests/Winche.Storage.Tests/ContentHashSurfaceTests.cs` (extend)

The single-shot confirm already does a HEAD (`ObjectExistsAsync`) whose response carries the ETag, and the multipart path's `CompleteMultipartUploadResponse` carries the final ETag — both discarded today. Surface them and persist into `content_hash`.

- [ ] **Step 1: Write the failing surface test** — append to `ContentHashSurfaceTests.cs`, inside the class:

```csharp
    [Fact]
    public void IArchive_exposes_GetObjectETagAsync_returning_Task_of_string()
    {
        var m = typeof(IArchive).GetMethod("GetObjectETagAsync");
        Assert.NotNull(m);
        Assert.Equal(typeof(Task<string>), m!.ReturnType); // string? erases to string at runtime
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `dotnet test tests/Winche.Storage.Tests --filter ContentHashSurfaceTests`
Expected: FAIL — `IArchive` has no `GetObjectETagAsync`.

- [ ] **Step 3: Update the interface** — in `IArchive.cs`, replace the `ObjectExistsAsync` line and change `CompleteMultipartUploadAsync` to return the ETag:

```csharp
    Task<string?> GetObjectETagAsync(string path, CancellationToken ct = default);
```
(replacing `Task<bool> ObjectExistsAsync(string path, CancellationToken ct = default);`)

```csharp
    Task<string?> CompleteMultipartUploadAsync(string path, string uploadId, CancellationToken ct = default);
```
(was `Task CompleteMultipartUploadAsync(...)`)

- [ ] **Step 4: Update `S3Archive.cs`** — add a private quote-stripping helper, rename `ObjectExistsAsync` → `GetObjectETagAsync` returning the ETag, and have `CompleteMultipartUploadAsync` return the final ETag.

Add the helper (anywhere in the class):
```csharp
    private static string? NormalizeETag(string? etag) => etag?.Trim('"');
```

Replace `ObjectExistsAsync`:
```csharp
    public async Task<string?> GetObjectETagAsync(string path, CancellationToken ct = default)
    {
        try
        {
            var meta = await s3.GetObjectMetadataAsync(new GetObjectMetadataRequest
            {
                BucketName = options.BucketName,
                Key = path,
            }, ct);
            return NormalizeETag(meta.ETag);
        }
        catch (AmazonS3Exception ex) when (ex.StatusCode == System.Net.HttpStatusCode.NotFound)
        {
            return null;
        }
    }
```

Change the end of `CompleteMultipartUploadAsync` from the discarded `await s3.CompleteMultipartUploadAsync(...)` to capture and return the ETag (signature becomes `Task<string?>`):
```csharp
    public async Task<string?> CompleteMultipartUploadAsync(string path, string uploadId, CancellationToken ct = default)
    {
        // ... unchanged list-parts loop ...
        var resp = await s3.CompleteMultipartUploadAsync(new CompleteMultipartUploadRequest
        {
            BucketName = options.BucketName,
            Key = path,
            UploadId = uploadId,
            PartETags = [.. parts.OrderBy(p => p.PartNumber).Select(p => new PartETag(p.PartNumber ?? 1, p.ETag))],
        }, ct);
        return NormalizeETag(resp.ETag);
    }
```

- [ ] **Step 5: Find and update other callers** — run `grep -rn "ObjectExistsAsync" src/` (Grep tool). The only production caller is `FileStorage.ConfirmUploadAsync`; update it in the next step. If any other caller exists, change it to `GetObjectETagAsync` and treat a `null` return as "not found".

- [ ] **Step 6: Thread the ETag through confirm** — in `src/Winche.Storage/Services/FileStorage.cs`, replace the body of `ConfirmUploadAsync` so it captures the hash and passes it to the DB op:

```csharp
    public async Task<FileRecord> ConfirmUploadAsync(string path, CancellationToken ct = default)
    {
        var file = await GetAsync(path, ct) ?? throw new FileRecordNotFoundException("File not found");
        if (file.UploadStatus != UploadStatus.Pending)
            throw new InvalidUploadStatusException(path, UploadStatus.Pending, file.UploadStatus);

        string? contentHash;
        if (file.UploadId is not null)
        {
            contentHash = await archive.CompleteMultipartUploadAsync(path, file.UploadId, ct);
            await using var conn1 = await source.OpenConnectionAsync(ct);
            await new SetUploadIdOperation(conn1, null).ExecuteAsync(path, null, ct);
        }
        else
        {
            contentHash = await archive.GetObjectETagAsync(path, ct);
            if (contentHash is null) throw new FileNotUploadedException(path);
        }

        await using var conn = await source.OpenConnectionAsync(ct);
        var record = await new ConfirmUploadOperation(conn, null).ExecuteAsync(path, contentHash, ct)
            ?? throw new FileRecordNotFoundException(path);
        hookDispatcher.Enqueue(path, (h, t) => h.OnUploadConfirmedAsync(record, t));
        return record;
    }
```

- [ ] **Step 7: Persist it** — in `src/Winche.Storage/Operations/ConfirmUploadOperation.cs`, add a `contentHash` parameter and the column to the UPDATE:

```csharp
    internal async Task<FileRecord?> ExecuteAsync(string path, string? contentHash, CancellationToken ct)
    {
        var info = FilePathParser.Parse(path);

        await using var cmd = conn.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = $"""
            UPDATE {WincheTables.Files}
            SET upload_status = @status, updated_at = NOW(), content_hash = @hash
            WHERE path = @path
            RETURNING *
            """;

        cmd.Parameters.AddWithValue("status", (short)UploadStatus.Complete);
        cmd.Parameters.AddWithValue("hash", (object?)contentHash ?? DBNull.Value);
        cmd.Parameters.AddWithValue("path", path);

        await using var reader = await cmd.ExecuteReaderAsync(ct);
        return await NpgsqlFileReader.ReadSingleAsync(reader, ct);
    }
```

Leave `src/Winche.Storage/Operations/UpdateMetadataOperation.cs` **unchanged** — it must never touch `content_hash` (that asymmetry is the whole feature).

- [ ] **Step 8: Build + tests**

Run: `dotnet build` then `dotnet test tests/Winche.Storage.Tests`
Expected: build succeeds; the two surface tests pass; existing tests still pass.
Note: the ETag-capture-on-confirm behavior itself is an S3+DB integration path with no unit harness here — verify against a real bucket/DB on deploy.

- [ ] **Step 9: Commit**

```bash
git add src/Winche.Storage/Interfaces/IArchive.cs src/Winche.Storage.S3/Archives/S3Archive.cs src/Winche.Storage/Services/FileStorage.cs src/Winche.Storage/Operations/ConfirmUploadOperation.cs tests/Winche.Storage.Tests/ContentHashSurfaceTests.cs
git commit -m "Capture S3 ETag into content_hash on confirm"
```

---

# Part B — SDK (Dart)

All paths below are under `C:\Users\Ehsan Rashidi\Desktop\Winche\Dart\winche_storage`.

### Task B1: `FileData.contentHash`

**Files:**
- Modify: `lib/src/models/file_data.dart`
- Test: `test/file_data_json_test.dart`

- [ ] **Step 1: Write the failing test** — append inside `main()` of `test/file_data_json_test.dart`:

```dart
  test('contentHash round-trips and defaults to null when absent', () {
    final data = FileData(
      id: 'i', directory: 'd', path: 'a/b',
      createdAt: DateTime.utc(2026, 1, 1), updatedAt: DateTime.utc(2026, 1, 1),
      metadata: const {}, version: 1, mimeType: 'image/png', sizeBytes: 3,
      uploadStatus: UploadStatus.complete, contentHash: 'etag-123',
    );
    expect(FileData.fromJson(data.toJson()).contentHash, 'etag-123');

    final json = Map<String, dynamic>.from(data.toJson())..remove('contentHash');
    expect(FileData.fromJson(json).contentHash, isNull);
  });
```

- [ ] **Step 2: Run it to verify it fails**

Run: `dart test test/file_data_json_test.dart -n contentHash`
Expected: FAIL — `FileData` has no `contentHash` parameter.

- [ ] **Step 3: Implement** — in `lib/src/models/file_data.dart`:

Add the field (after `isCached`):
```dart
  /// The server's content fingerprint (the object ETag) at the time this record
  /// was read. Changes when the file's bytes are overwritten, not on a
  /// metadata-only change. Null when the server hasn't recorded one. Server-side.
  final String? contentHash;
```

Add to the constructor (with the other optionals):
```dart
    this.localPath,
    this.isCached = false,
    this.contentHash,
```

Add to `fromJson` (after `isCached:`):
```dart
      isCached: json['isCached'] as bool? ?? false,
      contentHash: json['contentHash'] as String?,
```

Add to `copyWith` — a `String? contentHash` parameter and pass-through:
```dart
  FileData copyWith({
    Map<String, dynamic>? metadata,
    UploadStatus? uploadStatus,
    DateTime? updatedAt,
    String? localPath,
    bool? isCached,
    String? contentHash,
  }) {
    return FileData(
      id: id,
      directory: directory,
      path: path,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      metadata: metadata ?? this.metadata,
      version: version,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      uploadStatus: uploadStatus ?? this.uploadStatus,
      localPath: localPath ?? this.localPath,
      isCached: isCached ?? this.isCached,
      contentHash: contentHash ?? this.contentHash,
    );
  }
```

Add to `toJson` (after `isCached`):
```dart
        'isCached': isCached,
        'contentHash': contentHash,
```

- [ ] **Step 4: Run tests**

Run: `dart test test/file_data_json_test.dart && dart analyze lib/src/models/file_data.dart`
Expected: PASS; analyzer clean.

- [ ] **Step 5: Commit**

```bash
git add lib/src/models/file_data.dart test/file_data_json_test.dart
git commit -m "Add optional FileData.contentHash"
```

---

### Task B2: `OfflineCopyStatus` enum

**Files:**
- Create: `lib/src/offline/offline_copy_status.dart`
- Modify: `lib/winche_storage.dart` (export)
- Test: `test/offline/offline_copy_status_test.dart` (create)

- [ ] **Step 1: Write the failing test** — create `test/offline/offline_copy_status_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:winche_storage/winche_storage.dart';

void main() {
  test('OfflineCopyStatus is exported with the expected values', () {
    expect(OfflineCopyStatus.values, [
      OfflineCopyStatus.notPinned,
      OfflineCopyStatus.upToDate,
      OfflineCopyStatus.contentChanged,
      OfflineCopyStatus.remoteDeleted,
      OfflineCopyStatus.unknown,
    ]);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `dart test test/offline/offline_copy_status_test.dart`
Expected: FAIL — `OfflineCopyStatus` undefined.

- [ ] **Step 3: Implement** — create `lib/src/offline/offline_copy_status.dart`:

```dart
/// The freshness of a pinned offline copy relative to the server, as reported by
/// `ChildReference.offlineCopyStatus()`.
enum OfflineCopyStatus {
  /// Nothing is pinned at this path.
  notPinned,

  /// The cached bytes match the current remote content.
  upToDate,

  /// The remote content was overwritten — the cached bytes are stale, so
  /// `refreshOfflineCopy()` should be called to re-download them.
  contentChanged,

  /// The remote file no longer exists.
  remoteDeleted,

  /// Couldn't be determined — the server was unreachable (offline), or no content
  /// fingerprint is available on the cached or remote record (e.g. a file pinned
  /// before content hashing existed).
  unknown,
}
```

Add the export to `lib/winche_storage.dart` (next to the other offline exports):
```dart
export 'src/offline/offline_copy_status.dart' show OfflineCopyStatus;
```

- [ ] **Step 4: Run tests**

Run: `dart test test/offline/offline_copy_status_test.dart && dart analyze`
Expected: PASS; clean.

- [ ] **Step 5: Commit**

```bash
git add lib/src/offline/offline_copy_status.dart lib/winche_storage.dart test/offline/offline_copy_status_test.dart
git commit -m "Add OfflineCopyStatus enum"
```

---

### Task B3: `OfflineCatalog.offlineCopyStatus` (replaces `isStale`)

**Files:**
- Modify: `lib/src/offline/offline_catalog.dart`
- Test: `test/offline/offline_catalog_test.dart`

- [ ] **Step 1: Write the failing tests** — in `test/offline/offline_catalog_test.dart`, REPLACE the three existing `isStale:` tests (`'isStale: false when nothing pinned'`, `'isStale: true when remote version differs from stored'`, `'isStale: true when remote deleted'`) **and** the two added ones (`'isStale: false when offline (server unreachable)'`, `'isStale: rethrows non-offline API errors'`) with these. (The `_Api`, `_ThrowingApi`, `_data`, `build`, `buildThrowing` helpers already exist in the file; extend `_data` to accept a hash by adding an optional param — see Step 3.)

```dart
  test('offlineCopyStatus: notPinned when nothing is cached', () async {
    final cat = build({'a/b.png': _data('a/b.png')});
    expect(await cat.offlineCopyStatus('a/b.png'), OfflineCopyStatus.notPinned);
  });

  test('offlineCopyStatus: upToDate when hashes match', () async {
    final cat = build({'a/b.png': _data('a/b.png', hash: 'h1')});
    await cat.debugPut(CatalogEntry(
      data: _data('a/b.png', hash: 'h1'),
      localPath: '${tmp.path}/id-a_b.png',
      pinnedAt: DateTime.utc(2026, 1, 1),
      status: CatalogStatus.ready,
    ));
    expect(await cat.offlineCopyStatus('a/b.png'), OfflineCopyStatus.upToDate);
  });

  test('offlineCopyStatus: contentChanged when remote hash differs', () async {
    final cat = build({'a/b.png': _data('a/b.png', hash: 'h2')});
    await cat.debugPut(CatalogEntry(
      data: _data('a/b.png', hash: 'h1'),
      localPath: '${tmp.path}/id-a_b.png',
      pinnedAt: DateTime.utc(2026, 1, 1),
      status: CatalogStatus.ready,
    ));
    expect(await cat.offlineCopyStatus('a/b.png'),
        OfflineCopyStatus.contentChanged);
  });

  test('offlineCopyStatus: remoteDeleted when the server has no record',
      () async {
    final cat = build({'a/b.png': null});
    await cat.debugPut(CatalogEntry(
      data: _data('a/b.png', hash: 'h1'),
      localPath: '${tmp.path}/id-a_b.png',
      pinnedAt: DateTime.utc(2026, 1, 1),
      status: CatalogStatus.ready,
    ));
    expect(await cat.offlineCopyStatus('a/b.png'),
        OfflineCopyStatus.remoteDeleted);
  });

  test('offlineCopyStatus: unknown when a hash is missing', () async {
    final cat = build({'a/b.png': _data('a/b.png')}); // remote hash null
    await cat.debugPut(CatalogEntry(
      data: _data('a/b.png', hash: 'h1'),
      localPath: '${tmp.path}/id-a_b.png',
      pinnedAt: DateTime.utc(2026, 1, 1),
      status: CatalogStatus.ready,
    ));
    expect(await cat.offlineCopyStatus('a/b.png'), OfflineCopyStatus.unknown);
  });

  test('offlineCopyStatus: unknown when offline', () async {
    final cat = buildThrowing(const StorageUnavailableException('offline'));
    await cat.debugPut(CatalogEntry(
      data: _data('a/b.png', hash: 'h1'),
      localPath: '${tmp.path}/id-a_b.png',
      pinnedAt: DateTime.utc(2026, 1, 1),
      status: CatalogStatus.ready,
    ));
    expect(await cat.offlineCopyStatus('a/b.png'), OfflineCopyStatus.unknown);
  });

  test('offlineCopyStatus: rethrows non-offline API errors', () async {
    final cat = buildThrowing(const StorageInternalException('boom'));
    await cat.debugPut(CatalogEntry(
      data: _data('a/b.png', hash: 'h1'),
      localPath: '${tmp.path}/id-a_b.png',
      pinnedAt: DateTime.utc(2026, 1, 1),
      status: CatalogStatus.ready,
    ));
    expect(() => cat.offlineCopyStatus('a/b.png'),
        throwsA(isA<StorageInternalException>()));
  });
```

- [ ] **Step 2: Run it to verify it fails**

Run: `dart test test/offline/offline_catalog_test.dart -n offlineCopyStatus`
Expected: FAIL — `offlineCopyStatus` not defined / `_data` has no `hash` param.

- [ ] **Step 3: Update the `_data` helper** — in `test/offline/offline_catalog_test.dart`, add an optional `hash` param to the `_data` factory so the tests can set `contentHash`:

```dart
FileData _data(String path, {int version = 1, int size = 3, String? hash}) =>
    FileData(
      id: 'id-${path.replaceAll('/', '_')}',
      directory: 'd',
      path: path,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, version),
      metadata: const {},
      version: version,
      mimeType: 'image/png',
      sizeBytes: size,
      uploadStatus: UploadStatus.complete,
      contentHash: hash,
    );
```

- [ ] **Step 4: Implement** — in `lib/src/offline/offline_catalog.dart`, add the import and REPLACE the `isStale` method with `offlineCopyStatus`:

Add the import (with the other offline imports):
```dart
import 'offline_copy_status.dart';
```

Replace the entire `isStale(String path)` method with:
```dart
  /// The freshness of the pinned copy at [path] relative to the server. Compares
  /// the cached content fingerprint against the current remote one; returns
  /// [OfflineCopyStatus.unknown] when offline or when either fingerprint is
  /// absent. Other (non-offline) API errors propagate.
  Future<OfflineCopyStatus> offlineCopyStatus(String path) async {
    final entry = await entryFor(path);
    if (entry == null) return OfflineCopyStatus.notPinned;
    final FileData? remote;
    try {
      remote = await _api.getFile(path);
    } on StorageUnavailableException {
      return OfflineCopyStatus.unknown;
    }
    if (remote == null) return OfflineCopyStatus.remoteDeleted;
    final remoteHash = remote.contentHash;
    final cachedHash = entry.data.contentHash;
    if (remoteHash == null || cachedHash == null) {
      return OfflineCopyStatus.unknown;
    }
    return remoteHash == cachedHash
        ? OfflineCopyStatus.upToDate
        : OfflineCopyStatus.contentChanged;
  }
```

- [ ] **Step 5: Run tests**

Run: `dart test test/offline/offline_catalog_test.dart && dart analyze lib/src/offline/offline_catalog.dart`
Expected: PASS; clean.

- [ ] **Step 6: Commit**

```bash
git add lib/src/offline/offline_catalog.dart test/offline/offline_catalog_test.dart
git commit -m "Replace OfflineCatalog.isStale with offlineCopyStatus"
```

---

### Task B4: `ChildReference.offlineCopyStatus` + update callers

**Files:**
- Modify: `lib/src/child_reference.dart`
- Modify: `test/offline/child_reference_offline_test.dart`, `example/lib/main.dart` (callers)

- [ ] **Step 1: Write the failing test** — in `test/offline/child_reference_offline_test.dart`, replace the test that used `ref.isOfflineCopyStale` with one using the new method. Find the test asserting the stale getter and rewrite its body to:

```dart
    expect(() => ref.offlineCopyStatus(), throwsStateError); // no catalog → StateError
```

(If that file constructs a `ChildReference` with a catalog and asserts a stale value, change `ref.isOfflineCopyStale()` → `ref.offlineCopyStatus()` and assert the corresponding `OfflineCopyStatus`.)

- [ ] **Step 2: Run it to verify it fails**

Run: `dart test test/offline/child_reference_offline_test.dart`
Expected: FAIL — `offlineCopyStatus` not defined on `ChildReference`.

- [ ] **Step 3: Implement** — in `lib/src/child_reference.dart`, add the import and REPLACE `isOfflineCopyStale()`:

Add the import (with the offline imports):
```dart
import 'offline/offline_copy_status.dart';
```

Replace the `isOfflineCopyStale()` method with:
```dart
  /// The freshness of this file's pinned offline copy: `notPinned`, `upToDate`,
  /// `contentChanged` (re-download via [refreshOfflineCopy]), `remoteDeleted`, or
  /// `unknown` (offline / no fingerprint). Requires a configured store.
  Future<OfflineCopyStatus> offlineCopyStatus() {
    final c = catalog;
    if (c == null) {
      throw StateError(
          'no offline store configured (set directoryResolver or inMemory).');
    }
    return c.offlineCopyStatus(path);
  }
```

- [ ] **Step 4: Update the example** — in `example/lib/main.dart`, the `'stale'` case of `_handleAction` currently calls `ref.isOfflineCopyStale()`. Replace it with:

```dart
      case 'stale':
        try {
          final status = await ref.offlineCopyStatus();
          _snack('Offline copy: ${status.name}');
        } catch (e) {
          _snack('Status check failed: $e');
        }
```

- [ ] **Step 5: Run analyzer to catch any remaining callers, then the full suite**

Run: `dart analyze`
Expected: clean. If it flags any other `isOfflineCopyStale()` caller (e.g. a test), change it to `offlineCopyStatus()` and adjust the assertion to an `OfflineCopyStatus`.

Run: `dart test`
Expected: all tests pass.

Run: `cd example && flutter analyze`
Expected: No issues found.

- [ ] **Step 6: Commit**

```bash
git add lib/src/child_reference.dart test/offline/child_reference_offline_test.dart example/lib/main.dart
git commit -m "Replace ChildReference.isOfflineCopyStale with offlineCopyStatus"
```

---

### Task B5: Docs (README + CHANGELOG)

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Update the Offline-cache staleness example** — in `README.md`, replace the `isOfflineCopyStale()` snippet (the `final bool stale = await photoRef.isOfflineCopyStale();` block) with:

```dart
// What changed about the pinned copy? (content overwrite vs deleted vs current)
switch (await photoRef.offlineCopyStatus()) {
  case OfflineCopyStatus.contentChanged:
    await photoRef.refreshOfflineCopy(); // bytes changed — re-download
  case OfflineCopyStatus.remoteDeleted:
    await photoRef.removeOfflineCopy();  // gone — drop the local copy
  case OfflineCopyStatus.upToDate:
  case OfflineCopyStatus.notPinned:
  case OfflineCopyStatus.unknown:        // offline / no fingerprint — leave as-is
    break;
}
```

- [ ] **Step 2: Update the `ChildReference` API table row** — replace the `isOfflineCopyStale()` row with:

```
| `offlineCopyStatus()` | `Future<OfflineCopyStatus>` — `upToDate` / `contentChanged` / `remoteDeleted` / `notPinned` / `unknown` (offline or no fingerprint). Requires a configured store. |
```

- [ ] **Step 3: Add `OfflineCopyStatus` to the types section** — in the "Offline / auto-resume types" table, add:

```
| `OfflineCopyStatus` | `notPinned`, `upToDate`, `contentChanged`, `remoteDeleted`, `unknown` — result of `offlineCopyStatus()`. |
```

- [ ] **Step 4: Note `contentHash` on `FileData`** — in the `FileData` fields paragraph, add `contentHash` to the listed fields and a one-line note: "`contentHash` — the server's content fingerprint (object ETag), used by `offlineCopyStatus()`; null when the backend hasn't recorded one."

- [ ] **Step 5: CHANGELOG** — add a bullet to the `4.0.0` entry:

```
* Offline staleness is now content-aware: `isOfflineCopyStale()` (bool) is
  replaced by `offlineCopyStatus()` returning `OfflineCopyStatus`
  (`upToDate`/`contentChanged`/`remoteDeleted`/`notPinned`/`unknown`), driven by a
  new server content fingerprint exposed as `FileData.contentHash`.
```

- [ ] **Step 6: Verify + commit**

Run: `dart analyze && dart test`
Expected: clean; all pass (docs don't affect these, but confirm nothing regressed).

```bash
git add README.md CHANGELOG.md
git commit -m "Document offlineCopyStatus + contentHash"
```

---

## Self-review

- **Spec coverage:** backend `content_hash` column/model/reader (A1), ETag capture at confirm + `updateMetadata` untouched (A2); SDK `FileData.contentHash` (B1), `OfflineCopyStatus` enum (B2), catalog `offlineCopyStatus` with the exact decision table incl. `unknown`-on-missing-hash and `unknown`-on-offline (B3), `ChildReference.offlineCopyStatus` replacing `isOfflineCopyStale` (B4), docs (B5). All spec sections map to a task.
- **Type names consistent:** `contentHash` (SDK) / `ContentHash` / `content_hash` (backend); `OfflineCopyStatus` and its five values are identical across B2/B3/B4/B5.
- **`id` deliberately not compared** in `offlineCopyStatus` (per spec — a byte-identical recreate stays `upToDate`).
- **Honest test gap:** the backend has no Postgres/S3 integration harness, so A1/A2 verify via surface tests + `dotnet build`/`dotnet test`; the persistence/ETag-capture behavior is integration-verified out of band (noted in each task).
- **Compat:** nullable column + optional `FileData.contentHash`; legacy/undeployed → `unknown` (B3 covers it).
