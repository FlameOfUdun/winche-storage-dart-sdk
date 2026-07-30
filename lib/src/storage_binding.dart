import 'package:winche_core/winche_core.dart';

import 'api/winche_storage_api.dart';
import 'offline/live_task_registry.dart';
import 'offline/offline_catalog.dart';
import 'offline/transfer_controller.dart';

/// The collaborators a [ChildReference] needs, resolved when it is *used*
/// rather than captured when it is built.
///
/// A reference is often built long before it is used, and can outlive the
/// session it was built under — a field on a widget, say, that survives a
/// sign-out. Capturing the api and store at construction would leave it
/// pointing at a torn-down session; resolving through here means a reference
/// is always about the identity signed in at the moment you use it.
///
/// It also means `WincheStorage.child()` can return a reference while nobody
/// is signed in, and fail only if something is actually attempted with it.
/// That matters because the alternative is throwing from a constructor call
/// in a widget's `build`, which tears down the tree instead of reaching an
/// error branch.
///
/// One of these lives for the lifetime of the service; [bind] and [unbind]
/// swap its contents as sessions come and go.
final class StorageBinding {
  /// Tracks one-shot transfers so teardown can abort them. Outlives sessions,
  /// because a one-shot started under one session must still be cancellable
  /// after it ends.
  final LiveTaskRegistry registry;

  /// Called when a reference actually reaches for the api, so the service can
  /// mark itself used and refuse further config changes.
  final void Function() onUse;

  StorageBinding({required this.registry, required this.onUse});

  WincheStorageApi? _api;
  OfflineCatalog? _catalog;
  TransferController? _controller;
  Future<String> Function()? _directoryResolver;
  int _multipartThreshold = 5 * 1024 * 1024;

  /// Whether a session is currently bound.
  bool get isBound => _api != null;

  void bind({
    required WincheStorageApi api,
    required OfflineCatalog? catalog,
    required TransferController? controller,
    required Future<String> Function()? directoryResolver,
    required int multipartThreshold,
  }) {
    _api = api;
    _catalog = catalog;
    _controller = controller;
    _directoryResolver = directoryResolver;
    _multipartThreshold = multipartThreshold;
  }

  void unbind() {
    _api = null;
    _catalog = null;
    _controller = null;
    _directoryResolver = null;
  }

  /// The bound api.
  ///
  /// Throws [WincheUnboundException] when nobody is signed in. Every operation
  /// on a reference goes through here, which is what makes an unbound
  /// reference fail on use rather than on construction.
  WincheStorageApi get api {
    final api = _api;
    if (api == null) throw WincheUnboundException();
    onUse();
    return api;
  }

  OfflineCatalog? get catalog => _catalog;

  TransferController? get controller => _controller;

  Future<String> Function()? get directoryResolver => _directoryResolver;

  int get multipartThreshold => _multipartThreshold;
}
