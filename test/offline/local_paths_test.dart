import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winche_storage/src/offline/local_paths.dart';

void main() {
  test('uses source name extension when id has none', () {
    expect(localFileName('abc123', sourceName: 'photo.JPG'), 'abc123.JPG');
  });

  test('does not double-append when id already has the extension', () {
    expect(localFileName('abc123.jpg', sourceName: 'photo.jpg'), 'abc123.jpg');
  });

  test('falls back to mimeType when source has no extension', () {
    expect(localFileName('abc', sourceName: 'noext', mimeType: 'image/png'),
        'abc.png');
  });

  test('returns bare id when neither yields an extension', () {
    expect(localFileName('abc', sourceName: 'noext'), 'abc');
  });

  test('joins under a directory using the platform separator', () {
    expect(
      localFilePath('/cache', 'abc', sourceName: 'photo.jpg'),
      p.normalize(p.join('/cache', 'abc.jpg')),
    );
  });

  test('normalizes a directory with mixed separators', () {
    // A directory built with a stray forward slash still yields a clean path.
    final result =
        localFilePath('${p.join('root', 'a')}/b', 'id', sourceName: 'x.png');
    expect(result, p.join('root', 'a', 'b', 'id.png'));
  });

  test('stagingFilePath is under .staging, hashed, and extension-free', () {
    final a = stagingFilePath('/cache', 'a/b.png');
    expect(p.split(a), containsAllInOrder(['.staging']));
    expect(p.basename(a), isNot(contains('.'))); // no extension
    expect(a, p.normalize(a));
  });

  test('stagingFilePath is deterministic and unique per ref path', () {
    expect(stagingFilePath('/cache', 'a/b.png'),
        stagingFilePath('/cache', 'a/b.png'));
    expect(stagingFilePath('/cache', 'a/b.png'),
        isNot(stagingFilePath('/cache', 'a/c.png')));
  });
}
