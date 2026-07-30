import 'dart:typed_data';

import 'package:mime/mime.dart';

import 'api/winche_storage_api.dart';
import 'directory_snapshot.dart';
import 'file_snapshot.dart';
import 'offline/cache_status.dart';
import 'offline/cached_file.dart';
import 'offline/catalog_entry.dart';
import 'offline/live_task_registry.dart';
import 'offline/offline_catalog.dart';
import 'offline/transfer_controller.dart';
import 'storage_binding.dart';
import 'tasks/download_task.dart';
import 'tasks/upload_task.dart';

final class ChildReference {
  final String path;

  /// Set when this reference resolves through a live service, null when its
  /// collaborators were supplied directly.
  ///
  /// The two forms exist for different callers. Internals and tests build a
  /// reference over explicit collaborators and want them fixed. A reference
  /// handed out by `WincheStorage.child()` must instead resolve at use time,
  /// so that it can be built while signed out and still work once an identity
  /// arrives — and so it never keeps a torn-down session alive.
  final StorageBinding? _binding;

  final WincheStorageApi? _api;
  final int _multipartThreshold;
  final Future<String> Function()? _directoryResolver;
  final OfflineCatalog? _catalog;
  final TransferController? _controller;
  final LiveTaskRegistry? _registry;

  const ChildReference({
    required this.path,
    required WincheStorageApi api,
    int multipartThreshold = 5 * 1024 * 1024,
    Future<String> Function()? directoryResolver,
    OfflineCatalog? catalog,
    TransferController? controller,
    LiveTaskRegistry? registry,
  })  : _binding = null,
        _api = api,
        _multipartThreshold = multipartThreshold,
        _directoryResolver = directoryResolver,
        _catalog = catalog,
        _controller = controller,
        _registry = registry;

  /// A reference that resolves its collaborators from [binding] when used.
  const ChildReference.bound({required this.path, required StorageBinding binding})
      : _binding = binding,
        _api = null,
        _multipartThreshold = 5 * 1024 * 1024,
        _directoryResolver = null,
        _catalog = null,
        _controller = null,
        _registry = null;

  /// The api this reference operates against.
  ///
  /// For a bound reference this throws `WincheUnboundException` when nobody is
  /// signed in — which is why building one never throws and using one can.
  WincheStorageApi get api => _binding?.api ?? _api!;

  int get multipartThreshold =>
      _binding?.multipartThreshold ?? _multipartThreshold;

  /// Resolves the default download directory, or null when none is configured.
  /// Resolved lazily by [DownloadTask] when `saveTo` is omitted.
  Future<String> Function()? get directoryResolver =>
      _binding != null ? _binding.directoryResolver : _directoryResolver;

  /// Offline catalog when a local store is configured, else null.
  OfflineCatalog? get catalog =>
      _binding != null ? _binding.catalog : _catalog;

  /// Transfer controller when a durable store is configured, else null.
  TransferController? get controller =>
      _binding != null ? _binding.controller : _controller;

  /// Tracks the one-shot transfers this reference starts so teardown can abort
  /// them. Null for references built inside the SDK, whose transfers are
  /// durable and tracked by [controller].
  LiveTaskRegistry? get registry =>
      _binding != null ? _binding.registry : _registry;

  /// A reference to [fullPath] carrying this reference's configuration, in
  /// whichever of the two forms this one uses.
  ChildReference _withPath(String fullPath) {
    final binding = _binding;
    if (binding != null) {
      return ChildReference.bound(path: fullPath, binding: binding);
    }
    return ChildReference(
      path: fullPath,
      api: _api!,
      multipartThreshold: _multipartThreshold,
      directoryResolver: _directoryResolver,
      catalog: _catalog,
      controller: _controller,
      registry: _registry,
    );
  }

  /// The last path segment (e.g. `a.png`).
  String get name {
    final i = path.lastIndexOf('/');
    return i < 0 ? path : path.substring(i + 1);
  }

