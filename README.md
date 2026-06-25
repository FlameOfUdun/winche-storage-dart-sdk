# winche_storage

Dart SDK for the WincheStorage file management backend. Provides resumable, multipart-aware upload and download tasks behind a reference-based API, with an optional durable **offline cache** and **auto-resume** layer.

## Features

- Reference-based `ChildReference` API (`storage.child('a/b/c.jpg')`).
- Resumable, multipart-aware uploads from a file path or raw bytes.
- Resumable downloads with HTTP `Range` support.
- Pause / resume / cancel on both upload and download tasks, with progress streams.
- **Offline cache (opt-in):** pin files for offline use — on upload (no download
  roundtrip) or after — query them, and read them back even when the server is
  unreachable. On-demand freshness checks.
- **Auto-resume (opt-in):** a durable transfer queue that survives app restarts
  and self-retries with backoff. Resume all uploads/downloads, or one by path.
- Pure Dart — no Flutter dependency. Persistence via [`sembast`](https://pub.dev/packages/sembast)
  (file on native, IndexedDB on web), or fully in-memory.
- Pluggable backend via the `WincheStorageApi` interface (`WincheStorageHttpApi` ships by default).
- Typed exceptions (`WincheStorageException` and subclasses).

## Installation

```bash
dart pub add winche_storage
```

Or add it to `pubspec.yaml`:

```yaml
dependencies:
  winche_storage: ^2.0.0
```

## Setup

`WincheStorage` is ready to use as soon as it's constructed — there is no
initialize step. Offline cache and auto-resume are **off by default**; turn them
on with the flags below.

```dart
import 'package:winche_storage/winche_storage.dart';

final storage = WincheStorage(
  WincheStorageConfig(
    uri: Uri.parse('https://your-api.example.com/files'),

    // Optional. Returns the current auth token, re-read on every request, so a
    // rotated token is picked up automatically. Sent as `Authorization: Bearer`.
    tokenProvider: () async => currentToken,

    // Resolves the offline cache root and the sembast database directory.
    // Required on native when offline cache or persistent auto-resume is enabled.
    directoryResolver: () async {
      final dir = await getApplicationDocumentsDirectory(); // from path_provider
      return '${dir.path}/winche_files';
    },

    // Optional. Files larger than this are uploaded in parts. Defaults to 5 MiB.
    multipartThreshold: 5 * 1024 * 1024,

    // Opt-in features (both default false):
    enableOfflineCache: true, // pin files for offline use + cache-fallback reads
    enableAutoResume: true,   // durable transfer queue that resumes after restart

    // Optional. Use an in-memory index (catalog + transfer queue) instead of
    // sembast — files still go to disk. Handy for tests. Defaults to false.
    inMemory: false,

    // Optional. Backoff tuning for auto-resume retries.
    retry: const TransferRetryConfig(
      baseDelay: Duration(seconds: 1),
      maxDelay: Duration(seconds: 30),
      maxAttempts: 5,
      pollInterval: Duration(seconds: 30),
    ),
  ),
);
```

> **`directoryResolver` requirement:** on native platforms it is required when
> `enableOfflineCache` is true, or when `enableAutoResume` is true with
> `inMemory: false` (sembast needs a directory). With both features off, the SDK
> is fully stateless and `directoryResolver` is not needed (`download` takes an
> explicit path).

Call `await storage.dispose()` when you're done to stop the retry timer and close
the local store.

## Usage

### References

`ChildReference` points to a file by its slash-separated path. References
compose via `.child()`.

```dart
final userRoot = storage.child('userFiles/user-123');
final photoRef = userRoot.child('photo.jpg');
// equivalent to storage.child('userFiles/user-123/photo.jpg')

photoRef.name;     // 'photo.jpg'  — last path segment
photoRef.path;     // 'userFiles/user-123/photo.jpg'
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

Uploading to a path that already has a file:

- **Completed file, identical size + MIME** — skipped; the existing record is
  returned without re-uploading.
- **Completed file, different size or MIME** — replaced (the old object is
  deleted and the new content uploaded).
- **Interrupted upload, identical size + MIME** — resumed from the last
  completed part.
- **Interrupted upload, different size or MIME** — discarded and re-uploaded
  from scratch (so a previously failed attempt never blocks the path).

Files at or below `multipartThreshold` upload in a single request; larger files
are uploaded in parts.

> When `enableAutoResume` is on, **file-backed** uploads (`uploadPath`) are added
> to a durable queue and resume automatically after an app restart.
> `uploadBytes` keeps its in-session retry but is **not** rehydrated after a kill
> (the bytes live only in memory).

#### Make available offline while uploading

When `enableOfflineCache` is on, pass `makeAvailableOffline: true` to place the
uploaded bytes **straight into the offline cache** — no separate download. The
source is staged, uploaded from that staged copy, then moved into the id-keyed
cache on success. Caching is best-effort: if it fails the upload still succeeds
and the pin is recorded as stale for a later `refresh()`. Ignored (with a debug
warning) when `enableOfflineCache` is off. Works for both `uploadPath` and
`uploadBytes`, including auto-resumed uploads.

```dart
final task = photoRef.uploadPath('/local/path/photo.jpg', makeAvailableOffline: true);
await task.whenDone; // uploaded AND available offline — no download roundtrip
```

This is the upload-time counterpart to [`makeAvailableOffline()`](#offline-cache):
same result, but it reuses the bytes you already have on disk instead of
downloading them back.

### Download

`download` writes the file's bytes to an explicit path. For a managed,
offline-cached copy that needs no path, use
[`makeAvailableOffline`](#offline-cache) instead.

```dart
final task = photoRef.download('/local/photos/photo.jpg');

task.stateStream.listen((DownloadTaskState state) {
  print('${state.status} — ${(state.progress * 100).toStringAsFixed(1)}%');
});

await task.whenDone;
```

When `enableAutoResume` is on, the download is enqueued durably and resumes after
an app restart.

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

### Offline cache

Requires `enableOfflineCache: true`. Pin a file to download it into a managed,
id-keyed cache directory and track it so it stays available offline.

> If you're the one uploading the file, prefer
> `uploadPath(..., makeAvailableOffline: true)` (see [Upload](#upload)) — it
> populates the cache from the bytes you already have, skipping the download this
> method would otherwise perform.

```dart
// Download + pin for offline use. Completes when the file is on disk.
await photoRef.makeAvailableOffline();

// Has the remote version changed since it was pinned? (version/updatedAt/size)
// Returns false when offline (server unreachable) — staleness can't be
// confirmed, so the pinned copy is treated as current.
final bool stale = await photoRef.isStale();
if (stale) {
  await photoRef.refresh(); // re-download the current remote version
}

// Drop the local copy and catalog entry.
await photoRef.evict();

// Remove every pinned file.
await storage.clearOfflineCache();
```

Reads become **remote-first with a cache fallback**. `get()` returns the
authoritative server record when reachable; when the server is unreachable and a
local copy exists, it returns the cached record with `FileSnapshot.fromCache ==
true`. All offline info lives on the `FileData` (`snap.data`):

- `data.isCached` — `true` when the file's **content is downloaded locally** and
  ready for offline use.
- `data.localPath` — absolute path to the local copy (set once the file is
  pinned), or `null`.

```dart
final FileSnapshot snap = await photoRef.get();

if (snap.exists) {
  final data = snap.data!;
  if (snap.fromCache) print('metadata served from cache (server unreachable)');
  if (data.isCached) {
    print('available offline at: ${data.localPath}'); // e.g. <cacheDir>/<id>.jpg
  }
}
```

`list()` returns a `DirectorySnapshot` and populates `data.isCached` /
`data.localPath` for every file too (from a single local-catalog lookup), so you
can render "downloaded" state directly:

```dart
final dir = await userRoot.list();
for (final snap in dir.files) {
  final badge = snap.data!.isCached ? '✓ offline' : '';
  print('${snap.reference.path} $badge');
}
```

When the server is unreachable, `list()` falls back to the **locally pinned**
files directly under the path and sets `dir.fromCache == true` — a partial view,
not the full directory. (With offline cache off, it throws instead.)

```dart
final dir = await userRoot.list();
if (dir.fromCache) print('offline — showing ${dir.length} downloaded file(s) only');
```

> `fromCache` describes how the **metadata** was obtained (server vs. local
> cache); `isCached` describes whether the **content** is downloaded. They're
> independent.

Cached files are stored at `<directoryResolver()>/<fileId><.ext>` — keyed by the
immutable file id (so they survive path/metadata changes), with an extension
derived from the name or MIME type. Pins are explicit and never auto-evicted.

### Auto-resume

Requires `enableAutoResume: true`. File-backed uploads and all downloads are
persisted to a durable queue, resumed when the SDK is constructed, and retried
on failure with exponential backoff (configurable via `WincheStorageConfig.retry`).

```dart
// Started normally — also enqueued durably under the hood.
final task = photoRef.download('/local/photos/photo.jpg');

// On app start, the SDK auto-resumes pending transfers. You can also trigger
// drains explicitly (e.g. when connectivity returns):
await storage.resumeDownloads();
await storage.resumeUploads();

// Resume a single path's transfer.
await photoRef.resume();

// Observe lifecycle events as the queue drains.
storage.transferEvents.listen((TransferEvent e) {
  print('${e.type} ${e.kind} ${e.path}'); // started | completed | failed | retrying
});
```

Calling `download()` / `uploadPath()` again for a path that is already
transferring returns the **existing** in-flight task rather than starting a
duplicate — so re-calling on app start is a safe way to reattach progress UI to
an auto-resumed transfer. Per-byte progress stays on the returned task's
`stateStream`.

### List a directory

```dart
final DirectorySnapshot dir = await storage.child('userFiles/user-123').list(
  mimeType: 'image/jpeg', // optional filter
);

if (dir.fromCache) print('offline — partial (pinned-only) listing');
for (final snapshot in dir.files) {
  print('${snapshot.reference.path} — ${snapshot.data?.sizeBytes} bytes');
}
```

### Get file metadata

`get()` always returns a `FileSnapshot`. Check `exists` to know whether the file
is present; `data` is null when it isn't. With `enableOfflineCache`, see the
[Offline cache](#offline-cache) section for `fromCache` / `localPath` behavior.

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
| `multipartThreshold` | `int` | `5 * 1024 * 1024` | File size (bytes) above which multipart upload is used |
| `enableOfflineCache` | `bool` | `false` | Enable the pin/cache subsystem and cache-fallback reads |
| `enableAutoResume` | `bool` | `false` | Enable the durable transfer queue + backoff retry |
| `inMemory` | `bool` | `false` | Use an in-memory index (catalog + queue) instead of sembast; files still go to disk |
| `directoryResolver` | `Future<String> Function()?` | null | Resolves the offline cache root + sembast directory (lazy, cached). Required on native when a feature needs disk |
| `retry` | `TransferRetryConfig` | defaults | Backoff tuning for auto-resume retries |

### `WincheStorage`

| Member | Description |
| --- | --- |
| `WincheStorage(config)` | Creates the SDK. Ready to use immediately; auto-resumes pending transfers if `enableAutoResume`. |
| `WincheStorage.withStore(api, store, {...})` | Advanced/testing: build over an explicit `WincheStorageApi` and `StorageLocalStore`. |
| `child(path)` | Returns a `ChildReference` for the given path. |
| `resumeDownloads()` | Drains all queued downloads. Throws `StateError` if `enableAutoResume` is off. |
| `resumeUploads()` | Drains all queued uploads. Throws `StateError` if `enableAutoResume` is off. |
| `pendingTransfers({kind})` | Snapshot of the durable queue (pending/running/failed `TransferRecord`s), optionally filtered by `TransferKind`. Throws `StateError` if `enableAutoResume` is off. |
| `transferEvents` | `Stream<TransferEvent>` of queue lifecycle events. Throws `StateError` if `enableAutoResume` is off. |
| `clearOfflineCache()` | Evicts every pinned file. Throws `StateError` if `enableOfflineCache` is off. |
| `dispose()` | Stops the retry timer and closes the local store. |

### `ChildReference`

| Member | Description |
| --- | --- |
| `path` | The file's slash-separated path string. |
| `name` | The last path segment (e.g. `photo.jpg`). |
| `parent` | The parent reference, or `null` at a single-segment path. |
| `child(path)` | Returns a new `ChildReference` at `this.path/path`. |
| `get()` | Fetches metadata. Remote-first with cache fallback (see Offline cache). |
| `list({mimeType})` | Lists files under this path, returning a `DirectorySnapshot` (its `.files` holds a `FileSnapshot` each). Remote-first; offline it returns the pinned subset with `fromCache: true`. |
| `uploadPath(localPath, {mimeType, metadata, multipartThreshold, makeAvailableOffline})` | Starts an `UploadTask` from a local file. `makeAvailableOffline: true` also pins it into the offline cache with no download roundtrip (requires `enableOfflineCache`). |
| `uploadBytes(bytes, mimeType, {metadata, multipartThreshold, makeAvailableOffline})` | Starts an `UploadTask` from raw bytes. `makeAvailableOffline: true` also pins it into the offline cache (requires `enableOfflineCache`). |
| `download(saveTo)` | Starts a `DownloadTask` writing the file to the explicit path `saveTo`. |
| `makeAvailableOffline()` | Pins + downloads the file for offline use. Requires `enableOfflineCache`. |
| `refresh()` | Re-downloads the current remote version into the cache. Requires `enableOfflineCache`. |
| `isStale()` | `Future<bool>` — whether the pinned remote version changed (or was deleted). Requires `enableOfflineCache`. |
| `evict()` | Removes the local copy + catalog entry. Requires `enableOfflineCache`. |
| `resume()` | Resumes this path's queued transfer. Requires `enableAutoResume`. |
| `updateMetadata(metadata)` | Updates server-side metadata. Returns a `FileSnapshot`. |
| `delete()` | Deletes the file. Returns `bool`. |

Offline / resume methods throw `StateError` when their feature flag is off.

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
| `saveTo` | `String` | The absolute destination path the file is written to. |
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
| `fromCache` | `bool` | True when the *metadata* was served from the offline cache because the server was unreachable. |
| `reference` | `ChildReference` | The reference this snapshot belongs to (use `reference.path` for the full path). |
| `name` | `String` | The last path segment. |
| `timestamp` | `DateTime` | When the snapshot was taken. |

`FileData` fields: `id`, `directory`, `path`, `mimeType`, `sizeBytes`,
`uploadStatus`, `metadata`, `version`, `createdAt`, `updatedAt`, plus two
client-side offline fields:

| Field | Type | Description |
| --- | --- | --- |
| `localPath` | `String?` | Absolute path to the local copy, when pinned/registered. |
| `isCached` | `bool` | True when the content is fully downloaded locally and ready for offline use. |

### `DirectorySnapshot`

An immutable snapshot of a directory listing, returned by `list()`.

| Member | Type | Description |
| --- | --- | --- |
| `files` | `List<FileSnapshot>` | One snapshot per child file (unmodifiable). |
| `fromCache` | `bool` | True when the listing was served from the local catalog because the server was unreachable — a partial, pinned-only view. |
| `reference` | `ChildReference` | The directory this snapshot lists. |
| `name` | `String` | The directory's last path segment. |
| `length` / `isEmpty` / `isNotEmpty` | — | Convenience over `files`. |
| `timestamp` | `DateTime` | When the snapshot was taken. |

### Offline / auto-resume types

| Type | Description |
| --- | --- |
| `TransferEvent` | `{type, kind, path, error}` emitted on `transferEvents`. |
| `TransferEventType` | `started`, `completed`, `failed`, `retrying`. |
| `TransferKind` | `upload`, `download`. |
| `TransferRetryConfig` | `{baseDelay, maxDelay, maxAttempts, pollInterval}`. |
| `CatalogEntry` / `CatalogStatus` | A pinned file record (`downloading`, `ready`, `stale`). |
| `StorageLocalStore` | Persistence interface; `MemoryStorageLocalStore` and `SembastStorageLocalStore` ship by default. |

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
- [`path`](https://pub.dev/packages/path) — platform-correct path joining for the offline cache
- [`sembast`](https://pub.dev/packages/sembast) / [`sembast_web`](https://pub.dev/packages/sembast_web) — pure-Dart durable store for the offline catalog and transfer queue (native file / web IndexedDB)

## License

[MIT](LICENSE)
