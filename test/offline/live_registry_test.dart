import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

/// Hangs on the first server call until released, so a test can observe a
/// transfer that is genuinely in flight.
class _HangingApi extends NoopApi {
  final _gate = Completer<void>();
  final started = Completer<void>();

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<DownloadSession> generateDownloadUrl(String path) async {
    if (!started.isCompleted) started.complete();
    await _gate.future;
    // Port 1 is reliably closed, so the transfer then fails deterministically
    // rather than depending on DNS.
    return DownloadSession(
        url: 'http://127.0.0.1:1/x', expiresAt: DateTime.utc(2030));
  }
}

/// Lets the broadcast stream deliver: events are added synchronously but
/// dispatched on a later microtask, so asserting immediately sees nothing.
Future<void> pumpEvents() => Future<void>.delayed(Duration.zero);

void main() {
  late Directory tmp;
  late WincheApp app;
  late WincheStorage storage;
  late _HangingApi api;
  late List<TransferEvent> events;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('winche-registry');
    app = WincheApp('registry');
    storage = WincheStorage(app)
      ..config = const WincheStorageConfig(
        retryPollInterval: Duration(hours: 1),
      );
    api = _HangingApi();
    storage.debugBindStore(api, MemoryStorageLocalStore(),
        directoryResolver: () async => tmp.path);
    events = [];
    storage.transferEvents.listen(events.add);
  });

  tearDown(() async {
    api.release();
    await app.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {
      // Best effort: the store may still hold a handle on Windows.
    }
  });

  test('a live download is findable by path and emits started', () async {
    final task = storage.child('a/b.png').download(p.join(tmp.path, 'out.bin'));
    task.whenDone.ignore();
    await api.started.future; // genuinely in flight
    await pumpEvents();

    expect(storage.downloadFor('a/b.png'), same(task));
    // Closes a hole that predates this redesign: only the durable queue used to
    // emit, so anything started without `enqueue:` was invisible here.
    expect(events.map((e) => e.type), contains(TransferEventType.started));
    expect(events.map((e) => e.kind), contains(TransferKind.download));
  });

  test('the entry is pruned once the task settles', () async {
    final task = storage.child('a/b.png').download(p.join(tmp.path, 'out.bin'));
    task.whenDone.ignore();
    await api.started.future;
    api.release();
    await task.whenDone.then<void>((_) {}, onError: (_) {});
    await pumpEvents();

    expect(storage.downloadFor('a/b.png'), isNull);
    expect(events.map((e) => e.type), contains(TransferEventType.failed));
  });

  test('a download never emits paused', () async {
    final task = storage.child('a/b.png').download(p.join(tmp.path, 'out.bin'));
    task.whenDone.ignore();
    await api.started.future;
    task.pause();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // `paused` means "the durable queue halted on an expired token or a dead
    // network" — an upload concept. A user-driven pause is visible on the
    // task's own stateStream, so reusing the event would give it two meanings.
    expect(
        events.map((e) => e.type), isNot(contains(TransferEventType.paused)));
  });

  test('downloadFor is null for a path with nothing in flight', () async {
    expect(storage.downloadFor('nothing/here.png'), isNull);
  });
}