  /// The parent reference, or null at the root (a single-segment path).
  ChildReference? get parent {
    final i = path.lastIndexOf('/');
    if (i < 0) return null;
    return _withPath(path.substring(0, i));
  }

  /// Returns a new [ChildReference] for a child path.
  ChildReference child(String path) => _withPath('${this.path}/$path');

  /// Fetches the file's record from the server, annotated with whether this
  /// device has its bytes cached.
  ///
  /// Always live: directory and metadata reads are never served from a cache, so
  /// this throws `StorageUnavailableException` when the server is unreachable. A
  /// server-confirmed absence yields a missing snapshot. For the local bytes
  /// without any network call, use [cachedFile].
  Future<FileSnapshot> getSnapshot() async {
    final data = await api.getFile(path);
    if (data == null) return FileSnapshot.missing(this);
    final row = await catalog?.entryFor(path);
    final cached = row != null && row.status == CatalogStatus.ready;
    return FileSnapshot.fromData(
      data,
      reference: this,
      isCached: cached,
      localPath: cached ? row.localPath : null,
    );
  }

  /// Lists the files in the directory at this reference's path, optionally
  /// filtered by [mimeType]. Each [FileSnapshot] is annotated with whether this
  /// device has that file's bytes cached, so a listing alone is enough to badge
  /// what is available offline.
  ///
  /// Always live — listings are never cached — so this throws
  /// `StorageUnavailableException` when the server is unreachable.
  Future<DirectorySnapshot> listChildren({String? mimeType}) async {
    final timestamp = DateTime.now();
    final files = await api.listDirectory(path, mimeType: mimeType);
    // One bulk catalog read for the whole listing, rather than a filesystem
    // check per file. Advisory by design: this renders a badge. [cachedFile] is
    // the authoritative check, because it hands out a path someone will open.
    final rows = {
      for (final e in await catalog?.all() ?? const <CatalogEntry>[])
        e.path: e,
    };
    final snapshots = files.map((file) {
      final row = rows[file.path];
      final cached = row != null && row.status == CatalogStatus.ready;
      return FileSnapshot.fromData(
        file,
        timestamp: timestamp,
        reference: _childRef(file.path),
        isCached: cached,
        localPath: cached ? row.localPath : null,
      );
    }).toList();
    return DirectorySnapshot.fromFiles(snapshots,
        reference: this, timestamp: timestamp);
  }

  ChildReference _childRef(String fullPath) => _withPath(fullPath);

  /// Uploads a local file.
  ///
  /// [mimeType] is optional — when omitted it is inferred from [localPath]'s
  /// extension via the `mime` package, falling back to `application/octet-stream`.
  ///
  /// [enqueue] makes the upload durable: it joins the outbox, is deduped
  /// by path, survives an app restart, and retries until it succeeds (so it can
  /// be started while offline). Requires a configured store, else throws
  /// `StateError`.
  ///
  /// [cache] also keeps the bytes on this device: the source is staged, uploaded
  /// from the staged copy, then moved into the id-keyed cache on success
  /// (best-effort — a caching failure leaves the upload successful and records a
  /// row a later [keepCached] fills in). Requires a configured store, else
  /// throws `StateError`.
  UploadTask uploadPath(
    String localPath, {
    String? mimeType,
    Map<String, dynamic>? metadata,
    int? multipartThreshold,
    bool enqueue = false,
    bool cache = false,
  }) {
    final resolvedMime =
        mimeType ?? lookupMimeType(localPath) ?? 'application/octet-stream';
    if (cache && catalog == null) {
      throw StateError('cache requires an offline store; configure '
          'directoryResolver or inMemory.');
    }
    if (enqueue && controller == null) {
      throw StateError('enqueue requires a durable store; configure '
          'directoryResolver or inMemory.');
    }
    if (enqueue) {
      return controller!.startUpload(
        this,
        localPath: localPath,
        mimeType: resolvedMime,
        metadata: metadata,
        multipartThreshold: multipartThreshold ?? this.multipartThreshold,
        pinned: cache,
      );
    }
    return _trackUpload(UploadTask.start(
      reference: this,
      localPath: localPath,
      mimeType: resolvedMime,
      metadata: metadata,
      multipartThreshold: multipartThreshold ?? this.multipartThreshold,
      stageSource: cache
          ? () => catalog!.stageForUpload(this, sourcePath: localPath)
          : null,
      onPinFinalize: cache ? (c) => catalog!.finalizePin(this, c) : null,
      onPinDeferred: cache ? (c) => catalog!.markPinDeferred(this, c) : null,
    ));
  }

