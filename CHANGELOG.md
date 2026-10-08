## 0.1.0

- Add `NativeDesktopAdapter`, selecting WinHTTP on Windows and rhttp on Linux.
- Add explicit `WinHttpAdapter` and `RhttpAdapter` transports.
- Support native TLS, configurable proxies, Dio redirect policies, cookies,
  multipart uploads, byte/stream responses, cancellation, and timeout budgets.
- Add transport contract tests, a runnable example, and native smoke tests.
