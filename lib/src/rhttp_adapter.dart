import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:native_dio_adapter_desktop/src/rhttp/rhttp.dart' as rhttp;

import 'conversion_layer_adapter.dart';

/// Dio transport backed by Rust reqwest/rustls on Linux.
class RhttpAdapter extends ConversionLayerAdapter {
  /// Automatically initializes rhttp before the first request.
  ///
  /// Dio owns redirects and status validation. Native cookies are disabled so
  /// Dio cookie interceptors remain authoritative. Proxy/TLS/DNS settings are
  /// supplied by [createSettings], once, on first use.
  RhttpAdapter({
    rhttp.ClientSettings Function()? createSettings,
    bool initializeRhttp = true,
  }) : super(() => _RhttpClient(createSettings, initializeRhttp));
}

/// The http conversion boundary is shared with WinHTTP. Unlike rhttp's stock
/// compatible client, this bridge honors each request's redirect policy and
/// retains the original response header lists.
class _RhttpClient extends http.BaseClient {
  _RhttpClient(this._createSettings, this._initializeRhttp);

  final rhttp.ClientSettings Function()? _createSettings;
  final bool _initializeRhttp;
  final _clients = <(bool, int), Future<rhttp.RhttpClient>>{};
  late final _settings =
      (_createSettings?.call() ?? const rhttp.ClientSettings()).copyWith(
        baseUrl: null,
        throwOnStatusCode: false,
        cookieSettings: const rhttp.CookieSettings.none(),
      );
  bool _closed = false;
  static Future<void>? _initialization;

  Future<rhttp.RhttpClient> _client(http.BaseRequest request) => _clients
      .putIfAbsent((request.followRedirects, request.maxRedirects), () async {
        try {
          if (_initializeRhttp) {
            await (_initialization ??= rhttp.Rhttp.init());
          }
        } catch (_) {
          _initialization = null;
          rethrow;
        }
        if (_closed) {
          throw http.ClientException('Adapter is closed.', request.url);
        }
        return rhttp.RhttpClient.create(
          settings: _settings.copyWith(
            redirectSettings: request.followRedirects
                ? rhttp.RedirectSettings.limited(request.maxRedirects)
                : const rhttp.RedirectSettings.none(),
          ),
        );
      });

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw http.ClientException('Adapter is closed.', request.url);
    final bytes = await request.finalize().toBytes();
    final client = await _client(request);
    if (_closed) throw http.ClientException('Adapter is closed.', request.url);
    final token = rhttp.CancelToken();
    var nativeFinished = false;
    if (request case http.Abortable(abortTrigger: final trigger?)) {
      unawaited(
        trigger.then((_) async {
          if (!nativeFinished) await token.cancel();
        }),
      );
    }
    final rhttp.HttpStreamResponse response;
    try {
      response = await client.requestStream(
        method: rhttp.HttpMethod(request.method),
        url: request.url.toString(),
        headers: rhttp.HttpHeaders.rawMap(request.headers),
        body: bytes.isEmpty ? null : rhttp.HttpBody.bytes(bytes),
        cancelToken: token,
      );
    } catch (_) {
      nativeFinished = true;
      rethrow;
    }
    return _RhttpResponse(
      response,
      request,
      token,
      () => nativeFinished = true,
    );
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final client in _clients.values) {
      unawaited(
        client.then(
          (value) => value.dispose(cancelRunningRequests: true),
          onError: (Object _, StackTrace _) {},
        ),
      );
    }
    _clients.clear();
  }
}

class _RhttpResponse extends http.StreamedResponse
    implements MultiValueHeaders {
  _RhttpResponse(
    rhttp.HttpStreamResponse response,
    http.BaseRequest request,
    rhttp.CancelToken token,
    void Function() onNativeDone,
  ) : headerLists = response.headerMapList,
      super(
        _nativeBody(response.body, token, onNativeDone),
        response.statusCode,
        request: request,
        headers: response.headerMap,
        isRedirect:
            !request.followRedirects &&
            response.statusCode >= 300 &&
            response.statusCode < 400,
      );

  @override
  final Map<String, List<String>> headerLists;
}

// Keep listening until Rust acknowledges cancellation. Cancelling the FRB
// subscription immediately can discard its sink while Rust is still sending
// STREAM_CANCEL_ERROR, causing an uncaught asynchronous codec exception.
Stream<List<int>> _nativeBody(
  Stream<List<int>> source,
  rhttp.CancelToken token,
  void Function() onNativeDone,
) {
  late StreamController<List<int>> controller;
  late StreamSubscription<List<int>> subscription;
  final drained = Completer<void>();
  var discarding = false;
  controller = StreamController<List<int>>(
    onPause: () => subscription.pause(),
    onResume: () => subscription.resume(),
    onCancel: () async {
      if (drained.isCompleted) return;
      discarding = true;
      subscription.resume();
      await token.cancel();
      await drained.future;
    },
  );
  subscription = source.listen(
    (chunk) {
      if (!discarding) controller.add(chunk);
    },
    onError: (Object error, StackTrace stack) {
      if (!discarding) controller.addError(error, stack);
    },
    onDone: () {
      onNativeDone();
      drained.complete();
      unawaited(controller.close());
    },
  );
  return controller.stream;
}
