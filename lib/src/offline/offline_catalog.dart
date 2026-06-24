import 'dart:io';

import 'package:dio/dio.dart';

import '../api/winche_storage_api.dart';
import '../child_reference.dart';
import '../tasks/download_task.dart';
import 'catalog_entry.dart';
import 'local_paths.dart';
import 'storage_local_store.dart';
import 'transfer_controller.dart';

/// Tracks files pinned for offline availability. Owns an id-keyed cache
/// directory rooted at [_directoryResolver]; files live at `<dir>/<id><.ext>`.
class OfflineCatalog {
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
  /// False when nothing is pinned at [path].
  Future<bool> isStale(String path) async {
    final entry = await entryFor(path);
    if (entry == null) return false;
    final remote = await _api.getFile(path);
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

  Future<void> _put(CatalogEntry entry) =>
      _store.putCatalog(entry.path, entry.toJson());

  /// Test seam: seed an entry without performing a real download.
  Future<void> debugPut(CatalogEntry entry) => _put(entry);
}
