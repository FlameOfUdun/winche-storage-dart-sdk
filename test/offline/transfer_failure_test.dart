import 'package:test/test.dart';
import 'package:winche_storage/src/offline/transfer_failure.dart';
import 'package:winche_storage/winche_storage.dart';

void main() {
  TransferFailureClass classify(StorageErrorStatus s) =>
      classifyTransferFailure(
          WincheStorageException.fromStatus(s, 'boom'));

  group('pause — clears on its own, must never spend the retry budget', () {
    test('an expired token pauses', () {
      expect(classify(StorageErrorStatus.unauthenticated),
          TransferFailureClass.pause);
    });

    test('an unreachable server pauses', () {
      expect(classify(StorageErrorStatus.unavailable),
          TransferFailureClass.pause);
    });
  });

  group('terminal — repeating the request verbatim cannot help', () {
    for (final status in const [
      StorageErrorStatus.permissionDenied,
      StorageErrorStatus.notFound,
      StorageErrorStatus.invalidArgument,
      StorageErrorStatus.failedPrecondition,
    ]) {
      test('${status.name} is terminal', () {
        expect(classify(status), TransferFailureClass.terminal);
      });
    }
  });

  group('retry — possibly transient, bounded by the attempt cap', () {
    for (final status in const [
      StorageErrorStatus.internal,
      StorageErrorStatus.deadlineExceeded,
      StorageErrorStatus.cancelled,
      StorageErrorStatus.unknown,
    ]) {
      test('${status.name} retries', () {
        expect(classify(status), TransferFailureClass.retry);
      });
    }

    test('a non-Winche error retries rather than being dropped', () {
      // Some of these are permanent (a missing source file), but the attempt
      // cap reaches the same end state, and treating an unrecognised error as
      // terminal would throw away recoverable work.
      expect(classifyTransferFailure(StateError('local file missing')),
          TransferFailureClass.retry);
      expect(classifyTransferFailure(Exception('boom')),
          TransferFailureClass.retry);
    });
  });

  test('every status is classified', () {
    for (final status in StorageErrorStatus.values) {
      expect(() => classify(status), returnsNormally,
          reason: '${status.name} has no arm');
    }
  });
}