  /// Registers a one-shot task with the registry, when one is configured, so
  /// `WincheStorage.close()` can abort it and so it stays observable on
  /// `transferEvents` and via `uploadFor`/`downloadFor`. Returns [task] for
  /// inline use.
  UploadTask _trackUpload(UploadTask task) =>
      registry == null ? task : registry!.addUpload(path, task);

  DownloadTask _trackDownload(DownloadTask task) =>
      registry == null ? task : registry!.addDownload(path, task);

  /// Uploads bytes.
  ///
  /// [mimeType] is required when uploading bytes, as it cannot be inferred.
  ///
  /// [cache] also keeps the bytes on this device: they are staged to disk
  /// first, uploaded from the staged copy, then moved into the id-keyed cache
  /// on success (best-effort). Requires a configured store, else throws
  /// `StateError`. Byte uploads are not durable — for a queued upload,
  /// write the bytes to a file and use [uploadPath] with `enqueue: true`.
  UploadTask uploadBytes(
    Uint8List bytes,
    String mimeType, {
    Map<String, dynamic>? metadata,
    int? multipartThreshold,
    bool cache = false,
  }) {
    if (mimeType.isEmpty) {
      throw ArgumentError('mimeType is required when uploading bytes.');
    }
    if (cache && catalog == null) {
      throw StateError('cache requires an offline store; configure '
          'directoryResolver or inMemory.');
    }
    return _trackUpload(UploadTask.startFromBytes(
      reference: this,
      bytes: bytes,
      mimeType: mimeType,
      metadata: metadata,
      multipartThreshold: multipartThreshold ?? this.multipartThreshold,
      stageSource:
          cache ? () => catalog!.stageForUpload(this, bytes: bytes) : null,
      onPinFinalize: cache ? (c) => catalog!.finalizePin(this, c) : null,
      onPinDeferred: cache ? (c) => catalog!.markPinDeferred(this, c) : null,
    ));
  }

  /// Downloads the file to [saveTo] (an absolute path; bytes written verbatim).
  /// For a managed copy that needs no path, use [keepCached] instead.
  ///
  /// One-shot, with in-session retry. Downloads are never persisted: the bytes
  /// stay authoritative on the server, so a download interrupted by app exit
  /// costs bandwidth to redo, never data. Progress is on the returned task's
  /// `stateStream`, and `WincheStorage.downloadFor(path)` finds it again if the
  /// handle is lost.
  DownloadTask download(String saveTo) => _trackDownload(
      DownloadTask.start(reference: this, saveTo: saveTo));

  /// Updates metadata on the server. Throws `StorageNotFoundException` when the
  /// file does not exist. When this file is cached, its cached metadata is
  /// updated too (content fingerprint preserved) — runs only after the server
  /// write succeeds.
  Future<FileSnapshot> updateMetadata(Map<String, dynamic> metadata) async {
    final updatedData = await api.updateMetadata(path, metadata);
    await catalog?.syncMetadata(path, updatedData.metadata);
    return FileSnapshot.fromData(updatedData, reference: this);
  }

