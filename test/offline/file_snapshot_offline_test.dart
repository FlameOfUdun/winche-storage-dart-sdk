import 'package:test/test.dart';
import 'package:winche_storage/winche_storage.dart';

import '../support/noop_api.dart';

FileData _data() => FileData(
      id: 'rec1',
      directory: 'a',
      path: 'a/b.png',
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
      metadata: const {},
      version: 1,
      mimeType: 'image/png',
      sizeBytes: 1,
      uploadStatus: UploadStatus.complete,
    );

void main() {
  test('a server snapshot carries no device state by default', () {
    final ref = ChildReference(path: 'a/b.png', api: NoopApi());
    final s = FileSnapshot.fromData(_data(), reference: ref);

    expect(s.exists, isTrue);
    expect(s.isCached, isFalse);
    expect(s.localPath, isNull);
  });

  test('annotation records this device cache state on the snapshot', () {
    final ref = ChildReference(path: 'a/b.png', api: NoopApi());
    final s = FileSnapshot.fromData(
      _data(),
      reference: ref,
      isCached: true,
      localPath: '/cache/rec1.png',
    );

    expect(s.isCached, isTrue);
    expect(s.localPath, '/cache/rec1.png');
  });

  test('FileData stays a pure wire model', () {
    // localPath/isCached used to live here, so a model that otherwise mirrors
    // the server carried two fields the server never sends. Anything on
    // FileData now came from the server.
    final json = _data().toJson();

    expect(json.containsKey('localPath'), isFalse);
    expect(json.containsKey('isCached'), isFalse);
    expect(json.containsKey('contentHash'), isTrue); // server-side, stays
  });

  test('a missing snapshot is never annotated', () {
    final ref = ChildReference(path: 'a/b.png', api: NoopApi());
    final s = FileSnapshot.missing(ref);

    expect(s.exists, isFalse);
    expect(s.isCached, isFalse);
    expect(s.localPath, isNull);
  });
}
