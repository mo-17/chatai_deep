import 'dart:io';
import 'dart:typed_data';

/// 对外网络功能共享的目标地址策略。
///
/// 主机名会去掉 DNS 绝对名称末尾的点；调用方必须校验解析出的全部 A/AAAA，
/// 只要混入一个非公网地址就拒绝，避免 DNS rebinding 与 dual-stack 旁路。
final class PublicNetworkAddressPolicy {
  const PublicNetworkAddressPolicy._();

  static String normalizeHostname(String rawHost) {
    var host = rawHost.trim().toLowerCase();
    while (host.length > 1 && host.endsWith('.')) {
      host = host.substring(0, host.length - 1);
    }
    return host;
  }

  static bool isLocalHostname(String rawHost) {
    final host = normalizeHostname(rawHost);
    return host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host.endsWith('.internal') ||
        host == 'home.arpa' ||
        host.endsWith('.home.arpa');
  }

  static bool isPublicAddress(InternetAddress address) {
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      return _isPublicIpv4(bytes);
    }
    if (address.type != InternetAddressType.IPv6 || bytes.length != 16) {
      return false;
    }

    // IPv4-compatible / mapped IPv6（包括 ::ffff:127.0.0.1）。
    final firstTenZero = bytes.take(10).every((byte) => byte == 0);
    if (firstTenZero &&
        ((bytes[10] == 0 && bytes[11] == 0) ||
            (bytes[10] == 0xff && bytes[11] == 0xff))) {
      return false;
    }

    // 只允许原生 global-unicast 2000::/3；再剔除文档、隧道和测试前缀。
    if ((bytes[0] & 0xe0) != 0x20) return false;
    if (bytes[0] == 0x20 && bytes[1] == 0x01) {
      if (bytes[2] == 0x00 && bytes[3] == 0x00) return false; // Teredo
      if (bytes[2] == 0x00 && bytes[3] == 0x02) return false; // benchmark
      if (bytes[2] == 0x0d && bytes[3] == 0xb8) return false; // documentation
      if (bytes[2] == 0x00 &&
          ((bytes[3] & 0xf0) == 0x10 || (bytes[3] & 0xf0) == 0x20)) {
        return false; // ORCHID / ORCHIDv2
      }
    }
    if (bytes[0] == 0x20 && bytes[1] == 0x02) return false; // 6to4
    if (bytes[0] == 0x3f && (bytes[1] & 0xf0) == 0xf0) {
      return false; // 3fff::/20 documentation
    }
    return true;
  }

  static bool _isPublicIpv4(Uint8List bytes) {
    if (bytes.length != 4) return false;
    final first = bytes[0];
    final second = bytes[1];
    if (first == 0 || first == 10 || first == 127 || first >= 224) {
      return false;
    }
    if (first == 100 && second >= 64 && second <= 127) return false;
    if (first == 169 && second == 254) return false;
    if (first == 172 && second >= 16 && second <= 31) return false;
    if (first == 192 && second == 168) return false;
    if (first == 192 && second == 0) return false;
    if (first == 192 && second == 88 && bytes[2] == 99) return false;
    if (first == 198 && (second == 18 || second == 19)) return false;
    if (first == 198 && second == 51 && bytes[2] == 100) return false;
    if (first == 203 && second == 0 && bytes[2] == 113) return false;
    return true;
  }
}
