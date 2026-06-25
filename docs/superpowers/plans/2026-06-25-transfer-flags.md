# Transfer flags (`enqueue` + `cache`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-call `enqueue` (durable, retrying, can-start-offline) and `cache` (keep-available-offline) flags on the upload/download API, backed by a stable transfer-handle model with a `queued` state, and a simplified config with the two feature booleans removed.

**Architecture:** A tracked transfer is a **stable handle** — the same `UploadTask`/`DownloadTask` instance, re-run across retry attempts by `TransferController`, whose `whenDone` resolves only on the terminal outcome. The per-attempt transfer work becomes an internal "run one attempt" method; the controller owns retry/terminal decisions. The durable queue + offline cache exist whenever a store is configured; `enqueue`/`cache` route to the tracked/staged paths.

**Tech Stack:** Dart, `dio`, `sembast`/in-memory `StorageLocalStore`, `package:test`.

**Source spec:** `docs/superpowers/specs/2026-06-25-transfer-flags-design.md`.

---

## Phased decomposition

This is a large refactor; it ships in three independently-testable phases, executed in order:

- **Phase 1 — Stable handle + `queued` state** *(detailed below)*. The engine: `UploadTask`/`DownloadTask` gain a `queued` state and a managed (controller-driven) mode where one instance is re-run across attempts and `whenDone` is terminal-only; `TransferController` drives one stable handle per path. The existing public API keeps working — uploads/downloads routed through the controller simply become robust. **No API or config change in this phase.**
- **Phase 2 — Config simplification** *(scoped at the end)*. Remove `enableOfflineCache`/`enableAutoResume`; subsystems exist when a store/`directoryResolver` is configured; eager controller + rehydrate; call-time `StateError` scaffolding.
- **Phase 3 — `enqueue` + `cache` flags + lookup-by-path** *(scoped at the end)*. Surface the per-call flags on `uploadPath`/`uploadBytes`/`download`; `cache` reuses staging; add `uploadFor(path)`/`downloadFor(path)`; `pendingTransfers()` returns handles.

Phases 2 and 3 are listed with concrete tasks and signatures but will each be expanded into a full TDD plan once Phase 1 lands, because their exact code depends on Phase 1's final shapes.

---

## File structure (whole feature)

| File | Change | Responsibility |
|---|---|---|
| `lib/src/tasks/upload_task.dart` | modify | Add `queued` status; extract `_attemptOnce()`; add managed mode (`UploadTask.managed`, `runOnce`, `failPermanently`). |
| `lib/src/tasks/download_task.dart` | modify | Same shape for downloads (`_attemptOnce` already ≈ `_attempt`). |
| `lib/src/offline/transfer_controller.dart` | modify | Drive one stable handle per path across attempts; managed drive loop; rehydrate recreates queued handles; `uploadFor`/`downloadFor` (Phase 3). |
| `lib/winche_storage.dart` | modify (Phase 2/3) | Drop the two booleans; build subsystems from store presence; expose flags/lookups. |
| `lib/src/child_reference.dart` | modify (Phase 3) | `enqueue`/`cache` params on `uploadPath`/`uploadBytes`; `enqueue` on `download`. |
| `test/offline/transfer_handle_test.dart` | create | Phase 1 handle/state-machine tests. |
| `test/tasks/upload_task_managed_test.dart` | create | Phase 1 `UploadTask` managed-mode tests. |
| `test/tasks/download_task_managed_test.dart` | create | Phase 1 `DownloadTask` managed-mode tests. |

---

## Phase 1 — Stable handle + `queued` state

### Task 1: Add `queued` to the task status enums

**Files:**
- Modify: `lib/src/tasks/upload_task.dart:12-18`
- Modify: `lib/src/tasks/download_task.dart:8-14`
- Test: `test/tasks/status_enum_test.dart` (create)

- [ ] **Step 1: Write the failing test**

Create `test/tasks/status_enum_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:winche_storage/winche_storage.dart';

void main() {
  test('queued is the first upload/download status', () {
    expect(UploadTaskStatus.values.first, UploadTaskStatus.queued);
    expect(DownloadTaskStatus.values.first, DownloadTaskStatus.queued);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/tasks/status_enum_test.dart`
Expected: FAIL — `queued` is not a member of the enums.

- [ ] **Step 3: Implement**

