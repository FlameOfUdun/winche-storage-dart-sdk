import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:winche_core/winche_core.dart';

/// A client whose network is [answer]: it sees each request (its body already
/// read, so upload progress has run) and returns the response.
WincheHttp fakeHttp(FutureOr<http.StreamedResponse> Function(http.BaseRequest request) answer) =>
    WincheHttp.standalone(
      client: MockClient.streaming((request, body) async {
        await body.drain<void>();
        return answer(request);
      }),
    );

/// A client answering every request 200 with no body.
WincheHttp okHttp() => fakeHttp((_) => respond(const []));

/// A response with [body].
http.StreamedResponse respond(List<int> body, {int status = 200, Map<String, String> headers = const {}, int? contentLength}) =>
    http.StreamedResponse(Stream.value(body), status, headers: headers, contentLength: contentLength ?? body.length);
