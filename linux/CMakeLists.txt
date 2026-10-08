cmake_minimum_required(VERSION 3.10)
project(native_dio_adapter_desktop LANGUAGES CXX)

# Only Linux registers this FFI plugin. Windows uses system WinHTTP;
# mobile apps use their own adapters and never build this Rust library.
include("../third_party/rhttp/cargokit/cmake/cargokit.cmake")
apply_cargokit(${PROJECT_NAME} ../third_party/rhttp/rust rhttp "")
set(native_dio_adapter_desktop_bundled_libraries
  "${${PROJECT_NAME}_cargokit_lib}"
  PARENT_SCOPE
)
