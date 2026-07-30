/// Probes whether the download backend honours HTTP `Range`. The resume path
/// depends on it, and a backend that answers 206 while ignoring the range would
/// splice bytes silently.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:winche_storage/winche_storage.dart';

Future<void> main() async {
  final api = WincheStorageHttpApi(
    baseUrl: 'http://localhost:5209/files',
    tokenProvider: () async => 'alice',
  );
  const path = 'userFiles/alice/probe_range.bin';
  final bytes = Uint8List.fromList(List.filled(1024 * 1024, 0x41));

  final tmp = Directory.systemTemp.createTempSync('winche-probe');
  final src = File('${tmp.path}/src.bin')..writeAsBytesSync(bytes);

  try {
    await api.deleteFile(path).catchError((_) => false);
    final ref = ChildReference(path: path, api: api);
    await ref.uploadPath(src.path).whenDone;

    final session = await api.generateDownloadUrl(path);
    final dio = Dio(BaseOptions(validateStatus: (s) => s != null));

    const offset = 500000;
    final r = await dio.get<List<int>>(
      session.url,
      options: Options(
        responseType: ResponseType.bytes,
        headers: {'Range': 'bytes=$offset-'},
        validateStatus: (s) => s != null,
      ),
    );

    print('status:          ${r.statusCode}');
    print('content-length:  ${r.headers.value('content-length')}');
    print('content-range:   ${r.headers.value('content-range')}');
    print('accept-ranges:   ${r.headers.value('accept-ranges')}');
    print('etag:            ${r.headers.value('etag')}');
    print('body bytes:      ${r.data!.length}');
    print('expected if honoured: ${bytes.length - offset}');
    print('');
    if (r.statusCode == 206 && r.data!.length == bytes.length) {
      print('VERDICT: 206 but the FULL body — the range was ignored.');
      print('Appending this to a partial corrupts the file.');
    } else if (r.statusCode == 206) {
      print('VERDICT: range honoured.');
    } else {
      print('VERDICT: ${r.statusCode} — no partial content; the client '
          'truncates and rewrites, which is safe.');
    }
  } finally {
    await api.deleteFile(path).catchError((_) => false);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  }
}
