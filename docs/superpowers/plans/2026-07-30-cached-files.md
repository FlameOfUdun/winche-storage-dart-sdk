# `cachedFiles()` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `ChildReference.cachedFiles()` — the cached files directly under a
path, verified against the disk — and fix `CachedFile.reference` so the
references it hands out can actually do cache operations.

**Architecture:** The byte-verification rule shared by both cache reads moves
into one private helper in `OfflineCatalog`; a new `cachedFilesIn(directory)`
filters `all()` by parent directory and runs each surviving row through it.
`ChildReference.cachedFiles()` is a one-line delegate, like every other cache
method there. No new types, no store-interface change.

**Tech Stack:** Dart 3.10, `package:test`, sembast (untouched here), the
in-memory store and `NoopApi` fake for tests.

**Spec:** `docs/superpowers/specs/2026-07-30-cached-files-design.md`

**Before you start:** run `dart test` once and confirm 181 tests pass, so a
later failure is unambiguously yours.

---

## File Structure

| file | responsibility | change |
|---|---|---|
| `lib/src/offline/offline_catalog.dart` | owns the catalog rows and what "usable bytes" means | extract `_verified`, add `cachedFilesIn` + `_parentDir`, fix `_refFor` |
| `lib/src/child_reference.dart` | the public per-path API | add the `cachedFiles()` delegate; see-also on `listChildren()` |
| `test/offline/cached_files_test.dart` | all coverage for the new method and the reference fix | **new** |
| `README.md` | public documentation | table row, see-also, example |
| `CHANGELOG.md` | release notes | new `5.1.0` section |
| `pubspec.yaml` | version | `5.0.0` → `5.1.0` |

Nothing else is touched. In particular `StorageLocalStore` and its three
implementations, `CachedFile`, `CatalogEntry`, `FileSnapshot` and
`DirectorySnapshot` are all unchanged.

---

## Task 1: Extract the byte-verification helper

A pure refactor with no behaviour change. `cachedFile()`'s existing tests are
the safety net — they must keep passing untouched.

**Files:**
- Modify: `lib/src/offline/offline_catalog.dart:73-89`
- Test: `test/offline/child_reference_offline_test.dart` (existing, unchanged)

- [ ] **Step 1: Replace `cachedFile()` with a delegate plus a helper**

In `lib/src/offline/offline_catalog.dart`, replace the whole existing
`cachedFile` method (its doc comment included) with:

```dart
  /// The cached copy at [path], or null when this device has no usable bytes.
  ///
  /// Verifies against the filesystem rather than trusting the row's status: the
  /// disk is what actually answers "do I have these bytes", and this call is
  /// about to hand out a path someone will open. It also means a row left
  /// `downloading` by a process kill stops being a permanent blocker — the
  /// bytes decide, so the next [pin] repairs it.
  Future<CachedFile?> cachedFile(String path) async {
    final entry = await entryFor(path);
    if (entry == null) return null;
    return _verified(entry);
  }

  /// A [CachedFile] for [entry] when its bytes are complete on disk, else null.
  ///
  /// The single definition of "usable bytes", shared by [cachedFile] and
  /// [cachedFilesIn] so the two cannot drift.
  Future<CachedFile?> _verified(CatalogEntry entry) async {
    final file = File(entry.localPath);
    if (!await file.exists()) return null;
    if (await file.length() != entry.data.sizeBytes) return null;
    return CachedFile(
      reference: _refFor(entry.path),
      data: entry.data,
      localPath: entry.localPath,
      cachedAt: entry.pinnedAt,
    );
  }
```

The `[cachedFilesIn]` reference in the doc comment resolves in Task 2. Dart
analysis does not fail on an unresolved doc reference, so this order is safe.

- [ ] **Step 2: Run the existing suite to prove nothing changed**

Run: `dart test`
Expected: 181 tests pass, 0 failures.

- [ ] **Step 3: Analyze**

