import 'package:win_http/win_http.dart';

import 'conversion_layer_adapter.dart';

/// Dio transport backed by WinHTTP and Windows Schannel.
class WinHttpAdapter extends ConversionLayerAdapter {
  /// Creates an owned WinHTTP client lazily on the first request.
  WinHttpAdapter({WinHttpClientConfiguration Function()? createConfiguration})
    : super(
        () => WinHttpClient.fromConfiguration(
          createConfiguration?.call() ?? const WinHttpClientConfiguration(),
        ),
      );

  /// Uses an existing client, which this adapter owns and closes.
  /// Useful for explicit client configuration and transport contract tests.
  WinHttpAdapter.fromClient(super.client) : super.fromClient();
}
