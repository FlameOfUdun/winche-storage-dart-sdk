import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';

import '../models/download_session.dart';
import '../models/file_part.dart';
import '../models/file_data.dart';
import '../models/upload_session.dart';
import 'winche_storage_api.dart';
import 'winche_storage_exception.dart';

/// Default HTTP implementation of [WincheStorageApi] for the WincheStorage REST
/// backend. Paths are base64Url-encoded; custom operations are AIP-136 colon-verbs
/// (`POST /{enc}:upload`, etc.). Provide [tokenProvider] for `Authorization: Bearer` auth.
final class WincheStorageHttpApi implements WincheStorageApi {
  final String _baseUrl;
  final FutureOr<String> Function()? _tokenProvider;
  final Dio _httpClient;

  WincheStorageHttpApi({
    required String baseUrl,
    FutureOr<String> Function()? tokenProvider,
    Dio? httpClient,
  })  : _baseUrl = baseUrl,
        _tokenProvider = tokenProvider,
        _httpClient = httpClient ??
            Dio(BaseOptions(
              baseUrl: baseUrl,
              headers: {'content-type': 'application/json'},
            ));

  String _encode(String path) => base64Url.encode(utf8.encode(path));

  Future<Map<String, String>> _headers() async {
    final token = await _tokenProvider?.call();
    return {
      'content-type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  WincheStorageException _mapDioException(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return const StorageDeadlineExceededException(
            'Request timed out', {'statusCode': 408});
      case DioExceptionType.connectionError:
      case DioExceptionType.badCertificate:
        return StorageUnavailableException(
            e.message ?? 'Connection error', const {'statusCode': 503});
      case DioExceptionType.cancel:
        return const StorageCancelledException(
            'Request was cancelled', {'statusCode': 499});
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode ?? 500;
        final message = _messageFrom(e.response) ?? 'Request failed';
        return WincheStorageException.fromStatus(
            _statusFromHttp(code), message, {'statusCode': code});
      case DioExceptionType.unknown:
        return StorageUnknownException(
            e.message ?? 'Unknown error', const {'statusCode': -1});
    }
  }

  StorageErrorStatus _statusFromHttp(int code) {
    switch (code) {
      case 400:
        return StorageErrorStatus.invalidArgument;
      case 401:
        return StorageErrorStatus.unauthenticated;
      case 403:
        return StorageErrorStatus.permissionDenied;
      case 404:
        return StorageErrorStatus.notFound;
      case 409:
      case 412:
        return StorageErrorStatus.failedPrecondition;
      default:
        return code >= 500
            ? StorageErrorStatus.internal
            : StorageErrorStatus.unknown;
    }
  }

  String? _messageFrom(Response? res) {
    final data = res?.data;
    if (data is Map && data['error'] is String) return data['error'] as String;
    if (data is String && data.isNotEmpty) return data;
    return null;
  }

  @override
  Future<FileData> setFile(String path, String mimeType, int sizeBytes,
      {Map<String, dynamic>? metadata}) {
    return _guard(() async {
      final res = await _httpClient.put(
        '$_baseUrl/${_encode(path)}',
        options: Options(headers: await _headers()),
        data: jsonEncode({
          'mimeType': mimeType,
          'sizeBytes': sizeBytes,
          'metadata': metadata
        }),
      );
      return FileData.fromJson(res.data as Map<String, dynamic>);
    });
  }

  @override
  Future<FileData?> getFile(String path) async {
    try {
      return await _guard(() async {
        final res = await _httpClient.get(
          '$_baseUrl/${_encode(path)}',
          options: Options(headers: await _headers()),
        );
        if (res.data == null) return null;
        return FileData.fromJson(res.data as Map<String, dynamic>);
      });
    } on StorageNotFoundException {
      return null;
    }
  }

  @override
  Future<UploadSession> generateFileUploadUrl(String path) {
    return _guard(() async {
      final res = await _httpClient.post(
        '$_baseUrl/${_encode(path)}:upload',
        options: Options(headers: await _headers()),
      );
      return UploadSession.fromJson(res.data as Map<String, dynamic>);
    });
  }

  @override
  Future<DownloadSession> generateDownloadUrl(String path) {
    return _guard(() async {
      final res = await _httpClient.post(
        '$_baseUrl/${_encode(path)}:download',
        options: Options(headers: await _headers()),
      );
      return DownloadSession.fromJson(res.data as Map<String, dynamic>);
    });
  }

  @override
  Future<FileData> confirmUpload(String path) {
    return _guard(() async {
      final res = await _httpClient.post(
        '$_baseUrl/${_encode(path)}:confirm',
        options: Options(headers: await _headers()),
      );
      return FileData.fromJson(res.data as Map<String, dynamic>);
    });
  }

  @override
  Future<bool> deleteFile(String path) async {
    try {
      return await _guard(() async {
        await _httpClient.delete(
          '$_baseUrl/${_encode(path)}',
          options: Options(headers: await _headers()),
        );
        return true;
      });
    } on StorageNotFoundException {
      return false;
    }
  }

  @override
  Future<FileData> updateMetadata(String path, Map<String, dynamic> metadata) {
    return _guard(() async {
      final res = await _httpClient.patch(
        '$_baseUrl/${_encode(path)}',
        options: Options(headers: await _headers()),
        data: jsonEncode({'metadata': metadata}),
      );
      return FileData.fromJson(res.data as Map<String, dynamic>);
    });
  }

  @override
  Future<List<FileData>> listDirectory(String directory, {String? mimeType}) {
    return _guard(() async {
      final res = await _httpClient.post(
        '$_baseUrl/${_encode(directory)}:list',
        queryParameters: {if (mimeType != null) 'mimeType': mimeType},
        options: Options(headers: await _headers()),
      );
      return (res.data as List<dynamic>)
          .map((e) => FileData.fromJson(e as Map<String, dynamic>))
          .toList();
    });
  }

  @override
  Future<List<FilePart>> listParts(String path) {
    return _guard(() async {
      final res = await _httpClient.post(
        '$_baseUrl/${_encode(path)}:listParts',
        options: Options(headers: await _headers()),
      );
      return (res.data as List<dynamic>)
          .map((e) => FilePart.fromJson(e as Map<String, dynamic>))
          .toList();
    });
  }

  @override
  Future<UploadSession> generatePartUploadUrl(String path, int partNumber) {
    return _guard(() async {
      final res = await _httpClient.post(
        '$_baseUrl/${_encode(path)}:signPart',
        options: Options(headers: await _headers()),
        data: jsonEncode({'partNumber': partNumber}),
      );
      return UploadSession.fromJson(res.data as Map<String, dynamic>);
    });
  }
}
