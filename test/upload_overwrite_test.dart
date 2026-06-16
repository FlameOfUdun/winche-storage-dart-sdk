import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:winche_storage/winche_storage.dart';

import 'support/noop_api.dart';

/// Captures the record-handling and transfer-path decisions [UploadTask] makes.
class _UploadApi extends NoopApi {
  _UploadApi({this.parts = const []});

  FileData? existing;
  List<FilePart> parts;
  final List<String> calls = [];

  FileData _record(int sizeBytes, String mimeType, UploadStatus status) =>
      FileData(
        id: 'rec1',
        directory: 'a',
        path: 'a/b',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
        metadata: const {},
        version: 1,
        mimeType: mimeType,
        sizeBytes: sizeBytes,
        uploadStatus: status,
      );

  @override
  Future<FileData?> getFile(String path) async {
    calls.add('getFile');
    return existing;
  }

  @override
  Future<FileData> setFile(String path, String mimeType, int sizeBytes,
      {Map<String, dynamic>? metadata}) async {
    calls.add('setFile($sizeBytes)');
    return existing = _record(sizeBytes, mimeType, UploadStatus.pending);
  }

  @override
  Future<bool> deleteFile(String path) async {
    calls.add('deleteFile');
    existing = null;
    parts = const [];
    return true;
  }

  @override
  Future<List<FilePart>> listParts(String path) async {
    calls.add('listParts');
    return parts;
  }

  @override
  Future<UploadSession> generateFileUploadUrl(String path) async {
    calls.add('upload');
    return UploadSession(
      url: 'https://upload.example/whole',
      expiresAt: DateTime.utc(2030, 1, 1),
    );
  }

  @override
  Future<UploadSession> generatePartUploadUrl(
      String path, int partNumber) async {
    calls.add('signPart($partNumber)');
    return UploadSession(
      url: 'https://upload.example/part/$partNumber',
      expiresAt: DateTime.utc(2030, 1, 1),
    );
  }

  @override
  Future<FileData> confirmUpload(String path) async {
    calls.add('confirm');
    return existing!.copyWith(uploadStatus: UploadStatus.complete);
  }
}

/// Returns HTTP 200 for every PUT so the upload progresses.
class _OkAdapter implements HttpClientAdapter {
  int puts = 0;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    puts++;
    return ResponseBody.fromBytes(<int>[], 200);
  }

  @override
  void close({bool force = false}) {}
}

UploadTask _start(
  _UploadApi api,
  Uint8List bytes, {
  String mime = 'image/png',
  int threshold = 5 * 1024 * 1024,
}) {
  final dio = Dio(BaseOptions(validateStatus: (s) => s != null))
    ..httpClientAdapter = _OkAdapter();
  return UploadTask.startFromBytes(
    reference: ChildReference(path: 'a/b', api: api),
    bytes: bytes,
    mimeType: mime,
    multipartThreshold: threshold,
    httpClient: dio,
  );
}

void main() {
  group('single-shot (size <= threshold)', () {
    test('no existing record: setFile then single PUT', () async {
      final api = _UploadApi();
      await _start(api, Uint8List(3)).whenDone;
      expect(api.calls, ['getFile', 'setFile(3)', 'upload', 'confirm']);
    });

    test('empty file uploads via single-shot (was broken under multipart)',
        () async {
      final api = _UploadApi();
      await _start(api, Uint8List(0)).whenDone;
      expect(api.calls, ['getFile', 'setFile(0)', 'upload', 'confirm']);
    });

    test('complete + identical size/mime: skip', () async {
      final api = _UploadApi()
        ..existing =
            _UploadApi()._record(3, 'image/png', UploadStatus.complete);
      await _start(api, Uint8List(3)).whenDone;
      expect(api.calls, ['getFile']);
    });

    test('complete + different size: delete + setFile + re-upload', () async {
      final api = _UploadApi()
        ..existing =
            _UploadApi()._record(10, 'image/png', UploadStatus.complete);
      await _start(api, Uint8List(3)).whenDone;
      expect(
          api.calls, ['getFile', 'deleteFile', 'setFile(3)', 'upload', 'confirm']);
    });

    test('incomplete + matching: re-upload whole object (no parts)', () async {
      final api = _UploadApi()
        ..existing = _UploadApi()._record(3, 'image/png', UploadStatus.pending);
      await _start(api, Uint8List(3)).whenDone;
      expect(api.calls, ['getFile', 'upload', 'confirm']);
    });

    test('incomplete + different size: discard + replace (the stuck-path bug)',
        () async {
      final api = _UploadApi()
        ..existing =
            _UploadApi()._record(10, 'image/png', UploadStatus.pending);
      await _start(api, Uint8List(3)).whenDone;
      expect(
          api.calls, ['getFile', 'deleteFile', 'setFile(3)', 'upload', 'confirm']);
    });
  });

  group('multipart (size > threshold)', () {
    test('no existing record: setFile then one signed PUT per part', () async {
      final api = _UploadApi();
      // threshold 4, size 10 -> parts of 4, 4, 2.
      await _start(api, Uint8List(10), threshold: 4).whenDone;
      expect(api.calls, [
        'getFile',
        'setFile(10)',
        'signPart(1)',
        'signPart(2)',
        'signPart(3)',
        'confirm',
      ]);
    });

    test('incomplete + matching: resume from last completed part', () async {
      final api = _UploadApi(parts: const [
        FilePart(number: 1, size: 4),
        FilePart(number: 2, size: 4),
      ])..existing = _UploadApi()._record(10, 'image/png', UploadStatus.pending);
      await _start(api, Uint8List(10), threshold: 4).whenDone;
      expect(
          api.calls, ['getFile', 'listParts', 'signPart(3)', 'confirm']);
    });
  });
}
