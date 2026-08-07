import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../api/winche_storage_api.dart';
import '../api/winche_storage_exception.dart';
import '../child_reference.dart';
import '../models/file_data.dart';
import '../models/upload_status.dart';
import '../tasks/download_task.dart';
import 'cache_status.dart';
import 'cached_file.dart';
import 'catalog_entry.dart';
import 'live_task_registry.dart';
import 'local_paths.dart';
import 'storage_local_store.dart';
import 'upload_pin_sink.dart';

/// The file cache: which files this device holds bytes for, and where.
///
/// Owns an id-keyed cache directory rooted at [_directoryResolver] — which
/// resolves to the caller's identity-scoped root — with files at
/// `<root>/cache/<id><.ext>` and in-progress cached uploads at
/// `<root>/staging/<hash>`.
class OfflineCatalog implements UploadPinSink {
  OfflineCatalog({
    required WincheStorageApi api,
    required StorageLocalStore store,
    required Future<String> Function()? directoryResolver,
    int multipartThreshold = 5 * 1024 * 1024, // accepted for API symmetry; downloads don't use it
    LiveTaskRegistry? registry,
    Dio? httpClient,
  })  : _api = api,
        _store = store,
        _directoryResolver = directoryResolver,
        _registry = registry,
        _httpClient = httpClient;

  final WincheStorageApi _api;
  final StorageLocalStore _store;
  final Future<String> Function()? _directoryResolver;

  /// Tracks cache fills so teardown can abort them, and so they are visible on
  /// `transferEvents` like any other transfer.
  ///
  /// Without this a fill started before a sign-out keeps writing into the cache
  /// path after the session is gone — and the next session's fill for the same
  /// file writes to the same place concurrently, producing a file that is the
  /// partial plus a whole second copy.
  final LiveTaskRegistry? _registry;

  final Dio? _httpClient;

  /// In-flight downloads keyed by path — de-dups concurrent cache/refresh calls.
  final Map<String, Future<CachedFile>> _activePins = {};

  Future<CatalogEntry?> entryFor(String path) async {
    final raw = await _store.getCatalog(path);
    return raw == null ? null : CatalogEntry.fromJson(raw);
  }

  Future<List<CatalogEntry>> all() async =>
      [for (final j in await _store.allCatalog()) CatalogEntry.fromJson(j)];

  /// The cached copy at [path], or null when this device has no usable bytes.
  ///
  /// Absence is not an error: "I do not have these bytes" is an ordinary
  /// answer, not a failure. A non-null result is one a caller can act on
  /// directly — its `localPath` opens. A row this returns null for is repaired
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

