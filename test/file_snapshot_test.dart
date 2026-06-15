import 'package:test/test.dart';
import 'package:winche_storage/winche_storage.dart';

import 'support/noop_api.dart';

void main() {
  final api = NoopApi();
  final ref = ChildReference(path: 'userFiles/u1/a.png', api: api);

  FileData sampleData() => FileData(
        id: 'rec1',
        directory: 'userFiles/u1',
        path: 'userFiles/u1/a.png',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
        metadata: const {'k': 'v'},
        version: 1,
        mimeType: 'image/png',
        sizeBytes: 10,
        uploadStatus: UploadStatus.pending,
      );

  test('missing snapshot', () {
    final s = FileSnapshot.missing(ref);
    expect(s.exists, isFalse);
    expect(s.data, isNull);
    expect(s.name, 'a.png');
    expect(s.path, 'userFiles/u1/a.png');
    expect(s.ref, same(ref));
  });

  test('fromData snapshot', () {
    final data = sampleData();
    final s = FileSnapshot.fromData(data, reference: ref);
    expect(s.exists, isTrue);
    expect(s.data, same(data));
    expect(s.data!.metadata, {'k': 'v'});
  });

  test('reference parent', () {
    expect(ref.parent?.path, 'userFiles/u1');
    expect(ref.name, 'a.png');
    expect(ref.fullPath, 'userFiles/u1/a.png');
    expect(ChildReference(path: 'root', api: api).parent, isNull);
  });
}
