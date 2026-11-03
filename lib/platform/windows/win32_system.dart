import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'windows_system.dart';

/// [WindowsSystem] through the Windows API itself (`dart:ffi`).
///
/// Direct calls rather than `reg.exe` or PowerShell: nothing to parse, no
/// quoting, and no script for antivirus heuristics to object to. The
/// libraries are opened on first use, so constructing this on another
/// platform is harmless — calling it is not.
class Win32System implements WindowsSystem {
  Win32System();

  static final _advapi32 = DynamicLibrary.open('advapi32.dll');
  static final _user32 = DynamicLibrary.open('user32.dll');
  static final _shell32 = DynamicLibrary.open('shell32.dll');
  static final _kernel32 = DynamicLibrary.open('kernel32.dll');

  // LSTATUS RegGetValueW(HKEY, LPCWSTR, LPCWSTR, DWORD, LPDWORD, PVOID, LPDWORD)
  static final _regGetValue = _advapi32.lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Uint32,
          Pointer<Uint32>, Pointer<Void>, Pointer<Uint32>),
      int Function(int, Pointer<Utf16>, Pointer<Utf16>, int, Pointer<Uint32>,
          Pointer<Void>, Pointer<Uint32>)>('RegGetValueW');

  // LSTATUS RegSetKeyValueW(HKEY, LPCWSTR, LPCWSTR, DWORD, LPCVOID, DWORD)
  static final _regSetKeyValue = _advapi32.lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Uint32,
          Pointer<Void>, Uint32),
      int Function(int, Pointer<Utf16>, Pointer<Utf16>, int, Pointer<Void>,
          int)>('RegSetKeyValueW');

  // LRESULT SendMessageTimeoutW(HWND, UINT, WPARAM, LPARAM, UINT, UINT,
  //                             PDWORD_PTR)
  static final _sendMessageTimeout = _user32.lookupFunction<
      IntPtr Function(IntPtr, Uint32, IntPtr, Pointer<Utf16>, Uint32, Uint32,
          Pointer<IntPtr>),
      int Function(int, int, int, Pointer<Utf16>, int, int,
          Pointer<IntPtr>)>('SendMessageTimeoutW');

  // BOOL ShellExecuteExW(SHELLEXECUTEINFOW*)
  static final _shellExecuteEx = _shell32.lookupFunction<
      Int32 Function(Pointer<_ShellExecuteInfo>),
      int Function(Pointer<_ShellExecuteInfo>)>('ShellExecuteExW');

  // HINSTANCE ShellExecuteW(HWND, LPCWSTR, LPCWSTR, LPCWSTR, LPCWSTR, INT)
  static final _shellExecute = _shell32.lookupFunction<
      IntPtr Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>,
          Pointer<Utf16>, Int32),
      int Function(int, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>,
          Pointer<Utf16>, int)>('ShellExecuteW');

  // DWORD WaitForSingleObject(HANDLE, DWORD)
  static final _waitForSingleObject = _kernel32.lookupFunction<
      Uint32 Function(IntPtr, Uint32),
      int Function(int, int)>('WaitForSingleObject');

  // BOOL GetExitCodeProcess(HANDLE, LPDWORD)
  static final _getExitCodeProcess = _kernel32.lookupFunction<
      Int32 Function(IntPtr, Pointer<Uint32>),
      int Function(int, Pointer<Uint32>)>('GetExitCodeProcess');

  // BOOL CloseHandle(HANDLE)
  static final _closeHandle = _kernel32.lookupFunction<Int32 Function(IntPtr),
      int Function(int)>('CloseHandle');

  // Predefined HKEYs are sign-extended 32-bit values.
  static const _hkeyCurrentUser = -0x7FFFFFFF; // 0x80000001
  static const _hkeyLocalMachine = -0x7FFFFFFE; // 0x80000002

  static const _rrfRtRegDword = 0x00000010;
  static const _rrfRtRegSz = 0x00000002;
  static const _rrfRtRegExpandSz = 0x00000004;
  static const _rrfNoExpand = 0x10000000;
  static const _regExpandSz = 2;
  static const _errorSuccess = 0;
  static const _errorMoreData = 234;

  static const _hwndBroadcast = 0xFFFF;
  static const _wmSettingChange = 0x001A;
  static const _smtoAbortIfHung = 0x0002;

  static const _seeMaskNoCloseProcess = 0x00000040;
  static const _swHide = 0;
  static const _waitTimeout = 0x00000102;

  static int _hkey(RegistryRoot root) => switch (root) {
        RegistryRoot.currentUser => _hkeyCurrentUser,
        RegistryRoot.localMachine => _hkeyLocalMachine,
      };

  @override
  int? readDword(RegistryRoot root, String key, String name) =>
      using((arena) {
        final data = arena<Uint32>();
        final size = arena<Uint32>()..value = sizeOf<Uint32>();
        final status = _regGetValue(
          _hkey(root),
          key.toNativeUtf16(allocator: arena),
          name.toNativeUtf16(allocator: arena),
          _rrfRtRegDword,
          nullptr,
          data.cast(),
          size,
        );
        return status == _errorSuccess ? data.value : null;
      });

  @override
  String? readRawString(RegistryRoot root, String key, String name) =>
      _readString(root, key, name, expand: false);

  @override
  String? readExpandedString(RegistryRoot root, String key, String name) =>
      _readString(root, key, name, expand: true);

  String? _readString(
    RegistryRoot root,
    String key,
    String name, {
    required bool expand,
  }) =>
      using((arena) {
        final flags = _rrfRtRegSz |
            _rrfRtRegExpandSz |
            (expand ? 0 : _rrfNoExpand);
        final keyPtr = key.toNativeUtf16(allocator: arena);
        final namePtr = name.toNativeUtf16(allocator: arena);
        final size = arena<Uint32>();
        // Ask for the size first, then read; a value written in between is
        // simply retried.
        for (var attempt = 0; attempt < 3; attempt++) {
          var status = _regGetValue(_hkey(root), keyPtr, namePtr, flags,
              nullptr, nullptr, size);
          if (status != _errorSuccess) return null;
          final buffer = calloc<Uint8>(size.value + 2);
          try {
            status = _regGetValue(_hkey(root), keyPtr, namePtr, flags,
                nullptr, buffer.cast(), size);
            if (status == _errorMoreData) continue;
            if (status != _errorSuccess) return null;
            return buffer.cast<Utf16>().toDartString();
          } finally {
            calloc.free(buffer);
          }
        }
        return null;
      });

  @override
  bool writeUserExpandString(String key, String name, String data) =>
      using((arena) {
        final value = data.toNativeUtf16(allocator: arena);
        // Bytes, including the terminating NUL.
        final bytes = (data.length + 1) * 2;
        return _regSetKeyValue(
              _hkeyCurrentUser,
              key.toNativeUtf16(allocator: arena),
              name.toNativeUtf16(allocator: arena),
              _regExpandSz,
              value.cast(),
              bytes,
            ) ==
            _errorSuccess;
      });

  @override
  void broadcastEnvironmentChange() => using((arena) {
        _sendMessageTimeout(
          _hwndBroadcast,
          _wmSettingChange,
          0,
          'Environment'.toNativeUtf16(allocator: arena),
          _smtoAbortIfHung,
          5000,
          arena<IntPtr>(),
        );
      });

  @override
  bool shellOpen(String target) => using((arena) {
        // Above 32 is success; anything else is an error code.
        return _shellExecute(
              0,
              'open'.toNativeUtf16(allocator: arena),
              target.toNativeUtf16(allocator: arena),
              nullptr,
              nullptr,
              _swShowNormal,
            ) >
            32;
      });

  static const _swShowNormal = 1;

  // HRESULT AssocQueryStringW(ASSOCF, ASSOCSTR, LPCWSTR, LPCWSTR, LPWSTR,
  //                           DWORD*)
  static final _assocQueryString = DynamicLibrary.open('shlwapi.dll')
      .lookupFunction<
          Int32 Function(Uint32, Uint32, Pointer<Utf16>, Pointer<Utf16>,
              Pointer<Utf16>, Pointer<Uint32>),
          int Function(int, int, Pointer<Utf16>, Pointer<Utf16>,
              Pointer<Utf16>, Pointer<Uint32>)>('AssocQueryStringW');

  static const _assocfIsProtocol = 0x00001000;
  static const _assocstrFriendlyAppName = 4;

  @override
  String? protocolHandler(String scheme) => using((arena) {
        const capacity = 512;
        final length = arena<Uint32>()..value = capacity;
        final buffer = arena<Uint16>(capacity).cast<Utf16>();
        final result = _assocQueryString(
          _assocfIsProtocol,
          _assocstrFriendlyAppName,
          scheme.toNativeUtf16(allocator: arena),
          nullptr,
          buffer,
          length,
        );
        if (result != 0) return null;
        final name = buffer.toDartString();
        return name.isEmpty ? null : name;
      });

  static final _crypt32 = DynamicLibrary.open('crypt32.dll');

  // PCCERT_CONTEXT CertCreateCertificateContext(DWORD, const BYTE*, DWORD)
  static final _certCreateCertificateContext = _crypt32.lookupFunction<
      Pointer<Void> Function(Uint32, Pointer<Uint8>, Uint32),
      Pointer<Void> Function(
          int, Pointer<Uint8>, int)>('CertCreateCertificateContext');

  // BOOL CertFreeCertificateContext(PCCERT_CONTEXT)
  static final _certFreeCertificateContext = _crypt32.lookupFunction<
      Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)>('CertFreeCertificateContext');

  // BOOL CertGetCertificateChain(HCERTCHAINENGINE, PCCERT_CONTEXT, LPFILETIME,
  //     HCERTSTORE, PCERT_CHAIN_PARA, DWORD, LPVOID, PCCERT_CHAIN_CONTEXT*)
  static final _certGetCertificateChain = _crypt32.lookupFunction<
      Int32 Function(IntPtr, Pointer<Void>, Pointer<Void>, IntPtr,
          Pointer<_CertChainPara>, Uint32, Pointer<Void>,
          Pointer<Pointer<_CertChainContext>>),
      int Function(
          int,
          Pointer<Void>,
          Pointer<Void>,
          int,
          Pointer<_CertChainPara>,
          int,
          Pointer<Void>,
          Pointer<Pointer<_CertChainContext>>)>('CertGetCertificateChain');

  // VOID CertFreeCertificateChain(PCCERT_CHAIN_CONTEXT)
  static final _certFreeCertificateChain = _crypt32.lookupFunction<
      Void Function(Pointer<_CertChainContext>),
      void Function(Pointer<_CertChainContext>)>('CertFreeCertificateChain');

  static const _x509AsnEncoding = 0x00000001;
  static const _pkcs7AsnEncoding = 0x00010000;
  static const _usageMatchTypeAnd = 0;
  static const _oidServerAuth = '1.3.6.1.5.5.7.3.1';

  @override
  Future<bool> buildCertificateChain(Uint8List der) =>
      // Windows may download roots and intermediates here, for seconds at a
      // time: off the UI isolate.
      Isolate.run(() => _buildCertificateChain(der));

  static bool _buildCertificateChain(Uint8List der) => using((arena) {
        final bytes = arena<Uint8>(der.length);
        bytes.asTypedList(der.length).setAll(0, der);
        final cert = _certCreateCertificateContext(
            _x509AsnEncoding | _pkcs7AsnEncoding, bytes, der.length);
        if (cert == nullptr) return false;
        try {
          final usage = arena<Pointer<Utf8>>()
            ..value = _oidServerAuth.toNativeUtf8(allocator: arena);
          final para = arena<_CertChainPara>();
          para.ref.cbSize = sizeOf<_CertChainPara>();
          para.ref.requestedUsage
            ..dwType = _usageMatchTypeAnd
            ..usage.cUsageIdentifier = 1
            ..usage.rgpszUsageIdentifier = usage;
          final chain = arena<Pointer<_CertChainContext>>();
          // The default engine, the current time, no extra store, no flags:
          // what Windows' own TLS asks for, network retrieval included.
          if (_certGetCertificateChain(
                  0, cert, nullptr, 0, para, 0, nullptr, chain) ==
              0) {
            return false;
          }
          try {
            return chain.value.ref.dwErrorStatus == 0;
          } finally {
            _certFreeCertificateChain(chain.value);
          }
        } finally {
          _certFreeCertificateContext(cert);
        }
      });

  @override
  Future<int?> runElevated(String executable, String parameters) async {
    final info = calloc<_ShellExecuteInfo>();
    final verb = 'runas'.toNativeUtf16();
    final file = executable.toNativeUtf16();
    final params = parameters.toNativeUtf16();
    final exitCode = calloc<Uint32>();
    try {
      info.ref
        ..cbSize = sizeOf<_ShellExecuteInfo>()
        ..fMask = _seeMaskNoCloseProcess
        ..lpVerb = verb
        ..lpFile = file
        ..lpParameters = params
        ..nShow = _swHide;
      // False when the user declines the UAC prompt (ERROR_CANCELLED) or the
      // program cannot be started; either way, nothing ran.
      if (_shellExecuteEx(info) == 0) return null;
      final process = info.ref.hProcess;
      if (process == 0) return null;
      try {
        // Polled rather than blocked on: this runs on the UI isolate, and
        // the prompt can sit there as long as the user likes.
        while (_waitForSingleObject(process, 0) == _waitTimeout) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        if (_getExitCodeProcess(process, exitCode) == 0) return null;
        return exitCode.value;
      } finally {
        _closeHandle(process);
      }
    } finally {
      calloc
        ..free(info)
        ..free(verb)
        ..free(file)
        ..free(params)
        ..free(exitCode);
    }
  }
}