  /// The cached files whose parent directory is exactly [directory], sorted by
  /// path.
  ///
  /// One level, because the server's listing is one level: a recursive variant
  /// would cover a different set than [ChildReference.listChildren], and
  /// comparing the two is the point of having both. Verified through
  /// [_verifiedFile].
  Future<List<CachedFile>> cachedFilesIn(String directory) async {
    final out = <CachedFile>[];
    for (final entry in await all()) {
      if (_parentDir(entry.path) != directory) continue;
      // Sequential on purpose: `Future.wait` over these stats would save
      // microseconds and risk a descriptor storm on a large directory.
      final file = await _verifiedFile(entry);
      if (file != null) out.add(file);
    }
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  /// The parent directory of [p] — everything before the final `/`.
  ///
  /// Derived from the key rather than read from `data.directory`: that field
  /// is the server's, nothing local keeps it in step with the key a row is
  /// stored under, and the result of [cachedFilesIn] is a list of keys.
  ///
  /// A slashless path yields `''`. That is the root, which [ChildReference]
  /// models as a null parent rather than as an address; the two only meet if a
  /// caller builds `child('')`, which nothing in the API produces on its own.
  String _parentDir(String p) {
    final i = p.lastIndexOf('/');
    return i < 0 ? '' : p.substring(0, i);
  }

  /// Ensures [ref] is cached, returning the existing copy when the bytes are
  /// already complete. Downloads only when they are not — for an unconditional
  /// re-download use [refresh].
  ///
  /// A second call for the same path while a download is in flight returns the
  /// same future.
  Future<CachedFile> pin(ChildReference ref) async {
    final existing = await cachedFile(ref.path);
    if (existing != null) return existing;
    return _download(ref);
  }

  /// Re-downloads the current remote version, replacing any cached bytes.
  Future<CachedFile> refresh(ChildReference ref) => _download(ref);

  Future<CachedFile> _download(ChildReference ref) {
    final existing = _activePins[ref.path];
    if (existing != null) return existing;
    final fut = _doDownload(ref);
    _activePins[ref.path] = fut;
    // Cleanup only — the caller observes success/failure via the returned [fut];
    // `.ignore()` keeps a failed download from surfacing here as an unhandled
    // error.
    fut.whenComplete(() {
      if (identical(_activePins[ref.path], fut)) _activePins.remove(ref.path);
    }).ignore();
    return fut;
  }

  Future<CachedFile> _doDownload(ChildReference ref) async {
    final remote = await _api.getFile(ref.path);
    if (remote == null) {
      throw StorageNotFoundException('No file at "${ref.path}".');
    }
    // uploadStatus is the server's own statement about whether bytes exist.
    // contentHash being null is a symptom of the same thing, so key on the
    // statement rather than on the symptom.
    if (remote.uploadStatus != UploadStatus.complete) {
      throw StorageFailedPreconditionException(
        remote.uploadStatus == UploadStatus.pending
            ? 'The file at "${ref.path}" is still uploading, so there are no '
                'bytes to cache yet. To cache a file you are uploading, use '
                'uploadPath(..., cache: true).'
            : 'The upload for "${ref.path}" failed, so the server has no bytes '
                'to serve. It must be re-uploaded before it can be cached.',
      );
    }

    final resolver = _directoryResolver;
    if (resolver == null) {
      throw StateError(
          'directoryResolver is required to cache files on this device.');
    }
    final localPath = await _cachePath(await resolver(), remote, ref.name);

    // Resume guard. Appending to a partial written from different bytes yields
    // a file that passes a length check and is silently corrupt. Both hashes
    // are always present here: uploadStatus == complete implies a contentHash.
    final previous = await entryFor(ref.path);
    final partial = File(localPath);
    var canResume = false;
    if (previous != null && await partial.exists()) {
      canResume = previous.data.contentHash == remote.contentHash;
      if (!canResume) await partial.delete();
    }

    await _put(CatalogEntry(
      data: remote,
      localPath: localPath,
      pinnedAt: DateTime.now(),
      status: CatalogStatus.downloading,
      etag: canResume ? previous?.etag : null,
    ));

    final started = DownloadTask.start(
      reference: ref,
      saveTo: localPath,
      httpClient: _httpClient,
      isResume: canResume,
      ifRangeEtag: canResume ? previous?.etag : null,
    );
    // Tracked so teardown aborts it. An untracked fill outlives its session and
    // races the next one for the same cache path.
    final task = _registry?.addDownload(ref.path, started) ?? started;

    await task.whenDone; // throws on failure — the row stays `downloading`.

    final entry = CatalogEntry(
      data: remote,
      localPath: localPath,
      pinnedAt: DateTime.now(),
      status: CatalogStatus.ready,
      etag: task.observedEtag,
    );
    await _put(entry);
    return CachedFile(
      reference: ref,
      data: entry.data,
      localPath: entry.localPath,
      cachedAt: entry.pinnedAt,
    );
  }

  /// Compares the cached copy at [path] against the server's current record.
  ///
  /// Round-trips — unlike every other cache read. "Not cached" is deliberately
  /// not one of the results: it is `cachedFile() == null`, answerable locally.
  /// Non-offline API errors propagate.
  Future<CacheStatus> checkForUpdate(String path) async {
    final entry = await entryFor(path);
    if (entry == null) return CacheStatus.unknown;
    final FileData? remote;
    try {
      remote = await _api.getFile(path);
    } on StorageUnavailableException {
      return CacheStatus.unknown;
    }
    if (remote == null) return CacheStatus.remoteDeleted;
    // The server's own statement that it holds no bytes. Distinct from
    // `unknown`, which now means only "could not ask".
    if (remote.uploadStatus != UploadStatus.complete) {
      return CacheStatus.remoteIncomplete;
    }
    return remote.contentHash == entry.data.contentHash
        ? CacheStatus.upToDate
        : CacheStatus.contentChanged;
  }

  /// Updates a cached file's metadata after a successful server write, so a
  /// later [cachedFile] or [cachedFilesIn] reports the current metadata. Only
  /// the metadata is touched — the content fingerprint (and every byte-identity
  /// field) is preserved, so [checkForUpdate] still correctly flags stale
  /// cached *bytes* even if the server content changed too. No-op when not cached.
  ///
  /// Returns the updated row, or null when nothing is cached here — which is
  /// what lets the caller annotate its snapshot without a second read.
  Future<CatalogEntry?> syncMetadata(
      String path, Map<String, dynamic> metadata) async {
    final entry = await entryFor(path);
    if (entry == null) return null;
    final updated =
        entry.copyWith(data: entry.data.copyWith(metadata: metadata));
    await _put(updated);
    return updated;
  }

  /// Removes the local file (best-effort) and the catalog entry.
  Future<void> evict(String path) async {
    final entry = await entryFor(path);
    if (entry == null) return;
    try {
      final f = File(entry.localPath);
      if (await f.exists()) await f.delete();
    } catch (_) {
      // best-effort
    }
    await _store.removeCatalog(path);
  }

  /// Deletes every cached file.
  Future<void> clear() async {
    for (final entry in await all()) {
      await evict(entry.path);
    }
  }

  Future<String> _requireDir() async {
    final resolver = _directoryResolver;
    if (resolver == null) {
      throw StateError(
          'directoryResolver is required to cache files on this device.');
    }
    return resolver();
  }

  /// The `cache/` path for [data] under the scoped [root], with its directory
  /// created. Downloads and upload finalization both write here, and neither can
  /// assume the directory already exists.
  Future<String> _cachePath(
      String root, FileData data, String sourceName) async {
    final path = cacheFilePath(root, data.id,
        sourceName: sourceName, mimeType: data.mimeType);
    await File(path).parent.create(recursive: true);
    return path;
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

  // ── UploadPinSink implementation ──────────────────────────────────────────

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
  Future<String?> finalizeUploadPin(String path, FileData confirmed) =>
      finalizePin(_refFor(path), confirmed);

  // ──────────────────────────────────────────────────────────────────────────

  /// Finalizes a `cache: true` upload: moves the staged copy to the id-keyed path
  /// and records a `ready` entry. Idempotent — if the final file already exists
  /// it just (re)writes the entry. Falls back to a `stale` entry (a later
  /// [refresh] fills it in) when neither a staged nor a final file is present.
  ///
  /// Returns the path the cached bytes now live at, or null when it deferred —
  /// which is what lets the upload's own snapshot report this device's cache
  /// state without a second read.
  Future<String?> finalizePin(ChildReference ref, FileData confirmed) async {
    final dir = await _requireDir();
    final staging = stagingFilePath(dir, ref.path);
    final finalPath = await _cachePath(dir, confirmed, ref.name);
    final stagedFile = File(staging);
    final finalFile = File(finalPath);

    if (await stagedFile.exists()) {
      if (await finalFile.exists()) await finalFile.delete();
      await stagedFile.rename(finalPath);
    } else if (!await finalFile.exists()) {
      await markPinDeferred(ref, confirmed);
      return null;
    }

    await _put(CatalogEntry(
      data: confirmed,
      localPath: finalPath,
      pinnedAt: DateTime.now(),
      status: CatalogStatus.ready,
    ));
    return finalPath;
  }

  /// Records a `stale` entry for a cached copy that could not be populated from the
  /// upload source. A later [refresh]/[pin] downloads it and flips it to ready.
  Future<void> markPinDeferred(ChildReference ref, FileData confirmed) async {
    final finalPath =
        await _cachePath(await _requireDir(), confirmed, ref.name);
    await _put(CatalogEntry(
      data: confirmed,
      localPath: finalPath,
      pinnedAt: DateTime.now(),
      status: CatalogStatus.stale,
    ));
  }

  Future<void> _put(CatalogEntry entry) =>
      _store.putCatalog(entry.path, entry.toJson());

  /// Test seam: seed an entry without performing a real download.
  Future<void> debugPut(CatalogEntry entry) => _put(entry);
}
