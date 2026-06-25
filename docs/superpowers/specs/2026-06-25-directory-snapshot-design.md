# DirectorySnapshot — Design

**Date:** 2026-06-25
**Status:** Approved (pending spec review)

## Problem

`ChildReference.list()` returns a bare `List<FileSnapshot>` and makes a live
`api.listDirectory` call with no offline handling, so it **throws** when the
server is unreachable — inconsistent with `get()`, which falls back to the local
cache. A bare list also can't carry directory-level metadata (e.g. whether the
listing came from cache).

## Goal

Introduce a `DirectorySnapshot` value returned by `list()` that:

- Wraps the per-file `FileSnapshot`s plus directory-level metadata.
- Carries a `fromCache` flag, mirroring `FileSnapshot.fromCache`, so an offline
  (cache-served, partial) listing is explicitly marked rather than silently
  looking complete.
- Lets `list()` succeed offline by returning the locally-pinned subset under the
  path, instead of throwing.

## Non-goals

- No change to how the online listing is fetched or enriched (same
  `api.listDirectory` + catalog enrichment as today).
- No new caching of full directory listings — the offline view is built from the
  existing pin catalog only.

## The type: `DirectorySnapshot`

New file `lib/src/directory_snapshot.dart`. Immutable, mirroring `FileSnapshot`:

```dart
final class DirectorySnapshot {
  final ChildReference reference;   // the directory this lists
  final List<FileSnapshot> files;   // one FileSnapshot per child file
  final DateTime timestamp;

  /// True when the listing was served from the local catalog because the server
  /// was unreachable. In that case it is the pinned-only (partial) view of the
  /// directory, not the authoritative server listing.
  final bool fromCache;

  const DirectorySnapshot._({
    required this.reference,
    required this.files,
    required this.timestamp,
    required this.fromCache,
  });

  factory DirectorySnapshot.fromFiles(
    List<FileSnapshot> files, {
    required ChildReference reference,
    DateTime? timestamp,
    bool fromCache = false,
  });

  /// The last path segment of [reference] (e.g. `user-123`).
  String get name;

  int get length => files.length;
  bool get isEmpty => files.isEmpty;
  bool get isNotEmpty => files.isNotEmpty;
}
```

`fromCache` is the single honesty signal — `false` for an authoritative server
listing, `true` for the offline/partial cache view. Exported from
`lib/winche_storage.dart`.

## `list()` behavior

Signature changes to `Future<DirectorySnapshot> list({String? mimeType})`.

**Online (server reachable):**
1. `final files = await api.listDirectory(path, mimeType: mimeType);`
2. Enrich each record with `localPath`/`isCached` from the catalog (unchanged
   from today — a single `catalog.all()` lookup indexed by path).
3. Return `DirectorySnapshot.fromFiles(snapshots, reference: this,
   fromCache: false)`.

**Offline (`StorageUnavailableException` from `listDirectory`):**
1. If `catalog == null`, rethrow — no cache to fall back to (same stance as
   `get()`).
2. Otherwise, take `catalog.all()` and keep entries that live **directly under
   this path**: an entry whose parent directory equals `reference.path` (i.e.
   `entry.path` with its last `/`-segment removed equals `reference.path`).
3. If `mimeType` is provided, keep only entries whose `data.mimeType` matches.
4. Map each surviving entry to `FileSnapshot.fromCachedEntry(entry,
   reference: <child ref for entry.path>)`.
5. Return `DirectorySnapshot.fromFiles(snapshots, reference: this,
   fromCache: true)` — possibly empty (honest: nothing cached here), but
   `fromCache: true` marks it as the offline view.

Only `StorageUnavailableException` triggers the fallback; other API errors
(auth, server 5xx, etc.) still propagate — consistent with the `isStale`
treatment.

### "Directly under this path" rule

A pinned entry at `entry.path` belongs to the directory `reference.path` when the
substring of `entry.path` before its final `/` equals `reference.path`. Entries
in nested subdirectories are excluded (a flat listing of the immediate
directory, matching the online `listDirectory` contract).

## Breaking impact

`list()`'s return type changes from `List<FileSnapshot>` to
`DirectorySnapshot`. Every `for (snap in await ref.list())` becomes
`for (snap in (await ref.list()).files)`. This warrants a **major version bump**
in `pubspec.yaml`.

Internal call sites to update:
- README usage examples and the `list()` API-reference row.
- Existing tests that call `list()` and index the result directly.

## Testing

**Unit (`DirectorySnapshot`):**
- `fromFiles` sets `files`/`reference`/`fromCache`; `name`/`length`/`isEmpty`
  derive correctly.

**Integration (`list()`, memory store + fake api):**
- Online: returns `fromCache: false` with one `FileSnapshot` per server record;
  `localPath`/`isCached` enrichment still applied.
- Offline (`listDirectory` throws `StorageUnavailableException`): returns
  `fromCache: true` containing only pinned entries directly under the path.
- Offline subset excludes entries in nested subdirectories and entries under a
  different directory.
- Offline `mimeType` filter applies.
- Offline with `catalog == null` rethrows `StorageUnavailableException`.
- Other API errors (e.g. `StorageInternalException`) propagate in both online
  and offline-attempt paths.
