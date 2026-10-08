import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:win_http/win_http.dart';

/// Original header values exposed by native clients.
abstract interface class MultiValueHeaders {
  Map<String, List<String>> get headerLists;
}

/// Shared Dio/http boundary; contains no platform selection or application
/// routing. Bodies are buffered for consistent WinHTTP upload behavior.
class ConversionLayerAdapter implements HttpClientAdapter {
  ConversionLayerAdapter(this._createClient);

  ConversionLayerAdapter.fromClient(http.Client client)
    : _createClient = (() => client),
      _client = client;

  final http.Client Function() _createClient;
  http.Client? _client;
  final _active = <_RequestState>{};
  bool _closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_closed) throw StateError('HTTP adapter is closed.');
    final state = _RequestState(options, cancelFuture);
    _active.add(state);
    void finish() {
      state.finish();
      _active.remove(state);
      if (_closed && _active.isEmpty) _client?.close();
    }

    try {
      if (options.cancelToken?.isCancelled ?? false) {
        throw options.cancelToken!.cancelError!;
      }
      final bytes = await state.buffer(requestStream);
      state.check();
      final request =
          http.AbortableRequest(
              options.method,
              options.uri,
              abortTrigger: state.abort.future,
            )
            ..followRedirects = options.followRedirects
            ..maxRedirects = options.maxRedirects
            ..bodyBytes = bytes;
      for (final entry in options.headers.entries) {
        if (entry.value == null) continue;
        request.headers[options.preserveHeaderCase
            ? entry.key
            : entry.key.toLowerCase()] = entry.value is Iterable
            ? (entry.value as Iterable).join(', ')
            : entry.value.toString();
      }
      // package:http doesn't expose the connection/header boundary. Use one
      // combined budget, matching native_dio_adapter's conversion semantics.
      final budget =
          (options.connectTimeout ?? Duration.zero) +
          (options.receiveTimeout ?? Duration.zero);
      state.arm(
        budget,
        DioException.receiveTimeout(timeout: budget, requestOptions: options),
      );
      final response = await state.race(
        (_client ??= _createClient()).send(request),
      );
      state.stopTimer();
      final headers = response.headers.map(
        (key, value) => MapEntry(key, [value]),
      );
      // Preserve cookies with Expires commas. Linux keeps every original header
      // value; WinHTTP exposes merged fields through package:http.
      final split = response is MultiValueHeaders
          ? (response as MultiValueHeaders).headerLists
          : response.headersSplitValues;
      if (split['set-cookie'] case final cookies?) {
        headers['set-cookie'] = cookies;
      }
      return ResponseBody(
        state.wrap(response.stream, finish),
        response.statusCode,
        headers: headers,
        isRedirect: response.isRedirect,
        statusMessage: response.reasonPhrase,
      );
    } catch (error, stack) {
      finish();
      Error.throwWithStackTrace(_dioError(error, options), stack);
    }
  }

  @override
  void close({bool force = false}) {
    if (_closed && !force) return;
    _closed = true;
    if (force) {
      for (final state in _active.toList()) {
        state.fail(
          DioException(
            requestOptions: state.options,
            type: DioExceptionType.cancel,
            message: 'Adapter was closed with force: true.',
          ),
        );
      }
    }
    if (_active.isEmpty || force) _client?.close();
  }
}

DioException _dioError(Object error, RequestOptions options) {
  if (error is DioException) return error;
  final type = switch (error) {
    http.RequestAbortedException() ||
    rhttp.RhttpCancelException() => DioExceptionType.cancel,
    rhttp.RhttpInvalidCertificateException() => DioExceptionType.badCertificate,
    http.ClientException() ||
    rhttp.RhttpConnectionException() => DioExceptionType.connectionError,
    WinHttpException(errorCode: 12175) => DioExceptionType.badCertificate,
    WinHttpException() => DioExceptionType.connectionError,
    _ => DioExceptionType.unknown,
  };
  if (error is rhttp.RhttpTimeoutException ||
      error is WinHttpException && error.errorCode == 12002) {
    return DioException.receiveTimeout(
      timeout: options.receiveTimeout ?? Duration.zero,
      requestOptions: options,
      error: error,
    );
  }
  return DioException(
    requestOptions: options,
    type: type,
    error: error,
    message: error.toString(),
  );
}

