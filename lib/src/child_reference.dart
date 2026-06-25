import 'dart:typed_data';

import 'package:mime/mime.dart';

import 'api/winche_storage_api.dart';
import 'api/winche_storage_exception.dart';
import 'directory_snapshot.dart';
import 'file_snapshot.dart';
import 'offline/catalog_entry.dart';
import 'offline/offline_catalog.dart';
import 'offline/transfer_controller.dart';
import 'tasks/download_task.dart';
import 'tasks/upload_task.dart';

final class ChildReference {
  final String path;
  final WincheStorageApi api;
  final int multipartThreshold;

  /// Resolves the default download directory, or null when none is configured.
  /// Resolved lazily by [DownloadTask] when `saveTo` is omitted.
  final Future<String> Function()? directoryResolver;

  /// Offline catalog when `enableOfflineCache` is on, else null.
  final OfflineCatalog? catalog;

  /// Transfer controller when `enableAutoResume` is on, else null.
  final TransferController? controller;

  const ChildReference({
    required this.path,
    required this.api,
    this.multipartThreshold = 5 * 1024 * 1024,
    this.directoryResolver,
    this.catalog,
    this.controller,
  });

  /// The last path segment (e.g. `a.png`).
  String get name {
    final i = path.lastIndexOf('/');
    return i < 0 ? path : path.substring(i + 1);
  }

  /// The parent reference, or null at the root (a single-segment path).
  ChildReference? get parent {
    final i = path.lastIndexOf('/');
    if (i < 0) return null;
    return ChildReference(
      path: path.substring(0, i),
      api: api,
      multipartThreshold: multipartThreshold,
      directoryResolver: directoryResolver,
      catalog: catalog,
      controller: controller,
    );
  }

  /// Returns a new [ChildReference] for a child path.
  ChildReference child(String path) {
    return ChildReference(
      api: api,
      multipartThreshold: multipartThreshold,
      directoryResolver: directoryResolver,
      catalog: catalog,
      controller: controller,
      path: '${this.path}/$path',
    );
  }

  /// Fetches metadata. Remote-first: returns the authoritative server record
  /// when reachable. When the server is unreachable and a local copy exists,
  /// returns the cached record with [FileSnapshot.fromCache] true. A
  /// server-confirmed absence yields a missing snapshot, never a cache hit.
  Future<FileSnapshot> get() async {
    if (catalog == null) {
      final fileData = await api.getFile(path);
      if (fileData == null) return FileSnapshot.missing(this);
      return FileSnapshot.fromData(fileData, reference: this);
    }
    try {
      final remote = await api.getFile(path);
      if (remote == null) return FileSnapshot.missing(this);
      final entry = await catalog!.entryFor(path);
      final data = entry == null
          ? remote
          : remote.copyWith(
              localPath: entry.localPath, isCached: entry.isCached);
      return FileSnapshot.fromData(data, reference: this);
    } catch (_) {
      final entry = await catalog!.entryFor(path);
      if (entry != null) {
        return FileSnapshot.fromCachedEntry(entry, reference: this);
      }
      rethrow;
    }
  }

  /// Lists the files in the directory at this reference's path.
  ///
  /// Optionally filtered by [mimeType]. Returns a [DirectorySnapshot] whose
  /// `files` holds a [FileSnapshot] per child file.
  ///
  /// Remote-first: returns the authoritative server listing when reachable. When
  /// the server is unreachable and offline cache is on, returns the locally
  /// pinned files directly under this path with [DirectorySnapshot.fromCache]
  /// true (a partial view). A server-unreachable error with no catalog rethrows.
  Future<DirectorySnapshot> list({String? mimeType}) async {
    final timestamp = DateTime.now();
    final cat = catalog;
    try {
      final files = await api.listDirectory(path, mimeType: mimeType);

      // Enrich each record with its offline state (localPath / isCached) from
      // the local catalog, fetched once and indexed by path.
      final entries = <String, CatalogEntry>{};
      if (cat != null) {
        for (final e in await cat.all()) {
          entries[e.path] = e;
        }
      }

      final snapshots = files.map((file) {
        final entry = entries[file.path];
        final data = entry == null
            ? file
            : file.copyWith(
                localPath: entry.localPath, isCached: entry.isCached);
        return FileSnapshot.fromData(
          data,
          timestamp: timestamp,
          reference: _childRef(file.path),
        );
      }).toList();

      return DirectorySnapshot.fromFiles(snapshots,
          reference: this, timestamp: timestamp, fromCache: false);
    } on StorageUnavailableException {
      // Offline: fall back to the pinned files directly under this path. With no
      // catalog there's nothing to serve, so the error propagates.
      if (cat == null) rethrow;
      final snapshots = <FileSnapshot>[];
      for (final e in await cat.all()) {
        if (_parentDir(e.path) != path) continue;
        if (mimeType != null && e.data.mimeType != mimeType) continue;
        snapshots.add(FileSnapshot.fromCachedEntry(e,
            reference: _childRef(e.path), timestamp: timestamp));
      }
      return DirectorySnapshot.fromFiles(snapshots,
          reference: this, timestamp: timestamp, fromCache: true);
    }
  }

