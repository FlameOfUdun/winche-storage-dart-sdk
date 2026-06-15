# winche_storage

Dart SDK for the WincheStorage file management backend. Provides resumable, multipart-aware upload and download tasks behind a reference-based API.

## Features

- Reference-based `ChildReference` API (`storage.child('a/b/c.jpg')`).
- Resumable, multipart-aware uploads from a file path or raw bytes.
- Resumable downloads with HTTP `Range` support.
- Pause / resume / cancel on both upload and download tasks, with progress streams.
- Pluggable backend via the `WincheStorageApi` interface (`WincheStorageHttpApi` ships by default).
- Typed exceptions (`WincheStorageException` and subclasses).

## Installation

```bash
dart pub add winche_storage
```

Or add it to `pubspec.yaml`:

```yaml
dependencies:
  winche_storage: ^1.0.0
```

## Setup

`WincheStorage` is ready to use as soon as it's constructed — there is no
initialize step.

```dart
import 'package:winche_storage/winche_storage.dart';

final storage = WincheStorage(
  WincheStorageConfig(
    uri: Uri.parse('https://your-api.example.com/files'),

    // Optional. Returns the current auth token, re-read on every request, so a
    // rotated token is picked up automatically. Sent as `Authorization: Bearer`.
    tokenProvider: () async => currentToken,

    // Optional. Resolves the default local download directory. Required only if
    // you call download() without an explicit saveTo.
    directoryResolver: () async {
      final dir = await getApplicationDocumentsDirectory();
      return '${dir.path}/winche_files';
    },

    // Optional. Files larger than this are uploaded in parts. Defaults to 5 MiB.
    multipartThreshold: 5 * 1024 * 1024,
  ),
);
```

## Usage

### References

`ChildReference` points to a file by its slash-separated path. References
compose via `.child()`.

```dart
final userRoot = storage.child('userFiles/user-123');
final photoRef = userRoot.child('photo.jpg');
// equivalent to storage.child('userFiles/user-123/photo.jpg')

photoRef.name;     // 'photo.jpg'  — last path segment
photoRef.fullPath; // 'userFiles/user-123/photo.jpg'
photoRef.parent;   // ChildReference('userFiles/user-123')
```

### Upload

Upload from a local file path with `uploadPath`, or from bytes with
`uploadBytes`.

```dart
final task = photoRef.uploadPath(
  '/local/path/photo.jpg',
  mimeType: 'image/jpeg',     // optional — inferred from the extension if omitted
  metadata: {'label': 'cover'},
);

// Or from bytes (mimeType is required, as it can't be inferred):
final task = photoRef.uploadBytes(
  bytes,
  'image/jpeg',
  metadata: {'label': 'cover'},
);

// Stream progress
task.stateStream.listen((UploadTaskState state) {
  print('${state.status} — ${(state.progress * 100).toStringAsFixed(1)}%');
});

final FileSnapshot? snapshot = await task.whenDone; // null if cancelled
```

### Download

```dart
// Saves to: <directoryResolver result>/userFiles/user-123/photo.jpg
final task = photoRef.download();

// Override destination or extension
final task = photoRef.download(saveTo: '/tmp/photo.jpg', extension: 'jpg');

task.stateStream.listen((DownloadTaskState state) {
  print('${state.status} — ${(state.progress * 100).toStringAsFixed(1)}%');
});

await task.whenDone;
```

> If no `directoryResolver` is configured, `saveTo` is required — otherwise the
> download fails with a `StateError`.

### Pause / resume / cancel

Both `UploadTask` and `DownloadTask` support mid-flight control:

```dart
task.pause();
task.resume(); // resumes from the last completed part / byte offset

// Upload cancel — also deletes the remote file record
await task.cancel();

// Download cancel — deletes any partially written local file
task.cancel();
```

### List a directory

```dart
final List<FileSnapshot> files = await storage.child('userFiles/user-123').list(
  mimeType: 'image/jpeg', // optional filter
);

for (final snapshot in files) {
  print('${snapshot.path} — ${snapshot.data?.sizeBytes} bytes');
}
```

### Get file metadata

`get()` always returns a `FileSnapshot`. Check `exists` to know whether the file
is present; `data` is null when it isn't.

```dart
final FileSnapshot snapshot = await photoRef.get();

if (snapshot.exists) {
  final data = snapshot.data!;
  print(data.id);
  print(data.path);
  print(data.directory);
  print(data.mimeType);
  print(data.sizeBytes);
  print(data.uploadStatus); // UploadStatus.pending | .complete | .failed
  print(data.metadata);
  print(data.version);
  print(data.createdAt);
  print(data.updatedAt);
}
```

### Update metadata

```dart
final FileSnapshot updated = await photoRef.updateMetadata({'label': 'hero'});
```

### Delete

```dart
final bool deleted = await photoRef.delete(); // false if the file didn't exist
```

## API reference

### `WincheStorageConfig`

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `uri` | `Uri` | required | Base URI of the WincheStorage REST backend |
| `tokenProvider` | `FutureOr<String> Function()?` | null | Returns the auth token, re-read per request and sent as `Authorization: Bearer` |
| `directoryResolver` | `Future<String> Function()?` | null | Resolves the default local download directory (lazy, cached) |
| `multipartThreshold` | `int` | `5 * 1024 * 1024` | File size (bytes) above which multipart upload is used |

### `WincheStorage`

