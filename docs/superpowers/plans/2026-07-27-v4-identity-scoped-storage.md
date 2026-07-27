# Implementation plan — winche_storage 4.0.0

Spec: `../specs/2026-07-27-v4-identity-scoped-storage-design.md`

Phases are ordered so each one leaves the tree compiling and testable.

## Phase 1 — Path layout

- `lib/src/offline/local_paths.dart`
  - Add `cacheFilePath(root, id, {sourceName, mimeType})` → `<root>/cache/<name>`,
    built on the existing `localFileName`.
  - `stagingFilePath(root, refPath)` → `<root>/staging/<hash>` (was `.staging`).
  - Add `scopedRootPath(directory, namespace)` → `<directory>/winche_storage_<ns>`
    and `validateNamespace(String)` (regex `^[A-Za-z0-9._-]+$`, rejects `.`/`..`,
    throws `ArgumentError.value`). Namespace logic lives here so the facade and
    tests share one definition.
- `lib/src/offline/offline_catalog.dart` — swap the three `localFilePath` call
  sites to `cacheFilePath`; ensure the cache directory exists before a rename in
  `finalizePin`.
- Tests: extend `test/offline/local_paths_test.dart`.

## Phase 2 — Failure taxonomy

- New `lib/src/offline/transfer_failure.dart`: `TransferFailureClass` enum and
  `classifyTransferFailure(Object)`.
- `transfer_record.dart` — add `TransferStatus.paused`.
- `transfer_event.dart` — add `TransferEventType.paused`; add
  `TransferRecord? record` to `TransferEvent`.
- `transfer_controller.dart` — `_driveUpload`/`_driveDownload` switch on the
  class; `_emit` gains an optional record; `retryFailed` also re-drives `paused`.
- New `test/offline/transfer_failure_test.dart`.

## Phase 3 — Close

- `upload_task.dart` / `download_task.dart` — abstract `abortForClose()` on the
  base; `_Direct*` completes `whenDone` with `StorageCancelledException`;
  `Managed*` cancels the token and returns to `queued` (no terminal outcome, no
  remote delete — `cancel()` deletes the remote file and must not be used here).
- New `lib/src/offline/live_task_registry.dart` — tracks live one-shot tasks so
  `close()` can abort them; self-pruning on completion.
- `child_reference.dart` — accept and propagate a `LiveTaskRegistry?`; register
  one-shot tasks it creates.
- `transfer_controller.dart` — rename `_disposed` → `_closed`, track scheduled
  retry `Timer`s, add `close()` doing: flag → cancel timers → abort live managed
  tasks → flip `running` records to `pending` → close the event stream.
- `lazy_storage_local_store.dart` — `_closed` guard, no-op degradation,
  idempotent `close()`, `isClosed`.
- New `test/offline/close_test.dart`.

## Phase 4 — Facade

- `winche_storage.dart`
  - `WincheStorageConfig.namespaceResolver` + validation.
  - Memoized scoped-root resolver replacing the raw `directoryResolver` handed
    to the catalog and controller; sembast opened as `index` under it.
  - `dispose()` → `close()`; add `isClosed`; `StateError` after close.
  - Add `resumeTransfers()`.
  - Own and pass a `LiveTaskRegistry`.
- New `test/offline/namespace_test.dart`, `test/offline/auth_pause_test.dart`.

## Phase 5 — Docs and fallout

- Update every existing test calling `dispose()` or asserting cache paths.
- README: namespace section, close, taxonomy, `resumeTransfers`.
- CHANGELOG 4.0.0; `pubspec.yaml` to 4.0.0.
- Example app: `namespaceResolver`, `close()`.
- `dart analyze` + `dart test` green.