  /// Deletes from the server. Returns true if a file was deleted.
  ///
  /// Also cleans up local state once the server delete succeeds, so a deleted
  /// file never leaves an orphan behind: drops any cached copy (local file +
  /// catalog row) and any queued upload for this path. No-ops when neither the
  /// cache nor the queue is configured.
  Future<bool> delete() async {
    final deleted = await api.deleteFile(path);
    await catalog?.evict(path);
    await controller?.removePath(path);
    return deleted;
  }

  /// The cached copy of this file, or null when this device has no usable
  /// bytes. Never contacts the server, and never throws for "not cached".
  ///
  /// Authoritative: the bytes are verified against the file on disk, so a
  /// returned [CachedFile] always has a `localPath` that opens. Requires a
  /// configured store.
  Future<CachedFile?> cachedFile() => _requireCatalog().cachedFile(path);

  /// The cached files directly under this path, sorted by path.
  ///
  /// Never contacts the server — the one directory-shaped read that works
  /// offline. Returns an empty list when nothing here is cached; a file cached
  /// at a deeper level is not included, and neither is a row whose bytes are
  /// absent or incomplete, so every returned [CachedFile] has a `localPath`
  /// that opens.
  ///
  /// Matching is on the exact parent path, so `u1` never picks up `u10`'s
  /// files — and equally, a reference built with a trailing slash matches
  /// nothing, since nothing normalizes the path a reference carries.
  ///
  /// This reports what this device holds. It says nothing about what exists on
  /// the server — for that, [listChildren]. Requires a configured store.
  Future<List<CachedFile>> cachedFiles() => _requireCatalog().cachedFilesIn(path);

  /// Caches this file's bytes, returning the existing copy when
  /// they are already complete. Downloads only when they are not — for an
  /// unconditional re-download use [refreshCache].
  ///
  /// A resumed download is guarded: if the server's content changed since the
  /// partial was written, the partial is discarded rather than appended to.
  ///
  /// Throws `StorageNotFoundException` when the server has no record here, and
  /// `StorageFailedPreconditionException` when it has a record but no bytes —
  /// an upload in flight, or one that failed. To cache a file *you* are
  /// uploading, use `uploadPath(..., cache: true)`, which populates the cache
  /// from the source you already have.
  ///
  /// Throws `StorageUnavailableException` when the server is unreachable.
  /// Retrying is the caller's decision: a cache fill loses nothing by being
  /// deferred, since the bytes stay authoritative on the server.
  ///
  /// Caches exactly this file. To cache a directory's contents, list it and
  /// loop — which is also the only way to bound the concurrency yourself.
  Future<CachedFile> keepCached() => _requireCatalog().pin(this);

  /// Re-downloads this file's current remote version, replacing the cached
  /// bytes. Requires a configured store.
  Future<CachedFile> refreshCache() => _requireCatalog().refresh(this);

  /// Drops this file's cached bytes and its catalog row. A no-op when it is not
  /// cached. Requires a configured store.
  Future<void> clearCache() => _requireCatalog().evict(path);

  /// Compares the cached copy against the server's current record: `upToDate`,
  /// `contentChanged` (re-fetch via [refreshCache]), `remoteDeleted`,
  /// `remoteIncomplete`, or `unknown` (offline).
  ///
  /// Round-trips to the server — unlike every other cache method here. "Not
  /// cached" is not among the results: that is `cachedFile() == null`, which
  /// needs no network. Requires a configured store.
  Future<CacheStatus> checkForUpdate() => _requireCatalog().checkForUpdate(path);

  /// Resumes this path's queued or paused durable upload. Requires a configured
  /// store.
  Future<void> resumeUpload() {
    final ctrl = controller;
    if (ctrl == null) {
      throw StateError(
          'no durable store configured (set directoryResolver or inMemory).');
    }
    return ctrl.resumePath(path);
  }

  OfflineCatalog _requireCatalog() =>
      catalog ??
      (throw StateError(
          'no file cache configured (set directoryResolver or inMemory).'));
}
