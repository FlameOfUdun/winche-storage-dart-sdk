import 'dart:async';

import 'package:meta/meta.dart';
import 'package:winche_core/winche_core.dart';

import 'src/api/winche_storage_api.dart';
import 'src/api/winche_storage_exception.dart';
import 'src/api/winche_storage_http_api.dart';
import 'src/child_reference.dart';
import 'src/offline/lazy_storage_local_store.dart';
import 'src/offline/live_task_registry.dart';
import 'src/offline/local_paths.dart';
import 'src/offline/memory_storage_local_store.dart';
import 'src/offline/offline_catalog.dart';
import 'src/offline/sembast_storage_local_store.dart';
import 'src/offline/storage_local_store.dart';
import 'src/offline/transfer_controller.dart';
import 'src/offline/transfer_event.dart';
import 'src/offline/transfer_record.dart';
import 'src/storage_binding.dart';
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

/// The IndexedDB database name on the web, where there is no filesystem.
///
/// Names the same three parts as the native path — scope, identity, package —
/// flattened, because IndexedDB has no directories to nest in.
@visibleForTesting
String webDatabaseNameFor(WincheIdentity identity) =>
    'winche_${identity.storageKey}_storage';

/// Tuning for a [WincheStorage].
///
/// Only what storage decides for itself. The endpoint, the auth token, the
/// identity that scopes local state, and the directory that state lives under
/// all come from `winche_core` — see [WincheOptions] — so they cannot be set
/// here and cannot disagree with the rest of the stack.
final class WincheStorageConfig {
  /// Files larger than this are uploaded in multiple parts. Defaults to 5 MiB.
  final int multipartThreshold;

  /// Use a non-persistent in-memory index (catalog + transfer queue) instead of
  /// sembast. Files still go to disk. Defaults to false.
  final bool inMemory;

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
    this.multipartThreshold = 5 * 1024 * 1024,
    this.inMemory = false,
    this.retryBaseDelay = const Duration(seconds: 1),
    this.retryMaxDelay = const Duration(seconds: 30),
    this.retryMaxAttempts = 5,
    this.retryPollInterval = const Duration(seconds: 30),
  });
}

/// The entry point for the Winche Storage Dart SDK.
///
/// Bound to whichever identity is signed in. `winche_core` builds a session on
/// sign-in and tears it down on sign-out, so a user switch is not something
/// this class exposes or an app has to sequence: the outgoing identity's store
/// is fully closed before the incoming one opens.
///
/// NOTE: a persistent (sembast) store must be owned by a single isolate. Do not
/// open the same on-disk store from multiple isolates concurrently.
final class WincheStorage extends WincheStorageService {
  /// Creates the storage service and registers it with [app].
  ///
  /// Prefer [instance]; construct directly only to attach to a non-default app.
  WincheStorage(super.app);

  /// The storage attached to the default app, building it if needed.
  static WincheStorage get instance => instanceFor(Winche.app);

  /// The storage attached to [app], building it if needed.
  static WincheStorage instanceFor(WincheApp app) =>
      WincheService.instanceFor(app, () => WincheStorage(app));

  WincheStorageApi? _api;
  StorageLocalStore? _store;
  OfflineCatalog? _catalog;
  TransferController? _controller;
  Future<String> Function()? _resolveDirectory;
  final LiveTaskRegistry _oneShots = LiveTaskRegistry();

  /// Handed to every reference this service creates. Lives for the lifetime of
  /// the service and is re-pointed as sessions come and go, which is what lets
  /// a reference built while signed out start working once an identity
  /// arrives.
  late final StorageBinding _binding = StorageBinding(
    registry: _oneShots,
    onUse: () => _started = true,
  );

  bool _started = false;

  WincheStorageConfig _config = const WincheStorageConfig();

  /// Tuning for the sessions this facade builds.
  WincheStorageConfig get config => _config;

