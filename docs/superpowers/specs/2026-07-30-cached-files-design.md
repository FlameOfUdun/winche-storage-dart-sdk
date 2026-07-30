# winche_storage — `cachedFiles()`, per-directory cache enumeration

**Date:** 2026-07-30
**Package:** `winche_storage` (5.0.0 published; this ships as **5.1.0**)
**Status:** design agreed, not yet implemented

---

## Problem

5.0.0 turned the offline layer into a per-file content cache and deleted
`offlineChildren()` with no replacement, on the grounds that "cache checking is
per file, not per directory" and that a server listing annotated with
`isCached` covers the multi-file case.

Annotation only covers it *online*. `listChildren()` is a live read and throws
`StorageUnavailableException` when the server is unreachable, so at the moment
the cache matters most — no network — an application cannot ask what it has.
The only remaining bulk operation is `WincheStorage.clearCache()`, which
deletes. There is no way to look.

This adds one read: the cached files directly under a path.

---

## Scope

**In scope:** enumerating rows this device has already cached, under one
directory, verified against the disk.

**Out of scope, unchanged from 5.0.0:** caching the storage *index*. This method
reports what is on this device. It makes no claim about what exists on the
server, is never consulted by `listChildren()` or `getSnapshot()`, and never
calls `api.listDirectory` — the cache layer still has no call into the directory
index, which is what makes that boundary structural rather than documented.

### Why this does not reopen the boundary 5.0.0 drew

`offlineChildren()` was deleted because it *presented as a directory listing*:
it returned `DirectorySnapshot` — the same type as `listChildren()` — carrying
`FileSnapshot` records with an `exists` flag, distinguished only by
`fromCache: true`. That shape implies "the same question answered from two
sources", and a catalog that only ever holds explicitly-cached files can never
answer that question.

`cachedFiles()` differs on all three counts:

| | `offlineChildren()` (deleted) | `cachedFiles()` |
|---|---|---|
| return type | `DirectorySnapshot` — the listing type | `List<CachedFile>` — a cache type |
| implies completeness | yes, by sharing the listing's shape | no — "these are the bytes I have" |
| touches the index | no, but looked like it did | no, and cannot be mistaken for it |

The distinct return type is what carries this. Reusing `DirectorySnapshot`
would have restored the exact smell 5.0.0 removed, and its own doc comment
(`directory_snapshot.dart:6`) asserts it is "always the authoritative server
listing" — which this is not.

**Accepted risk.** `cachedFile()` and `cachedFiles()` differ by one letter,
which is the hazard the 5.0.0 vocabulary note cited when it rejected
`cacheFile()` alongside `cachedFile()`. It is weaker here: those two were
different operations a typo would silently swap, whereas these are the same
operation at two scopes, and the return types (`CachedFile?` vs
`List<CachedFile>`) make a mistyped call a compile error at the use site.

---

## Public API

One method on `ChildReference`:

```dart
/// The cached files directly under this path, verified against the disk.
///
/// Never contacts the server — the one directory-shaped read that works
/// offline. Returns an empty list when nothing here is cached. A file cached
/// at a deeper level is not included, and neither is a row whose bytes are
/// absent or incomplete, so every returned [CachedFile] has a `localPath`
/// that opens.
///
/// Sorted by path. Requires a configured store.
Future<List<CachedFile>> cachedFiles();
```

Nothing else changes: no new types, no changes to `CachedFile`, `CatalogEntry`,
`FileSnapshot`, `DirectorySnapshot`, `StorageLocalStore` or the three stores.

---

## Design decisions

### 1. Direct children only

A row belongs to the result when its parent directory is exactly this
reference's path — the rule the deleted `offlineChildren()` used.

Symmetric with `listChildren()`, so the two directory-shaped reads answer at the
same granularity and the pair is learnable as "live listing" vs "what is on
disk." A recursive variant was considered and rejected: it has no counterpart on
the server side, so `cachedFiles()` and `listChildren()` on the same reference
would cover different sets, and any diff between them — the obvious use — would
be wrong.

The one-level rule is also the only one expressible without inventing a
directory model. The cache is flat: rows are keyed by full storage path
(`sembast_storage_local_store.dart:16`) and the bytes are id-keyed under
`<root>/winche/<storageKey>/storage/cache/` (`local_paths.dart:58`). There is no
directory structure on disk, and the client derives the parent by taking
everything before the final `/` of the row's key.

**On `data.directory`.** Every row does carry a `directory` field — it is on
`FileData`, so it is persisted through `CatalogEntry.toJson`. The parent is
derived from the path anyway, deliberately: that field is the server's, nothing
local keeps it in step with the key a row is stored under, and the existing
suite already seeds rows where the two disagree
(`test/offline/child_reference_offline_test.dart:23` sets `directory: 'd'` for
path `a/b.png`). Nothing in `lib/` reads it today, and this feature does not
start. The matching must be against the key, because the key is what the result
is a list of.