In `lib/src/tasks/upload_task.dart` change the enum to:

```dart
enum UploadTaskStatus {
  queued,
  running,
  paused,
  complete,
  failed,
  cancelled,
}
```

In `lib/src/tasks/download_task.dart` change the enum to:

```dart
enum DownloadTaskStatus {
  queued,
  running,
  paused,
  complete,
  failed,
  cancelled,
}
```

- [ ] **Step 4: Run tests**

Run: `dart test test/tasks/status_enum_test.dart && dart analyze`
Expected: PASS; analyzer clean (the `DownloadTaskState` default `status: DownloadTaskStatus.running` and `UploadTaskState` initial `running` are unchanged — adding an enum value doesn't break them).

- [ ] **Step 5: Commit**

```bash
git add lib/src/tasks/upload_task.dart lib/src/tasks/download_task.dart test/tasks/status_enum_test.dart
git commit -m "Add queued status to transfer tasks"
```

---

### Task 2: Extract `DownloadTask._attemptOnce` and add managed mode

**Files:**
- Modify: `lib/src/tasks/download_task.dart`
- Test: `test/tasks/download_task_managed_test.dart` (create)

`DownloadTask` already isolates a single attempt in `_attempt()`. Managed mode adds: a queued-start factory, a `runOnce()` that performs exactly one attempt (queued→running→complete, or throws and returns to `queued` without completing `whenDone`), and `failPermanently()`.

- [ ] **Step 1: Write the failing test**

Create `test/tasks/download_task_managed_test.dart`:

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:winche_storage/src/tasks/download_task.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

class _DlApi extends NoopApi {
  _DlApi(this.fail);
  bool fail;
  @override
  Future<DownloadSession> generateDownloadUrl(String path) async {
    if (fail) throw const StorageUnavailableException('offline');
    return DownloadSession(url: 'https://dl/x', expiresAt: DateTime.utc(2030));
  }

  @override
  Future<FileData?> getFile(String path) async => FileData(
        id: 'id', directory: 'd', path: path,
        createdAt: DateTime.utc(2026, 1, 1), updatedAt: DateTime.utc(2026, 1, 1),
        metadata: const {}, version: 1, mimeType: 'text/plain',
        sizeBytes: 3, uploadStatus: UploadStatus.complete,
      );
}

class _BytesAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? s,
          Future<void>? c) async =>
      ResponseBody.fromBytes([1, 2, 3], 200,
          headers: {Headers.contentLengthHeader: ['3']});
  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('winche-dl-managed'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Dio dio() => Dio(BaseOptions(validateStatus: (s) => s != null))
    ..httpClientAdapter = _BytesAdapter();

  test('managed task starts queued and does not auto-run', () async {
    final task = DownloadTask.managed(
      reference: ChildReference(path: 'a/b', api: _DlApi(true)),
      saveTo: '${tmp.path}/out',
      httpClient: dio(),
    );
    expect(task.state.status, DownloadTaskStatus.queued);
  });

  test('runOnce: failure returns to queued without completing whenDone',
      () async {
    final task = DownloadTask.managed(
      reference: ChildReference(path: 'a/b', api: _DlApi(true)),
      saveTo: '${tmp.path}/out',
      httpClient: dio(),
    );
    await expectLater(task.runOnce(), throwsA(isA<Object>()));
    expect(task.state.status, DownloadTaskStatus.queued);
    var done = false;
    unawaited(task.whenDone.then((_) => done = true).catchError((_) {}));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(done, isFalse); // whenDone is NOT completed on a transient failure
  });

  test('runOnce: success completes the task', () async {
    final api = _DlApi(false);
    final task = DownloadTask.managed(
      reference: ChildReference(path: 'a/b', api: api),
      saveTo: '${tmp.path}/out',
      httpClient: dio(),
    );
    await task.runOnce();
    expect(task.state.status, DownloadTaskStatus.complete);
    await task.whenDone; // resolves
    expect(File('${tmp.path}/out').readAsBytesSync(), [1, 2, 3]);
  });

  test('failPermanently sets failed and errors whenDone', () async {
    final task = DownloadTask.managed(
      reference: ChildReference(path: 'a/b', api: _DlApi(true)),
      saveTo: '${tmp.path}/out',
      httpClient: dio(),
    );
    task.failPermanently(StateError('exhausted'));
    expect(task.state.status, DownloadTaskStatus.failed);
    await expectLater(task.whenDone, throwsA(isA<StateError>()));
  });
}
```

Add `import 'dart:async';` for `unawaited` at the top of the test.

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/tasks/download_task_managed_test.dart`
Expected: FAIL — `DownloadTask.managed`/`runOnce`/`failPermanently` are not defined.

