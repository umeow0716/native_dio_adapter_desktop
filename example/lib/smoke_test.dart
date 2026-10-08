import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:native_dio_adapter_desktop/native_dio_adapter_desktop.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> runSmokeTests() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final base = 'http://127.0.0.1:${server.port}';
  final slowStarted = Completer<void>();
  final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var proxyHits = 0;
  var connectHits = 0;
  final serverSubscription = server.listen((request) async {
    try {
      switch (request.uri.path) {
        case '/redirect':
          request.response.statusCode = 302;
          request.response.headers.set('location', '/cookies');
        case '/loop':
          request.response.statusCode = 302;
          request.response.headers.set('location', '/loop');
        case '/cookies':
          request.response.headers.add(
            'set-cookie',
            'one=1; Expires=Wed, 21 Oct 2030 07:28:00 GMT; Path=/',
          );
          request.response.headers.add('set-cookie', 'two=2; Path=/');
          request.response.headers.contentType = ContentType.text;
          request.response.write('原生連線');
        case '/echo':
          final body = await utf8.decoder.bind(request).join();
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'method': request.method,
              'body': body,
              'cookie': request.headers.value('cookie'),
              'type': request.headers.contentType.toString(),
            }),
          );
        case '/slow':
          if (!slowStarted.isCompleted) slowStarted.complete();
          await Future<void>.delayed(const Duration(milliseconds: 500));
          request.response.write('late');
        case '/stalled-body':
          request.response.headers.contentType = ContentType.text;
          request.response.write('first');
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 500));
          request.response.write('last');
        default:
          request.response.statusCode = 403;
          request.response.write('denied');
      }
      await request.response.close();
    } catch (_) {
      // Tests deliberately cancel sockets while the server is responding.
    }
  });
  final proxySubscription = proxy.listen((request) async {
    proxyHits++;
    if (request.method == 'CONNECT') {
      connectHits++;
      final upstream = await Socket.connect('example.com', 443);
      request.response.statusCode = 200;
      request.response.contentLength = 0;
      final downstream = await request.response.detachSocket();
      downstream.listen(
        upstream.add,
        onDone: upstream.destroy,
        onError: (Object _) => upstream.destroy(),
      );
      upstream.listen(
        downstream.add,
        onDone: downstream.destroy,
        onError: (Object _) => downstream.destroy(),
      );
      return;
    }
    await request.drain<void>();
    request.response.headers.contentType = ContentType.text;
    request.response.write('proxy:${request.uri.host}');
    await request.response.close();
  });
  final dio =
      Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 3),
            receiveTimeout: const Duration(seconds: 3),
          ),
        )
        ..httpClientAdapter = NativeDesktopAdapter(
          createWinHttpConfiguration: () => const WinHttpClientConfiguration(
            accessType: WinHttpAccessType.noProxy,
          ),
          createRhttpSettings: () =>
              const ClientSettings(proxySettings: ProxySettings.noProxy()),
        );
  Dio? proxied;
  try {
    final redirect = await dio.get(
      '$base/redirect',
      options: Options(followRedirects: false, validateStatus: (_) => true),
    );
    check(redirect.statusCode == 302, 'followRedirects:false must return 302');
    check(redirect.headers.value('location') == '/cookies', 'Location missing');
    final cookies = await dio.get('$base/cookies');
    check(cookies.data == '原生連線', 'UTF-8 response corrupted');
    check(cookies.headers['set-cookie']?.length == 2, 'Repeated cookies lost');
    final followed = await dio.get('$base/redirect');
    check(
      followed.statusCode == 200 && followed.data == '原生連線',
      'Native redirects failed',
    );
    try {
      await dio.get('$base/loop', options: Options(maxRedirects: 2));
      throw StateError('Redirect limit was ignored');
    } on DioException catch (error) {
      check(error.response?.statusCode != 200, 'Unexpected loop response');
    }
    final echo = await dio.post(
      '$base/echo',
      data: {'name': '測試'},
      options: Options(headers: {'cookie': 'manual=1'}),
    );
    check(echo.data['method'] == 'POST', 'POST changed');
    check(
      jsonDecode(echo.data['body'])['name'] == '測試',
      'JSON upload corrupted',
    );
    check(echo.data['cookie'] == 'manual=1', 'Explicit cookie lost');
    final noCookies = await dio.post('$base/echo', data: 'plain');
    check(
      noCookies.data['cookie'] == null,
      'Native cookie jar must remain disabled',
    );
    final multipart = await dio.post(
      '$base/echo',
      data: FormData.fromMap({
        'field': 'hello',
        'file': MultipartFile.fromString('content', filename: 'file.txt'),
      }),
    );
    check(
      (multipart.data['body'] as String).contains('filename="file.txt"'),
      'Multipart lost',
    );
    try {
      await dio.get('$base/denied');
      throw StateError('Dio status validation bypassed');
    } on DioException catch (error) {
      check(
        error.type == DioExceptionType.badResponse,
        'Wrong status error type',
      );
    }
    final token = CancelToken();
    final slow = dio.get('$base/slow', cancelToken: token);
    await slowStarted.future;
    token.cancel('smoke');
    try {
      await slow;
      throw StateError('Cancellation ignored');
    } on DioException catch (error) {
      check(error.type == DioExceptionType.cancel, 'Wrong cancellation error');
    }
    try {
      await dio.get(
        '$base/stalled-body',
        options: Options(receiveTimeout: const Duration(milliseconds: 100)),
      );
      throw StateError('Body timeout ignored');
    } on DioException catch (error) {
      check(
        error.type == DioExceptionType.receiveTimeout,
        'Wrong body timeout error',
      );
    }
    proxied = Dio()
      ..httpClientAdapter = NativeDesktopAdapter(
        createWinHttpConfiguration: () => WinHttpClientConfiguration(
          accessType: WinHttpAccessType.named,
          proxy: '127.0.0.1:${proxy.port}',
        ),
        createRhttpSettings: () => ClientSettings(
          proxySettings: ProxySettings.proxy('http://127.0.0.1:${proxy.port}'),
        ),
      );
    final viaProxy = await proxied.get('http://native-adapter.invalid/test');
    check(
      viaProxy.data == 'proxy:native-adapter.invalid' && proxyHits == 1,
      'Explicit proxy was not used',
    );
    // Public HTTPS exercises the actual native TLS stack and trusted roots.
    final tls = await dio.get(
      'https://example.com',
      options: Options(responseType: ResponseType.plain),
    );
    check(tls.statusCode == 200, 'Native TLS failed');
    final proxyTls = await proxied.get(
      'https://example.com',
      options: Options(responseType: ResponseType.plain),
    );
    check(
      proxyTls.statusCode == 200 && connectHits == 1,
      'HTTPS CONNECT proxy failed',
    );
    stdout.writeln(
      'PASS: redirect policy, cookies, UTF-8, uploads, status, cancel, body timeout, proxy, TLS',
    );
  } finally {
    dio.close(force: true);
    proxied?.close(force: true);
    await serverSubscription.cancel();
    await proxySubscription.cancel();
    await server.close(force: true);
    await proxy.close(force: true);
  }
}
