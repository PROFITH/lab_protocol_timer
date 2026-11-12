import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// HTTPS certificates checked by Windows when the app's own check fails.
///
/// The app (Dart, BoringSSL) trusts the root certificates of Windows but
/// does not fetch a missing intermediate certificate, nor a root Windows has
/// not installed yet (Windows installs them on first use). Browsers ask
/// Windows, which does both, so a server that works in the browser can fail
/// in the app with `CERTIFICATE_VERIFY_FAILED: unable to get local issuer
/// certificate` (seen with minerva.ugr.es on a new computer, 12/11/2026).
///
/// When that happens, the certificate is given to Windows
/// (`CertGetCertificateChain` and the SSL policy for the host name), and it
/// is accepted only if Windows accepts it for that host, exactly as the
/// browser would. Verification is never turned off.
class WindowsTlsTrust extends HttpOverrides {
  /// Installs it for every HTTPS connection of the app (Windows only).
  static void install() {
    if (!Platform.isWindows) return;
    HttpOverrides.global = WindowsTlsTrust();
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.badCertificateCallback = (cert, host, port) {
      final ok = verifyWithWindows(cert.der, host);
      debugPrint('[TLS] $host:$port no verificado por la app; Windows ${ok ? 'lo acepta' : 'lo rechaza'}');
      return ok;
    };
    return client;
  }

  /// Whether Windows trusts the server certificate [der] for [host].
  static bool verifyWithWindows(Uint8List der, String host) {
    if (!Platform.isWindows || der.isEmpty) return false;
    try {
      return _Crypt32().verify(der, host);
    } catch (e) {
      debugPrint('[TLS] No se pudo preguntar a Windows: $e');
      return false;
    }
  }
}

// ---------------------------------------------------------------------------
// crypt32.dll
// ---------------------------------------------------------------------------

const _x509AsnEncoding = 0x00000001;
const _pkcs7AsnEncoding = 0x00010000;
const _usageMatchTypeAnd = 0;
const _authTypeServer = 2;
const _certChainPolicySsl = 4;
const _serverAuthOid = '1.3.6.1.5.5.7.3.1';

final class _CertEnhKeyUsage extends Struct {
  @Uint32()
  external int cUsageIdentifier;
  external Pointer<Pointer<Utf8>> rgpszUsageIdentifier;
}

final class _CertUsageMatch extends Struct {
  @Uint32()
  external int dwType;
  external _CertEnhKeyUsage usage;
}

final class _CertChainPara extends Struct {
  @Uint32()
  external int cbSize;
  external _CertUsageMatch requestedUsage;
}

final class _SslExtraPolicyPara extends Struct {
  @Uint32()
  external int cbSize;
  @Uint32()
  external int dwAuthType;
  @Uint32()
  external int fdwChecks;
  external Pointer<Utf16> pwszServerName;
}

final class _CertChainPolicyPara extends Struct {
  @Uint32()
  external int cbSize;
  @Uint32()
  external int dwFlags;
  external Pointer<Void> pvExtraPolicyPara;
}

final class _CertChainPolicyStatus extends Struct {
  @Uint32()
  external int cbSize;
  @Uint32()
  external int dwError;
  @Int32()
  external int lChainIndex;
  @Int32()
  external int lElementIndex;
  external Pointer<Void> pvExtraPolicyStatus;
}

typedef _CreateContextC = Pointer<Void> Function(Uint32, Pointer<Uint8>, Uint32);
typedef _CreateContext = Pointer<Void> Function(int, Pointer<Uint8>, int);
typedef _GetChainC = Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>,
    Pointer<_CertChainPara>, Uint32, Pointer<Void>, Pointer<Pointer<Void>>);
typedef _GetChain = int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>,
    Pointer<_CertChainPara>, int, Pointer<Void>, Pointer<Pointer<Void>>);
typedef _VerifyPolicyC = Int32 Function(
    Pointer<Void>, Pointer<Void>, Pointer<_CertChainPolicyPara>, Pointer<_CertChainPolicyStatus>);
typedef _VerifyPolicy = int Function(
    Pointer<Void>, Pointer<Void>, Pointer<_CertChainPolicyPara>, Pointer<_CertChainPolicyStatus>);
typedef _FreeC = Void Function(Pointer<Void>);
typedef _Free = void Function(Pointer<Void>);
typedef _FreeContextC = Int32 Function(Pointer<Void>);
typedef _FreeContext = int Function(Pointer<Void>);

class _Crypt32 {
  _Crypt32() : _lib = DynamicLibrary.open('crypt32.dll');

  final DynamicLibrary _lib;

  late final _createContext =
      _lib.lookupFunction<_CreateContextC, _CreateContext>('CertCreateCertificateContext');
  late final _getChain = _lib.lookupFunction<_GetChainC, _GetChain>('CertGetCertificateChain');
  late final _verifyPolicy =
      _lib.lookupFunction<_VerifyPolicyC, _VerifyPolicy>('CertVerifyCertificateChainPolicy');
  late final _freeChain = _lib.lookupFunction<_FreeC, _Free>('CertFreeCertificateChain');
  late final _freeContext = _lib.lookupFunction<_FreeContextC, _FreeContext>('CertFreeCertificateContext');

  bool verify(Uint8List der, String host) {
    return using((arena) {
      final bytes = arena<Uint8>(der.length)..asTypedList(der.length).setAll(0, der);
      final cert = _createContext(_x509AsnEncoding | _pkcs7AsnEncoding, bytes, der.length);
      if (cert == nullptr) return false;
      try {
        // A chain for server authentication; Windows fetches what is missing.
        final oid = arena<Pointer<Utf8>>()..value = _serverAuthOid.toNativeUtf8(allocator: arena);
        final para = arena<_CertChainPara>();
        para.ref
          ..cbSize = sizeOf<_CertChainPara>()
          ..requestedUsage.dwType = _usageMatchTypeAnd
          ..requestedUsage.usage.cUsageIdentifier = 1
          ..requestedUsage.usage.rgpszUsageIdentifier = oid;
        final chain = arena<Pointer<Void>>();
        if (_getChain(nullptr, cert, nullptr, nullptr, para, 0, nullptr, chain) == 0 || chain.value == nullptr) {
          return false;
        }
        try {
          // The SSL policy: trusted root, dates, usage and the host name.
          final ssl = arena<_SslExtraPolicyPara>();
          ssl.ref
            ..cbSize = sizeOf<_SslExtraPolicyPara>()
            ..dwAuthType = _authTypeServer
            ..fdwChecks = 0
            ..pwszServerName = host.toNativeUtf16(allocator: arena);
          final policy = arena<_CertChainPolicyPara>();
          policy.ref
            ..cbSize = sizeOf<_CertChainPolicyPara>()
            ..dwFlags = 0
            ..pvExtraPolicyPara = ssl.cast();
          final status = arena<_CertChainPolicyStatus>();
          status.ref.cbSize = sizeOf<_CertChainPolicyStatus>();
          final called = _verifyPolicy(Pointer.fromAddress(_certChainPolicySsl), chain.value, policy, status);
          return called != 0 && status.ref.dwError == 0;
        } finally {
          _freeChain(chain.value);
        }
      } finally {
        _freeContext(cert);
      }
    });
  }
}