  /// A reference to [fullPath] carrying this reference's configuration.
  ChildReference _childRef(String fullPath) => ChildReference(
        path: fullPath,
        api: api,
        multipartThreshold: multipartThreshold,
        directoryResolver: directoryResolver,
        catalog: catalog,
        controller: controller,
      );

  /// The parent directory of [p] (everything before the final `/`), or `''`
  /// when [p] has no slash.
  String _parentDir(String p) {
    final i = p.lastIndexOf('/');
    return i < 0 ? '' : p.substring(0, i);
  }

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

  /// Uploads local file.
  ///
  /// [mimeType] is optional — when omitted it is inferred from [localPath]'s
  /// extension via the `mime` package, falling back to `application/octet-stream`.
  ///
  /// When [makeAvailableOffline] is true and `enableOfflineCache` is on, the
  /// uploaded bytes are placed directly into the offline cache (no download
  /// roundtrip): the source is staged, uploaded from the staged copy, then
  /// moved to the id-keyed cache path on success. Caching is best-effort — if
  /// it fails the upload still succeeds and the pin is recorded as stale for a
  /// later `refresh`. Ignored (with a debug warning) when `enableOfflineCache`
  /// is off.
  UploadTask uploadPath(
    String localPath, {
    String? mimeType,
    Map<String, dynamic>? metadata,
    int? multipartThreshold,
    bool makeAvailableOffline = false,
  }) {
    final resolvedMime =
        mimeType ?? lookupMimeType(localPath) ?? 'application/octet-stream';
    final wantPin = makeAvailableOffline && _ensurePinnable();
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

  /// Uploads bytes.
  ///
  /// [mimeType] is required when uploading bytes, as it cannot be inferred.
  ///
  /// When [makeAvailableOffline] is true and `enableOfflineCache` is on, the
  /// in-memory bytes are staged to disk first, then uploaded from the staged
  /// copy and moved to the id-keyed cache path on success. Caching is
  /// best-effort — if it fails the upload still succeeds and the pin is
  /// recorded as stale for a later `refresh`. Ignored (with a debug warning)
  /// when `enableOfflineCache` is off.
  UploadTask uploadBytes(
    Uint8List bytes,
    String mimeType, {
    Map<String, dynamic>? metadata,
    int? multipartThreshold,
    bool makeAvailableOffline = false,
  }) {
    if (mimeType.isEmpty) {
      throw ArgumentError('mimeType is required when uploading bytes.');
    }
    final wantPin = makeAvailableOffline && _ensurePinnable();
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

  /// Downloads the file to [saveTo].
  ///
  /// [saveTo] is an absolute path; the file's bytes are written there verbatim
  /// (include any extension you want in the path). For a managed, offline-cached
  /// copy that needs no path, use [makeAvailableOffline] instead.
  ///
  /// When `enableAutoResume` is on, the download is enqueued durably and resumes
  /// after an app restart.
  DownloadTask download(String saveTo) {
    final ctrl = controller;
    if (ctrl != null) return ctrl.startDownload(this, saveTo: saveTo);
    return DownloadTask.start(reference: this, saveTo: saveTo);
  }

  /// Updates metadata on the server. Throws `StorageNotFoundException` when the
  /// file does not exist.
  Future<FileSnapshot> updateMetadata(Map<String, dynamic> metadata) async {
    final updatedData = await api.updateMetadata(path, metadata);
    return FileSnapshot.fromData(updatedData, reference: this);
  }

  /// Deletes from the server. Returns true if a file was deleted.
  Future<bool> delete() async {
    return await api.deleteFile(path);
  }

  /// Pins this file for offline use (downloads it to the id-keyed cache).
  /// Requires `enableOfflineCache`. The future completes when the download
  /// finishes; progress is observable on `WincheStorage.transferEvents`.
  Future<void> makeAvailableOffline() {
    final c = catalog;
    if (c == null) {
      throw StateError('enableOfflineCache is false; offline cache disabled.');
    }
    return c.pin(this);
  }

  /// Re-downloads the current remote version into the offline cache.
  /// Requires `enableOfflineCache`.
  Future<void> refresh() {
    final c = catalog;
    if (c == null) {
      throw StateError('enableOfflineCache is false; offline cache disabled.');
    }
    return c.refresh(this);
  }

  /// True when the pinned remote version has changed (or was deleted).
  /// False when nothing is pinned, or when the server is unreachable (offline) —
  /// staleness can't be confirmed, so the pinned copy is treated as current.
  /// Requires `enableOfflineCache`.
  Future<bool> isStale() {
    final c = catalog;
    if (c == null) {
      throw StateError('enableOfflineCache is false; offline cache disabled.');
    }
    return c.isStale(path);
  }

  /// Removes the local copy and catalog entry. Requires `enableOfflineCache`.
  Future<void> evict() {
    final c = catalog;
    if (c == null) {
      throw StateError('enableOfflineCache is false; offline cache disabled.');
    }
    return c.evict(path);
  }

  /// Resumes this path's queued transfer. Requires `enableAutoResume`.
  Future<void> resume() {
    final ctrl = controller;
    if (ctrl == null) {
      throw StateError('enableAutoResume is false; auto-resume disabled.');
    }
    return ctrl.resumePath(path);
  }
}