Run: `dart analyze`
Expected: `No issues found!`

- [ ] **Step 4: Commit**

```bash
git add lib/src/offline/offline_catalog.dart
git commit -m "refactor: extract the cache byte-verification helper"
```

---

## Task 2: `cachedFiles()` — direct children, verified, sorted

**Files:**
- Modify: `lib/src/offline/offline_catalog.dart` (add `cachedFilesIn`, `_parentDir`)
- Modify: `lib/src/child_reference.dart` (add `cachedFiles()` after `cachedFile()`)
- Create: `test/offline/cached_files_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `test/offline/cached_files_test.dart` with exactly this content:

```dart
import 'dart:io';

import 'package:test/test.dart';
import 'package:winche_storage/src/offline/offline_catalog.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

/// Inherits [NoopApi], so every method throws [UnimplementedError]. Any test
/// that passes without an override is proof `cachedFiles()` never contacts the
/// server.
class _OfflineApi extends NoopApi {}

FileData _data(String path, {required String id, int sizeBytes = 3}) => FileData(
      id: id,
      directory: path.substring(0, path.lastIndexOf('/')),
      path: path,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
      metadata: const {},
      version: 1,
      mimeType: 'image/png',
      sizeBytes: sizeBytes,
      uploadStatus: UploadStatus.complete,
    );

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('winche-cached-files'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {
      // Best effort: the store may still hold a handle on Windows.
    }
  });

  OfflineCatalog catFor(WincheStorageApi api) => OfflineCatalog(
        api: api,
        store: MemoryStorageLocalStore(),
        directoryResolver: () async => tmp.path,
      );

  /// Seeds a catalog row for [path]. [byteCount] bytes are written to disk —
  /// pass null to write none, or a value other than [sizeBytes] for a partial.
  Future<void> seed(
    OfflineCatalog cat,
    String path, {
    required String id,
    int sizeBytes = 3,
    int? byteCount = 3,
    CatalogStatus status = CatalogStatus.ready,
  }) async {
    final local = '${tmp.path}/$id.png';
    if (byteCount != null) {
      await File(local).writeAsBytes(List.filled(byteCount, 1));
    }
    await cat.debugPut(CatalogEntry(
      data: _data(path, id: id, sizeBytes: sizeBytes),
      localPath: local,
      pinnedAt: DateTime.utc(2026, 1, 1),
      status: status,
    ));
  }

  test('returns the direct children whose bytes are complete', () async {
    final api = _OfflineApi();
    final cat = catFor(api);
    await seed(cat, 'u1/a.png', id: 'a');
    await seed(cat, 'u1/photos/b.png', id: 'b'); // deeper — not a direct child
    await seed(cat, 'u2/c.png', id: 'c'); // another directory
    await seed(cat, 'u1/gone.png', id: 'gone', byteCount: null); // row, no bytes
    final ref = ChildReference(path: 'u1', api: api, catalog: cat);

    final files = await ref.cachedFiles();

    expect(files.map((f) => f.path), ['u1/a.png']);
    expect(files.single.localPath, '${tmp.path}/a.png');
    expect(files.single.data.id, 'a');
    expect(files.single.cachedAt, DateTime.utc(2026, 1, 1));
  });

  test('is sorted by path', () async {
    final api = _OfflineApi();
    final cat = catFor(api);
    await seed(cat, 'u1/c.png', id: 'c');
    await seed(cat, 'u1/a.png', id: 'a');
    await seed(cat, 'u1/b.png', id: 'b');
    final ref = ChildReference(path: 'u1', api: api, catalog: cat);

    expect((await ref.cachedFiles()).map((f) => f.path),
        ['u1/a.png', 'u1/b.png', 'u1/c.png']);
  });

  test('is empty when nothing under the path is cached', () async {
    final api = _OfflineApi();
    final cat = catFor(api);
    await seed(cat, 'u2/c.png', id: 'c');
    final ref = ChildReference(path: 'u1', api: api, catalog: cat);

    expect(await ref.cachedFiles(), isEmpty);
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `dart test test/offline/cached_files_test.dart`
Expected: compile error — `The method 'cachedFiles' isn't defined for the type 'ChildReference'`.

- [ ] **Step 3: Rename the helper and move the rationale onto it**

Carried over from Task 1's code review. After the extraction, `cachedFile()`'s
doc comment still explains why verification happens against the disk — but it
no longer verifies anything, and `cachedFilesIn` is about to inherit the same
rule. Rationale that belongs to the helper has to live on the helper, or it
gets restated on both callers. The name changes at the same time: `_verified`
reads as a predicate while returning `Future<CachedFile?>`, and the file's
other private helpers are noun phrases (`_refFor`, `_cachePath`).

In `lib/src/offline/offline_catalog.dart`, replace both methods added in
Task 1 with:

```dart
  /// The cached copy at [path], or null when this device has no usable bytes.
  ///
  /// Absence is not an error: "I do not have these bytes" is an ordinary
  /// answer, and a caller that gets one back has a `localPath` it can open —
  /// which is what this call is for. A row this returns null for is repaired
  /// by the next [pin].
  Future<CachedFile?> cachedFile(String path) async {
    final entry = await entryFor(path);
    if (entry == null) return null;
    return _verifiedFile(entry);
  }

  /// A [CachedFile] for [entry] when its bytes are complete on disk, else null.
  ///
  /// The disk is what actually answers "do I have these bytes", so both cache
  /// reads verify here rather than trusting the row's status — which is also
  /// what stops a row left `downloading` by a process kill from being a
  /// permanent blocker. One definition, shared by [cachedFile] and
  /// [cachedFilesIn] so the two cannot drift.
  Future<CachedFile?> _verifiedFile(CatalogEntry entry) async {
    final file = File(entry.localPath);
    if (!await file.exists()) return null;
    if (await file.length() != entry.data.sizeBytes) return null;
    return CachedFile(
      reference: _refFor(entry.path),
      data: entry.data,
      localPath: entry.localPath,
      cachedAt: entry.pinnedAt,
    );
  }
```

- [ ] **Step 4: Add `cachedFilesIn` to the catalog**

In `lib/src/offline/offline_catalog.dart`, immediately after `_verifiedFile`:

```dart
  /// The cached files whose parent directory is exactly [directory], sorted by
  /// path.
  ///
  /// One level only, mirroring a directory listing. Verified through
  /// [_verifiedFile], so a row whose bytes are absent or incomplete is omitted
  /// rather than returned in a degraded form.
  Future<List<CachedFile>> cachedFilesIn(String directory) async {
    final out = <CachedFile>[];
    for (final entry in await all()) {
      if (_parentDir(entry.path) != directory) continue;
      final file = await _verifiedFile(entry);
      if (file != null) out.add(file);
    }
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  /// The parent directory of [p] — everything before the final `/` — or `''`
  /// when [p] has no slash.
  String _parentDir(String p) {
    final i = p.lastIndexOf('/');
    return i < 0 ? '' : p.substring(0, i);
  }
```

The stats run sequentially on purpose: `Future.wait` over them saves
microseconds and risks a file-descriptor storm on a large directory.

- [ ] **Step 5: Add the `ChildReference` delegate**

In `lib/src/child_reference.dart`, directly after the `cachedFile()` method
(currently line 323):

```dart
  /// The cached files directly under this path, sorted by path.
  ///
  /// Never contacts the server — the one directory-shaped read that works
  /// offline. Returns an empty list when nothing here is cached; a file cached
  /// at a deeper level is not included, and neither is a row whose bytes are
  /// absent or incomplete, so every returned [CachedFile] has a `localPath`
  /// that opens.
  ///
  /// This reports what this device holds. It says nothing about what exists on
  /// the server — for that, [listChildren]. Requires a configured store.
  Future<List<CachedFile>> cachedFiles() => _requireCatalog().cachedFilesIn(path);
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `dart test test/offline/cached_files_test.dart`
Expected: 3 tests pass.

- [ ] **Step 7: Run the full suite and analyzer**

Run: `dart test && dart analyze`
Expected: 184 tests pass; `No issues found!`

- [ ] **Step 8: Commit**

```bash
git add lib/src/offline/offline_catalog.dart lib/src/child_reference.dart test/offline/cached_files_test.dart
git commit -m "feat: add ChildReference.cachedFiles()"
```

---

## Task 3: Lock down the verification edges

These tests pass the moment they are written, because Task 2 reuses
`_verified`. That is the point: they pin the reuse, so a later refactor cannot
quietly turn the list path into a row-only read that hands back paths which do
not open. Write them, watch them pass, commit.

**Files:**
- Modify: `test/offline/cached_files_test.dart`

- [ ] **Step 1: Add the edge-case tests**

Append these inside `main()`, after the existing `test(...)` calls:

```dart
  test('skips a row whose bytes are the wrong length', () async {
    // A partial download: the row says ready, the disk disagrees. Disk wins.
    final api = _OfflineApi();
    final cat = catFor(api);
    await seed(cat, 'u1/a.png', id: 'a', sizeBytes: 3, byteCount: 2);
    final ref = ChildReference(path: 'u1', api: api, catalog: cat);

    expect(await ref.cachedFiles(), isEmpty);
  });

  test('skips a stale row whose bytes never landed', () async {
    // What markPinDeferred leaves behind when an upload could not be staged.
    final api = _OfflineApi();
    final cat = catFor(api);
    await seed(cat, 'u1/a.png',
        id: 'a', byteCount: null, status: CatalogStatus.stale);
    final ref = ChildReference(path: 'u1', api: api, catalog: cat);

    expect(await ref.cachedFiles(), isEmpty);
  });

  test('skips a downloading row that is still partial', () async {
    final api = _OfflineApi();
    final cat = catFor(api);
    await seed(cat, 'u1/a.png',
        id: 'a', sizeBytes: 3, byteCount: 1, status: CatalogStatus.downloading);
    final ref = ChildReference(path: 'u1', api: api, catalog: cat);

    expect(await ref.cachedFiles(), isEmpty);
  });

  test('returns a downloading row whose bytes are complete', () async {
    // The process-kill case: the bytes landed, the frame that would have
    // flipped the row to ready died with the process. The bytes decide.
    final api = _OfflineApi();
    final cat = catFor(api);
    await seed(cat, 'u1/a.png', id: 'a', status: CatalogStatus.downloading);
    final ref = ChildReference(path: 'u1', api: api, catalog: cat);

    expect((await ref.cachedFiles()).map((f) => f.path), ['u1/a.png']);
  });

  test('throws StateError without a configured store', () {
    expect(ChildReference(path: 'u1', api: NoopApi()).cachedFiles,
        throwsStateError);
  });
```

- [ ] **Step 2: Run them**

Run: `dart test test/offline/cached_files_test.dart`
Expected: 8 tests pass. If any of the first four fails, `_verified` is not
being reused by `cachedFilesIn` — fix that rather than the test.

- [ ] **Step 3: Commit**

```bash
git add test/offline/cached_files_test.dart
git commit -m "test: pin cachedFiles() byte verification to the disk"
```

---

## Task 4: Fix `CachedFile.reference`

`OfflineCatalog._refFor` builds references with no `catalog`, so every cache
method on a `CachedFile.reference` throws `StateError`, and `delete()` through
one leaves the cached bytes and row behind as an orphan. `cachedFiles()` hands
out N of these, so the fix ships with it.

**Files:**
- Modify: `lib/src/offline/offline_catalog.dart:297-298`
- Modify: `lib/src/offline/cached_file.dart` (doc the remaining limitation)
- Modify: `test/offline/cached_files_test.dart`

- [ ] **Step 1: Write the failing tests**

Add this fake class at the top of `test/offline/cached_files_test.dart`, after
`_OfflineApi`:

```dart
class _DeleteApi extends NoopApi {
  final deleted = <String>[];

  @override
  Future<bool> deleteFile(String path) async {
    deleted.add(path);
    return true;
  }
}
```

And append these tests inside `main()`:

```dart
  test('a returned reference can drop its own cached copy', () async {
    final api = _OfflineApi();
    final cat = catFor(api);
    await seed(cat, 'u1/a.png', id: 'a');
    final dir = ChildReference(path: 'u1', api: api, catalog: cat);
    final file = (await dir.cachedFiles()).single;

    await file.reference.clearCache();

    expect(await dir.cachedFiles(), isEmpty);
    expect(File('${tmp.path}/a.png').existsSync(), isFalse);
  });

  test('deleting through a returned reference leaves no orphan', () async {
    // Without a catalog on the reference, delete() succeeds on the server and
    // silently no-ops its local cleanup — the bytes and the row survive a
    // deletion that reported success.
    final api = _DeleteApi();
    final cat = catFor(api);
    await seed(cat, 'u1/a.png', id: 'a');
    final dir = ChildReference(path: 'u1', api: api, catalog: cat);
    final file = (await dir.cachedFiles()).single;

    expect(await file.reference.delete(), isTrue);

    expect(api.deleted, ['u1/a.png']);
    expect(await dir.cachedFiles(), isEmpty);
    expect(File('${tmp.path}/a.png').existsSync(), isFalse);
  });
```

- [ ] **Step 2: Run them to verify they fail**

Run: `dart test test/offline/cached_files_test.dart`
Expected: both new tests FAIL — the first with `StateError: no file cache
configured (set directoryResolver or inMemory).`, the second on
`expect(await dir.cachedFiles(), isEmpty)` because the row survives the delete.

- [ ] **Step 3: Wire the collaborators the catalog holds**

In `lib/src/offline/offline_catalog.dart`, replace `_refFor` (line 297):

```dart
  ChildReference _refFor(String path) =>
      ChildReference(path: path, api: _api, directoryResolver: _directoryResolver);
```

with:

```dart
  /// A reference carrying the collaborators this catalog holds, so a reference
  /// handed out on a [CachedFile] can run cache operations — and so `delete()`
  /// through one evicts the copy instead of orphaning it.
  ///
  /// No `controller`: the catalog does not hold one. It is wired the other way
  /// round, in `WincheStorage._bind`, which sets `controller.pinSink = catalog`.
  ChildReference _refFor(String path) => ChildReference(
        path: path,
        api: _api,
        directoryResolver: _directoryResolver,
        catalog: this,
        registry: _registry,
      );
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `dart test test/offline/cached_files_test.dart`
Expected: 10 tests pass.

- [ ] **Step 5: Document what the fix does not cover**

In `lib/src/offline/cached_file.dart`, replace the `reference` field
declaration:

```dart
  final ChildReference reference;
```

with:

```dart
  /// A reference to this file, wired for cache operations — `clearCache()`,
  /// `refreshCache()` and `checkForUpdate()` all work on it, and `delete()`
  /// evicts the local copy along with the remote one.
  ///
  /// It carries no upload queue, so `resumeUpload()` throws on it and
  /// `delete()` will not cancel a queued upload for this path. Use
  /// `storage.child(path)` when either matters.
  final ChildReference reference;
```

- [ ] **Step 6: Run the full suite and analyzer**

Run: `dart test && dart analyze`
Expected: 191 tests pass; `No issues found!`

- [ ] **Step 7: Commit**

```bash
git add lib/src/offline/offline_catalog.dart lib/src/offline/cached_file.dart test/offline/cached_files_test.dart
git commit -m "fix: wire the catalog into references handed out on CachedFile"
```

---

## Task 5: Documentation and version bump

**Files:**
- Modify: `lib/src/child_reference.dart` (the `listChildren()` doc comment)
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `pubspec.yaml:4`

- [ ] **Step 1: Cross-reference from `listChildren()`**

In `lib/src/child_reference.dart`, in the `listChildren()` doc comment, replace
this closing paragraph:

```dart
  /// Always live — listings are never cached — so this throws
  /// `StorageUnavailableException` when the server is unreachable.
```

with:

```dart
  /// Always live — listings are never cached — so this throws
  /// `StorageUnavailableException` when the server is unreachable. For what
  /// this device already holds under this path, which needs no network, use
  /// [cachedFiles].
```

- [ ] **Step 2: Add the README table row**

In `README.md`, in the `ChildReference` method table, insert immediately after
the `cachedFile()` row:

```markdown
| `cachedFiles()` | `Future<List<CachedFile>>` — the cached files **directly under** this path, sorted by path and each verified against the disk. Never contacts the server, so it is the one directory-shaped read that works offline. Empty when nothing here is cached. Requires a store. |
```

- [ ] **Step 3: Update the `listChildren()` table row**

In the same table, replace the `listChildren({mimeType})` row with:

```markdown
| `listChildren({mimeType})` | Lists files under this path from the **server**, returning a `DirectorySnapshot` whose `.files` each carry `isCached` / `localPath`; throws when offline. For what is on disk without a network call, use `cachedFiles()`. |
```

- [ ] **Step 4: Add the README example**

In `README.md`, in the file-cache section, immediately after the code block
that ends with:

```dart
// Drop every cached file for the signed-in identity.
await storage.clearCache();
```

add:

````markdown
Annotation on `listChildren()` covers the multi-file case while the server is
reachable. When it is not, `cachedFiles()` answers the same question from disk
alone:

```dart
// What this device already has directly under a directory. No network, so
// this works offline — and every localPath opens.
for (final CachedFile f in await dir.cachedFiles()) {
  print('${f.path} → ${f.localPath}');
}
```

One level, like a listing. A file cached at a deeper path is not included, and
neither is a row whose bytes are missing or partial.
````

- [ ] **Step 5: Add the CHANGELOG entry**

In `CHANGELOG.md`, insert between the `# CHANGELOG` heading and `## 5.0.0`:

```markdown
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

### Fixed: cache operations on `CachedFile.reference`

The reference carried by a `CachedFile` was built without the catalog, so
`clearCache()`, `refreshCache()`, `keepCached()`, `cachedFile()` and
`checkForUpdate()` all threw `StateError` on an object obtained *from the
cache* — and `delete()` through one deleted the file on the server, then
silently skipped its local cleanup, leaving the bytes and the catalog row
behind as an orphan that still reported as cached.

It now carries the catalog. It still carries no upload queue, so
`resumeUpload()` throws on it and `delete()` will not cancel a queued upload
for that path — use `storage.child(path)` when either matters.
```

- [ ] **Step 6: Bump the version**

In `pubspec.yaml`, change line 4 from `version: 5.0.0` to `version: 5.1.0`.

- [ ] **Step 7: Verify everything**

Run: `dart test && dart analyze`
Expected: 191 tests pass; `No issues found!`

Then run: `dart pub publish --dry-run`
Expected: the package validates. This step is a sanity check on the version
bump, not a gate — if it reports warnings that predate this change (packaging,
`.pubignore`, repository metadata), note them and move on rather than fixing
them here.

- [ ] **Step 8: Commit**

```bash
git add lib/src/child_reference.dart README.md CHANGELOG.md pubspec.yaml
git commit -m "docs: document cachedFiles() and release 5.1.0"
```

---

## Done

`cachedFiles()` on `ChildReference`, 10 new tests (191 total), the
`CachedFile.reference` fix, and a 5.1.0 release entry. No breaking change: a
5.0.0 consumer compiles untouched, and the reference fix only changes behaviour
where that behaviour was a `StateError` or a silent orphan.
