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
    show TransferEvent, TransferEventType, TransferRetryConfig;

/// True on the web, where Dart's numeric types collapse so `0` and `0.0` are
/// identical. Used to relax the native `directoryResolver` requirement.
const bool _kIsWeb = identical(0, 0.0);

/// Connection and offline options for [WincheStorage].
final class WincheStorageConfig {
  /// The REST base URI, e.g. `Uri.parse('https://host/files')`.
  final Uri uri;

  /// Supplies the auth token sent as `Authorization: Bearer <token>`.
  final FutureOr<String> Function()? tokenProvider;

  /// Files larger than this are uploaded in multiple parts. Defaults to 5 MiB.
  final int multipartThreshold;

  /// Opt-in: pin files for offline use, with remote-first reads and a cache
  /// fallback. Requires [directoryResolver] on native. Defaults to false.
  final bool enableOfflineCache;

  /// Opt-in: durable transfer queue that resumes uploads/downloads after a
  /// restart and self-retries with backoff. Requires [directoryResolver] on
  /// native unless [inMemory] is true. Defaults to false.
  final bool enableAutoResume;

  /// Use a non-persistent in-memory index (catalog + transfer queue) instead of
  /// sembast. Files still go to disk via [directoryResolver]. Defaults to false.
  final bool inMemory;

  /// Resolves the default download directory and the offline cache root.
  final Future<String> Function()? directoryResolver;

  /// Backoff tunables for [enableAutoResume].
  final TransferRetryConfig retry;

  const WincheStorageConfig({
    required this.uri,
    this.tokenProvider,
    this.multipartThreshold = 5 * 1024 * 1024,
    this.enableOfflineCache = false,
    this.enableAutoResume = false,
    this.inMemory = false,
    this.directoryResolver,
    this.retry = const TransferRetryConfig(),
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
    final needsStore = config.enableOfflineCache || config.enableAutoResume;
    final needsDir = config.enableOfflineCache ||
        (config.enableAutoResume && !config.inMemory);
    if (needsDir && !_kIsWeb && config.directoryResolver == null) {
      throw ArgumentError(
          'directoryResolver is required on native when offline cache or '
          'persistent auto-resume is enabled.');
    }

    final resolver = config.directoryResolver;
    final resolveDirectory = resolver == null ? null : _memoize(resolver);

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
      enableOfflineCache: config.enableOfflineCache,
      enableAutoResume: config.enableAutoResume,
      multipartThreshold: config.multipartThreshold,
      resolveDirectory: resolveDirectory,
      retry: config.retry,
    );
  }

  /// Advanced / testing: build a client over an explicit [api] and [store].
  factory WincheStorage.withStore(
    WincheStorageApi api,
    StorageLocalStore store, {
    bool enableOfflineCache = false,
    bool enableAutoResume = false,
    int multipartThreshold = 5 * 1024 * 1024,
    Future<String> Function()? directoryResolver,
    TransferRetryConfig retry = const TransferRetryConfig(),
  }) {
    final resolveDirectory =
        directoryResolver == null ? null : _memoize(directoryResolver);
    return WincheStorage._build(
      api: api,
      store: store,
      enableOfflineCache: enableOfflineCache,
      enableAutoResume: enableAutoResume,
      multipartThreshold: multipartThreshold,
      resolveDirectory: resolveDirectory,
      retry: retry,
    );
  }

  factory WincheStorage._build({
    required WincheStorageApi api,
    required StorageLocalStore? store,
    required bool enableOfflineCache,
    required bool enableAutoResume,
    required int multipartThreshold,
    required Future<String> Function()? resolveDirectory,
    required TransferRetryConfig retry,
  }) {
    // Controller first, so the catalog can route pins through it (durable +
    // de-duped) when auto-resume is also enabled.
    final controller = (enableAutoResume && store != null)
        ? TransferController(
            api: api,
            store: store,
            multipartThreshold: multipartThreshold,
            directoryResolver: resolveDirectory,
            retry: retry,
          )
        : null;
    final catalog = (enableOfflineCache && store != null)
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

  /// Resumes all queued downloads. Requires `enableAutoResume`.
  Future<void> resumeDownloads() {
    final c = _controller;
    if (c == null) {
      throw StateError('enableAutoResume is false; auto-resume disabled.');
    }
    return c.resumeDownloads();
  }

  /// Resumes all queued uploads. Requires `enableAutoResume`.
  Future<void> resumeUploads() {
    final c = _controller;
    if (c == null) {
      throw StateError('enableAutoResume is false; auto-resume disabled.');
    }
    return c.resumeUploads();
  }

  /// A snapshot of the durable transfer queue — every transfer that hasn't
  /// completed yet (pending, running, or failed awaiting retry), optionally
  /// filtered by [kind] (e.g. `TransferKind.upload`). Requires `enableAutoResume`.
  Future<List<TransferRecord>> pendingTransfers({TransferKind? kind}) {
    final c = _controller;
    if (c == null) {
      throw StateError('enableAutoResume is false; auto-resume disabled.');
    }
    return c.pendingTransfers(kind: kind);
  }

  /// Lifecycle events as the transfer queue drains. Requires `enableAutoResume`.
  Stream<TransferEvent> get transferEvents {
    final c = _controller;
    if (c == null) {
      throw StateError('enableAutoResume is false; auto-resume disabled.');
    }
    return c.events;
  }

  /// Evicts every pinned offline file. Requires `enableOfflineCache`.
  Future<void> clearOfflineCache() {
    final c = _catalog;
    if (c == null) {
      throw StateError('enableOfflineCache is false; offline cache disabled.');
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
