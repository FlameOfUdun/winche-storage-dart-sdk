import 'dart:async';

import 'src/api/winche_storage_api.dart';
import 'src/api/winche_storage_http_api.dart';
import 'src/child_reference.dart';

export 'src/child_reference.dart' show ChildReference;
export 'src/file_snapshot.dart' show FileSnapshot;
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

/// Connection options for [WincheStorage]. Mirrors the shape of
/// `winche_database`'s `ConnectionConfig`.
final class WincheStorageConfig {
  /// The REST base URI, e.g. `Uri.parse('https://host/files')`.
  final Uri uri;

  /// Supplies the auth token sent as `Authorization: Bearer <token>` on every
  /// request. Return the current value here — it is re-read per request, so a
  /// rotated token is picked up automatically.
  final FutureOr<String> Function()? tokenProvider;

  /// Files larger than this are uploaded in multiple parts. Defaults to 5 MiB.
  final int multipartThreshold;

  /// Resolves the default download directory. Used by [ChildReference.download]
  /// when no `saveTo` is given. Resolved lazily on first such download and cached.
  final Future<String> Function()? directoryResolver;

  const WincheStorageConfig({
    required this.uri,
    this.tokenProvider,
    this.multipartThreshold = 5 * 1024 * 1024,
    this.directoryResolver,
  });
}

/// The entry point for the Winche Storage Dart SDK.
///
/// Ready to use on construction — there is no initialize step. The default
/// download directory (if [WincheStorageConfig.directoryResolver] is set) is
/// resolved lazily on the first directory-less download and cached.
final class WincheStorage {
  final WincheStorageConfig _config;
  late final WincheStorageApi _api;
  late final Future<String> Function()? _resolveDirectory;

  WincheStorage(this._config) {
    _api = WincheStorageHttpApi(
      baseUrl: _config.uri.toString(),
      tokenProvider: _config.tokenProvider,
    );
    final resolver = _config.directoryResolver;
    _resolveDirectory = resolver == null ? null : _memoize(resolver);
  }

  /// Returns a [ChildReference] for the given [path].
  ChildReference child(String path) {
    return ChildReference(
      path: path,
      api: _api,
      multipartThreshold: _config.multipartThreshold,
      directoryResolver: _resolveDirectory,
    );
  }

  /// Wraps [f] so its first invocation is awaited once and the result reused.
  static Future<String> Function() _memoize(Future<String> Function() f) {
    Future<String>? cached;
    return () => cached ??= f();
  }
}
