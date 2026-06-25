import 'package:test/test.dart';
import 'package:winche_storage/winche_storage.dart';

void main() {
  test('queued is the first upload/download status', () {
    expect(UploadTaskStatus.values.first, UploadTaskStatus.queued);
    expect(DownloadTaskStatus.values.first, DownloadTaskStatus.queued);
  });
}
