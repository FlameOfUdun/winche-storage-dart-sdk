import 'package:test/test.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_storage/winche_storage.dart';

/// What winche_database hands over: a link and what the server resolved for it.
final class _Link extends WincheLink {
  _Link(super.app, super.kind, super.target, [super.json]);
}

void main() {
  final app = WincheApp('file-link-${DateTime.now().microsecondsSinceEpoch}',
      options: WincheOptions(endpoints: {'storage': Uri.parse('http://localhost:1/files')}));
  final record = {
    'id': 'a.png', 'directory': 'scans', 'path': 'scans/a.png', 'createdAt': '2026-11-13T10:00:00Z', 'updatedAt': '2026-11-13T10:00:00Z',
    'metadata': {'ward': 'icu'}, 'version': 2, 'mimeType': 'image/png', 'sizeBytes': 42, 'uploadStatus': 'complete',
  };

  test('a resolved file link is a FileSnapshot with a working reference', () {
    final link = _Link(app, 'file', 'scans/a.png', record);
    final file = link.file!;
    expect((file.data!.sizeBytes, file.data!.metadata['ward'], file.reference.path), (42, 'icu', 'scans/a.png'));
    expect(link.fileRef.path, 'scans/a.png');
  });

  test('an unresolved file link still reaches the file; other kinds are not files', () {
    expect(_Link(app, 'file', 'scans/hidden.png').file, isNull);
    expect(_Link(app, 'file', 'scans/hidden.png').fileRef.path, 'scans/hidden.png');
    expect(_Link(app, 'user', 'u1', {'uid': 'u1'}).file, isNull);
    expect(() => _Link(app, 'user', 'u1').fileRef, throwsStateError);
  });
}
