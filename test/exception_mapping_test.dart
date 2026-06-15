import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:winche_storage/winche_storage.dart';

const _baseUrl = 'https://api.test/files';

WincheStorageHttpApi _fail(
    {int? statusCode,
    Object? data,
    DioExceptionType type = DioExceptionType.badResponse}) {
  final dio = Dio(BaseOptions(baseUrl: _baseUrl));
  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) {
      handler.reject(DioException(
        requestOptions: options,
        type: type,
        response: statusCode == null
            ? null
            : Response(
                requestOptions: options, statusCode: statusCode, data: data),
      ));
    },
  ));
  return WincheStorageHttpApi(baseUrl: _baseUrl, httpClient: dio);
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

  test('getFile 404 -> null (not thrown)', () async {
    final api = _fail(statusCode: 404, data: {'error': 'nf'});
    expect(await api.getFile('a'), isNull);
  });

  test('deleteFile 404 -> false', () async {
    final api = _fail(statusCode: 404);
    expect(await api.deleteFile('a'), isFalse);
  });

  test('receive timeout -> StorageDeadlineExceededException', () {
    final api = _fail(type: DioExceptionType.receiveTimeout);
    expect(() => api.getFile('a'),
        throwsA(isA<StorageDeadlineExceededException>()));
  });

  test('connection error -> StorageUnavailableException', () {
    final api = _fail(type: DioExceptionType.connectionError);
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
