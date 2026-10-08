import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:rhttp/rhttp.dart';
import 'package:win_http/win_http.dart';

import 'rhttp_adapter.dart';
import 'win_http_adapter.dart';

/// Selects WinHTTP on Windows and rhttp on Linux.
///
/// Factories are lazy and only called on their respective platforms. Linux
/// initializes rhttp automatically before its first request. Other platforms
/// throw [UnsupportedError]; there is no silent dart:io TLS fallback.
class NativeDesktopAdapter implements HttpClientAdapter {
  NativeDesktopAdapter({
    WinHttpClientConfiguration Function()? createWinHttpConfiguration,
    ClientSettings Function()? createRhttpSettings,
    bool initializeRhttp = true,
  }) {
    if (Platform.isWindows) {
      adapter = WinHttpAdapter(createConfiguration: createWinHttpConfiguration);
    } else if (Platform.isLinux) {
      adapter = RhttpAdapter(
        createSettings: createRhttpSettings,
        initializeRhttp: initializeRhttp,
      );
    } else {
      throw UnsupportedError(
        'NativeDesktopAdapter supports only Windows and Linux.',
      );
    }
  }

  /// The selected adapter. Owned and closed by this adapter.
  late final HttpClientAdapter adapter;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => adapter.fetch(options, requestStream, cancelFuture);

  @override
  void close({bool force = false}) => adapter.close(force: force);
}
