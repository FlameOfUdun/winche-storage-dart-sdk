import 'package:test/test.dart';
import 'package:winche_storage/winche_storage.dart';

import 'support/noop_api.dart';

FileData _file(String path) => FileData(
  id: path.split('/').last,
  directory: path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '',
  path: path,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  metadata: const {},
  version: 1,
  mimeType: 'text/plain',
  sizeBytes: 1,
  uploadStatus: UploadStatus.complete,
);

/// Serves `docs` in pages of one entry: a.txt | sub/ | b.txt.
class _PagedApi extends NoopApi {
  final tokens = <String?>[];

  @override
  Future<FileListPage> list(String directory, {int? maxResults, String? pageToken, String? mimeType}) async {
    tokens.add(pageToken);
    return switch (pageToken) {
      null => FileListPage(items: [_file('docs/a.txt')], prefixes: const [], nextPageToken: '1'),
      '1' => const FileListPage(items: [], prefixes: ['docs/sub'], nextPageToken: '2'),
      _ => FileListPage(items: [_file('docs/b.txt')], prefixes: const []),
    };
  }
}

void main() {
  test('child paths have one form: stray slashes dropped, . and .. refused', () {
    final root = ChildReference(path: 'users', api: NoopApi());
    expect(root.child('u1//photos/').path, 'users/u1/photos');
    expect(root.child('/a').path, 'users/a');
    expect(() => root.child('../other'), throwsArgumentError);
    expect(() => root.child('a/./b'), throwsArgumentError);
  });

  test('list reads one page; listChildren reads them all', () async {
    final api = _PagedApi();
    final docs = ChildReference(path: 'docs', api: api);

    final first = await docs.list(maxResults: 1);
    expect(first.files.map((f) => f.reference.path), ['docs/a.txt']);
    expect(first.nextPageToken, '1');

    api.tokens.clear();
    final all = await docs.listChildren();
    expect(api.tokens, [null, '1', '2']);
    expect(all.files.map((f) => f.reference.path), ['docs/a.txt', 'docs/b.txt']);
    expect(all.folders.map((f) => f.path), ['docs/sub']);
    expect(all.nextPageToken, isNull);
  });
}