/// CERT_CHAIN_PARA, nested as Windows declares it: the usage holds a pointer,
/// so it is 8-byte aligned and starts at offset 8, not right after `cbSize`.
final class _CertChainPara extends Struct {
  @Uint32()
  external int cbSize;
  external _CertUsageMatch requestedUsage;
}

/// CERT_USAGE_MATCH.
final class _CertUsageMatch extends Struct {
  @Uint32()
  external int dwType;
  external _CertEnhKeyUsage usage;
}

/// CERT_ENHKEY_USAGE.
final class _CertEnhKeyUsage extends Struct {
  @Uint32()
  external int cUsageIdentifier;
  external Pointer<Pointer<Utf8>> rgpszUsageIdentifier;
}

/// The start of CERT_CHAIN_CONTEXT: its size, then its CERT_TRUST_STATUS.
final class _CertChainContext extends Struct {
  @Uint32()
  external int cbSize;
  @Uint32()
  external int dwErrorStatus;
  @Uint32()
  external int dwInfoStatus;
}

/// SHELLEXECUTEINFOW (64-bit layout).
final class _ShellExecuteInfo extends Struct {
  @Uint32()
  external int cbSize;
  @Uint32()
  external int fMask;
  @IntPtr()
  external int hwnd;
  external Pointer<Utf16> lpVerb;
  external Pointer<Utf16> lpFile;
  external Pointer<Utf16> lpParameters;
  external Pointer<Utf16> lpDirectory;
  @Int32()
  external int nShow;
  @IntPtr()
  external int hInstApp;
  external Pointer<Void> lpIDList;
  external Pointer<Utf16> lpClass;
  @IntPtr()
  external int hkeyClass;
  @Uint32()
  external int dwHotKey;
  @IntPtr()
  external int hIconOrMonitor;
  @IntPtr()
  external int hProcess;
}
