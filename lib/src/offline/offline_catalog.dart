import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../api/winche_storage_api.dart';
import '../api/winche_storage_exception.dart';
import '../child_reference.dart';
import '../models/file_data.dart';
import '../tasks/download_task.dart';
import 'catalog_entry.dart';
import 'local_paths.dart';
import 'storage_local_store.dart';
import 'transfer_controller.dart';
import 'upload_pin_sink.dart';

/// Tracks files pinned for offline availability. Owns an id-keyed cache
/// directory rooted at [_directoryResolver]; files live at `<dir>/<id><.ext>`.
class OfflineCatalog implements UploadPinSink {
  OfflineCatalog({
    required WincheStorageApi api,
    required StorageLocalStore store,
    required Future<String> Function()? directoryResolver,
    int multipartThreshold = 5 * 1024 * 1024, // accepted for API symmetry; downloads don't use it
    TransferController? controller,
    Dio? httpClient,
  })  : _api = api,
        _store = store,
        _directoryResolver = directoryResolver,
        _controller = controller,
        _httpClient = httpClient;

  final WincheStorageApi _api;
  final StorageLocalStore _store;
  final Future<String> Function()? _directoryResolver;
  final TransferController? _controller;
  final Dio? _httpClient;

  /// In-flight pins keyed by path — de-dups concurrent pin/refresh calls.
  final Map<String, Future<void>> _activePins = {};

  Future<CatalogEntry?> entryFor(String path) async {
    final raw = await _store.getCatalog(path);
    return raw == null ? null : CatalogEntry.fromJson(raw);
  }

  Future<List<CatalogEntry>> all() async =>
      [for (final j in await _store.allCatalog()) CatalogEntry.fromJson(j)];

  /// Pins [ref] for offline use: downloads it to `<dir>/<id><.ext>` and tracks
  /// it. Completes when the download finishes. A second pin/refresh for the same
  /// path while one is in flight returns the same future.
  Future<void> pin(ChildReference ref) => _download(ref);

  /// Re-downloads the current remote version of a pinned file.
  Future<void> refresh(ChildReference ref) => _download(ref);

  Future<void> _download(ChildReference ref) {
    final existing = _activePins[ref.path];
    if (existing != null) return existing;
    final fut = _doDownload(ref);
    _activePins[ref.path] = fut;
    fut.whenComplete(() {
      if (identical(_activePins[ref.path], fut)) _activePins.remove(ref.path);
    });
    return fut;
  }

  Future<void> _doDownload(ChildReference ref) async {
    final remote = await _api.getFile(ref.path);
    if (remote == null) {
      throw StateError('Cannot pin "${ref.path}": not found on server.');
    }
    final resolver = _directoryResolver;
    if (resolver == null) {
      throw StateError(
          'directoryResolver is required to store files for offline use.');
    }
    final dir = await resolver();
    final localPath = localFilePath(dir, remote.id,
        sourceName: ref.name, mimeType: remote.mimeType);

    await _put(CatalogEntry(
      data: remote,
      localPath: localPath,
      pinnedAt: DateTime.now(),
      status: CatalogStatus.downloading,
    ));

    // Route through the controller when present (durable + de-duped); otherwise
    // run a direct task. Either way, observe the same DownloadTask.
    final DownloadTask task = _controller != null
        ? _controller!.startDownload(ref, saveTo: localPath)
        : DownloadTask.start(
            reference: ref,
            saveTo: localPath,
            httpClient: _httpClient,
          );

    await task.whenDone; // throws on failure — the entry stays `downloading`.

    final fresh = await entryFor(ref.path);
    if (fresh != null) {
      await _put(fresh.copyWith(status: CatalogStatus.ready));
    }
  }

  /// True when the pinned file's remote version has changed (or it was deleted).
  /// False when nothing is pinned at [path], or when the server is unreachable
  /// (offline): staleness can't be confirmed, so the pinned copy is treated as
  /// current rather than surfacing an error. Other API errors still propagate.
  Future<bool> isStale(String path) async {
    final entry = await entryFor(path);
    if (entry == null) return false;
    final FileData? remote;
    try {
      remote = await _api.getFile(path);
    } on StorageUnavailableException {
      return false; // offline — can't compare; assume the cached copy is current
    }
    if (remote == null) return true;
    return remote.version != entry.data.version ||
        remote.updatedAt != entry.data.updatedAt ||
        remote.sizeBytes != entry.data.sizeBytes;
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

  /// Evicts every pinned file.
  Future<void> clear() async {
    for (final entry in await all()) {
      await evict(entry.path);
    }
  }

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

  // ── UploadPinSink implementation ──────────────────────────────────────────

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

  // ──────────────────────────────────────────────────────────────────────────

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

  Future<void> _put(CatalogEntry entry) =>
      _store.putCatalog(entry.path, entry.toJson());

  /// Test seam: seed an entry without performing a real download.
  Future<void> debugPut(CatalogEntry entry) => _put(entry);
}
