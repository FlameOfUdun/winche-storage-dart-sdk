import 'dart:async';
import 'dart:convert';

import 'package:winche_core/winche_core.dart';

import '../models/download_session.dart';
import '../models/file_part.dart';
import '../models/file_data.dart';
import '../models/file_list_page.dart';
import '../models/upload_session.dart';
import 'winche_storage_api.dart';
import 'winche_storage_exception.dart';

/// Default HTTP implementation of [WincheStorageApi] for the WincheStorage REST
/// backend. Paths are base64Url-encoded; custom operations are AIP-136 colon-verbs
/// (`POST /{enc}:upload`, etc.).
///
/// Requests go through [WincheHttp] (usually `app.http`): with a [session] they
/// carry its token, refreshed once when refused, and fail with
/// [WincheSessionExpired] once that session has ended; without one they carry
/// none. Lookups and other requests that are safe to repeat are retried on
/// network errors and 502/503/504.
final class WincheStorageHttpApi implements WincheStorageApi {
  final Uri _endpoint;
  final WincheHttp _http;
  final WincheSession? _session;

  /// An API at [endpoint] (e.g. `https://api.example.com/files/v1`) sending
  /// through [http] as [session], or signed out without one.
  WincheStorageHttpApi({required Uri endpoint, required WincheHttp http, WincheSession? session})
      : _endpoint = endpoint,
        _http = http,
        _session = session;

  String _encode(String path) => base64Url.encode(utf8.encode(path));

  Uri _url(String path, [String verb = '', Map<String, String>? query]) {
    final base = _endpoint.toString().replaceAll(RegExp(r'/+$'), '');
    // The top folder has no path segment: POST {base}/:list.
    final url = Uri.parse('$base/${path.isEmpty ? '' : _encode(path)}$verb');
    return query == null || query.isEmpty ? url : url.replace(queryParameters: query);
  }

  Future<Object?> _send(String method, Uri url, {Object? json, bool? idempotent}) async {
    try {
      final response = await _http.send(WincheRequest(
        method,
        url,
        json: json,
        auth: _session == null ? WincheRequestAuth.none : WincheRequestAuth.required,
        session: _session,
        idempotent: idempotent,
        service: 'storage',
      ));
      try {
        return response.json;
      } on FormatException {
        return null;
      }
    } on WincheUnboundException {
      throw WincheStorageException.of(WincheErrorCode.unauthenticated, 'No auth token available for the current session.', statusCode: 401);
    } on WincheHttpException catch (e) {
      throw WincheStorageException.of(e.code, e.message, reason: e.reason, statusCode: e.status);
    }
  }

  Map<String, dynamic> _obj(Object? json) => json as Map<String, dynamic>;

  @override
  Future<FileData> setFile(String path, String mimeType, int sizeBytes,
          {Map<String, dynamic>? metadata,
          bool ifNotExists = false,
          int? ifVersion,
          String? contentDisposition,
          String? cacheControl}) async =>
      FileData.fromJson(_obj(await _send('PUT', _url(path), json: {
        'mimeType': mimeType,
        'sizeBytes': sizeBytes,
        'metadata': metadata,
        if (ifNotExists || ifVersion != null)
          'precondition': {if (ifNotExists) 'exists': false, if (ifVersion != null) 'version': ifVersion},
        if (contentDisposition != null) 'contentDisposition': contentDisposition,
        if (cacheControl != null) 'cacheControl': cacheControl,
      })));

  @override
  Future<FileData?> getFile(String path) async {
    try {
      final json = await _send('GET', _url(path));
      return json == null ? null : FileData.fromJson(_obj(json));
    } on StorageNotFoundException {
      return null;
    }
  }

  @override
  Future<UploadSession> generateFileUploadUrl(String path) async =>
      UploadSession.fromJson(_obj(await _send('POST', _url(path, ':upload'), idempotent: true)));

  @override
  Future<DownloadSession> generateDownloadUrl(String path) async =>
      DownloadSession.fromJson(_obj(await _send('POST', _url(path, ':download'), idempotent: true)));

  @override
  Future<FileData> confirmUpload(String path) async => FileData.fromJson(_obj(await _send('POST', _url(path, ':confirm'))));

  @override
  Future<bool> deleteFile(String path, {int? ifVersion}) async {
    try {
      await _send('DELETE', _url(path, '', {if (ifVersion != null) 'ifVersion': '$ifVersion'}));
      return true;
    } on StorageNotFoundException {
      return false;
    }
  }

  @override
  Future<FileData> updateMetadata(String path, Map<String, dynamic> metadata,
          {int? ifVersion, String? contentDisposition, String? cacheControl}) async =>
      FileData.fromJson(_obj(await _send('PATCH', _url(path),
          json: {
            'metadata': metadata,
            if (contentDisposition != null) 'contentDisposition': contentDisposition,
            if (cacheControl != null) 'cacheControl': cacheControl,
            if (ifVersion != null) 'precondition': {'version': ifVersion},
          },
          // A merge is safe to repeat; one held to a version isn't (the first may have moved it on).
          idempotent: ifVersion == null)));

  @override
  Future<FileListPage> list(String directory, {int? maxResults, String? pageToken, String? mimeType}) async {
    final json = await _send(
        'POST',
        _url(directory, ':list', {
          if (maxResults != null) 'maxResults': '$maxResults',
          if (pageToken != null) 'pageToken': pageToken,
          if (mimeType != null) 'mimeType': mimeType,
        }),
        idempotent: true);
    return FileListPage.fromJson(_obj(json));
  }

  @override
  Future<List<FilePart>> listParts(String path) async {
    final json = await _send('POST', _url(path, ':listParts'), idempotent: true);
    return (json as List<dynamic>).map((e) => FilePart.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<UploadSession> generatePartUploadUrl(String path, int partNumber) async =>
      UploadSession.fromJson(_obj(await _send('POST', _url(path, ':signPart'), json: {'partNumber': partNumber}, idempotent: true)));
}
