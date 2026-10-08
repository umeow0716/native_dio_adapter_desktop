import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:native_dio_adapter_desktop/native_dio_adapter_desktop.dart';

void main() {
  Dio client(http.Client transport) =>
      Dio()..httpClientAdapter = WinHttpAdapter.fromClient(transport);

  test('passes method, URL, headers, and encoded body through Dio', () async {
    final dio = client(
      MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.queryParameters['x'], '1');
        expect(request.headers['x-test'], 'hello');
        expect(jsonDecode(request.body), {'name': '測試'});
        return http.Response(
          '{"ok":true}',
          201,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final response = await dio.post(
      'https://example.test/api?x=1',
      data: {'name': '測試'},
      options: Options(headers: {'X-Test': 'hello'}),
    );
    expect(response.statusCode, 201);
    expect(response.data, {'ok': true});
    dio.close();
  });

  test(
    'preserves redirect policy, location and cookies with Expires commas',
    () async {
      final transport = RecordingClient((request) async {
        expect(request.followRedirects, false);
        expect(request.maxRedirects, 3);
        return http.StreamedResponse(
          Stream.value(<int>[]),
          302,
          headers: {
            'location': '/final',
            'set-cookie':
                'a=1; Expires=Wed, 21 Oct 2030 07:28:00 GMT, b=2; Path=/',
          },
          isRedirect: true,
        );
      });
      final dio = client(transport);
      final response = await dio.get(
        'https://example.test/start',
        options: Options(
          followRedirects: false,
          maxRedirects: 3,
          validateStatus: (_) => true,
        ),
      );
      expect(response.statusCode, 302);
      expect(response.headers['location'], ['/final']);
      expect(response.headers['set-cookie'], [
        'a=1; Expires=Wed, 21 Oct 2030 07:28:00 GMT',
        'b=2; Path=/',
      ]);
      expect(response.isRedirect, true);
      dio.close();
    },
  );

  test('Dio owns status validation', () async {
    final dio = client(MockClient((_) async => http.Response('denied', 403)));
    await expectLater(
      dio.get('https://example.test'),
      throwsA(
        isA<DioException>()
            .having((e) => e.type, 'type', DioExceptionType.badResponse)
            .having((e) => e.response?.statusCode, 'status', 403),
      ),
    );
    dio.close();
  });

  test(
    'converts List<int> response chunks and supports byte responses',
    () async {
      final dio = client(
        RecordingClient(
          (_) async => http.StreamedResponse(
            Stream.fromIterable([
              <int>[1, 2],
              <int>[3],
            ]),
            200,
          ),
        ),
      );
      final response = await dio.get<List<int>>(
        'https://example.test',
        options: Options(responseType: ResponseType.bytes),
      );
      expect(response.data, [1, 2, 3]);
      dio.close();
    },
  );

  test('uploads multipart without re-encoding it', () async {
    final dio = client(
      MockClient((request) async {
        expect(
          request.headers['content-type'],
          contains('multipart/form-data; boundary='),
        );
        expect(request.body, contains('name="field"'));
        expect(request.body, contains('value'));
        expect(request.body, contains('filename="test.txt"'));
        expect(request.body, contains('file-content'));
        return http.Response('ok', 200);
      }),
    );
    await dio.post(
      'https://example.test',
      data: FormData.fromMap({
        'field': 'value',
        'file': MultipartFile.fromString('file-content', filename: 'test.txt'),
      }),
    );
    dio.close();
  });

  test('cancellation aborts the native request before headers', () async {
    final started = Completer<void>();
    final aborted = Completer<void>();
    final dio = client(
      RecordingClient((request) {
        started.complete();
        (request as http.AbortableRequest).abortTrigger!.then(
          (_) => aborted.complete(),
        );
        return Completer<http.StreamedResponse>().future;
      }),
    );
    final token = CancelToken();
    final response = dio.get('https://example.test', cancelToken: token);
    await started.future;
    token.cancel('cancel');
    await expectLater(
      response,
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    await aborted.future;
    dio.close();
  });

  test('cancels a pending upload subscription without sending', () async {
    var sent = false;
    final source = StreamController<Uint8List>();
    final transport = RecordingClient((_) async {
      sent = true;
      return http.StreamedResponse(Stream.empty(), 200);
    });
    final adapter = WinHttpAdapter.fromClient(transport);
    final cancellation = Completer<void>();
    final response = adapter.fetch(
      RequestOptions(path: 'https://example.test'),
      source.stream,
      cancellation.future,
    );
    cancellation.complete();
    await expectLater(
      response,
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    expect(source.hasListener, false);
    expect(sent, false);
    await source.close();
    adapter.close();
  });

  test('send timeout cancels a stalled upload', () async {
    final source = StreamController<Uint8List>();
    final adapter = WinHttpAdapter.fromClient(
      MockClient((_) async => http.Response('', 200)),
    );
    final response = adapter.fetch(
      RequestOptions(
        path: 'https://example.test',
        sendTimeout: const Duration(milliseconds: 20),
      ),
      source.stream,
      null,
    );
    await expectLater(
      response,
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.sendTimeout,
        ),
      ),
    );
    expect(source.hasListener, false);
    await source.close();
    adapter.close();
  });

  test('header timeout aborts a pending request', () async {
    final dio = client(
      RecordingClient((_) => Completer<http.StreamedResponse>().future),
    );
    dio.options.receiveTimeout = const Duration(milliseconds: 20);
    await expectLater(
      dio.get('https://example.test'),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.receiveTimeout,
        ),
      ),
    );
    dio.close();
  });

  test('receive timeout applies to gaps between body chunks', () async {
    final source = StreamController<List<int>>();
    final dio = client(
      RecordingClient((_) async => http.StreamedResponse(source.stream, 200)),
    );
    dio.options.receiveTimeout = const Duration(milliseconds: 20);
    await expectLater(
      dio.get('https://example.test'),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.receiveTimeout,
        ),
      ),
    );
    expect(source.hasListener, false);
    await source.close();
    dio.close();
  });

  test(
    'graceful close lets active requests finish and rejects new ones',
    () async {
      final headers = Completer<http.StreamedResponse>();
      final started = Completer<void>();
      final transport = RecordingClient((_) {
        started.complete();
        return headers.future;
      });
      final adapter = WinHttpAdapter.fromClient(transport);
      final response = adapter.fetch(
        RequestOptions(path: 'https://example.test'),
        null,
        null,
      );
      await started.future;
      adapter.close();
      expect(transport.closed, false);
      await expectLater(
        adapter.fetch(RequestOptions(path: 'https://example.test'), null, null),
        throwsStateError,
      );
      headers.complete(http.StreamedResponse(Stream.value([1]), 200));
      expect(await (await response).stream.expand((e) => e).toList(), [1]);
      expect(transport.closed, true);
    },
  );

  test('force close cancels active requests', () async {
    final started = Completer<void>();
    final transport = RecordingClient((_) {
      started.complete();
      return Completer<http.StreamedResponse>().future;
    });
    final adapter = WinHttpAdapter.fromClient(transport);
    final response = adapter.fetch(
      RequestOptions(path: 'https://example.test'),
      null,
      null,
    );
    await started.future;
    adapter.close(force: true);
    await expectLater(
      response,
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    expect(transport.closed, true);
  });

  test('already cancelled requests never initialize a client', () async {
    var created = false;
    final adapter = WinHttpAdapter(
      createConfiguration: () {
        created = true;
        return const WinHttpClientConfiguration();
      },
    );
    final token = CancelToken()..cancel();
    await expectLater(
      adapter.fetch(
        RequestOptions(path: 'https://example.test', cancelToken: token),
        null,
        null,
      ),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    expect(created, false);
    adapter.close();
  });

  test(
    'cancelling the response subscription releases the native stream',
    () async {
      final source = StreamController<List<int>>();
      final transport = RecordingClient(
        (_) async => http.StreamedResponse(source.stream, 200),
      );
      final adapter = WinHttpAdapter.fromClient(transport);
      final body = await adapter.fetch(
        RequestOptions(path: 'https://example.test'),
        null,
        null,
      );
      final subscription = body.stream.listen((_) {});
      await Future<void>.delayed(Duration.zero);
      expect(source.hasListener, true);
      await subscription.cancel();
      expect(source.hasListener, false);
      adapter.close();
      expect(transport.closed, true);
      await source.close();
    },
  );

  test('force close also aborts a streaming body', () async {
    final source = StreamController<List<int>>();
    final adapter = WinHttpAdapter.fromClient(
      RecordingClient((_) async => http.StreamedResponse(source.stream, 200)),
    );
    final body = await adapter.fetch(
      RequestOptions(path: 'https://example.test'),
      null,
      null,
    );
    final consumed = body.stream.toList();
    adapter.close(force: true);
    await expectLater(
      consumed,
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    expect(source.hasListener, false);
    await source.close();
  });

  test('receive timer pauses while the consumer pauses', () async {
    final source = StreamController<List<int>>();
    final adapter = WinHttpAdapter.fromClient(
      RecordingClient((_) async => http.StreamedResponse(source.stream, 200)),
    );
    final body = await adapter.fetch(
      RequestOptions(
        path: 'https://example.test',
        receiveTimeout: const Duration(milliseconds: 50),
      ),
      null,
      null,
    );
    final completed = Completer<void>();
    final chunks = <int>[];
    final subscription = body.stream.listen(
      chunks.addAll,
      onError: completed.completeError,
      onDone: completed.complete,
    );
    subscription.pause();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    source.add([1]);
    unawaited(source.close());
    subscription.resume();
    await completed.future;
    expect(chunks, [1]);
    adapter.close();
  });

  test('closing a fresh adapter never creates the native client', () {
    var created = false;
    final adapter = WinHttpAdapter(
      createConfiguration: () {
        created = true;
        return const WinHttpClientConfiguration();
      },
    );
    adapter.close();
    expect(created, false);
  });
}

class RecordingClient extends http.BaseClient {
  RecordingClient(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
  @override
  void close() => closed = true;
}
