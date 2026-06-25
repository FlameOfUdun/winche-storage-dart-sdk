import 'dart:async';

import 'src/api/winche_storage_api.dart';
import 'src/api/winche_storage_http_api.dart';
import 'src/child_reference.dart';
import 'src/offline/lazy_storage_local_store.dart';
import 'src/offline/memory_storage_local_store.dart';
import 'src/offline/offline_catalog.dart';
import 'src/offline/sembast_storage_local_store.dart';
import 'src/offline/storage_local_store.dart';
import 'src/offline/transfer_controller.dart';
import 'src/offline/transfer_event.dart';
import 'src/offline/transfer_record.dart';
import 'src/tasks/download_task.dart';
import 'src/tasks/upload_task.dart';

export 'src/child_reference.dart' show ChildReference;
export 'src/file_snapshot.dart' show FileSnapshot;
export 'src/directory_snapshot.dart' show DirectorySnapshot;
export 'src/models/file_data.dart' show FileData;
export 'src/models/upload_session.dart' show UploadSession;
export 'src/models/download_session.dart' show DownloadSession;
export 'src/models/file_part.dart' show FilePart;
export 'src/api/winche_storage_api.dart' show WincheStorageApi;
export 'src/api/winche_storage_http_api.dart' show WincheStorageHttpApi;
export 'src/api/winche_storage_exception.dart';
export 'src/models/upload_status.dart' show UploadStatus;
export 'src/tasks/upload_task.dart'
    show UploadTask, UploadTaskStatus, UploadTaskState;
export 'src/tasks/download_task.dart'
    show DownloadTask, DownloadTaskStatus, DownloadTaskState;
export 'src/offline/storage_local_store.dart' show StorageLocalStore;
export 'src/offline/memory_storage_local_store.dart'
    show MemoryStorageLocalStore;
export 'src/offline/sembast_storage_local_store.dart'
    show SembastStorageLocalStore;
export 'src/offline/catalog_entry.dart' show CatalogEntry, CatalogStatus;
export 'src/offline/transfer_record.dart'
    show TransferRecord, TransferKind, TransferStatus;
export 'src/offline/transfer_event.dart'
    show TransferEvent, TransferEventType;
export 'src/offline/offline_copy_status.dart' show OfflineCopyStatus;

/// True on the web, where Dart's numeric types collapse so `0` and `0.0` are
/// identical. On web the durable store uses IndexedDB (no directory needed).
const bool _kIsWeb = identical(0, 0.0);

/// Connection and offline options for [WincheStorage].
final class WincheStorageConfig {
  /// The REST base URI, e.g. `Uri.parse('https://host/files')`.
  final Uri uri;

  /// Supplies the auth token sent as `Authorization: Bearer <token>`.
  final FutureOr<String> Function()? tokenProvider;

  /// Files larger than this are uploaded in multiple parts. Defaults to 5 MiB.
  final int multipartThreshold;

  /// Use a non-persistent in-memory index (catalog + transfer queue) instead of
  /// sembast. Files still go to disk via [directoryResolver]. Defaults to false.
  final bool inMemory;

  /// Resolves the default download directory and the offline cache root.
  ///
  /// Its presence (or [inMemory], or web) enables the durable transfer queue and
  /// offline cache. With none of those configured on native, the client is
  /// stateless and durable/offline operations throw `StateError` at call time.
  final Future<String> Function()? directoryResolver;

  /// Initial backoff before the first durable-transfer retry. Defaults to 1s.
  final Duration retryBaseDelay;

  /// Cap on the exponential backoff between retries. Defaults to 30s.
  final Duration retryMaxDelay;

  /// How many times a failed transfer is retried before giving up permanently.
  /// Defaults to 5.
  final int retryMaxAttempts;

  /// Interval of the backstop poll that re-drives failed transfers still within
  /// the attempt cap. Defaults to 30s.
  final Duration retryPollInterval;

  const WincheStorageConfig({
    required this.uri,
    this.tokenProvider,
    this.multipartThreshold = 5 * 1024 * 1024,
    this.inMemory = false,
    this.directoryResolver,
    this.retryBaseDelay = const Duration(seconds: 1),
    this.retryMaxDelay = const Duration(seconds: 30),
    this.retryMaxAttempts = 5,
    this.retryPollInterval = const Duration(seconds: 30),
  });
}

/// The entry point for the Winche Storage Dart SDK.
final class WincheStorage {
  final WincheStorageApi _api;
  final StorageLocalStore? _store;
  final OfflineCatalog? _catalog;
  final TransferController? _controller;
  final int _multipartThreshold;
  late final Future<String> Function()? _resolveDirectory;

  WincheStorage._({
    required WincheStorageApi api,
    required StorageLocalStore? store,
    required OfflineCatalog? catalog,
    required TransferController? controller,
    required int multipartThreshold,
    required Future<String> Function()? resolveDirectory,
  })  : _api = api,
        _store = store,
        _catalog = catalog,
        _controller = controller,
        _multipartThreshold = multipartThreshold {
    _resolveDirectory = resolveDirectory;
    unawaited(controller?.rehydrate());
  }

  factory WincheStorage(WincheStorageConfig config) {
    final resolver = config.directoryResolver;
    final resolveDirectory = resolver == null ? null : _memoize(resolver);

    // The durable queue + offline cache exist when there's somewhere to put a
    // store: a directory (native), an in-memory index, or web (IndexedDB).
    final needsStore = config.inMemory || resolver != null || _kIsWeb;

    final api = WincheStorageHttpApi(
      baseUrl: config.uri.toString(),
      tokenProvider: config.tokenProvider,
    );

    final StorageLocalStore? store = !needsStore
        ? null
        : (config.inMemory
            ? MemoryStorageLocalStore()
            : LazyStorageLocalStore(() async => SembastStorageLocalStore.open(
                  'winche_storage',
                  directory: _kIsWeb ? null : await resolveDirectory!(),
                )));

    return WincheStorage._build(
      api: api,
      store: store,
      multipartThreshold: config.multipartThreshold,
      resolveDirectory: resolveDirectory,
      retry: TransferRetryConfig(
        baseDelay: config.retryBaseDelay,
        maxDelay: config.retryMaxDelay,
        maxAttempts: config.retryMaxAttempts,
        pollInterval: config.retryPollInterval,
      ),
    );
  }

