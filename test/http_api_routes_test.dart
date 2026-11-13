import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:winche_core/testing.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_storage/winche_storage.dart';

const _baseUrl = 'https://api.test/files/v1';

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

MockClient _answering(Object? responseData, List<http.Request> captured) => MockClient((request) async {
      captured.add(request);
      return http.Response(responseData == null ? '' : jsonEncode(responseData), 200);
    });

(WincheStorageHttpApi, List<http.Request>) _stub(Object? responseData) {
  final captured = <http.Request>[];
  final api = WincheStorageHttpApi(
    endpoint: Uri.parse(_baseUrl),
    http: WincheHttp.standalone(client: _answering(responseData, captured)),
  );
  return (api, captured);
}

/// Hands over the session core builds, like the storage service does.
final class _Grab extends WincheService implements WincheSessionConsumer {
  _Grab(super.app);
  WincheSession? session;
  @override
  Future<void> onSessionChanged(WincheSession? session) async => this.session = session;
  @override
  Future<void> onTokenChanged() async {}
}

String _enc(String p) => base64Url.encode(utf8.encode(p));

void main() {
  test('setFile -> PUT /{enc} with body', () async {
    final (api, reqs) = _stub(_fileJson);
    await api
        .setFile('userFiles/u1/a.png', 'image/png', 10, metadata: {'k': 'v'});
    expect(reqs.single.method, 'PUT');
    expect(_where(reqs.single), '$_baseUrl/${_enc('userFiles/u1/a.png')}');
    expect(jsonDecode(reqs.single.body), {
      'mimeType': 'image/png',
      'sizeBytes': 10,
      'metadata': {'k': 'v'}
    });
  });

  test('getFile -> GET /{enc}', () async {
    final (api, reqs) = _stub(_fileJson);
    await api.getFile('a');
    expect(reqs.single.method, 'GET');
    expect(_where(reqs.single), '$_baseUrl/${_enc('a')}');
  });

  test('updateMetadata -> PATCH /{enc} with body', () async {
    final (api, reqs) = _stub(_fileJson);
    await api.updateMetadata('a', {'k': 'v2'});
    expect(reqs.single.method, 'PATCH');
    expect(_where(reqs.single), '$_baseUrl/${_enc('a')}');
    expect(jsonDecode(reqs.single.body), {
      'metadata': {'k': 'v2'}
    });
  });

  test('confirmUpload -> POST /{enc}:confirm', () async {
    final (api, reqs) = _stub(_fileJson);
    await api.confirmUpload('a');
    expect(reqs.single.method, 'POST');
    expect(_where(reqs.single), '$_baseUrl/${_enc('a')}:confirm');
  });

  test('generateFileUploadUrl -> POST /{enc}:upload', () async {
    final (api, reqs) = _stub(_sessionJson);
    await api.generateFileUploadUrl('a');
    expect(reqs.single.method, 'POST');
    expect(_where(reqs.single), '$_baseUrl/${_enc('a')}:upload');
  });

  test('generateDownloadUrl -> POST /{enc}:download', () async {
    final (api, reqs) = _stub(_sessionJson);
    await api.generateDownloadUrl('a');
    expect(reqs.single.method, 'POST');
    expect(_where(reqs.single), '$_baseUrl/${_enc('a')}:download');
  });

  test('listDirectory -> POST /{enc}:list?mimeType=', () async {
    final (api, reqs) = _stub([_fileJson]);
    await api.listDirectory('userFiles/u1', mimeType: 'image/png');
    expect(reqs.single.method, 'POST');
    expect(_where(reqs.single), '$_baseUrl/${_enc('userFiles/u1')}:list');
    expect(reqs.single.url.queryParameters['mimeType'], 'image/png');
  });

  test('listParts -> POST /{enc}:listParts', () async {
    final (api, reqs) = _stub(<dynamic>[]);
    await api.listParts('a');
    expect(reqs.single.method, 'POST');
    expect(_where(reqs.single), '$_baseUrl/${_enc('a')}:listParts');
  });

  test('generatePartUploadUrl -> POST /{enc}:signPart with partNumber body',
      () async {
    final (api, reqs) = _stub(_sessionJson);
    await api.generatePartUploadUrl('a', 3);
    expect(reqs.single.method, 'POST');
    expect(_where(reqs.single), '$_baseUrl/${_enc('a')}:signPart');
    expect(jsonDecode(reqs.single.body), {'partNumber': 3});
  });

  test('deleteFile -> DELETE /{enc}', () async {
    final (api, reqs) = _stub(null);
    final ok = await api.deleteFile('a');
    expect(ok, isTrue);
    expect(reqs.single.method, 'DELETE');
    expect(_where(reqs.single), '$_baseUrl/${_enc('a')}');
  });

  test("a session-bound API sends that session's token", () async {
    final app = WincheApp('routes');
    final auth = ScriptedAuthService(app);
    final grab = _Grab(app);
    auth.announce(WincheIdentity('u1'));
    await app.settled;
    final captured = <http.Request>[];
    final api = WincheStorageHttpApi(
      endpoint: Uri.parse(_baseUrl),
      http: WincheHttp.standalone(client: _answering(_fileJson, captured)),
      session: grab.session,
    );
    await api.getFile('a');
    expect(captured.single.headers['authorization'], 'Bearer token-u1-0');
    await app.dispose();
  });

  test('without a session, no token is sent', () async {
    final (api, reqs) = _stub(_fileJson);
    await api.getFile('a');
    expect(reqs.single.headers['authorization'], isNull);
  });
}

String _where(http.Request r) => '${r.url.origin}${r.url.path}';