A path is a file or a directory depending on which method is called on it —
already true of `getSnapshot()` vs `listChildren()`. `cachedFiles()` on a path
that is itself a cached file returns an empty list, not that file.

**Two edges of exact matching**, both documented rather than smoothed over:

- A trailing slash matches nothing. `ChildReference.child()` concatenates
  literally and nothing in `lib/` normalizes, so `child('photos/')` yields a
  reference whose `cachedFiles()` is always empty — while `listChildren()` on
  the same reference may well succeed, since it hands the path to a server that
  can tolerate it. Normalizing here would be the only path normalization in the
  package, applied at one call site; stating the constraint is honest and does
  not create an inconsistency.
- The derived parent of a slashless path is `''`, whereas `ChildReference`
  models the root as `parent == null` rather than as an address. The two only
  meet if a caller constructs `child('')` — which nothing in the API produces on
  its own — and there it returns the root-level rows. Left alone: inventing a
  root sentinel to reject would be more machinery than the case is worth.

### 2. Every row is verified against the disk

For each candidate row: the file exists, and its length equals
`data.sizeBytes`. Rows failing either are omitted.

This is the invariant `CachedFile` documents (`cached_file.dart:5-10`) — the
object is handed out only when the content is complete and usable, which is why
`cachedFile()` returns `CachedFile?` rather than a snapshot to interrogate. A
list of objects that might not open would be a weaker contract than the single
one, for no reason a caller could see.

Cost is two filesystem calls per row. Bounded by construction: rows exist only
for files the application named. The catalog read is a full materialization via
`all()` (`offline_catalog.dart:63`), which is what `listChildren()` already does
on this path (`child_reference.dart:159-162`), so this introduces no new cost
profile.

The stats run **sequentially**, matching `clear()`'s loop. `Future.wait` over
stats saves microseconds and risks a file-descriptor storm on a large directory.

Verification also makes the method self-correcting, with no separate healing
mechanism:

| row | on disk | result |
|---|---|---|
| `ready` | complete | returned |
| `ready` | missing (user cleared app data) | omitted |
| `downloading` | partial, or none | omitted |
| `stale` (deferred upload pin) | none yet | omitted |
| `downloading` left by a process kill | complete | **returned** — the bytes decide, not the status |

### 3. `List<CachedFile>`, sorted by path

A plain list. Empty means nothing here is cached — the same "absence is not an
error" stance as `cachedFile()` returning null, and no exception for the normal
case.

Sorted by path ascending, because `allCatalog()`'s ordering is incidental:
`sembast_storage_local_store.dart:65` calls `find` with no `Finder`, and
`MemoryStorageLocalStore` returns map iteration order. Without an explicit
sort the two stores could disagree, which would make tests order-sensitive for
no benefit. `listChildren()` needs no sort because server order is meaningful;
catalog order is not.

One inherited edge, stated rather than changed: after a teardown
`LazyStorageLocalStore.allCatalog()` returns `const []`
(`lazy_storage_local_store.dart:43`), so `cachedFiles()` on a torn-down session
returns an empty list rather than throwing. That is the behaviour `all()`
already gives `listChildren()`'s annotation, and "empty" is the honest answer
for a session with no store.

### 4. No `mimeType` parameter

`listChildren({mimeType})` takes one because filtering server-side saves a round
trip and bandwidth. Here the rows are already in memory, so the parameter buys
nothing over `.where((f) => f.data.mimeType == …)` — and being exact-match, as
`offlineChildren()`'s was, it could not express `image/*` anyway.

### 5. No facade counterpart

`WincheStorage.cachedFiles()` — every cached file for the identity — is not
added. With direct-children-only there is consequently no way to enumerate the
whole cache; `clearCache()` remains the only whole-cache operation.

Deliberate: adding it later is non-breaking, removing it is not. It should
follow a caller that needs it (a cache-management screen, size accounting), not
precede one.

### 6. The logic lives in `OfflineCatalog`

`OfflineCatalog` gains `cachedFilesIn(String directory)`, and the byte
verification shared with `cachedFile()` moves into one private helper.
`ChildReference.cachedFiles()` is a one-line delegate over `_requireCatalog()`,
like every other cache method there.

The alternative — the loop in `ChildReference`, where `offlineChildren()` had it
— re-reads each row from the store (`all()` returns it, then `cachedFile(path)`
fetches it again by key) and splits the rules: parent-directory in the
reference, byte verification in the catalog. Pushing a prefix query down into
`StorageLocalStore` was also rejected: an interface change plus three
implementations plus test fakes, and sembast still scans without an index, so it
buys nothing measurable at any cache size this package will see.

