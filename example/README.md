# Native desktop example

Run `flutter run -d linux` or `flutter run -d windows` for an interactive HTTPS
request. Install Rust before building; Linux also needs Flutter's GTK build
dependencies.

To run native smoke tests after a release build:

- Linux: `xvfb-run -a build/linux/x64/release/bundle/native_desktop_example --smoke-test`
- Windows: `build\windows\x64\runner\Release\native_desktop_example.exe --smoke-test`

The tests cover local HTTP, redirects, repeated cookies, multipart/JSON uploads,
cancellation, receive timeout, explicit proxy routing, and public HTTPS. The
last check requires Internet access.
