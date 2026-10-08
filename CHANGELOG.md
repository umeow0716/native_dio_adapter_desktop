## 0.2.0

* Build and bundle Rust only on Linux; Windows uses system WinHTTP.
* Vendor the matched rhttp 0.18.0 Dart/Rust backend and preserve MIT notices.
* Re-export Rhttp for explicit initialization of the bundled backend.
* Import Linux settings from this package; separate upstream rhttp types differ.

## 0.1.0

- Add `NativeDesktopAdapter`, selecting WinHTTP on Windows and rhttp on Linux.
- Add explicit `WinHttpAdapter` and `RhttpAdapter` transports.
- Support native TLS, configurable proxies, Dio redirect policies, cookies,
  multipart uploads, byte/stream responses, cancellation, and timeout budgets.
- Add transport contract tests, a runnable example, and native smoke tests.
