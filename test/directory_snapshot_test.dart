import 'package:test/test.dart';
import 'package:winche_storage/winche_storage.dart';

import 'support/noop_api.dart';

void main() {
  test('fromFiles sets fields and derives name/length/isEmpty', () {
    final ref = ChildReference(path: 'a/dir', api: NoopApi());
    final snap = DirectorySnapshot.fromFiles(
      const [],
      reference: ref,
      timestamp: DateTime.utc(2026, 1, 1),
    );
    expect(snap.fromCache, isFalse);
    expect(snap.name, 'dir');
    expect(snap.length, 0);
    expect(snap.isEmpty, isTrue);
    expect(snap.files, isEmpty);
  });

  test('files list is unmodifiable', () {
    final ref = ChildReference(path: 'dir', api: NoopApi());
    final snap = DirectorySnapshot.fromFiles(
      [FileSnapshot.missing(ref)],
      reference: ref,
    );
    expect(snap.isNotEmpty, isTrue);
    expect(() => snap.files.add(FileSnapshot.missing(ref)),
        throwsUnsupportedError);
  });
}
