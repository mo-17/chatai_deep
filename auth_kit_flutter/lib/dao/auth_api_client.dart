import 'dart:convert';
import 'package:http/http.dart' as http;

/// 宿主注入的回调类型
typedef HeaderProvider = Future<Map<String, String>> Function();

/// API 客户端 — 接受 baseUrl + headerProvider，不依赖任何宿主包。
class AuthApiClient {
  final String baseUrl;
  final HeaderProvider headerProvider;
  final http.Client httpClient;

  AuthApiClient({
    required this.baseUrl,
    required this.headerProvider,
    http.Client? httpClient,
  }) : httpClient = httpClient ?? http.Client();

  Uri _uri(String path) {
    final url = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return Uri.parse('$url$path');
  }

  Future<Map<String, String>> _headers() async {
    final h = await headerProvider();
    h['Content-Type'] = 'application/json';
    return h;
  }

  /// POST JSON 请求，返回已解码的 Map（含 code/data/extra）
  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body) async {
    final uri = _uri(path);
    final headers = await _headers();
    final response = await httpClient.post(uri, headers: headers, body: jsonEncode(body));
    final decoded = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    if (response.statusCode >= 400) {
      throw AuthApiException(
        statusCode: response.statusCode,
        code: decoded['code']?.toString(),
        message: decoded['message']?.toString() ?? '请求失败',
      );
    }
    if (decoded['code'] != 0) {
      throw AuthApiException(
        statusCode: response.statusCode,
        code: decoded['code']?.toString(),
        message: decoded['message']?.toString() ?? '请求失败',
      );
    }
    return decoded;
  }

  /// GET 请求
  Future<Map<String, dynamic>> get(String path) async {
    final uri = _uri(path);
    final headers = await _headers();
    final response = await httpClient.get(uri, headers: headers);
    final decoded = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    if (response.statusCode >= 400) {
      throw AuthApiException(
        statusCode: response.statusCode,
        code: decoded['code']?.toString(),
        message: decoded['message']?.toString() ?? '请求失败',
      );
    }
    return decoded;
  }

  void dispose() {
    httpClient.close();
  }
}

class AuthApiException implements Exception {
  final int statusCode;
  final String? code;
  final String message;
  const AuthApiException({required this.statusCode, this.code, required this.message});

  @override
  String toString() => 'AuthApiException($statusCode, $code): $message';
}