  /// Throws a [StateError] once the current session has been used.
  ///
  /// Construction is lazy, so a session core bound synchronously during
  /// `WincheStorage.instance` has not been used yet. That window is what lets
  /// `instance.config = ...` work on the line after `.instance`.
  set config(WincheStorageConfig value) {
    if (_started) {
      throw StateError(
        'WincheStorage.config cannot be changed once storage has been used. '
        'Set it immediately after first obtaining the instance.',
      );
    }
    _config = value;
  }

  /// Whether a session is currently bound. For tests and the core contract
  /// suite only.
  @visibleForTesting
  Object? get debugSession => _api;

  @override
  Future<void> onSessionChanged(WincheSession? session) async {
    await _teardown();
    if (session == null) return;

    final endpoint = app.options?.storageEndpoint;
    if (endpoint == null) {
      throw StateError(
        'WincheOptions.storageEndpoint is required to use winche_storage.',
      );
    }

    final root = app.options?.directoryResolver;

    // Everything for one identity lives under a single scoped root, so the
    // catalog, the controller and sembast stay identity-unaware: they only ever
    // see a directory. Memoized, which is what pins it for this session.
    final resolveDirectory = root == null
        ? null
        : _memoize(() async =>
            scopedRootPath(await root(), session.identity.storageKey));

    // The durable queue + offline cache exist when there is somewhere to put a
    // store: a directory (native), an in-memory index, or web (IndexedDB).
    final needsStore = _config.inMemory || root != null || _kIsWeb;

    _bind(
      api: WincheStorageHttpApi(
        baseUrl: endpoint.toString(),
        tokenProvider: () async {
          final token = await session.token();
          if (token == null) {
            throw const StorageUnauthenticatedException(
              'No auth token available for the current session.',
            );
          }
          return token;
        },
      ),
      store: !needsStore
          ? null
          : (_config.inMemory
              ? MemoryStorageLocalStore()
              : LazyStorageLocalStore(
                  () async => SembastStorageLocalStore.open(
                    // No directory on the web, so the identity has to ride on
                    // the IndexedDB database name instead.
                    _kIsWeb ? webDatabaseNameFor(session.identity) : 'index',
                    directory: _kIsWeb ? null : await resolveDirectory!(),
                  ),
                )),
      resolveDirectory: resolveDirectory,
    );
  }

  /// A token rotation is exactly what an `unauthenticated`-paused transfer is
  /// waiting for, so re-drive the queue rather than leaving it to the
  /// `retryPollInterval` backstop.
  @override
  Future<void> onTokenChanged() async {
    await _controller?.resumeTransfers();
  }

  void _bind({
    required WincheStorageApi api,
    required StorageLocalStore? store,
    required Future<String> Function()? resolveDirectory,
  }) {
    // Controller first, so the catalog can route pins through it.
    final controller = store == null
        ? null
        : TransferController(
            api: api,
            store: store,
            multipartThreshold: _config.multipartThreshold,
            directoryResolver: resolveDirectory,
            retry: TransferRetryConfig(
              baseDelay: _config.retryBaseDelay,
              maxDelay: _config.retryMaxDelay,
              maxAttempts: _config.retryMaxAttempts,
              pollInterval: _config.retryPollInterval,
            ),
          );
    final catalog = store == null
        ? null
        : OfflineCatalog(
            api: api,
            store: store,
            directoryResolver: resolveDirectory,
            multipartThreshold: _config.multipartThreshold,
            controller: controller,
          );
    if (controller != null && catalog != null) controller.pinSink = catalog;

    _api = api;
    _store = store;
    _catalog = catalog;
    _controller = controller;
    _resolveDirectory = resolveDirectory;
    _binding.bind(
      api: api,
      catalog: catalog,
      controller: controller,
      directoryResolver: resolveDirectory,
      multipartThreshold: _config.multipartThreshold,
    );

    // Fire-and-forget, so its failures must be swallowed: an unopenable store
    // would otherwise surface as an unhandled async error from a hook nobody
    // awaited. The same failure resurfaces, catchably, on the next real store
    // access.
    unawaited(controller?.rehydrate().catchError((Object _) {}));
  }

