# winche_storage 4.0.0 — identity-scoped stores, safe close, auth-aware queue

**Date:** 2026-07-27
**Status:** Approved

## Motivation

`winche_database` 5.0.0 fixed four defects found while wiring up multi-user
support. Three of them exist in `winche_storage` too, in a more damaging form,
because storage persists file *bytes* alongside its index.

| database 5.0.0 change | winche_storage |
| --- | --- |
| `namespaceResolver` — identity-scoped store | Applies, doubly: the sembast index is a fixed `'winche_storage'`, **and** cached bytes sit flat under `directoryResolver`. |
| Safe, awaitable, idempotent `close()` | Applies. `dispose()` cancels only the poll timer; drive loops and scheduled retry `Timer`s outlive it and write into a closed sembast. |
| `UNAUTHENTICATED` must not destroy queued work | Applies. A 401 is treated as a transient failure: five attempts, then `failPermanently` and the durable record is dropped. |
| `reconnect()` — re-dial with a fresh token | No direct analogue; the HTTP API reads `tokenProvider` per request. The equivalent need is un-pausing an auth-halted queue. |
| Frame-race buffering | Not applicable — no WebSocket. |
| Non-blocking writes | Already true; `startUpload`/`startDownload` return a handle synchronously. |

Two concrete bugs motivate the work:

1. **Cross-identity leak.** A second user on the same device reads the first
   user's pinned files through `offlineSnapshot()` / `offlineChildren()`, and the
   first user's queued uploads replay under the second user's token.
2. **Durable work destroyed by a transient condition.** An expired token, or
   simply being offline, burns `retryMaxAttempts` (default 5, ~2.5 minutes) and
   then permanently drops the transfer. This directly contradicts the 3.0.0
   contract that a durable transfer "retries until it succeeds, so it can be
   started while offline".

## 1. Identity scoping

### Configuration

`WincheStorageConfig` gains:

```dart
final FutureOr<String> Function()? namespaceResolver;
```

Rules, following the `winche_database` convention:

- **Required** unless `inMemory: true`. Missing it throws `ArgumentError` at
  construction, with a message naming the signed-in user id as the value to
  return.
- **Must be null** when `inMemory: true` — there is no persistence to scope, so
  supplying one is an `ArgumentError`.
- Stateless native mode (no `directoryResolver`, not `inMemory`, not web) still
  requires one. It is unused there, but the rule stays flat: you must name the
  identity. One rule beats a matrix keyed on `directoryResolver` and platform.
- Resolved lazily on first store access and **memoized**, exactly like
  `directoryResolver`. It pins the identity for the lifetime of the instance;
  returning a changing value does not migrate a live instance.
- Validated against `^[A-Za-z0-9._-]+$`, additionally rejecting `.` and `..`.
  Validated, never sanitised: silently rewriting a user id would collapse two
  identities onto one store.

`WincheStorage.withStore(api, store, …)` is **unchanged** — the store is supplied
explicitly, so scoping is the caller's concern. This matches
`WincheDatabase.withStore`, which takes no namespace either.

### On-disk layout

```
<dir>/winche_storage_<ns>/index.db      ← sembast: catalog + transfer queue
<dir>/winche_storage_<ns>/cache/<id>.png ← cached bytes
<dir>/winche_storage_<ns>/staging/<hash> ← in-progress pinned uploads
```

Index and bytes travel together, so "forget this user" is one directory removal
and a signed-out user's cache can never half-exist.

`staging/` is a sibling of `cache/`, not a child, and loses its leading dot.
Staged bytes are an upload in flight, not a cached file: `clearOfflineCache()`
must be able to empty `cache/` without disturbing an upload mid-flight.

On the web there are no files; the IndexedDB database is named
`winche_storage_<ns>`.

`download(saveTo)` takes an explicit absolute path from the caller, so
`directoryResolver` is only ever the SDK's private cache root. Namespacing it
disturbs no user-chosen download location.

### Implementation shape

The facade currently memoizes `directoryResolver` and hands that same function to
`OfflineCatalog` and `TransferController`. It is replaced by a memoized
**scoped-root resolver**:

```dart
Future<String> Function() scopedRoot = _memoize(() async =>
    p.join(await directoryResolver(), 'winche_storage_${_validate(await namespaceResolver())}'));
```

The catalog and controller keep taking "a directory resolver" and remain
namespace-unaware. Only the facade knows about namespaces. This is the single
change point; no call site has to learn a new concept.

`local_paths.dart` gains `cacheFilePath(root, id, {sourceName, mimeType})`
returning `<root>/cache/<name>`, next to the existing `localFilePath`.
`stagingFilePath` returns `<root>/staging/<hash>`.

The sembast database name becomes `index`, opened under the scoped root, rather
than `winche_storage` opened under `<dir>`.

## 2. Failure taxonomy

Today `_driveUpload` and `_driveDownload` have exactly one response to any thrown
error: increment `attempt`, back off, and after `retryMaxAttempts` call
`failPermanently` and drop the record. Errors are split into three classes.

New file `lib/src/offline/transfer_failure.dart`:

```dart
enum TransferFailureClass { pause, retry, terminal }

TransferFailureClass classifyTransferFailure(Object error);
```

A pure function over the error, unit-testable without a controller.

