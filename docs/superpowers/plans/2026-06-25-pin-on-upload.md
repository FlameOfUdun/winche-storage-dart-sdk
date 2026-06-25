# Pin-on-upload Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a consumer mark a file `pinned` when uploading so its bytes are placed directly into the offline cache, skipping the download roundtrip that `makeAvailableOffline()` would otherwise incur.

**Architecture:** Stage-first. When `pinned: true`, the upload source is first copied into a `.staging/` area inside the cache directory and the upload runs *from that staged copy* (so it no longer depends on the caller's original file). On `confirmUpload`, the staged file is atomically renamed to the id-keyed cache path `<dir>/<id><ext>` and a `ready` `CatalogEntry` is written. Caching is best-effort: any failure leaves the upload successful and records a `stale` entry for a later `refresh` to fill in. Works for `uploadPath` (direct and via the durable `TransferController`) and `uploadBytes` (direct).

**Tech Stack:** Dart, `dio` (HTTP), `sembast`/in-memory `StorageLocalStore`, `package:test`.

---

## Background: how the pieces fit

- `ChildReference.uploadPath/uploadBytes` (`lib/src/child_reference.dart:138,167`) build an `UploadTask`. `uploadPath` routes through `TransferController.startUpload` when auto-resume is on; `uploadBytes` always runs a direct `UploadTask`.
- `UploadTask._run` (`lib/src/tasks/upload_task.dart:139`) reconciles the remote record, uploads (single-shot or multipart), then `confirmUpload` returns the `FileData` carrying the server-assigned `id`.
- The cache path scheme is `<dir>/<id><ext>` via `localFilePath` (`lib/src/offline/local_paths.dart:45`). `OfflineCatalog` (`lib/src/offline/offline_catalog.dart`) owns the cache; entries are `CatalogEntry` with `CatalogStatus { downloading, ready, stale }`.
- `TransferController` (`lib/src/offline/transfer_controller.dart`) persists `TransferRecord`s and recreates tasks on restart/retry. It is constructed **before** the catalog in `WincheStorage._build` (`lib/winche_storage.dart:171-208`); both share a memoized `directoryResolver`.

**Key invariant:** the staging path must be *deterministic* from the reference path so a resumed/retried upload (which has lost the original closures) recomputes the exact same path. We therefore key the staging file by a stable hash of `refPath` and give it **no extension** (the extension only matters for the final id-keyed name).

---

## Task 1: Deterministic staging path in `local_paths.dart`

**Files:**
- Modify: `lib/src/offline/local_paths.dart`
- Test: `test/offline/local_paths_test.dart`

- [ ] **Step 1: Write the failing test**

Append to `test/offline/local_paths_test.dart` (inside `main()`):

```dart
  test('stagingFilePath is under .staging, hashed, and extension-free', () {
    final a = stagingFilePath('/cache', 'a/b.png');
    expect(p.split(a), containsAllInOrder(['.staging']));
    expect(p.basename(a), isNot(contains('.'))); // no extension
    expect(a, p.normalize(a));
  });

  test('stagingFilePath is deterministic and unique per ref path', () {
    expect(stagingFilePath('/cache', 'a/b.png'),
        stagingFilePath('/cache', 'a/b.png'));
    expect(stagingFilePath('/cache', 'a/b.png'),
        isNot(stagingFilePath('/cache', 'a/c.png')));
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/offline/local_paths_test.dart -n stagingFilePath`
Expected: FAIL — `stagingFilePath` is not defined.

- [ ] **Step 3: Implement**

Append to `lib/src/offline/local_paths.dart`:

```dart
/// A deterministic FNV-1a (32-bit) hash of [s], rendered as 8 hex chars.
/// Dart's `String.hashCode` is not guaranteed stable across runs, so a resumed
/// upload could not recompute a `hashCode`-based path — this can.
String _stableHash(String s) {
  var hash = 0x811c9dc5; // FNV offset basis
  for (final unit in s.codeUnits) {
    hash ^= unit & 0xff;
    hash = (hash * 0x01000193) & 0xffffffff; // FNV prime, kept to 32 bits
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

/// The staging path for an in-progress pinned upload of [refPath]. Lives under a
/// `.staging/` subdir of [directory], keyed by a stable hash of [refPath] (unique
/// per upload target) and intentionally extension-free. Deterministic, so a
/// resumed upload recomputes the same path.
String stagingFilePath(String directory, String refPath) =>
    p.normalize(p.join(directory, '.staging', _stableHash(refPath)));
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/offline/local_paths_test.dart`
Expected: PASS (all tests in the file).

- [ ] **Step 5: Commit**

```bash
git add lib/src/offline/local_paths.dart test/offline/local_paths_test.dart
git commit -m "Add deterministic staging path helper"
```

---

## Task 2: `OfflineCatalog.stageForUpload`

**Files:**
- Modify: `lib/src/offline/offline_catalog.dart`
- Test: `test/offline/offline_catalog_test.dart`

- [ ] **Step 1: Write the failing test**

Append inside `main()` of `test/offline/offline_catalog_test.dart`:

```dart
  test('stageForUpload copies a source file into .staging and verifies size',
      () async {
    final cat = build({});
    final src = File('${tmp.path}/src.bin')..writeAsBytesSync([1, 2, 3, 4]);
    final ref = ChildReference(path: 'a/b.png', api: _Api({}));

    final staged = await cat.stageForUpload(ref, sourcePath: src.path);

    expect(File(staged).existsSync(), isTrue);
    expect(File(staged).lengthSync(), 4);
    expect(p.split(staged), contains('.staging'));
  });

  test('stageForUpload writes in-memory bytes into .staging', () async {
    final cat = build({});
    final ref = ChildReference(path: 'a/b.png', api: _Api({}));

    final staged =
        await cat.stageForUpload(ref, bytes: Uint8List.fromList([9, 9]));

    expect(File(staged).readAsBytesSync(), [9, 9]);
  });
```

Add these imports at the top of the test file if missing:

```dart
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:winche_storage/src/child_reference.dart';
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/offline/offline_catalog_test.dart -n stageForUpload`
Expected: FAIL — `stageForUpload` is not defined.

- [ ] **Step 3: Implement**

In `lib/src/offline/offline_catalog.dart`, add the import for staging/local file (already imports `local_paths.dart`; add `dart:typed_data`):

```dart
import 'dart:typed_data';
```

Add a shared resolver helper and the staging method (place above `_put`):

```dart
  Future<String> _requireDir() async {
    final resolver = _directoryResolver;
    if (resolver == null) {
      throw StateError(
          'directoryResolver is required to store files for offline use.');
    }
    return resolver();
  }

  /// Copies/writes the upload source into the staging area and returns the
  /// staged path. Throws on any I/O error so the caller can fall back to a
  /// deferred (stale) pin. Provide exactly one of [sourcePath] or [bytes].
  Future<String> stageForUpload(
    ChildReference ref, {
    String? sourcePath,
    Uint8List? bytes,
  }) async {
    final dir = await _requireDir();
    final staging = stagingFilePath(dir, ref.path);
    final file = File(staging);
    await file.parent.create(recursive: true);

    final int expected;
    if (bytes != null) {
      await file.writeAsBytes(bytes, flush: true);
      expected = bytes.length;
    } else {
      await File(sourcePath!).copy(staging);
      expected = await File(sourcePath).length();
    }

    final actual = await file.length();
    if (actual != expected) {
      throw StateError('Staged copy size mismatch ($actual != $expected).');
    }
    return staging;
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/offline/offline_catalog_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/src/offline/offline_catalog.dart test/offline/offline_catalog_test.dart
git commit -m "Add OfflineCatalog.stageForUpload"
```

---

## Task 3: `OfflineCatalog.finalizePin` and `markPinDeferred`

**Files:**
- Modify: `lib/src/offline/offline_catalog.dart`
- Test: `test/offline/offline_catalog_test.dart`

- [ ] **Step 1: Write the failing test**

Append inside `main()` of `test/offline/offline_catalog_test.dart`:

```dart
  test('finalizePin moves the staged file to the id-keyed path, entry ready',
      () async {
    final cat = build({});
    final ref = ChildReference(path: 'a/b.png', api: _Api({}));
    final staged =
        await cat.stageForUpload(ref, bytes: Uint8List.fromList([1, 2, 3]));
    final confirmed = _data('a/b.png'); // id 'id-a_b.png', mime image/png

    await cat.finalizePin(ref, confirmed);

    final expectedFinal = '${tmp.path}/id-a_b.png.png';
    expect(File(staged).existsSync(), isFalse); // moved, not copied
    expect(File(expectedFinal).readAsBytesSync(), [1, 2, 3]);
    final entry = await cat.entryFor('a/b.png');
    expect(entry!.status, CatalogStatus.ready);
    expect(entry.localPath, expectedFinal);
  });

  test('finalizePin without a staged file records a stale (deferred) entry',
      () async {
    final cat = build({});
    final ref = ChildReference(path: 'a/b.png', api: _Api({}));

    await cat.finalizePin(ref, _data('a/b.png')); // nothing staged

    final entry = await cat.entryFor('a/b.png');
    expect(entry!.status, CatalogStatus.stale);
  });

  test('markPinDeferred records a stale entry at the id-keyed path', () async {
    final cat = build({});
    final ref = ChildReference(path: 'a/b.png', api: _Api({}));

    await cat.markPinDeferred(ref, _data('a/b.png'));

    final entry = await cat.entryFor('a/b.png');
    expect(entry!.status, CatalogStatus.stale);
    expect(entry.localPath, '${tmp.path}/id-a_b.png.png');
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/offline/offline_catalog_test.dart -n "finalizePin"`
Expected: FAIL — `finalizePin` is not defined.

- [ ] **Step 3: Implement**

In `lib/src/offline/offline_catalog.dart`, add below `stageForUpload`:

```dart
  /// Finalizes a pinned upload: moves the staged copy to the id-keyed cache path
  /// and records a `ready` entry. Idempotent — if the final file already exists
  /// it just (re)writes the entry. Falls back to a `stale` entry (a later
  /// [refresh] fills it in) when neither a staged nor a final file is present.
  Future<void> finalizePin(ChildReference ref, FileData confirmed) async {
    final dir = await _requireDir();
    final staging = stagingFilePath(dir, ref.path);
    final finalPath = localFilePath(dir, confirmed.id,
        sourceName: ref.name, mimeType: confirmed.mimeType);
    final stagedFile = File(staging);
    final finalFile = File(finalPath);

    if (await stagedFile.exists()) {
      if (await finalFile.exists()) await finalFile.delete();
      await stagedFile.rename(finalPath);
    } else if (!await finalFile.exists()) {
      await markPinDeferred(ref, confirmed);
      return;
    }

    await _put(CatalogEntry(
      data: confirmed,
      localPath: finalPath,
      pinnedAt: DateTime.now(),
      status: CatalogStatus.ready,
    ));
  }

  /// Records a `stale` entry for a pin that could not be populated from the
  /// upload source. A later [refresh]/[pin] downloads it and flips it to ready.
  Future<void> markPinDeferred(ChildReference ref, FileData confirmed) async {
    final dir = await _requireDir();
    final finalPath = localFilePath(dir, confirmed.id,
        sourceName: ref.name, mimeType: confirmed.mimeType);
    await _put(CatalogEntry(
      data: confirmed,
      localPath: finalPath,
      pinnedAt: DateTime.now(),
      status: CatalogStatus.stale,
    ));
  }
```

Add the `FileData` import if not already present (the file imports `catalog_entry.dart` which re-exports it transitively, but import explicitly for clarity):

```dart
import '../models/file_data.dart';
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/offline/offline_catalog_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/src/offline/offline_catalog.dart test/offline/offline_catalog_test.dart
git commit -m "Add OfflineCatalog.finalizePin and markPinDeferred"
```

---

## Task 4: `UploadTask` pin hooks (stage-first + settle)

**Files:**
- Modify: `lib/src/tasks/upload_task.dart`
- Test: `test/upload_pin_test.dart` (create)

This is the behavioral core: stage before uploading, upload from the staged copy, settle the pin after confirm. Settling is fully guarded so a caching failure never fails the upload.

- [ ] **Step 1: Write the failing test**

Create `test/upload_pin_test.dart`:

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:winche_storage/src/tasks/upload_task.dart';
import 'package:winche_storage/winche_storage.dart';

import 'support/noop_api.dart';

/// Minimal upload API: getFile->null, setFile->pending, confirm->complete.
/// generateDownloadUrl deliberately throws so a test can assert no download.
class _PinApi extends NoopApi {
  FileData? _existing;
  final List<String> calls = [];

  FileData _rec(int size, String mime, UploadStatus s) => FileData(
        id: 'srv-id',
        directory: 'a',
        path: 'a/b.png',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
        metadata: const {},
        version: 1,
        mimeType: mime,
        sizeBytes: size,
        uploadStatus: s,
      );

  @override
  Future<FileData?> getFile(String path) async => _existing;
  @override
  Future<FileData> setFile(String path, String mimeType, int sizeBytes,
          {Map<String, dynamic>? metadata}) async =>
      _existing = _rec(sizeBytes, mimeType, UploadStatus.pending);
  @override
  Future<UploadSession> generateFileUploadUrl(String path) async =>
      UploadSession(url: 'https://up/whole', expiresAt: DateTime.utc(2030));
  @override
  Future<FileData> confirmUpload(String path) async =>
      _existing!.copyWith(uploadStatus: UploadStatus.complete);
  @override
  Future<DownloadSession> generateDownloadUrl(String path) async {
    calls.add('download');
    throw StateError('no download expected during a pinned upload');
  }
}

class _OkAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options,
          Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async =>
      ResponseBody.fromBytes(<int>[], 200);
  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('winche-pin'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Dio okDio() => Dio(BaseOptions(validateStatus: (s) => s != null))
    ..httpClientAdapter = _OkAdapter();

  test('pinned uploadPath stages, uploads from the copy, then finalizes',
      () async {
    final api = _PinApi();
    final ref = ChildReference(path: 'a/b.png', api: api);
    final src = File('${tmp.path}/src.png')..writeAsBytesSync([1, 2, 3]);

    FileData? finalized;
    var staged = false;
    final task = UploadTask.start(
      reference: ref,
      localPath: src.path,
      mimeType: 'image/png',
      multipartThreshold: 5 * 1024 * 1024,
      httpClient: okDio(),
      stageSource: () async {
        staged = true;
        final dst = '${tmp.path}/staged.bin';
        await File(src.path).copy(dst);
        return dst;
      },
      onPinFinalize: (c) async => finalized = c,
      onPinDeferred: (c) async => fail('should not defer on success'),
    );

    await task.whenDone;
    expect(staged, isTrue);
    expect(finalized!.id, 'srv-id');
    expect(api.calls, isEmpty); // no download issued
  });

  test('staging failure falls back to deferred, upload still succeeds',
      () async {
    final api = _PinApi();
    final ref = ChildReference(path: 'a/b.png', api: api);
    final src = File('${tmp.path}/src.png')..writeAsBytesSync([1, 2, 3]);

    FileData? deferred;
    final task = UploadTask.start(
      reference: ref,
      localPath: src.path,
      mimeType: 'image/png',
      multipartThreshold: 5 * 1024 * 1024,
      httpClient: okDio(),
      stageSource: () async => throw StateError('disk full'),
      onPinFinalize: (c) async => fail('should not finalize without a stage'),
      onPinDeferred: (c) async => deferred = c,
    );

    final snap = await task.whenDone;
    expect(snap, isNotNull); // upload succeeded
    expect(deferred!.id, 'srv-id');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/upload_pin_test.dart`
Expected: FAIL — `UploadTask.start` has no `stageSource`/`onPinFinalize`/`onPinDeferred` parameters.

- [ ] **Step 3: Implement the fields, constructor, and factory params**

In `lib/src/tasks/upload_task.dart`, add fields to the class (near the other `final` fields, after `_httpClient`):

```dart
  final Future<String> Function()? _stageSource;
  final Future<void> Function(FileData confirmed)? _onPinFinalize;
  final Future<void> Function(FileData confirmed)? _onPinDeferred;

  /// Set once a stage succeeds; guards against re-staging on pause/resume.
  String? _stagedPath;
```

Update the private constructor to accept and assign them:

```dart
  UploadTask._({
    required this.reference,
    this.localPath,
    this.bytes,
    required this.mimeType,
    required this.metadata,
    required this.multipartThreshold,
    required this.maxRetries,
    required this.retryBaseDelay,
    required Dio httpClient,
    Future<String> Function()? stageSource,
    Future<void> Function(FileData confirmed)? onPinFinalize,
    Future<void> Function(FileData confirmed)? onPinDeferred,
  })  : _httpClient = httpClient,
        _stageSource = stageSource,
        _onPinFinalize = onPinFinalize,
        _onPinDeferred = onPinDeferred;
```

Add the three optional params to **both** factories (`UploadTask.start` and `UploadTask.startFromBytes`) and forward them. For `UploadTask.start`, add to the parameter list:

```dart
    Future<String> Function()? stageSource,
    Future<void> Function(FileData confirmed)? onPinFinalize,
    Future<void> Function(FileData confirmed)? onPinDeferred,
```

and in its `UploadTask._(...)` call add:

```dart
      stageSource: stageSource,
      onPinFinalize: onPinFinalize,
      onPinDeferred: onPinDeferred,
```

Do the same for `UploadTask.startFromBytes`.

- [ ] **Step 4: Implement staging + settle in `_run`**

In `_run`, replace the source-resolution block (currently):

```dart
      final File? localFile;
      final int sizeBytes;

      if (bytes != null) {
        localFile = null;
        sizeBytes = bytes!.length;
      } else {
        localFile = File(localPath!);
        if (!await localFile.exists()) {
          throw Exception('Local file not found at $localPath');
        }
        sizeBytes = (await localFile.stat()).size;
      }
```

with:

```dart
      // Pin-on-upload: stage a safe local copy and upload *from* it, so the
      // upload no longer depends on the caller's original file. Best-effort —
      // on staging failure we upload from the original source and mark the pin
      // deferred after confirm.
      String? effPath = localPath;
      Uint8List? effBytes = bytes;
      if (_stageSource != null) {
        if (_stagedPath == null) {
          try {
            _stagedPath = await _stageSource!();
          } catch (_) {
            _stagedPath = null; // fall back to the original source
          }
        }
        if (_stagedPath != null) {
          effPath = _stagedPath;
          effBytes = null;
        }
      }

      final File? localFile;
      final int sizeBytes;

      if (effBytes != null) {
        localFile = null;
        sizeBytes = effBytes.length;
      } else {
        localFile = File(effPath!);
        if (!await localFile.exists()) {
          throw Exception('Local file not found at $effPath');
        }
        sizeBytes = (await localFile.stat()).size;
      }
```

In `_run`, the two helper invocations currently pass `bytes: bytes`. Change both to `bytes: effBytes`:

```dart
          await _uploadPartWithRetry(
            localFile: localFile,
            bytes: effBytes,
            partNumber: partNumber,
            byteOffset: byteOffset,
            chunkSize: chunkSize,
            sizeBytes: sizeBytes,
          );
```

```dart
        await _uploadWholeWithRetry(
          localFile: localFile,
          bytes: effBytes,
          sizeBytes: sizeBytes,
        );
```

Still in `_run`, settle the pin after a successful confirm. Replace:

```dart
      final confirmed = await reference.api.confirmUpload(reference.path);

      _setProgress(1.0);
      _setStatus(UploadTaskStatus.complete);
      _completeTask(confirmed);
```

with:

```dart
      final confirmed = await reference.api.confirmUpload(reference.path);

      await _settlePin(confirmed);
      _setProgress(1.0);
      _setStatus(UploadTaskStatus.complete);
      _completeTask(confirmed);
```

And in the early "already complete & matches" branch, replace:

```dart
            _setProgress(1.0);
            _setStatus(UploadTaskStatus.complete);
            _completeTask(existingRecord);
            return;
```

with:

```dart
            await _settlePin(existingRecord);
            _setProgress(1.0);
            _setStatus(UploadTaskStatus.complete);
            _completeTask(existingRecord);
            return;
```

Add the `_settlePin` helper (place near `_completeTask`):

```dart
  /// Populates the offline cache for a pinned upload. Fully guarded: a caching
  /// failure must never fail the upload. No-op when this isn't a pinned upload
  /// (i.e. [_stageSource] is null) or when no settle hooks were supplied (the
  /// controller path, which finalizes pins itself).
  Future<void> _settlePin(FileData confirmed) async {
    if (_stageSource == null) return;
    final finalize = _onPinFinalize;
    final defer = _onPinDeferred;
    try {
      if (_stagedPath != null && finalize != null) {
        await finalize(confirmed);
        return;
      }
    } catch (_) {
      // fall through to the deferred path
    }
    if (defer != null) {
      try {
        await defer(confirmed);
      } catch (_) {
        // best-effort; nothing more we can do
      }
    }
  }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `dart test test/upload_pin_test.dart`
Expected: PASS (both tests).

- [ ] **Step 6: Run the existing upload tests to confirm no regression**

Run: `dart test test/upload_overwrite_test.dart`
Expected: PASS (the `effBytes`/`effPath` refactor must not change non-pinned behavior).

- [ ] **Step 7: Commit**

```bash
git add lib/src/tasks/upload_task.dart test/upload_pin_test.dart
git commit -m "Add stage-first pin hooks to UploadTask"
```

---

## Task 5: `ChildReference` — `pinned` on the direct path

**Files:**
- Modify: `lib/src/child_reference.dart`
- Test: `test/offline/child_reference_pin_test.dart` (create)

Wires the `pinned` flag for `uploadBytes` (always direct) and `uploadPath` when no controller is present. Adds `_ensurePinnable()` which warns and disables pinning when the cache is off. The controller path is wired in Task 8.

- [ ] **Step 1: Write the failing test**

Create `test/offline/child_reference_pin_test.dart`:

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winche_storage/src/child_reference.dart';
import 'package:winche_storage/src/offline/local_paths.dart';
import 'package:winche_storage/src/offline/offline_catalog.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

/// getFile throws (network down) so the upload fails fast *after* staging — we
/// assert the staged file exists, proving ChildReference wired stageSource.
class _OfflineApi extends NoopApi {
  @override
  Future<FileData?> getFile(String path) async => throw StateError('offline');
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('winche-cr-pin'));
  tearDown(() => tmp.deleteSync(recursive: true));

  OfflineCatalog cat(WincheStorageApi api) => OfflineCatalog(
        api: api,
        store: MemoryStorageLocalStore(),
        directoryResolver: () async => tmp.path,
        multipartThreshold: 5 * 1024 * 1024,
      );

  test('uploadBytes(pinned: true) stages bytes before uploading', () async {
    final api = _OfflineApi();
    final ref = ChildReference(path: 'a/b.png', api: api, catalog: cat(api));

    final task = ref.uploadBytes(Uint8List.fromList([7, 7, 7]), 'image/png',
        pinned: true);
    await task.whenDone.catchError((_) => null);

    final staged = stagingFilePath(tmp.path, 'a/b.png');
    expect(File(staged).existsSync(), isTrue);
    expect(File(staged).readAsBytesSync(), [7, 7, 7]);
  });

  test('pinned upload with no catalog is a no-op (does not throw)', () async {
    final api = _OfflineApi();
    final ref = ChildReference(path: 'a/b.png', api: api); // catalog == null

    final task =
        ref.uploadBytes(Uint8List.fromList([1]), 'image/png', pinned: true);
    await task.whenDone.catchError((_) => null);

    expect(Directory(p.join(tmp.path, '.staging')).existsSync(), isFalse);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/offline/child_reference_pin_test.dart`
Expected: FAIL — `uploadBytes` has no `pinned` parameter.

- [ ] **Step 3: Implement**

In `lib/src/child_reference.dart`, add the `_ensurePinnable` helper (place after the `name`/`parent` getters or near the upload methods):

```dart
  /// Whether a pinned upload can populate the cache. Warns (debug only) and
  /// returns false — the upload proceeds unpinned — when caching is disabled.
  bool _ensurePinnable() {
    if (catalog != null) return true;
    assert(() {
      // ignore: avoid_print
      print('winche_storage: pinned upload ignored — enableOfflineCache is '
          'off.');
      return true;
    }());
    return false;
  }
```

Update `uploadPath` to add the `pinned` param and the direct-path hooks (the controller branch is updated in Task 8; for now route `pinned` only through the direct branch):

```dart
  UploadTask uploadPath(
    String localPath, {
    String? mimeType,
    Map<String, dynamic>? metadata,
    int? multipartThreshold,
    bool pinned = false,
  }) {
    final resolvedMime =
        mimeType ?? lookupMimeType(localPath) ?? 'application/octet-stream';
    final wantPin = pinned && _ensurePinnable();
    if (controller != null) {
      return controller!.startUpload(
        this,
        localPath: localPath,
        mimeType: resolvedMime,
        metadata: metadata,
        multipartThreshold: multipartThreshold ?? this.multipartThreshold,
      );
    }
    return UploadTask.start(
      reference: this,
      localPath: localPath,
      mimeType: resolvedMime,
      metadata: metadata,
      multipartThreshold: multipartThreshold ?? this.multipartThreshold,
      stageSource:
          wantPin ? () => catalog!.stageForUpload(this, sourcePath: localPath) : null,
      onPinFinalize: wantPin ? (c) => catalog!.finalizePin(this, c) : null,
      onPinDeferred: wantPin ? (c) => catalog!.markPinDeferred(this, c) : null,
    );
  }
```

Update `uploadBytes`:

```dart
  UploadTask uploadBytes(
    Uint8List bytes,
    String mimeType, {
    Map<String, dynamic>? metadata,
    int? multipartThreshold,
    bool pinned = false,
  }) {
    if (mimeType.isEmpty) {
      throw ArgumentError('mimeType is required when uploading bytes.');
    }
    final wantPin = pinned && _ensurePinnable();
    return UploadTask.startFromBytes(
      reference: this,
      bytes: bytes,
      mimeType: mimeType,
      metadata: metadata,
      multipartThreshold: multipartThreshold ?? this.multipartThreshold,
      stageSource:
          wantPin ? () => catalog!.stageForUpload(this, bytes: bytes) : null,
      onPinFinalize: wantPin ? (c) => catalog!.finalizePin(this, c) : null,
      onPinDeferred: wantPin ? (c) => catalog!.markPinDeferred(this, c) : null,
    );
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/offline/child_reference_pin_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/src/child_reference.dart test/offline/child_reference_pin_test.dart
git commit -m "Wire pinned uploads through ChildReference (direct path)"
```

---

## Task 6: `TransferRecord.pinned`

**Files:**
- Modify: `lib/src/offline/transfer_record.dart`
- Test: `test/offline/transfer_record_test.dart`

- [ ] **Step 1: Write the failing test**

Append inside `main()` of `test/offline/transfer_record_test.dart`:

```dart
  test('pinned round-trips through JSON and defaults to false', () {
    final rec = TransferRecord(
      seq: 1,
      kind: TransferKind.upload,
      path: 'a/b.png',
      localPath: '/src',
      mimeType: 'image/png',
      metadata: null,
      multipartThreshold: null,
      status: TransferStatus.running,
      attempt: 0,
      lastError: null,
      createdAt: DateTime.utc(2026, 1, 1),
      pinned: true,
    );
    expect(TransferRecord.fromJson(rec.toJson()).pinned, isTrue);

    final legacy = Map<String, Object?>.from(rec.toJson())..remove('pinned');
    expect(TransferRecord.fromJson(legacy).pinned, isFalse);
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/offline/transfer_record_test.dart -n pinned`
Expected: FAIL — `TransferRecord` has no `pinned` parameter.

- [ ] **Step 3: Implement**

In `lib/src/offline/transfer_record.dart`:

Add the field (after `createdAt`):

```dart
  final bool pinned;
```

Add to the constructor parameter list (with a default):

```dart
    this.pinned = false,
```

In `copyWith`, add a `bool? pinned` param and pass `pinned: pinned ?? this.pinned`:

```dart
  TransferRecord copyWith({
    String? localPath,
    TransferStatus? status,
    int? attempt,
    String? lastError,
    bool? pinned,
  }) =>
      TransferRecord(
        seq: seq,
        kind: kind,
        path: path,
        localPath: localPath ?? this.localPath,
        mimeType: mimeType,
        metadata: metadata,
        multipartThreshold: multipartThreshold,
        status: status ?? this.status,
        attempt: attempt ?? this.attempt,
        lastError: lastError,
        createdAt: createdAt,
        pinned: pinned ?? this.pinned,
      );
```

In `toJson`, add `'pinned': pinned,`. In `fromJson`, add `pinned: json['pinned'] as bool? ?? false,`.

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/offline/transfer_record_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/src/offline/transfer_record.dart test/offline/transfer_record_test.dart
git commit -m "Add pinned flag to TransferRecord"
```

---

## Task 7: `UploadPinSink` interface implemented by `OfflineCatalog`

**Files:**
- Create: `lib/src/offline/upload_pin_sink.dart`
- Modify: `lib/src/offline/offline_catalog.dart`
- Test: `test/offline/offline_catalog_test.dart`

A small interface lets `TransferController` populate pins without importing `OfflineCatalog`, avoiding a tight dependency.

- [ ] **Step 1: Write the failing test**

Append inside `main()` of `test/offline/offline_catalog_test.dart`:

```dart
  test('UploadPinSink: stage, resolve, finalize by path', () async {
    final OfflineCatalog cat = build({});
    final UploadPinSink sink = cat;

    final staged =
        await sink.stageUpload('a/b.png', _writeSrc(tmp, [4, 5]).path);
    expect(await sink.resolveStagedUpload('a/b.png'), staged);

    await sink.finalizeUploadPin('a/b.png', _data('a/b.png'));
    expect(await sink.resolveStagedUpload('a/b.png'), isNull); // moved away
    expect((await cat.entryFor('a/b.png'))!.status, CatalogStatus.ready);
  });
```

Add this helper above `main()` in the test file:

```dart
File _writeSrc(Directory dir, List<int> bytes) =>
    File('${dir.path}/src-${bytes.length}.bin')..writeAsBytesSync(bytes);
```

Add the import:

```dart
import 'package:winche_storage/src/offline/upload_pin_sink.dart';
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/offline/offline_catalog_test.dart -n UploadPinSink`
Expected: FAIL — `upload_pin_sink.dart` does not exist.

- [ ] **Step 3: Create the interface**

Create `lib/src/offline/upload_pin_sink.dart`:

```dart
import '../models/file_data.dart';

/// The bridge [TransferController] uses to populate the offline cache for a
/// pinned upload, without depending on [OfflineCatalog] directly. All methods
/// are keyed by the reference path (the upload's durable identity).
abstract interface class UploadPinSink {
  /// Stages [sourceLocalPath] into the cache and returns the staged path.
  Future<String> stageUpload(String path, String sourceLocalPath);

  /// The staged source for [path] if one exists on disk, else null.
  Future<String?> resolveStagedUpload(String path);

  /// Moves the staged copy into the id-keyed cache and records a ready entry.
  Future<void> finalizeUploadPin(String path, FileData confirmed);
}
```

- [ ] **Step 4: Implement on `OfflineCatalog`**

In `lib/src/offline/offline_catalog.dart`, add the import and `implements`:

```dart
import 'upload_pin_sink.dart';
```

```dart
class OfflineCatalog implements UploadPinSink {
```

Add the three methods (place near `stageForUpload`/`finalizePin`):

```dart
  ChildReference _refFor(String path) =>
      ChildReference(path: path, api: _api, directoryResolver: _directoryResolver);

  @override
  Future<String> stageUpload(String path, String sourceLocalPath) =>
      stageForUpload(_refFor(path), sourcePath: sourceLocalPath);

  @override
  Future<String?> resolveStagedUpload(String path) async {
    final dir = await _requireDir();
    final staging = stagingFilePath(dir, path);
    return await File(staging).exists() ? staging : null;
  }

  @override
  Future<void> finalizeUploadPin(String path, FileData confirmed) =>
      finalizePin(_refFor(path), confirmed);
```

- [ ] **Step 5: Run test to verify it passes**

Run: `dart test test/offline/offline_catalog_test.dart`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/src/offline/upload_pin_sink.dart lib/src/offline/offline_catalog.dart test/offline/offline_catalog_test.dart
git commit -m "Add UploadPinSink implemented by OfflineCatalog"
```

---

## Task 8: `TransferController` pin integration + facade wiring

**Files:**
- Modify: `lib/src/offline/transfer_controller.dart`
- Modify: `lib/winche_storage.dart`
- Modify: `lib/src/child_reference.dart` (route `pinned` through the controller)
- Test: `test/offline/transfer_controller_pin_test.dart` (create)

Durable pinned uploads: persist `pinned`, stage on the first run, prefer the staged copy on restart, and finalize on completion.

- [ ] **Step 1: Write the failing test**

Create `test/offline/transfer_controller_pin_test.dart`:

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:winche_storage/src/child_reference.dart';
import 'package:winche_storage/src/offline/offline_catalog.dart';
import 'package:winche_storage/src/offline/transfer_controller.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

class _PinApi extends NoopApi {
  FileData? _existing;
  FileData _rec(int size, UploadStatus s) => FileData(
        id: 'srv-id',
        directory: 'a',
        path: 'a/b.png',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
        metadata: const {},
        version: 1,
        mimeType: 'image/png',
        sizeBytes: size,
        uploadStatus: s,
      );
  @override
  Future<FileData?> getFile(String path) async => _existing;
  @override
  Future<FileData> setFile(String path, String mimeType, int sizeBytes,
          {Map<String, dynamic>? metadata}) async =>
      _existing = _rec(sizeBytes, UploadStatus.pending);
  @override
  Future<UploadSession> generateFileUploadUrl(String path) async =>
      UploadSession(url: 'https://up/whole', expiresAt: DateTime.utc(2030));
  @override
  Future<FileData> confirmUpload(String path) async =>
      _existing!.copyWith(uploadStatus: UploadStatus.complete);
}

class _OkAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? s,
          Future<void>? c) async =>
      ResponseBody.fromBytes(<int>[], 200);
  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('winche-ctrl-pin'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('a pinned upload through the controller finalizes a ready entry',
      () async {
    final api = _PinApi();
    final store = MemoryStorageLocalStore();
    final dio = Dio(BaseOptions(validateStatus: (s) => s != null))
      ..httpClientAdapter = _OkAdapter();
    final ctrl = TransferController(
      api: api,
      store: store,
      multipartThreshold: 5 * 1024 * 1024,
      directoryResolver: () async => tmp.path,
      httpClient: dio,
      retry: const TransferRetryConfig(pollInterval: Duration(hours: 1)),
    );
    final catalog = OfflineCatalog(
      api: api,
      store: store,
      directoryResolver: () async => tmp.path,
      multipartThreshold: 5 * 1024 * 1024,
      controller: ctrl,
    );
    ctrl.pinSink = catalog;

    final src = File('${tmp.path}/src.png')..writeAsBytesSync([1, 2, 3]);
    final ref = ChildReference(path: 'a/b.png', api: api);

    await ctrl
        .startUpload(ref,
            localPath: src.path,
            mimeType: 'image/png',
            multipartThreshold: 5 * 1024 * 1024,
            pinned: true)
        .whenDone;
    // Let the controller's completion handler run finalize.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final entry = await catalog.entryFor('a/b.png');
    expect(entry!.status, CatalogStatus.ready);
    expect(File(entry.localPath).readAsBytesSync(), [1, 2, 3]);
    await ctrl.dispose();
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/offline/transfer_controller_pin_test.dart`
Expected: FAIL — `startUpload` has no `pinned` param and `pinSink` does not exist.

- [ ] **Step 3: Add `pinSink`, imports, and `pinned` to `startUpload`**

In `lib/src/offline/transfer_controller.dart`, add imports:

```dart
import '../file_snapshot.dart';
import 'upload_pin_sink.dart';
```

Add a mutable field (after `_disposed`):

```dart
  /// Set by the facade after construction (the catalog is built later). Enables
  /// finalizing pinned uploads on completion. Null when offline cache is off.
  UploadPinSink? pinSink;
```

Update `startUpload`:

```dart
  UploadTask startUpload(
    ChildReference ref, {
    required String localPath,
    required String mimeType,
    Map<String, dynamic>? metadata,
    required int multipartThreshold,
    bool pinned = false,
  }) {
    final existing = _activeUploads[ref.path];
    if (existing != null) return existing;
    final sink = pinned ? pinSink : null;
    final task = UploadTask.start(
      reference: ref,
      localPath: localPath,
      mimeType: mimeType,
      metadata: metadata,
      multipartThreshold: multipartThreshold,
      maxRetries: 0,
      httpClient: _httpClient,
      stageSource:
          sink == null ? null : () => sink.stageUpload(ref.path, localPath),
    );
    _activeUploads[ref.path] = task;
    unawaited(_registerUpload(
      ref.path,
      localPath: localPath,
      mimeType: mimeType,
      metadata: metadata,
      multipartThreshold: multipartThreshold,
      pinned: pinned,
      done: task.whenDone,
    ));
    return task;
  }
```

(Note: the controller passes only `stageSource`; it finalizes the pin itself in `_drive`, so `onPinFinalize`/`onPinDeferred` are intentionally omitted.)

- [ ] **Step 4: Persist `pinned` in `_registerUpload`**

Add `required bool pinned` to `_registerUpload`'s signature and set it on the enqueued record:

```dart
  Future<void> _registerUpload(
    String path, {
    required String localPath,
    required String mimeType,
    Map<String, dynamic>? metadata,
    required int multipartThreshold,
    required bool pinned,
    required Future<Object?> done,
  }) async {
    final seq =
        await _existingSeq(TransferKind.upload, path, localPath: localPath) ??
            await _queue.enqueue((seq) => TransferRecord(
                  seq: seq,
                  kind: TransferKind.upload,
                  path: path,
                  localPath: localPath,
                  mimeType: mimeType,
                  metadata: metadata,
                  multipartThreshold: multipartThreshold,
                  status: TransferStatus.running,
                  attempt: 0,
                  lastError: null,
                  createdAt: DateTime.now(),
                  pinned: pinned,
                ));
    _running.add(seq);
    _emit(TransferEventType.started, TransferKind.upload, path);
    _drive(seq, done, TransferKind.upload, path);
  }
```

- [ ] **Step 5: Finalize pinned uploads in `_drive`**

Replace the success branch of `_drive` (the `done.then(...)` body) with one that finalizes pinned uploads using the confirmed `FileData`:

```dart
  void _drive(int seq, Future<Object?> done, TransferKind kind, String path) {
    done.then((result) async {
      _running.remove(seq);
      _removeActive(kind, path);
      if (kind == TransferKind.upload && pinSink != null) {
        final rec = await _queue.get(seq);
        final data = result is FileSnapshot ? result.data : null;
        if (rec != null && rec.pinned && data != null) {
          try {
            await pinSink!.finalizeUploadPin(path, data);
          } catch (_) {
            // pinning is best-effort; the upload still succeeded
          }
        }
      }
      await _queue.remove(seq);
      _emit(TransferEventType.completed, kind, path);
    }).catchError((Object e) async {
      _running.remove(seq);
      _removeActive(kind, path);
      final rec = await _queue.get(seq);
      if (rec == null) return;
      final attempt = rec.attempt + 1;
      await _queue.update(rec.copyWith(
          status: TransferStatus.failed, attempt: attempt, lastError: '$e'));
      _emit(TransferEventType.failed, kind, path, e);
      if (attempt <= _retry.maxAttempts) _scheduleRetry(seq, attempt);
    });
  }
```

- [ ] **Step 6: Prefer the staged copy on restart**

In `_restart`, replace the upload branch (`} else { ... }`, currently the `// Upload:` block) with:

```dart
    } else {
      // Pinned uploads prefer the staged copy (it survives the original file
      // being moved/deleted); otherwise the source is the recorded local file.
      var source = rec.localPath;
      if (rec.pinned && pinSink != null) {
        final staged = await pinSink!.resolveStagedUpload(rec.path);
        if (staged != null) source = staged;
      }
      if (source == null) {
        _running.remove(seq);
        await _queue.remove(seq);
        return;
      }
      final task = UploadTask.start(
        reference: ref,
        localPath: source,
        mimeType: rec.mimeType ?? 'application/octet-stream',
        metadata: rec.metadata,
        multipartThreshold: rec.multipartThreshold ?? _multipartThreshold,
        maxRetries: 0,
        httpClient: _httpClient,
      );
      _activeUploads[rec.path] = task;
      _drive(seq, task.whenDone, TransferKind.upload, rec.path);
    }
```

- [ ] **Step 7: Wire the facade and the controller route in `ChildReference`**

In `lib/winche_storage.dart`, inside `_build`, after both `controller` and `catalog` are created and before `return WincheStorage._(...)`:

```dart
    if (controller != null && catalog != null) {
      controller.pinSink = catalog;
    }
```

In `lib/src/child_reference.dart`, update the controller branch of `uploadPath` to forward `pinned` (replace the `if (controller != null)` block written in Task 5):

```dart
    if (controller != null) {
      return controller!.startUpload(
        this,
        localPath: localPath,
        mimeType: resolvedMime,
        metadata: metadata,
        multipartThreshold: multipartThreshold ?? this.multipartThreshold,
        pinned: wantPin,
      );
    }
```

- [ ] **Step 8: Run the new and existing controller tests**

Run: `dart test test/offline/transfer_controller_pin_test.dart test/offline/transfer_controller_test.dart`
Expected: PASS (new pinned test passes; existing controller tests still pass).

- [ ] **Step 9: Commit**

```bash
git add lib/src/offline/transfer_controller.dart lib/winche_storage.dart lib/src/child_reference.dart test/offline/transfer_controller_pin_test.dart
git commit -m "Finalize pinned uploads through the durable controller"
```

---

## Task 9: Docs, facade smoke test, and full suite

**Files:**
- Modify: `lib/src/child_reference.dart` (dartdoc)
- Test: `test/offline/facade_offline_test.dart`

- [ ] **Step 1: Write the failing facade test**

Append inside `main()` of `test/offline/facade_offline_test.dart` (match its existing imports/helpers; add `dart:io` and `package:winche_storage/src/offline/local_paths.dart` if not present):

```dart
  test('facade: pinned uploadPath stages through the controller', () async {
    final tmp = Directory.systemTemp.createTempSync('winche-facade-pin');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final storage = WincheStorage.withStore(
      _ThrowingGetFileApi(), // getFile throws -> upload fails after staging
      MemoryStorageLocalStore(),
      enableOfflineCache: true,
      enableAutoResume: true,
      directoryResolver: () async => tmp.path,
      retry: const TransferRetryConfig(
          maxAttempts: 0, pollInterval: Duration(hours: 1)),
    );
    addTearDown(storage.dispose);

    final src = File('${tmp.path}/src.png')..writeAsBytesSync([1, 2, 3]);
    final task = storage.child('a/b.png').uploadPath(src.path, pinned: true);
    await task.whenDone.catchError((_) => null);

    expect(File(stagingFilePath(tmp.path, 'a/b.png')).existsSync(), isTrue);
  });
```

Add this fake near the top of the file (after the imports):

```dart
class _ThrowingGetFileApi extends NoopApi {
  @override
  Future<FileData?> getFile(String path) async => throw StateError('offline');
}
```

Ensure these imports exist in the file:

```dart
import 'dart:io';
import 'package:winche_storage/src/offline/local_paths.dart';
import '../support/noop_api.dart';
```

- [ ] **Step 2: Run test to verify it fails (or passes if wiring is complete)**

Run: `dart test test/offline/facade_offline_test.dart -n "pinned uploadPath"`
Expected: PASS if Task 8 wiring is correct. If it FAILS because no staged file appears, the `controller.pinSink` wiring in `_build` or the `pinned` route in `uploadPath` is wrong — fix before continuing.

- [ ] **Step 3: Add dartdoc to the public methods**

In `lib/src/child_reference.dart`, update the doc comment above `uploadPath` to document `pinned`:

```dart
  /// Uploads local file.
  ///
  /// [mimeType] is optional — when omitted it is inferred from [localPath]'s
  /// extension via the `mime` package, falling back to `application/octet-stream`.
  ///
  /// When [pinned] is true and `enableOfflineCache` is on, the uploaded bytes
  /// are placed directly into the offline cache (no download roundtrip): the
  /// source is staged, uploaded from the staged copy, then moved to the
  /// id-keyed cache path on success. Caching is best-effort — if it fails the
  /// upload still succeeds and the pin is recorded as stale for a later
  /// `refresh`. Ignored (with a debug warning) when `enableOfflineCache` is off.
```

Add an equivalent `[pinned]` paragraph to the `uploadBytes` doc comment.

- [ ] **Step 4: Run the full suite and analyzer**

Run: `dart analyze && dart test`
Expected: No analyzer issues; all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/src/child_reference.dart test/offline/facade_offline_test.dart
git commit -m "Document pinned uploads and add facade smoke test"
```

---

## Self-review notes (already reconciled against the spec)

- **No interim `downloading` entry.** The spec mentioned a `downloading` `CatalogEntry` at stage time, but `CatalogEntry.data` requires a `FileData` we don't have until `confirmUpload`. The plan therefore writes the catalog entry only at settle time (`ready`) or on failure (`stale`). Upload progress remains observable via `UploadTask.stateStream`.
- **Staging path is extension-free and hashed** so stage and finalize compute the identical path and a resumed upload (which lost the original closures) recomputes it deterministically.
- **`uploadBytes` stays on the direct path** (never routed through the controller), matching existing behaviour; its pin is finalized by `UploadTask._settlePin`.
- **`uploadPath` with auto-resume** routes through the controller, which stages on the first run, prefers the staged copy on restart, and finalizes in `_drive`.
- **Best-effort caching** is enforced in two guarded places: `UploadTask._settlePin` (direct path) and the `_drive` try/catch (controller path).
</content>
</invoke>
