/// Native Dio transports for Windows and Linux.
library;

export 'package:native_dio_adapter_desktop/src/rhttp/rhttp.dart'
    show
        Rhttp,
        ClientSettings,
        ProxySettings,
        RedirectSettings,
        TlsSettings,
        RootCertSource,
        TimeoutSettings,
        HttpVersionPref,
        CookieSettings;
export 'package:win_http/win_http.dart'
    show WinHttpClientConfiguration, WinHttpAccessType;

export 'src/native_desktop_adapter.dart';
export 'src/rhttp_adapter.dart' show RhttpAdapter;
export 'src/win_http_adapter.dart' show WinHttpAdapter;
