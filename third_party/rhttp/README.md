# Vendored rhttp 0.18.0

Source: https://codeberg.org/Tienisto/rhttp (pub.dev release 0.18.0).
The upstream MIT license is retained in LICENSE. CargoKit has its own LICENSE.

Dart sources are in ../../lib/src/rhttp. Their package imports are rewritten
from package:rhttp to package:native_dio_adapter_desktop/src/rhttp and formatted
with this repository's Dart SDK. Rust and CargoKit sources are retained.
Only the root adapter's Linux FFI plugin registers the native build; upstream
Android, iOS, macOS and Windows plugin registrations are intentionally omitted.

The shared library remains librhttp.so, matching the generated FFI loader.
To update, copy a matching upstream Dart/Rust release, update imports and retain
licenses. Keep Dart flutter_rust_bridge aligned with the Rust Cargo.lock version.
