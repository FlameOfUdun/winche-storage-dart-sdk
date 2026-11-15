import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_storage/winche_storage.dart';

final _endpoint = Uri.parse('https://api.test/files/v1');

enum _Failure { timeout, connection }

WincheStorageHttpApi _fail({int? statusCode, Object? data, _Failure? type}) {
  final client = MockClient((request) async {
    switch (type) {
      case _Failure.timeout:
        return Completer<http.Response>().future;
      case _Failure.connection:
        throw http.ClientException('connection refused', request.url);
      case null:
        return http.Response(data == null ? '' : jsonEncode(data), statusCode!);
    }
  });
  final transport = WincheHttp.standalone(client: client)
    ..retryDelay = Duration.zero
    ..timeout = const Duration(milliseconds: 20);
  return WincheStorageHttpApi(endpoint: _endpoint, http: transport);
}

void main() {
  test('403 -> StoragePermissionDeniedException', () {
    final api = _fail(statusCode: 403, data: {'error': 'denied'});
    expect(() => api.setFile('a', 'image/png', 1),
        throwsA(isA<StoragePermissionDeniedException>()));
  });

  test('400 -> StorageInvalidArgumentException', () {
    final api = _fail(statusCode: 400, data: {'error': 'bad'});
    expect(() => api.confirmUpload('a'),
        throwsA(isA<StorageInvalidArgumentException>()));
  });

  test('413 (over the size limit) -> StorageInvalidArgumentException, not retried', () {
    final api = _fail(statusCode: 413, data: {'error': 'too large'});
    expect(() => api.setFile('a', 'video/mp4', 1 << 40),
        throwsA(isA<StorageInvalidArgumentException>()));
  });

  test('getFile 404 -> null (not thrown)', () async {
    final api = _fail(statusCode: 404, data: {'error': 'nf'});
    expect(await api.getFile('a'), isNull);
  });

  test('deleteFile 404 -> false', () async {
    final api = _fail(statusCode: 404);
    expect(await api.deleteFile('a'), isFalse);
  });

  test('receive timeout -> StorageDeadlineExceededException', () {
    final api = _fail(type: _Failure.timeout);
    expect(() => api.getFile('a'),
        throwsA(isA<StorageDeadlineExceededException>()));
  });

  test('connection error -> StorageUnavailableException', () {
    final api = _fail(type: _Failure.connection);
    expect(() => api.confirmUpload('a'),
        throwsA(isA<StorageUnavailableException>()));
  });

  test('error message comes from response body error field', () async {
    final api = _fail(statusCode: 403, data: {'error': 'access denied msg'});
    try {
      await api.setFile('a', 'image/png', 1);
      fail('expected throw');
    } on WincheStorageException catch (e) {
      expect(e.message, 'access denied msg');
      expect(e.statusCode, 403);
    }
  });
}
