# native_dio_adapter_desktop

Native Dio adapters for **Windows** and **Linux**, powered by WinHTTP and rhttp,
with native TLS and configurable proxy support.

| Platform | Transport | TLS |
| --- | --- | --- |
| Windows | [`win_http`](https://pub.dev/packages/win_http) | Windows Schannel |
| Linux | [`rhttp`](https://codeberg.org/Tienisto/rhttp) / reqwest | rustls |

Inspired by the platform selection and conversion-layer design of
[`native_dio_adapter`](https://github.com/cfug/dio/tree/main/plugins/native_dio_adapter).
This is a separate desktop companion package. It doesn't depend on or replace
that package's Android/iOS adapters.

## Install

```yaml
dependencies:
  dio: ^5.9.0
  native_dio_adapter_desktop:
    git:
      url: https://github.com/umeow0716/native_dio_adapter_desktop.git
      ref: main
```

Requires Flutter >=3.35.0 and Dart >=3.9.0. Install a current stable Rust toolchain
via [rustup](https://rustup.rs/) on build machines: the transitive rhttp plugin
compiles native Rust code. End users do **not** need Rust installed.

## Use

```dart
import 'package:dio/dio.dart';
import 'package:native_dio_adapter_desktop/native_dio_adapter_desktop.dart';

final dio = Dio()
  ..httpClientAdapter = NativeDesktopAdapter();

final response = await dio.get('https://example.com');
dio.close();
```

Linux initialization is automatic and asynchronous before the first request;
you don't need to call `Rhttp.init()`. If your app already initializes rhttp,
pass `initializeRhttp: false` and finish that initialization before sending requests. Adapter and native clients are created
lazily. Closing an unused adapter doesn't initialize either transport.

The public platform adapters are `WinHttpAdapter` and `RhttpAdapter`. The
selector exposes its selected adapter as `adapter` and throws on unsupported
platforms. It never silently switches to `dart:io` TLS.

## Proxy configuration

Defaults preserve each backend's system proxy behavior. For a local HTTP proxy
(e.g. a GP tunnel's CONNECT proxy), configure both platform factories:

```dart
final dio = Dio()
  ..httpClientAdapter = NativeDesktopAdapter(
    createWinHttpConfiguration: () => const WinHttpClientConfiguration(
      accessType: WinHttpAccessType.named,
      proxy: '127.0.0.1:8080', // WinHTTP expects host:port, not a URL.
    ),
    createRhttpSettings: () => const ClientSettings(
      proxySettings: ProxySettings.proxy('http://127.0.0.1:8080'),
    ),
  );
```

Factories run once on first use, only on the selected platform. If a proxy port
changes after reconnecting, replace the adapter and close the previous adapter.
Domain routing and GP lifecycle belong to the application; this package contains
neither. TLS remains with the native client when using an HTTP CONNECT proxy.

To disable system proxies, use `WinHttpAccessType.noProxy` and
`ProxySettings.noProxy()`. Advanced Linux TLS/DNS settings are available through
`ClientSettings`. Explicit `RootCertSource.platform` can be used when you need
system-installed roots; rhttp defaults to its bundled Mozilla roots.

## Redirects, cookies and status codes

Dio's `followRedirects` and `maxRedirects` are honored. Use
`followRedirects: false` when a Dio redirect interceptor or your application must
inspect every redirect hop and choose its route.

Native cookie storage is disabled. Cookies are passed through as headers,
including multiple `Set-Cookie` values with `Expires` commas. Add
`dio_cookie_manager` if you want a cookie jar. With native automatic redirects,
intermediate responses are not exposed to Dio cookie interceptors. WinHTTP may
forward custom request headers across redirects; disable automatic redirects
when redirect destinations require application-level header/routing decisions.

Dio remains responsible for response decoding and `validateStatus`. In
particular, Linux's native `throwOnStatusCode`, cookie settings, redirect policy,
and base URL are overridden to retain Dio's behavior. Other supplied Linux
settings are retained. Linux clients are reused per redirect policy for the
adapter's lifetime.

## Cancellation, timeouts and streaming

- Cancellation and `close(force: true)` abort active native requests.
- `close()` prevents new requests and lets active requests finish.
- Response bodies stream into Dio and respect subscription cancellation.
- Upload bodies (including multipart) are buffered in memory, matching WinHTTP's
  upload implementation. This package isn't intended for very large uploads.
- Dio `sendTimeout` covers buffering the upload stream. It does not independently
  measure native socket upload time; use WinHTTP's native `sendTimeout` setting
  or Linux's native total `TimeoutSettings.timeout` when needed.
- The shared `package:http` interface cannot separate connection establishment
  from waiting for response headers. Before headers, this adapter enforces
  **connectTimeout + receiveTimeout** as one budget and reports a
  `DioExceptionType.receiveTimeout` on expiry. After headers, `receiveTimeout`
  limits idle gaps between body chunks; it pauses when the consumer pauses.
- Native timeout settings can impose additional limits. Native timeout failures
  map to Dio's receive-timeout category because a reliable phase isn't exposed.

## Linux compatibility

Ubuntu **22.04** is the build and execution baseline. CI builds and runs native
smoke tests inside Ubuntu 22.04 on x64 and ARM64. Build separate executables and
native libraries for each architecture; an x64 bundle cannot run on ARM64.

Build on the oldest supported distribution, include the entire Flutter bundle,
and check ELF dependencies with `ldd`/`readelf`. Building on a newer distribution
can introduce newer glibc requirements. Alpine/musl is not covered by the GNU
Linux targets used here. The full application may have additional GTK/WebKit or
other plugin dependencies, independent of this HTTP adapter.

Using rustls changes the TLS implementation but doesn't emulate a browser's
ClientHello or guarantee that a particular campus network accepts requests.

## Development

```sh
flutter pub get
flutter analyze
flutter test
cd example
flutter build linux --release
xvfb-run -a build/linux/x64/release/bundle/native_desktop_example --smoke-test
```

The example provides an interactive HTTPS request and an executable smoke-test
mode. Smoke tests use local HTTP servers and an explicit proxy, plus one public
HTTPS request to `https://example.com` to exercise trusted native TLS. Internet
access is required for that check. Windows CI builds and runs the same tests.

## License

The source in this repository is **MIT**; see [LICENSE](LICENSE).
Dependencies keep their own licenses: `rhttp` is MIT and `win_http` 0.2.3 is
**GPL-3.0**. Choosing MIT for this adapter does not relicense `win_http` or remove
its distribution conditions. The adapter implementation does not vendor upstream adapter code. See the dependency packages for their license texts.