  /// Advanced / testing: build a client over an explicit [api] and [store]. The
  /// durable queue + offline cache are always available (the store is explicit).
  factory WincheStorage.withStore(
    WincheStorageApi api,
    StorageLocalStore store, {
    int multipartThreshold = 5 * 1024 * 1024,
    Future<String> Function()? directoryResolver,
    Duration retryBaseDelay = const Duration(seconds: 1),
    Duration retryMaxDelay = const Duration(seconds: 30),
    int retryMaxAttempts = 5,
    Duration retryPollInterval = const Duration(seconds: 30),
  }) {
    final resolveDirectory =
        directoryResolver == null ? null : _memoize(directoryResolver);
    return WincheStorage._build(
      api: api,
      store: store,
      multipartThreshold: multipartThreshold,
      resolveDirectory: resolveDirectory,
      retry: TransferRetryConfig(
        baseDelay: retryBaseDelay,
        maxDelay: retryMaxDelay,
        maxAttempts: retryMaxAttempts,
        pollInterval: retryPollInterval,
      ),
    );
  }

  factory WincheStorage._build({
    required WincheStorageApi api,
    required StorageLocalStore? store,
    required int multipartThreshold,
    required Future<String> Function()? resolveDirectory,
    required TransferRetryConfig retry,
  }) {
    // When a store is configured, the durable queue + offline cache exist.
    // Controller first, so the catalog can route pins through it.
    final controller = store != null
        ? TransferController(
            api: api,
            store: store,
            multipartThreshold: multipartThreshold,
            directoryResolver: resolveDirectory,
            retry: retry,
          )
        : null;
    final catalog = store != null
        ? OfflineCatalog(
            api: api,
            store: store,
            directoryResolver: resolveDirectory,
            multipartThreshold: multipartThreshold,
            controller: controller,
          )
        : null;
    if (controller != null && catalog != null) {
      controller.pinSink = catalog;
    }
    return WincheStorage._(
      api: api,
      store: store,
      catalog: catalog,
      controller: controller,
      multipartThreshold: multipartThreshold,
      resolveDirectory: resolveDirectory,
    );
  }

  /// Returns a [ChildReference] for the given [path].
  ChildReference child(String path) {
    return ChildReference(
      path: path,
      api: _api,
      multipartThreshold: _multipartThreshold,
      directoryResolver: _resolveDirectory,
      catalog: _catalog,
      controller: _controller,
    );
  }

  /// Resumes all queued downloads. Requires a store (directoryResolver, inMemory, or web).
  Future<void> resumeDownloads() {
    final c = _controller;
    if (c == null) {
      throw StateError(
          'No store configured; configure directoryResolver or inMemory to enable auto-resume.');
    }
    return c.resumeDownloads();
  }

  /// Resumes all queued uploads. Requires a store (directoryResolver, inMemory, or web).
  Future<void> resumeUploads() {
    final c = _controller;
    if (c == null) {
      throw StateError(
          'No store configured; configure directoryResolver or inMemory to enable auto-resume.');
    }
    return c.resumeUploads();
  }

  /// A snapshot of the durable transfer queue — every transfer that hasn't
  /// completed yet (pending, running, or failed awaiting retry), optionally
  /// filtered by [kind] (e.g. `TransferKind.upload`).
  /// Requires a store (directoryResolver, inMemory, or web).
  Future<List<TransferRecord>> pendingTransfers({TransferKind? kind}) {
    final c = _controller;
    if (c == null) {
      throw StateError(
          'No store configured; configure directoryResolver or inMemory to enable auto-resume.');
    }
    return c.pendingTransfers(kind: kind);
  }

  /// The live tracked upload handle for [path], or null when none is in flight.
  /// Throws `StateError` when no store is configured.
  UploadTask? uploadFor(String path) {
    final c = _controller;
    if (c == null) {
      throw StateError('no durable store configured; cannot track transfers.');
    }
    return c.uploadFor(path);
  }

  /// The live tracked download handle for [path], or null when none is in flight.
  /// Throws `StateError` when no store is configured.
  DownloadTask? downloadFor(String path) {
    final c = _controller;
    if (c == null) {
      throw StateError('no durable store configured; cannot track transfers.');
    }
    return c.downloadFor(path);
  }

  /// Lifecycle events as the transfer queue drains.
  /// Requires a store (directoryResolver, inMemory, or web).
  Stream<TransferEvent> get transferEvents {
    final c = _controller;
    if (c == null) {
      throw StateError(
          'No store configured; configure directoryResolver or inMemory to enable auto-resume.');
    }
    return c.events;
  }

  /// Evicts every pinned offline file.
  /// Requires a store (directoryResolver, inMemory, or web).
  Future<void> clearOfflineCache() {
    final c = _catalog;
    if (c == null) {
      throw StateError(
          'No store configured; configure directoryResolver or inMemory to enable offline cache.');
    }
    return c.clear();
  }

  /// Disposes the controller and closes the local store.
  Future<void> dispose() async {
    await _controller?.dispose();
    await _store?.close();
  }

  static Future<String> Function() _memoize(Future<String> Function() f) {
    Future<String>? cached;
    return () => cached ??= f();
  }
}