class _RequestState {
  _RequestState(this.options, Future<void>? cancellation) {
    failure.future.ignore();
    final cancellationOrRelease = cancellation == null
        ? null
        : Future.any([cancellation, _released.future]);
    cancellationOrRelease?.then(
      (_) {
        if (!_finished) {
          fail(
            options.cancelToken?.cancelError ??
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.cancel,
                ),
          );
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!_finished) fail(_dioError(error, options));
      },
    );
  }

  final RequestOptions options;
  final _released = Completer<void>();
  final abort = Completer<void>();
  final failure = Completer<Never>();
  Timer? _timer;
  DioException? _error;
  bool _finished = false;

  void check() {
    if (_error case final error?) throw error;
  }

  Future<T> race<T>(Future<T> task) => Future.any([task, failure.future]);

  void arm(Duration duration, DioException error) {
    stopTimer();
    if (duration > Duration.zero) {
      _timer = Timer(duration, () => fail(error));
    }
  }

  void stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void fail(DioException error) {
    if (_finished || _error != null) return;
    _error = error;
    stopTimer();
    if (!abort.isCompleted) abort.complete();
    failure.completeError(error);
  }

  void finish() {
    if (_finished) return;
    _finished = true;
    _released.complete();
    stopTimer();
    if (!abort.isCompleted) abort.complete();
  }

  Future<Uint8List> buffer(Stream<Uint8List>? stream) async {
    if (stream == null) return Uint8List(0);
    final bytes = BytesBuilder(copy: false);
    final done = Completer<void>();
    arm(
      options.sendTimeout ?? Duration.zero,
      DioException.sendTimeout(
        timeout: options.sendTimeout ?? Duration.zero,
        requestOptions: options,
      ),
    );
    final subscription = stream.listen(
      bytes.add,
      onError: done.completeError,
      onDone: done.complete,
      cancelOnError: true,
    );
    try {
      await race(done.future);
      return bytes.takeBytes();
    } finally {
      stopTimer();
      await subscription.cancel();
    }
  }

  Stream<Uint8List> wrap(Stream<List<int>> source, void Function() onFinished) {
    late StreamController<Uint8List> controller;
    StreamSubscription<List<int>>? subscription;
    bool ended = false;
    void resetTimer() => arm(
      options.receiveTimeout ?? Duration.zero,
      DioException.receiveTimeout(
        timeout: options.receiveTimeout ?? Duration.zero,
        requestOptions: options,
      ),
    );
    Future<void> end({Object? error, StackTrace? stack}) async {
      if (ended) return;
      ended = true;
      stopTimer();
      if (error != null) {
        controller.addError(_dioError(error, options), stack);
      }
      onFinished();
      await subscription?.cancel();
      unawaited(controller.close());
    }

    controller = StreamController<Uint8List>(
      onListen: () {
        resetTimer();
        subscription = source.listen(
          (chunk) {
            if (ended) return;
            resetTimer();
            controller.add(
              chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
            );
          },
          onError: (Object error, StackTrace stack) {
            unawaited(end(error: error, stack: stack));
          },
          onDone: () => unawaited(end()),
        );
        unawaited(
          failure.future.then<void>(
            (_) {},
            onError: (Object error, StackTrace stack) {
              unawaited(end(error: error, stack: stack));
            },
          ),
        );
      },
      onPause: () {
        stopTimer();
        subscription?.pause();
      },
      onResume: () {
        resetTimer();
        subscription?.resume();
      },
      onCancel: () async {
        if (ended) return;
        ended = true;
        onFinished();
        await subscription?.cancel();
      },
    );
    return controller.stream;
  }
}
