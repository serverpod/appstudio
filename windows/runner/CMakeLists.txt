cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "compact_window.cpp"
  "flutter_window.cpp"
  "main.cpp"
  "toast_notifications.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "winsparkle_updater.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
# C++/WinRT, for toast notifications (toast_notifications.cpp).
target_link_libraries(${BINARY_NAME} PRIVATE "windowsapp.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# WinSparkle, for updates (winsparkle_updater.cpp). A pinned release, checked
# against the digest GitHub publishes for it, like every other download.
set(WINSPARKLE_VERSION "0.9.4")
set(WINSPARKLE_SHA256
  "6037df37fc263bd1650a1c4949681a9d40ffe991d01f35892a406cb5d103c976")
set(WINSPARKLE_DIR "${CMAKE_BINARY_DIR}/winsparkle")
set(WINSPARKLE_ROOT "${WINSPARKLE_DIR}/WinSparkle-${WINSPARKLE_VERSION}")
if(NOT EXISTS "${WINSPARKLE_ROOT}/include/winsparkle.h")
  set(WINSPARKLE_ZIP "${WINSPARKLE_DIR}/WinSparkle-${WINSPARKLE_VERSION}.zip")
  file(DOWNLOAD
    "https://github.com/vslavik/winsparkle/releases/download/v${WINSPARKLE_VERSION}/WinSparkle-${WINSPARKLE_VERSION}.zip"
    "${WINSPARKLE_ZIP}"
    EXPECTED_HASH SHA256=${WINSPARKLE_SHA256}
    TLS_VERIFY ON)
  file(ARCHIVE_EXTRACT INPUT "${WINSPARKLE_ZIP}" DESTINATION "${WINSPARKLE_DIR}")
endif()
target_include_directories(${BINARY_NAME} PRIVATE "${WINSPARKLE_ROOT}/include")
target_link_libraries(${BINARY_NAME} PRIVATE
  "${WINSPARKLE_ROOT}/x64/Release/WinSparkle.lib")
# For the top-level install step, which puts the DLL beside the executable.
set(WINSPARKLE_DLL "${WINSPARKLE_ROOT}/x64/Release/WinSparkle.dll"
  CACHE INTERNAL "WinSparkle's DLL")
# The release scripts sign updates with the tool from the same package.
set(WINSPARKLE_TOOL "${WINSPARKLE_ROOT}/bin/winsparkle-tool.exe"
  CACHE INTERNAL "WinSparkle's signing tool")

# The update feed and its signing key, from windows/release.json. Release
# builds with both set check for updates; the rest report them unavailable.
file(READ "${CMAKE_SOURCE_DIR}/release.json" APPSTUDIO_RELEASE_JSON)
string(JSON APPSTUDIO_APPCAST_URL GET "${APPSTUDIO_RELEASE_JSON}" appcastUrl)
string(JSON APPSTUDIO_EDDSA_PUBLIC_KEY GET "${APPSTUDIO_RELEASE_JSON}"
  eddsaPublicKey)
target_compile_definitions(${BINARY_NAME} PRIVATE
  "APPSTUDIO_APPCAST_URL=\"${APPSTUDIO_APPCAST_URL}\""
  "APPSTUDIO_EDDSA_PUBLIC_KEY=\"${APPSTUDIO_EDDSA_PUBLIC_KEY}\"")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
  "${CMAKE_SOURCE_DIR}/release.json")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