---

## Bug fixed: `CachedFile.reference` cannot do cache operations

`OfflineCatalog._refFor` (`offline_catalog.dart:297`) builds

```dart
ChildReference(path: path, api: _api, directoryResolver: _directoryResolver)
```

with no `catalog`, `controller` or `registry`. It was written for the
`UploadPinSink` path, where only `path` and `name` are read — but `cachedFile()`
hands the result out as `CachedFile.reference`. On that reference today:

- `cachedFile()`, `keepCached()`, `refreshCache()`, `clearCache()` and
  `checkForUpdate()` all throw `StateError` from `_requireCatalog()`, on an
  object obtained *from the cache*.
- `delete()` (`child_reference.dart:310-315`) succeeds on the server, then
  no-ops both `catalog?.evict(path)` and `controller?.removePath(path)`. The
  bytes and the row survive a deletion that reported success — an orphan that
  `cachedFiles()` will happily list as a file the device has.

`cachedFiles()` makes this acute rather than incidental: it returns N such
references, and the obvious loop over them is exactly what breaks.

**Fix.** `_refFor` passes the collaborators it holds:

```dart
ChildReference _refFor(String path) => ChildReference(
      path: path,
      api: _api,
      directoryResolver: _directoryResolver,
      catalog: this,
      registry: _registry,
    );
```

`controller` stays null — the catalog does not hold one; it is wired the other
way (`winche_storage.dart:277` sets `controller.pinSink = catalog`). So
`resumeUpload()` on a reference obtained from a `CachedFile` still throws, and
`delete()` still does not cancel a queued upload for that path. Both are
documented on `CachedFile.reference`. Closing them fully means giving the
catalog the `StorageBinding`, which is a larger change than this feature earns.

No test depends on the current bare reference; the `UploadPinSink` callers read
only `path` and `name`, so wiring the extra collaborators is inert there.

---

## Implementation

`lib/src/offline/offline_catalog.dart`:

```dart
/// A [CachedFile] for [entry] when its bytes are complete on disk, else null.
///
/// The disk is what actually answers "do I have these bytes", so both cache
/// reads verify here rather than trusting the row's status — which is also
/// what stops a row left `downloading` by a process kill from being a
/// permanent blocker.
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

Future<CachedFile?> cachedFile(String path) async {
  final entry = await entryFor(path);
  return entry == null ? null : _verified(entry);
}

/// The verified cached files whose parent directory is exactly [directory].
Future<List<CachedFile>> cachedFilesIn(String directory) async {
  final out = <CachedFile>[];
  for (final entry in await all()) {
    if (_parentDir(entry.path) != directory) continue;
    final file = await _verified(entry);
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

`lib/src/child_reference.dart`, beside `cachedFile()`:

```dart
Future<List<CachedFile>> cachedFiles() => _requireCatalog().cachedFilesIn(path);
```

Existing `cachedFile()` behaviour is unchanged — the same two checks, moved.

---

## Testing

New `test/offline/cached_files_test.dart`, following the fake-API pattern in
`test/offline/child_reference_offline_test.dart`:

- Returns direct children only: a nested row (`u1/photos/b.png`) and a sibling
  directory's row are both excluded.
- Skips a `ready` row whose bytes are missing, and one whose length does not
  match `data.sizeBytes`.
- Skips `downloading` and `stale` rows with no complete bytes, seeded via
  `debugPut`; returns a `downloading` row whose bytes *are* complete (the
  process-kill case).
- Empty list when nothing under the path is cached; results sorted by path.
- Makes no API call at all — asserted with a fake that throws on every method,
  the way `test/offline/directory_pin_test.dart` proves `keepCached()` never
  lists.
- `StateError` when no store is configured.

For the bug fix:

- `(await ref.cachedFile())!.reference.clearCache()` drops the row and the
  bytes, instead of throwing `StateError`.
- `delete()` through a `CachedFile.reference` leaves no catalog row and no bytes
  behind.

Existing suite is 175 tests and none should need changing.

---

## Documentation and release

| file | change |
|---|---|
| `README.md` | row in the `ChildReference` table; a short example in the file-cache section; note that this is the only directory-shaped read that works offline |
| `README.md` | `listChildren()`'s entry gains a see-also, since the pair now needs distinguishing |
| `child_reference.dart` | `listChildren()` doc comment gains the same see-also |
| `CHANGELOG.md` | new `5.1.0` entry: the added method, and the `CachedFile.reference` fix called out as a bug fix with the orphan-on-delete consequence spelled out |
| `pubspec.yaml` | `5.0.0` → `5.1.0` |

Additive: no consumer of 5.0.0 breaks. The reference fix changes behaviour only
where that behaviour was a `StateError` or a silent orphan.

---

## Open questions

None.