| Class | Statuses | Behaviour |
| --- | --- | --- |
| **pause** | `unauthenticated`, `unavailable` | Record kept, `attempt` untouched, `status` → `TransferStatus.paused`, `lastError` set. Handle stays alive in `queued`. `TransferEventType.paused` emitted. |
| **retry** | `internal`, `deadlineExceeded`, `unknown`, and any non-`WincheStorageException` | Today's behaviour: increment `attempt`, exponential backoff, `failPermanently` past `retryMaxAttempts`. |
| **terminal** | `permissionDenied`, `notFound`, `invalidArgument`, `failedPrecondition` | Record dropped, `failPermanently`, `failed` event carrying the record. |

Non-`WincheStorageException` errors default to **retry** rather than terminal —
some are permanent (a missing upload source file), but bounding them at
`retryMaxAttempts` reaches the same end state without needing to enumerate them.

### Consequences, accepted deliberately

- **`unavailable` moving into pause is a second bug fix.** It makes the
  documented 3.0.0 contract true: a durable transfer started offline now really
  does survive until the network returns, instead of dying in ~2.5 minutes.
- **A paused transfer's `whenDone` does not resolve while paused.** That is the
  intended stable-handle contract ("start an upload while offline and just
  `await` it"). No timeout is introduced.

### Surface changes

- `TransferStatus` gains `paused`, persisted with the reason in `lastError`, so
  `pendingTransfers()` distinguishes "waiting on a token or network" from
  "failed and retrying".
- `TransferEventType` gains `paused` — the `SyncPaused` analogue.
- `TransferEvent` gains `TransferRecord? record`, populated on terminal `failed`.
  This is the `WriteFailed.writes` analogue: a path and an error are not enough
  to re-enqueue a dropped upload, since `localPath`, `mimeType` and `metadata`
  are lost with the record.

### Resuming

- The `retryPollInterval` backstop (`retryFailed`) is extended to re-drive
  `paused` records as well as `failed` ones, so an app that refreshes its token
  in the background recovers unaided within ≤30s.
- **`WincheStorage.resumeTransfers()`** forces it immediately across both kinds —
  the honest `reconnect()` analogue, documented as the thing to call after a
  token refresh. `resumeUploads()` / `resumeDownloads()` remain as the narrower
  per-kind filters.

## 3. Close

`dispose()` is renamed to **`close()`**, returning `Future<void>`, idempotent,
alongside a new `WincheStorage.isClosed`. No deprecated alias — this is listed as
a breaking change.

Teardown runs in dependency order, mirroring database's:

1. Set the closed flag. Every drive-loop continuation and event emission is gated
   on it, so anything the teardown itself triggers becomes a no-op.
2. Cancel the retry-poll timer and **every scheduled retry `Timer`**. The
   controller must now track them; today `_scheduleRetry` creates fire-and-forget
   timers that outlive `dispose()` and fire into a closed store.
3. Abort in-flight HTTP on live managed tasks.
4. Flip durable records in `running` back to `pending`, so the next launch (or
   the next `WincheStorage` for that namespace) resumes them.
5. Await the drive loops unwinding.
6. Close the event stream controller.
7. Close the local store — last, because nothing above can touch it any more.

`close()` never waits on the network: in-flight transfers are aborted, not
drained. A user switch cannot block for minutes behind a large upload. One-shot,
non-enqueued handles fail with `StorageCancelledException`; durable ones resume
later.

`LazyStorageLocalStore` degrades to no-ops after close — null, empty list, or
plain return per method — because the backing sembast throws
`Bad state: database is closed` on any access, and a straggling callback would
surface that as an unhandled async error the caller cannot catch. "Nothing
cached" is the safe reading of a store that is gone. `close()` on it is
idempotent.

Facade calls after `close()` throw `StateError`.

## 4. Migration

**None.** Documented in the CHANGELOG:

- Existing installs orphan their old flat cache and `winche_storage.db` directly
  under `<dir>`. Nothing references them; they are not swept.
- Pinned files rebuild themselves on next use.
- **Un-synced uploads queued in the legacy store are lost.** Drain the queue
  before shipping the upgrade if that matters.

A sweep was considered and rejected as scope. Migrating the legacy store *into*
the first namespace that opens was rejected outright: it hands one arbitrary user
the previous shared state, which is the bug being fixed.

## 5. Testing

New:

- `test/offline/namespace_test.dart` — two namespaces see neither each other's
  catalog nor each other's transfer queue; resolved file paths sit under distinct
  roots; `cache/` and `staging/` land where specified; validation rejects an
  empty, missing, `.`, `..`, and path-separator-bearing namespace; `inMemory`
  plus `namespaceResolver` is an `ArgumentError`; omitting it without `inMemory`
  is an `ArgumentError`.
- `test/offline/transfer_failure_test.dart` — the taxonomy in isolation, every
  status mapped, non-Winche errors defaulting to retry.
- `test/offline/close_test.dart` — close during an in-flight transfer raises no
  `Bad state: database is closed`; idempotent; post-close facade calls throw
  `StateError`; `running` records become `pending` and resume in a fresh
  instance; a one-shot handle fails with `StorageCancelledException`; a scheduled
  retry timer does not fire after close.
- `test/offline/auth_pause_test.dart` — 401 pauses without incrementing
  `attempt` and leaves the record intact, emitting `paused`; `resumeTransfers()`
  re-drives it; the backstop re-drives it unaided; 403 is terminal and its
  `failed` event carries the record; 503 survives well past `retryMaxAttempts`.

Updated: existing tests calling `dispose()`, and any asserting cache file paths.

## 6. Version

`4.0.0`. Breaking: `namespaceResolver` required, on-disk layout moved with no
migration, `dispose()` renamed to `close()`, `TransferStatus` and
`TransferEventType` gained variants (exhaustive `switch`es need new arms).
