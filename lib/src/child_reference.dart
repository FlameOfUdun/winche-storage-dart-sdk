import 'dart:typed_data';

import 'package:mime/mime.dart';

import 'api/winche_storage_api.dart';
import 'directory_snapshot.dart';
import 'file_snapshot.dart';
import 'offline/offline_catalog.dart';
import 'offline/offline_copy_status.dart';
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

  /// Fetches the file's metadata from the server. Server-only: it does not
  /// consult the offline cache and throws `StorageUnavailableException` when the
  /// server is unreachable. A server-confirmed absence yields a missing snapshot.
  /// For the cached copy, use [offlineSnapshot].
  Future<FileSnapshot> getSnapshot() async {
    final data = await api.getFile(path);
    if (data == null) return FileSnapshot.missing(this);
    return FileSnapshot.fromData(data, reference: this);
  }

  /// Lists the files in the directory at this reference's path, optionally
  /// filtered by [mimeType]. Returns a [DirectorySnapshot] whose `files` holds a
  /// [FileSnapshot] per child file.
  ///
  /// Server-only: it does not consult the offline cache and throws
  /// `StorageUnavailableException` when the server is unreachable. For the locally
  /// pinned files under this path, use [offlineChildren].
  Future<DirectorySnapshot> listChildren({String? mimeType}) async {
    final timestamp = DateTime.now();
    final files = await api.listDirectory(path, mimeType: mimeType);
    final snapshots = files
        .map((file) => FileSnapshot.fromData(
              file,
              timestamp: timestamp,
              reference: _childRef(file.path),
            ))
        .toList();
    return DirectorySnapshot.fromFiles(snapshots,
        reference: this, timestamp: timestamp, fromCache: false);
  }

  /// The cached offline copy's metadata, read straight from the local catalog
  /// without contacting the server ([FileSnapshot.fromCache] true). Returns a
  /// missing snapshot when this file isn't pinned. Requires a configured store.
  Future<FileSnapshot> offlineSnapshot() async {
    final c = catalog;
    if (c == null) {
      throw StateError(
          'no offline store configured (set directoryResolver or inMemory).');
    }
    final entry = await c.entryFor(path);
    if (entry == null) return FileSnapshot.missing(this);
    return FileSnapshot.fromCachedEntry(entry, reference: this);
  }

  /// The locally pinned files directly under this path, read from the local
  /// catalog without contacting the server (a partial view,
  /// [DirectorySnapshot.fromCache] true). Optionally filtered by [mimeType]; may
  /// be empty. Requires a configured store.
  Future<DirectorySnapshot> offlineChildren({String? mimeType}) async {
    final c = catalog;
    if (c == null) {
      throw StateError(
          'no offline store configured (set directoryResolver or inMemory).');
    }
    final timestamp = DateTime.now();
    final snapshots = <FileSnapshot>[];
    for (final e in await c.all()) {
      if (_parentDir(e.path) != path) continue;
      if (mimeType != null && e.data.mimeType != mimeType) continue;
      snapshots.add(FileSnapshot.fromCachedEntry(e,
          reference: _childRef(e.path), timestamp: timestamp));
    }
    return DirectorySnapshot.fromFiles(snapshots,
        reference: this, timestamp: timestamp, fromCache: true);
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

  /// Uploads a local file.
  ///
  /// [mimeType] is optional — when omitted it is inferred from [localPath]'s
  /// extension via the `mime` package, falling back to `application/octet-stream`.
  ///
  /// [enqueue] makes the upload durable: it joins the transfer queue, is deduped
  /// by path, survives an app restart, and retries until it succeeds (so it can
  /// be started while offline). Requires a configured store, else throws
  /// `StateError`.
  ///
  /// [cache] keeps the file available offline: the source is staged, uploaded
  /// from the staged copy, then moved into the id-keyed offline cache on success
  /// (best-effort — a caching failure leaves the upload successful and records a
  /// stale pin). Requires a configured offline cache, else throws `StateError`.
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
    return UploadTask.start(
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
    );
  }

  /// Uploads bytes.
  ///
  /// [mimeType] is required when uploading bytes, as it cannot be inferred.
  ///
  /// [cache] keeps the file available offline: the bytes are staged to disk
  /// first, uploaded from the staged copy, then moved into the id-keyed offline
  /// cache on success (best-effort). Requires a configured offline cache, else
  /// throws `StateError`. Byte uploads are not durable — for a queued upload,
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
    return UploadTask.startFromBytes(
      reference: this,
      bytes: bytes,
      mimeType: mimeType,
      metadata: metadata,
      multipartThreshold: multipartThreshold ?? this.multipartThreshold,
      stageSource:
          cache ? () => catalog!.stageForUpload(this, bytes: bytes) : null,
      onPinFinalize: cache ? (c) => catalog!.finalizePin(this, c) : null,
      onPinDeferred: cache ? (c) => catalog!.markPinDeferred(this, c) : null,
    );
  }

  /// Downloads the file to [saveTo] (an absolute path; bytes written verbatim).
  /// For a managed, offline-cached copy that needs no path, use
  /// [makeAvailableOffline] instead.
  ///
  /// [enqueue] makes the download durable: it joins the transfer queue and
  /// resumes after an app restart, retrying until it succeeds. Requires a
  /// configured store, else throws `StateError`. Without it the download is a
  /// one-shot.
  DownloadTask download(String saveTo, {bool enqueue = false}) {
    if (enqueue && controller == null) {
      throw StateError('enqueue requires a durable store; configure '
          'directoryResolver or inMemory.');
    }
    if (enqueue) return controller!.startDownload(this, saveTo: saveTo);
    return DownloadTask.start(reference: this, saveTo: saveTo);
  }

  /// Updates metadata on the server. Throws `StorageNotFoundException` when the
  /// file does not exist. When this file is pinned offline, its cached metadata
  /// is updated too (content fingerprint preserved), so offline reads stay
  /// current — runs only after the server write succeeds.
  Future<FileSnapshot> updateMetadata(Map<String, dynamic> metadata) async {
    final updatedData = await api.updateMetadata(path, metadata);
    await catalog?.syncMetadata(path, updatedData.metadata);
    return FileSnapshot.fromData(updatedData, reference: this);
  }

  /// Deletes from the server. Returns true if a file was deleted.
  ///
  /// Also cleans up local state once the server delete succeeds, so a deleted
  /// file never leaves an orphan behind: evicts any offline copy (local file +
  /// catalog entry) and drops any queued/in-flight transfer for this path.
  /// No-ops when offline cache / auto-resume are off.
  Future<bool> delete() async {
    final deleted = await api.deleteFile(path);
    await catalog?.evict(path);
    await controller?.removePath(path);
    return deleted;
  }

  /// Pins this file for offline use (downloads it into the id-keyed cache). When
  /// this path is a directory, pins every file directly under it instead (one
  /// level — nested sub-directories are not included, since the server lists a
  /// single level). Requires a configured store. The future completes when the
  /// download(s) finish; progress is observable on `WincheStorage.transferEvents`.
  Future<void> makeAvailableOffline() {
    final c = catalog;
    if (c == null) {
      throw StateError(
          'no offline store configured (set directoryResolver or inMemory).');
    }
    return c.pin(this);
  }

  /// Re-downloads the current remote version into the offline cache, refreshing
  /// the pinned copy. Requires a configured store.
  Future<void> refreshOfflineCopy() {
    final c = catalog;
    if (c == null) {
      throw StateError(
          'no offline store configured (set directoryResolver or inMemory).');
    }
    return c.refresh(this);
  }

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

  /// Removes the local offline copy and its catalog entry. Requires a configured
  /// store.
  Future<void> removeOfflineCopy() {
    final c = catalog;
    if (c == null) {
      throw StateError(
          'no offline store configured (set directoryResolver or inMemory).');
    }
    return c.evict(path);
  }

  /// Resumes this path's queued/paused durable transfer. Requires a configured
  /// store.
  Future<void> resumeTransfer() {
    final ctrl = controller;
    if (ctrl == null) {
      throw StateError(
          'no durable store configured (set directoryResolver or inMemory).');
    }
    return ctrl.resumePath(path);
  }
}