  /// Tears the current session down in dependency order — one-shot transfers,
  /// then the controller, and only then the store — so nothing can read the
  /// store after it closes.
  ///
  /// Never waits on the network. Durable transfers are aborted mid-flight,
  /// their records reset to pending, and resume when this identity signs back
  /// in. One-shot transfers, started without `enqueue:`, have nothing to resume
  /// from and fail with [StorageCancelledException].
  Future<void> _teardown() async {
    final controller = _controller;
    final store = _store;

    // Cleared first, so anything the teardown below triggers sees an unbound
    // facade rather than half-torn-down collaborators.
    _api = null;
    _store = null;
    _catalog = null;
    _controller = null;
    _resolveDirectory = null;
    _started = false;
    _binding.unbind();

    _oneShots.abortAll();
    await controller?.close();
    await store?.close();
  }

  @override
  Future<void> dispose() async {
    await _teardown();
    await super.dispose();
  }

  WincheStorageApi _require() {
    final api = _api;
    if (api == null) throw WincheUnboundException();
    _started = true;
    return api;
  }

  TransferController _requireController() {
    _require();
    return _controller ??
        (throw StateError(
          'No local store configured. Set WincheOptions.directoryResolver, or '
          'WincheStorageConfig.inMemory, to enable the durable transfer queue.',
        ));
  }

  /// Returns a [ChildReference] for [path].
  ///
  /// Never throws, including while nobody is signed in. The reference resolves
  /// its api and store when it is *used*, so building one in a widget field or
  /// a `build` method is safe, and the operation you attempt on it is what
  /// rejects with [WincheUnboundException].
  ///
  /// It also means a reference outlives a user switch correctly: it is always
  /// about whoever is signed in at the moment you use it, never a stale
  /// session captured when it was built.
  ChildReference child(String path) =>
      ChildReference.bound(path: path, binding: _binding);

  /// Re-drives every transfer halted by a pause — an expired token or an
  /// unreachable server.
  ///
  /// A token refresh already does this on its own, so call it only for things
  /// the SDK cannot see: the OS reporting the network is back, or the app
  /// returning to the foreground. Nothing is lost by not calling it — a paused
  /// transfer keeps its place in the queue and its retry budget indefinitely,
  /// and the `retryPollInterval` backstop re-drives it within one poll.
  Future<void> resumeTransfers() => _requireController().resumeTransfers();

  /// A snapshot of the durable transfer queue — every transfer that has not
  /// completed yet (pending, running, or failed awaiting retry), optionally
  /// filtered by [kind].
  Future<List<TransferRecord>> pendingTransfers({TransferKind? kind}) =>
      _requireController().pendingTransfers(kind: kind);

  /// The live tracked upload handle for [path], or null when none is in flight.
  UploadTask? uploadFor(String path) => _requireController().uploadFor(path);

  /// The live tracked download handle for [path], or null when none is in
  /// flight.
  DownloadTask? downloadFor(String path) =>
      _requireController().downloadFor(path);

  /// Lifecycle events as the transfer queue drains.
  Stream<TransferEvent> get transferEvents => _requireController().events;

  /// Evicts every pinned offline file.
  Future<void> clearOfflineCache() {
    _require();
    final catalog = _catalog;
    if (catalog == null) {
      throw StateError(
        'No local store configured. Set WincheOptions.directoryResolver, or '
        'WincheStorageConfig.inMemory, to enable the offline cache.',
      );
    }
    return catalog.clear();
  }

  /// Binds a session over an explicitly supplied [api] and [store], bypassing
  /// the ones that would be derived from the signed-in identity.
  ///
  /// For tests that drive fakes directly. Production code binds through
  /// [onSessionChanged].
  @visibleForTesting
  void debugBindStore(
    WincheStorageApi api,
    StorageLocalStore store, {
    Future<String> Function()? directoryResolver,
  }) {
    _bind(
      api: api,
      store: store,
      resolveDirectory:
          directoryResolver == null ? null : _memoize(directoryResolver),
    );
  }

  static Future<String> Function() _memoize(Future<String> Function() f) {
    Future<String>? cached;
    return () => cached ??= f();
  }
}