- [ ] **Step 3: Implement**

In `lib/src/tasks/download_task.dart`, add a `_managed` field and a managed factory, and initialize state to `queued` when managed. Update the private constructor:

```dart
  final bool _managed;

  DownloadTask._({
    required this.reference,
    required this.saveTo,
    required this.maxRetries,
    required this.retryBaseDelay,
    required Dio httpClient,
    bool managed = false,
  })  : _httpClient = httpClient,
        _managed = managed,
        _state = DownloadTaskState(
          status: managed
              ? DownloadTaskStatus.queued
              : DownloadTaskStatus.running,
        );
```

Remove the field initializer `DownloadTaskState _state = const DownloadTaskState();` (it's now set in the constructor) — change the declaration to `late DownloadTaskState _state;` is **not** needed; instead declare `DownloadTaskState _state;` is illegal for a non-late final-free field set in the initializer list, so write it as a normal field assigned in the initializer list as shown above and change its declaration to:

```dart
  DownloadTaskState _state;
```

Add the managed factory after `DownloadTask.start`:

```dart
  /// Creates a controller-managed task: starts [DownloadTaskStatus.queued] and
  /// does NOT auto-run. The controller drives attempts via [runOnce].
  factory DownloadTask.managed({
    required ChildReference reference,
    required String saveTo,
    Dio? httpClient,
  }) {
    final client = httpClient ??
        Dio(BaseOptions(validateStatus: (status) => status != null));
    return DownloadTask._(
      reference: reference,
      saveTo: saveTo,
      maxRetries: 0,
      retryBaseDelay: const Duration(seconds: 1),
      httpClient: client,
      managed: true,
    );
  }
```

Add `runOnce` and `failPermanently` (place after `resume`):

```dart
  /// Runs exactly one attempt (managed mode). On success the task completes
  /// ([DownloadTaskStatus.complete], `whenDone` resolves). On failure it returns
  /// to [DownloadTaskStatus.queued] and rethrows WITHOUT completing `whenDone`,
  /// so the controller can retry the same handle or call [failPermanently].
  Future<void> runOnce({bool isResume = false}) async {
    _setStatus(DownloadTaskStatus.running);
    _cancelToken = CancelToken();
    try {
      await _attempt(isResume: isResume);
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.cancel) return;
      _setStatus(DownloadTaskStatus.queued);
      rethrow;
    }
  }

  /// Terminal failure (managed mode): retries exhausted / non-retryable. Sets
  /// [DownloadTaskStatus.failed] and errors `whenDone`.
  void failPermanently(Object error, [StackTrace? st]) {
    _setStatus(DownloadTaskStatus.failed);
    if (!_taskCompleter.isCompleted) {
      _taskCompleter.completeError(error, st);
    }
    _closeStreams();
  }
```

Note: `_attempt` already calls `_completeTask()` on success, so `runOnce` success completes `whenDone` via `_attempt`. On a partial-write failure `_attempt` throws; `runOnce` flips to `queued` and rethrows. (The unmanaged `_run` retry loop is unchanged.)

- [ ] **Step 4: Run tests**

Run: `dart test test/tasks/download_task_managed_test.dart && dart test test/download_verify_test.dart && dart analyze lib/src/tasks/download_task.dart`
Expected: PASS — managed tests pass and the existing download tests (unmanaged path) still pass.

- [ ] **Step 5: Commit**

```bash
git add lib/src/tasks/download_task.dart test/tasks/download_task_managed_test.dart
git commit -m "Add managed mode to DownloadTask"
```

---

### Task 3: Extract `UploadTask._attemptOnce` and add managed mode

**Files:**
- Modify: `lib/src/tasks/upload_task.dart`
- Test: `test/tasks/upload_task_managed_test.dart` (create)

`UploadTask._run` is currently one attempt with status/complete handling inline. Extract the body into `_attemptOnce()` returning the confirmed `FileData`, then wire both unmanaged `_run` and managed `runOnce` to it.

- [ ] **Step 1: Write the failing test**

Create `test/tasks/upload_task_managed_test.dart`:

```dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:winche_storage/src/tasks/upload_task.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

class _UpApi extends NoopApi {
  _UpApi(this.fail);
  bool fail;
  FileData? _rec;
  @override
  Future<FileData?> getFile(String path) async {
    if (fail) throw const StorageUnavailableException('offline');
    return _rec;
  }

  @override
  Future<FileData> setFile(String path, String mime, int size,
          {Map<String, dynamic>? metadata}) async =>
      _rec = FileData(
        id: 'id', directory: 'd', path: path,
        createdAt: DateTime.utc(2026, 1, 1), updatedAt: DateTime.utc(2026, 1, 1),
        metadata: const {}, version: 1, mimeType: mime, sizeBytes: size,
        uploadStatus: UploadStatus.pending,
      );
  @override
  Future<UploadSession> generateFileUploadUrl(String path) async =>
      UploadSession(url: 'https://up/x', expiresAt: DateTime.utc(2030));
  @override
  Future<FileData> confirmUpload(String path) async =>
      _rec!.copyWith(uploadStatus: UploadStatus.complete);
}

class _OkAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? s,
          Future<void>? c) async =>
      ResponseBody.fromBytes(const [], 200);
  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('winche-up-managed'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Dio dio() => Dio(BaseOptions(validateStatus: (s) => s != null))
    ..httpClientAdapter = _OkAdapter();
  File src() => File('${tmp.path}/s.txt')..writeAsBytesSync([1, 2, 3]);

  test('managed upload starts queued', () {
    final task = UploadTask.managed(
      reference: ChildReference(path: 'a/b', api: _UpApi(true)),
      localPath: src().path, mimeType: 'text/plain',
      multipartThreshold: 5 * 1024 * 1024, httpClient: dio(),
    );
    expect(task.state.status, UploadTaskStatus.queued);
  });

  test('runOnce failure → queued, whenDone not completed', () async {
    final task = UploadTask.managed(
      reference: ChildReference(path: 'a/b', api: _UpApi(true)),
      localPath: src().path, mimeType: 'text/plain',
      multipartThreshold: 5 * 1024 * 1024, httpClient: dio(),
    );
    await expectLater(task.runOnce(), throwsA(isA<Object>()));
    expect(task.state.status, UploadTaskStatus.queued);
  });

  test('runOnce success → complete with snapshot', () async {
    final task = UploadTask.managed(
      reference: ChildReference(path: 'a/b', api: _UpApi(false)),
      localPath: src().path, mimeType: 'text/plain',
      multipartThreshold: 5 * 1024 * 1024, httpClient: dio(),
    );
    await task.runOnce();
    expect(task.state.status, UploadTaskStatus.complete);
    final snap = await task.whenDone;
    expect(snap?.data?.uploadStatus, UploadStatus.complete);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/tasks/upload_task_managed_test.dart`
Expected: FAIL — `UploadTask.managed`/`runOnce` not defined.

- [ ] **Step 3: Implement**

In `lib/src/tasks/upload_task.dart`:

(a) Add a `_managed` field and initialize `_state` from it (mirror Task 2). Change the private constructor initializer list to set `_state`:

```dart
  final bool _managed;
```

Change the `_state` field declaration from
`UploadTaskState _state = const UploadTaskState(status: UploadTaskStatus.running, progress: 0.0);`
to a plain field set in the constructor:

```dart
  UploadTaskState _state;
```

and in `UploadTask._({...})` add `bool managed = false,` and the initializers:

```dart
  })  : _httpClient = httpClient,
        _stageSource = stageSource,
        _onPinFinalize = onPinFinalize,
        _onPinDeferred = onPinDeferred,
        _managed = managed,
        _state = UploadTaskState(
          status: managed ? UploadTaskStatus.queued : UploadTaskStatus.running,
          progress: 0.0,
        );
```

(b) Rename `Future<void> _run()` to `Future<FileData> _attemptOnce()` and change its terminal handling: instead of `_setStatus(complete)`/`_completeTask(confirmed)`/`_handleFailure`, it should **return** the confirmed `FileData` on success and **throw** on failure (let callers own status/completion). Concretely, in the renamed method:
  - Remove the leading `_setStatus(UploadTaskStatus.running);` (callers set status).
  - In the early "already complete & matches" branch, replace the block that does `await _settlePin(existingRecord); _setProgress(1.0); _setStatus(complete); _completeTask(existingRecord); return;` with `await _settlePin(existingRecord); return existingRecord;`.
  - At the normal end, replace `await _settlePin(confirmed); _setProgress(1.0); _setStatus(complete); _completeTask(confirmed);` with `await _settlePin(confirmed); return confirmed;`.
  - Remove the `on DioException` / `catch` blocks that call `_handleFailure` — let exceptions propagate (the cancel case is handled by callers).

(c) Add the unmanaged driver (preserves today's behavior) — the factories `start`/`startFromBytes` still `unawaited(task._runUnmanaged())`:

```dart
  Future<void> _runUnmanaged() async {
    _setStatus(UploadTaskStatus.running);
    _cancelToken = CancelToken();
    try {
      final confirmed = await _attemptOnce();
      _setProgress(1.0);
      _setStatus(UploadTaskStatus.complete);
      _completeTask(confirmed);
    } on DioException catch (e, st) {
      if (e.type == DioExceptionType.cancel) return;
      await _handleFailure(e, st);
    } catch (e, st) {
      await _handleFailure(e, st);
    }
  }
```

Update both factories to call `unawaited(task._runUnmanaged());` instead of `task._run()`. Update `resume()` to call `unawaited(_runUnmanaged());`.

(d) Add the managed factory + `runOnce` + `failPermanently`:

```dart
  factory UploadTask.managed({
    required ChildReference reference,
    String? localPath,
    Uint8List? bytes,
    required String mimeType,
    Map<String, dynamic>? metadata,
    required int multipartThreshold,
    Dio? httpClient,
    Future<String> Function()? stageSource,
    Future<void> Function(FileData confirmed)? onPinFinalize,
    Future<void> Function(FileData confirmed)? onPinDeferred,
  }) {
    final client = httpClient ??
        Dio(BaseOptions(validateStatus: (status) => status != null));
    return UploadTask._(
      reference: reference,
      localPath: localPath,
      bytes: bytes,
      mimeType: mimeType,
      metadata: metadata,
      multipartThreshold: multipartThreshold,
      maxRetries: 0,
      retryBaseDelay: const Duration(seconds: 1),
      httpClient: client,
      managed: true,
      stageSource: stageSource,
      onPinFinalize: onPinFinalize,
      onPinDeferred: onPinDeferred,
    );
  }

  /// One managed attempt: success completes the task; failure returns to
  /// [UploadTaskStatus.queued] and rethrows without completing `whenDone`.
  Future<void> runOnce() async {
    _setStatus(UploadTaskStatus.running);
    _cancelToken = CancelToken();
    try {
      final confirmed = await _attemptOnce();
      _setProgress(1.0);
      _setStatus(UploadTaskStatus.complete);
      _completeTask(confirmed);
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.cancel) return;
      _setStatus(UploadTaskStatus.queued);
      rethrow;
    }
  }

  void failPermanently(Object error, [StackTrace? st]) {
    _setStatus(UploadTaskStatus.failed);
    if (!_taskCompleter.isCompleted) {
      _taskCompleter.completeError(error, st);
    }
    _closeStreams();
  }
```

- [ ] **Step 4: Run tests**

Run: `dart test test/tasks/upload_task_managed_test.dart && dart test test/upload_overwrite_test.dart test/upload_pin_test.dart && dart analyze lib/src/tasks/upload_task.dart`
Expected: PASS — managed tests pass and the existing unmanaged upload tests are unaffected.

- [ ] **Step 5: Commit**

```bash
git add lib/src/tasks/upload_task.dart test/tasks/upload_task_managed_test.dart
git commit -m "Add managed mode to UploadTask"
```

---

### Task 4: Controller drives one stable handle per path

**Files:**
- Modify: `lib/src/offline/transfer_controller.dart`
- Test: `test/offline/transfer_handle_test.dart` (create)

Replace the "new task per attempt" model: `startUpload`/`startDownload` and `_restart` create a **managed** handle, keep it in `_activeUploads`/`_activeDownloads` for the transfer's lifetime, and a single `_driveManaged` loop re-runs `runOnce()` on that handle across attempts, only finishing on the terminal outcome.

- [ ] **Step 1: Write the failing test**

Create `test/offline/transfer_handle_test.dart`:

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:winche_storage/src/offline/transfer_controller.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

/// getFile throws until [online] is set; then a normal upload flow proceeds.
class _FlakyApi extends NoopApi {
  bool online = false;
  FileData? _rec;
  @override
  Future<FileData?> getFile(String path) async {
    if (!online) throw const StorageUnavailableException('offline');
    return _rec;
  }

  @override
  Future<FileData> setFile(String path, String mime, int size,
          {Map<String, dynamic>? metadata}) async =>
      _rec = FileData(
        id: 'id', directory: 'd', path: path,
        createdAt: DateTime.utc(2026, 1, 1), updatedAt: DateTime.utc(2026, 1, 1),
        metadata: const {}, version: 1, mimeType: mime, sizeBytes: size,
        uploadStatus: UploadStatus.pending,
      );
  @override
  Future<UploadSession> generateFileUploadUrl(String path) async =>
      UploadSession(url: 'https://up/x', expiresAt: DateTime.utc(2030));
  @override
  Future<FileData> confirmUpload(String path) async =>
      _rec!.copyWith(uploadStatus: UploadStatus.complete);
}

class _OkAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? s,
          Future<void>? c) async =>
      ResponseBody.fromBytes(const [], 200);
  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('winche-handle'));
  tearDown(() => tmp.deleteSync(recursive: true));

  TransferController build(WincheStorageApi api, StorageLocalStore store) =>
      TransferController(
        api: api, store: store, multipartThreshold: 5 * 1024 * 1024,
        directoryResolver: () async => tmp.path,
        httpClient: Dio(BaseOptions(validateStatus: (s) => s != null))
          ..httpClientAdapter = _OkAdapter(),
        retry: const TransferRetryConfig(
          baseDelay: Duration(milliseconds: 5),
          maxDelay: Duration(milliseconds: 10),
          maxAttempts: 100,
          pollInterval: Duration(hours: 1),
        ),
      );

  test('the same handle is returned and is stable across offline retries',
      () async {
    final api = _FlakyApi();
    final ctrl = build(api, MemoryStorageLocalStore());
    final src = File('${tmp.path}/s.txt')..writeAsBytesSync([1, 2, 3]);
    final ref = ChildReference(path: 'a/b', api: api);

    final task = ctrl.startUpload(ref,
        localPath: src.path, mimeType: 'text/plain',
        multipartThreshold: 5 * 1024 * 1024);

    // Same handle on a duplicate call.
    expect(identical(ctrl.startUpload(ref,
        localPath: src.path, mimeType: 'text/plain',
        multipartThreshold: 5 * 1024 * 1024), task), isTrue);

    // Offline: the handle sits queued, whenDone is NOT yet resolved.
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(task.state.status, UploadTaskStatus.queued);

    // Come online: the SAME handle drives to completion; whenDone resolves.
    api.online = true;
    await task.whenDone;
    expect(task.state.status, UploadTaskStatus.complete);
    await ctrl.dispose();
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/offline/transfer_handle_test.dart`
Expected: FAIL — today the first attempt rejects `whenDone` and a new task is created per retry, so the handle goes `failed`/stale rather than staying `queued` then completing.

- [ ] **Step 3: Implement**

In `lib/src/offline/transfer_controller.dart`:

(a) Replace `startUpload`'s task creation with a managed handle and the new drive loop:

```dart
  UploadTask startUpload(
    ChildReference ref, {
    required String localPath,
    required String mimeType,
    Map<String, dynamic>? metadata,
    required int multipartThreshold,
    bool pinned = false,
  }) {
    final existing = _activeUploads[ref.path];
    if (existing != null) return existing;
    final sink = pinned ? pinSink : null;
    final task = UploadTask.managed(
      reference: ref,
      localPath: localPath,
      mimeType: mimeType,
      metadata: metadata,
      multipartThreshold: multipartThreshold,
      httpClient: _httpClient,
      stageSource:
          sink == null ? null : () => sink.stageUpload(ref.path, localPath),
    );
    _activeUploads[ref.path] = task;
    unawaited(_registerUpload(
      ref.path,
      localPath: localPath, mimeType: mimeType, metadata: metadata,
      multipartThreshold: multipartThreshold, pinned: pinned, task: task,
    ));
    return task;
  }
```

(b) Change `_registerUpload` to take the `UploadTask task` (not a `done` future) and call `_driveUpload`:

```dart
  Future<void> _registerUpload(
    String path, {
    required String localPath,
    required String mimeType,
    Map<String, dynamic>? metadata,
    required int multipartThreshold,
    required bool pinned,
    required UploadTask task,
  }) async {
    final seq =
        await _existingSeq(TransferKind.upload, path, localPath: localPath) ??
            await _queue.enqueue((seq) => TransferRecord(
                  seq: seq, kind: TransferKind.upload, path: path,
                  localPath: localPath, mimeType: mimeType, metadata: metadata,
                  multipartThreshold: multipartThreshold,
                  status: TransferStatus.running, attempt: 0, lastError: null,
                  createdAt: DateTime.now(), pinned: pinned,
                ));
    _running.add(seq);
    _emit(TransferEventType.started, TransferKind.upload, path);
    unawaited(_driveUpload(seq, task, path));
  }
```

(c) Add the managed drive loop for uploads (replaces the per-attempt `_drive` for uploads). It re-runs `runOnce` on the SAME handle, bouncing `queued` between attempts, and only finishes terminally:

```dart
  Future<void> _driveUpload(int seq, UploadTask task, String path) async {
    while (!_disposed) {
      try {
        await task.runOnce();
        // success — finalize pin, clear record.
        final snap = await task.whenDone;
        if (pinSink != null) {
          final rec = await _queue.get(seq);
          if (rec != null && rec.pinned && snap?.data != null) {
            try {
              await pinSink!.finalizeUploadPin(path, snap!.data!);
            } catch (_) {/* best-effort */}
          }
        }
        _running.remove(seq);
        _activeUploads.remove(path);
        await _queue.remove(seq);
        _emit(TransferEventType.completed, TransferKind.upload, path);
        return;
      } catch (e) {
        // transient — the handle is back to `queued`.
        if (task.state.status == UploadTaskStatus.cancelled ||
            task.state.status == UploadTaskStatus.paused) {
          _running.remove(seq);
          return; // cancelled/paused: stop driving; resume re-enters elsewhere
        }
        final rec = await _queue.get(seq);
        if (rec == null) {
          _running.remove(seq);
          _activeUploads.remove(path);
          return;
        }
        final attempt = rec.attempt + 1;
        await _queue.update(rec.copyWith(
            status: TransferStatus.failed, attempt: attempt, lastError: '$e'));
        _emit(TransferEventType.failed, TransferKind.upload, path, e);
        if (attempt > _retry.maxAttempts) {
          _running.remove(seq);
          _activeUploads.remove(path);
          task.failPermanently(e);
          return;
        }
        _emit(TransferEventType.retrying, TransferKind.upload, path);
        await Future<void>.delayed(_backoff(attempt));
      }
    }
  }
```

(d) Mirror (a)–(c) for downloads: `startDownload` uses `DownloadTask.managed`, `_registerDownload` calls `_driveDownload`, and `_driveDownload` is the same loop with `DownloadTask`/`TransferKind.download` and no pin step.

(e) Rewrite `_restart` to recreate a **managed** handle (queued) from the record and drive it (reusing the same `_driveUpload`/`_driveDownload`), instead of `*.start(...)` + `_drive`. Keep the "source must exist / staged-copy preferred" logic. Remove the old `_drive` method (replaced by the two drive loops). Keep `_backoff`, `_existingSeq`, `_emit`, `retryFailed`, `resumePath`, `removePath`, `pendingTransfers`, `rehydrate` (it calls `_restart`).

- [ ] **Step 4: Run tests**

Run: `dart test test/offline/transfer_handle_test.dart test/offline/transfer_controller_test.dart test/offline/transfer_controller_pin_test.dart && dart analyze lib/src/offline/transfer_controller.dart`
Expected: PASS — the stable-handle test passes; existing controller tests still pass (some assertions about `failed` status timing may need updating to the new queued/retry flow — update them to assert eventual completion / queue state rather than a single failed attempt).

- [ ] **Step 5: Commit**

```bash
git add lib/src/offline/transfer_controller.dart test/offline/transfer_handle_test.dart
git commit -m "Drive one stable transfer handle per path across attempts"
```

---

### Task 5: Full suite green for Phase 1

- [ ] **Step 1:** Run `dart analyze` — expect **No issues found**.
- [ ] **Step 2:** Run `dart test` — expect all tests pass. Where older tests asserted a transient offline upload/download ends `failed`, update them to assert it sits `queued` and completes once the fake API is online (the new robust contract).
- [ ] **Step 3: Commit** any test updates:

```bash
git add test
git commit -m "Update transfer tests for stable-handle queued model"
```

---

## Phase 2 — Config simplification (to be expanded into a full plan)

Remove `enableOfflineCache`/`enableAutoResume`; subsystems exist when a store is configured.

- **Task 2.1** — `WincheStorageConfig`: delete the two bool fields. In `WincheStorage._build`, set `needsStore = directoryResolver != null || inMemory`; build `store`, `OfflineCatalog`, and `TransferController` whenever `needsStore`; keep wiring `controller.pinSink = catalog` and `unawaited(controller?.rehydrate())`. `WincheStorage.withStore`: drop the two bool params.
- **Task 2.2** — Replace the construction-time `directoryResolver` requirement with a call-time guard: a helper `_requireStore()` / `_requireCatalog()` throwing `StateError('configure directoryResolver/inMemory to use durable transfers / offline cache')`, used by Phase-3 flag paths and the existing `makeAvailableOffline`/`resume*` when their subsystem is absent.
- **Task 2.3** — Update `WincheStorageConfig` dartdoc + README config table + the example app constructor (drop the two flags). Update `facade_offline_test.dart` (the `enableAutoResume requires directoryResolver` test becomes "durable transfers require a store/dir, enforced at call time").
- **Tests:** building with only `directoryResolver`/`inMemory` yields working durable + cache; building with neither makes durable/cache operations throw `StateError`; rehydrate still runs at startup when a store is present.

## Phase 3 — `enqueue` + `cache` flags + lookup-by-path (to be expanded into a full plan)

- **Task 3.1** — `ChildReference.uploadPath`/`uploadBytes`: replace `makeAvailableOffline:` with `cache:`; add `enqueue:`. `enqueue:true` → `controller.startUpload(...)` (requires store, else `StateError`); `enqueue:false` → direct `UploadTask.start`. `cache:true` → wire the `stageSource`/`onPinFinalize`/`onPinDeferred` closures (requires catalog, else `StateError`). Both flags compose.
- **Task 3.2** — `ChildReference.download(saveTo, {bool enqueue = false})`: `enqueue:true` → `controller.startDownload`; else direct `DownloadTask.start`.
- **Task 3.3** — `TransferController.uploadFor(path)` / `downloadFor(path)` returning the live handle (or null), so a UI can reattach after restart; `WincheStorage` re-exposes them. `pendingTransfers()` unchanged (records); optionally add handle accessors.
- **Task 3.4** — Docs: README upload/download tables + example app switched to `enqueue`/`cache`; CHANGELOG entry (4.0.0, breaking: config fields removed, `makeAvailableOffline:` param renamed to `cache:`).
- **Tests:** the four `enqueue`×`cache` combinations; `enqueue:false` returns an untracked one-shot; `enqueue:true` dedups and survives a simulated restart; flag-without-subsystem throws; `cache:true` stages + finalizes.

---

## Self-review notes

- **Spec coverage:** `queued` state + stable handle + terminal `whenDone` (Phase 1); config booleans removed + store-presence enable + call-time validation (Phase 2); `enqueue`/`cache` flags + combinations + `uploadFor`/`downloadFor` (Phase 3); `cache` reuses staging (Phase 3, reusing the existing `stageForUpload`/`finalizePin`). All spec sections map to tasks.
- **Same task type:** managed and unmanaged transfers are both `UploadTask`/`DownloadTask` — only the drive path differs.
- **`whenDone` terminal-only** for managed handles is enforced by `runOnce` (no completion on transient failure) + the controller calling `failPermanently` only when attempts are exhausted.
- **Reuse:** signed-URL engines, multipart resume, `OfflineCatalog` staging, `pendingTransfers`, and the pin lifecycle are unchanged.
