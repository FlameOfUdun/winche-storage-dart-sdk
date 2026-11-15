/// Probes whether the download backend honours HTTP `Range`. The resume path
/// depends on it, and a backend that answers 206 while ignoring the range would
/// splice bytes silently.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:winche_core/winche_core.dart';
import 'package:winche_storage/winche_storage.dart';

/// Signs every request in as [uid], as the emulator's test tokens allow.
final class _As extends WincheHttpInterceptor {
  _As(this.uid);
  final String uid;
  @override
  WincheRequest onRequest(WincheRequest request) => request.withHeaders({'authorization': 'Bearer $uid'});
}

/// `dart run tool/probe_range.dart [http://localhost:9090/files/v1]`
Future<void> main(List<String> args) async {
  final transport = WincheHttp.standalone()..addInterceptor(_As('alice'));
  final api = WincheStorageHttpApi(
    endpoint: Uri.parse(args.isNotEmpty ? args[0] : 'http://localhost:9090/files/v1'),
    http: transport,
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
    const offset = 500000;
    final r = await http.get(Uri.parse(session.url), headers: {'Range': 'bytes=$offset-'});

    print('status:          ${r.statusCode}');
    print('content-length:  ${r.headers['content-length']}');
    print('content-range:   ${r.headers['content-range']}');
    print('accept-ranges:   ${r.headers['accept-ranges']}');
    print('etag:            ${r.headers['etag']}');
    print('body bytes:      ${r.bodyBytes.length}');
    print('expected if honoured: ${bytes.length - offset}');
    print('');
    if (r.statusCode == 206 && r.bodyBytes.length == bytes.length) {
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
    transport.close();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  }
}
