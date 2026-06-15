import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:winche_storage/winche_storage.dart';

const _baseUrl = 'https://api.test/files';

const _fileJson = {
  'id': 'rec1',
  'directory': 'userFiles/u1',
  'path': 'userFiles/u1/a.png',
  'createdAt': '2026-01-01T00:00:00Z',
  'updatedAt': '2026-01-01T00:00:00Z',
  'metadata': {'k': 'v'},
  'version': 1,
  'mimeType': 'image/png',
  'sizeBytes': 10,
  'uploadStatus': 'pending',
};

const _sessionJson = {
  'url': 'https://s3/x',
  'expiresAt': '2026-01-01T00:00:00Z'
};

(WincheStorageHttpApi, List<RequestOptions>) _stub(Object? responseData) {
  final captured = <RequestOptions>[];
  final dio = Dio(BaseOptions(baseUrl: _baseUrl));
  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) {
      captured.add(options);
      handler.resolve(Response(
          requestOptions: options, statusCode: 200, data: responseData));
    },
  ));
  return (WincheStorageHttpApi(baseUrl: _baseUrl, httpClient: dio), captured);
}

String _enc(String p) => base64Url.encode(utf8.encode(p));

void main() {
  test('setFile -> PUT /{enc} with body', () async {
    final (api, reqs) = _stub(_fileJson);
    await api
        .setFile('userFiles/u1/a.png', 'image/png', 10, metadata: {'k': 'v'});
    expect(reqs.single.method, 'PUT');
    expect(reqs.single.path, '$_baseUrl/${_enc('userFiles/u1/a.png')}');
    expect(jsonDecode(reqs.single.data as String), {
      'mimeType': 'image/png',
      'sizeBytes': 10,
      'metadata': {'k': 'v'}
    });
  });

  test('getFile -> GET /{enc}', () async {
    final (api, reqs) = _stub(_fileJson);
    await api.getFile('a');
    expect(reqs.single.method, 'GET');
    expect(reqs.single.path, '$_baseUrl/${_enc('a')}');
  });

  test('updateMetadata -> PATCH /{enc} with body', () async {
    final (api, reqs) = _stub(_fileJson);
    await api.updateMetadata('a', {'k': 'v2'});
    expect(reqs.single.method, 'PATCH');
    expect(reqs.single.path, '$_baseUrl/${_enc('a')}');
    expect(jsonDecode(reqs.single.data as String), {
      'metadata': {'k': 'v2'}
    });
  });

  test('confirmUpload -> POST /{enc}:confirm', () async {
    final (api, reqs) = _stub(_fileJson);
    await api.confirmUpload('a');
    expect(reqs.single.method, 'POST');
    expect(reqs.single.path, '$_baseUrl/${_enc('a')}:confirm');
  });

  test('generateFileUploadUrl -> POST /{enc}:upload', () async {
    final (api, reqs) = _stub(_sessionJson);
    await api.generateFileUploadUrl('a');
    expect(reqs.single.method, 'POST');
    expect(reqs.single.path, '$_baseUrl/${_enc('a')}:upload');
  });

  test('generateDownloadUrl -> POST /{enc}:download', () async {
    final (api, reqs) = _stub(_sessionJson);
    await api.generateDownloadUrl('a');
    expect(reqs.single.method, 'POST');
    expect(reqs.single.path, '$_baseUrl/${_enc('a')}:download');
  });

  test('listDirectory -> POST /{enc}:list?mimeType=', () async {
    final (api, reqs) = _stub([_fileJson]);
    await api.listDirectory('userFiles/u1', mimeType: 'image/png');
    expect(reqs.single.method, 'POST');
    expect(reqs.single.path, '$_baseUrl/${_enc('userFiles/u1')}:list');
    expect(reqs.single.queryParameters['mimeType'], 'image/png');
  });

  test('listParts -> POST /{enc}:listParts', () async {
    final (api, reqs) = _stub(<dynamic>[]);
    await api.listParts('a');
    expect(reqs.single.method, 'POST');
    expect(reqs.single.path, '$_baseUrl/${_enc('a')}:listParts');
  });

  test('generatePartUploadUrl -> POST /{enc}:signPart with partNumber body',
      () async {
    final (api, reqs) = _stub(_sessionJson);
    await api.generatePartUploadUrl('a', 3);
    expect(reqs.single.method, 'POST');
    expect(reqs.single.path, '$_baseUrl/${_enc('a')}:signPart');
    expect(jsonDecode(reqs.single.data as String), {'partNumber': 3});
  });

  test('deleteFile -> DELETE /{enc}', () async {
    final (api, reqs) = _stub(null);
    final ok = await api.deleteFile('a');
    expect(ok, isTrue);
    expect(reqs.single.method, 'DELETE');
    expect(reqs.single.path, '$_baseUrl/${_enc('a')}');
  });

  test('tokenProvider adds Authorization: Bearer header', () async {
    final captured = <RequestOptions>[];
    final dio = Dio(BaseOptions(baseUrl: _baseUrl));
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        captured.add(options);
        handler.resolve(Response(
            requestOptions: options, statusCode: 200, data: _fileJson));
      },
    ));
    final api = WincheStorageHttpApi(
      baseUrl: _baseUrl,
      tokenProvider: () async => 'tok-123',
      httpClient: dio,
    );
    await api.getFile('a');
    expect(captured.single.headers['Authorization'], 'Bearer tok-123');
  });
}