| Member | Description |
| --- | --- |
| `WincheStorage(config)` | Creates the SDK. Ready to use immediately — no initialize step. |
| `child(path)` | Returns a `ChildReference` for the given path. |

### `ChildReference`

| Member | Description |
| --- | --- |
| `path` | The file's slash-separated path string. |
| `name` | The last path segment (e.g. `photo.jpg`). |
| `fullPath` | Alias for `path`. |
| `parent` | The parent reference, or `null` at a single-segment path. |
| `child(path)` | Returns a new `ChildReference` at `this.path/path`. |
| `get()` | Fetches metadata. Returns a `FileSnapshot` (check `exists`). |
| `list({mimeType})` | Lists files under this path, returning `List<FileSnapshot>`. |
| `uploadPath(localPath, {mimeType, metadata, multipartThreshold})` | Starts an `UploadTask` from a local file. |
| `uploadBytes(bytes, mimeType, {metadata, multipartThreshold})` | Starts an `UploadTask` from raw bytes. |
| `download({saveTo, extension})` | Starts a `DownloadTask`. |
| `updateMetadata(metadata)` | Updates server-side metadata. Returns a `FileSnapshot`. |
| `delete()` | Deletes the file. Returns `bool`. |

### `UploadTask`

| Member | Type | Description |
| --- | --- | --- |
| `state` | `UploadTaskState` | Current synchronous snapshot of status + progress. |
| `stateStream` | `Stream<UploadTaskState>` | Broadcast stream of state changes. |
| `whenDone` | `Future<FileSnapshot?>` | Completes with the confirmed `FileSnapshot`, or `null` if cancelled. |
| `pause()` | — | Cancels the in-flight request; preserves uploaded parts. |
| `resume()` | — | Restarts from the last completed part. |
| `cancel()` | `Future<void>` | Cancels the upload and deletes the remote file record. |

`UploadTaskStatus`: `running`, `paused`, `complete`, `failed`, `cancelled`

### `DownloadTask`

| Member | Type | Description |
| --- | --- | --- |
| `state` | `DownloadTaskState` | Current synchronous snapshot of status + progress. |
| `stateStream` | `Stream<DownloadTaskState>` | Broadcast stream of state changes. |
| `whenDone` | `Future<void>` | Completes when the download finishes, or throws on failure. |
| `pause()` | — | Cancels the in-flight request; the partial file is kept for resume. |
| `resume()` | — | Resumes from the byte offset already written (HTTP `Range` request). |
| `cancel()` | — | Cancels and deletes any partial local file. |

`DownloadTaskStatus`: `running`, `paused`, `complete`, `failed`, `cancelled`

### `FileSnapshot`

An immutable snapshot of a file's metadata at a point in time.

| Member | Type | Description |
| --- | --- | --- |
| `exists` | `bool` | Whether the file is present. |
| `data` | `FileData?` | The file record, or `null` when `exists` is false. |
| `reference` / `ref` | `ChildReference` | The reference this snapshot belongs to. |
| `path` | `String` | The full path (= `reference.path`). |
| `name` | `String` | The last path segment. |
| `timestamp` | `DateTime` | When the snapshot was taken. |

`FileData` fields: `id`, `directory`, `path`, `mimeType`, `sizeBytes`,
`uploadStatus`, `metadata`, `version`, `createdAt`, `updatedAt`.

### `WincheStorageException`

A sealed exception hierarchy thrown on API errors. Each carries a semantic
`status` (`StorageErrorStatus`), a `message`, optional `details`, and the
originating `statusCode`.

```dart
try {
  await photoRef.updateMetadata({'label': 'hero'});
} on StorageNotFoundException catch (e) {
  print('not found: ${e.message}');
} on WincheStorageException catch (e) {
  print('${e.statusCode}: ${e.message}');
}
```

Subclasses: `StorageNotFoundException`, `StoragePermissionDeniedException`,
`StorageUnauthenticatedException`, `StorageInvalidArgumentException`,
`StorageFailedPreconditionException`, `StorageDeadlineExceededException`,
`StorageUnavailableException`, `StorageCancelledException`,
`StorageInternalException`, `StorageUnknownException`.

## Custom backend

Implement `WincheStorageApi` to connect a different backend, or use the bundled
`WincheStorageHttpApi` directly:

```dart
abstract interface class WincheStorageApi {
  Future<FileData> setFile(String path, String mimeType, int sizeBytes, {Map<String, dynamic>? metadata});
  Future<FileData?> getFile(String path);
  Future<UploadSession> generateFileUploadUrl(String path);
  Future<UploadSession> generatePartUploadUrl(String path, int partNumber);
  Future<DownloadSession> generateDownloadUrl(String path);
  Future<FileData> confirmUpload(String path);
  Future<bool> deleteFile(String path);
  Future<FileData> updateMetadata(String path, Map<String, dynamic> metadata);
  Future<List<FileData>> listDirectory(String directory, {String? mimeType});
  Future<List<FilePart>> listParts(String path);
}
```

> **Note for HTTP implementors:** all `path` values must be base64Url-encoded
> when placed in URLs — the WincheStorage REST backend calls `DecodeBase64(path)`
> on every endpoint. `WincheStorageHttpApi` does this automatically.

## Dependencies

- [`dio`](https://pub.dev/packages/dio) — HTTP client used by `WincheStorageHttpApi`, `UploadTask`, and `DownloadTask`
- [`mime`](https://pub.dev/packages/mime) — MIME type inference from file extension in `ChildReference.uploadPath`

## License

[MIT](LICENSE)
