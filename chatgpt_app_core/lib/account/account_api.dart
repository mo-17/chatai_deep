import 'dart:convert';
import 'package:chatgpt_app_core/util/hi_const.dart';
import 'package:http/http.dart' as http;
import 'package:login_sdk/dao/header_util.dart';
import 'package:login_sdk/dao/login_dao.dart';

class AccountApi {
  final http.Client? client;
  final String? _account = LoginDao.getAccountHash();
  final String? _token = LoginDao.getBoardingPass();
  final String _origin = BackendConst.buildUri('/').origin;
  AccountApi({this.client});
  void verifyCurrent() {
    if (_account != LoginDao.getAccountHash() ||
        _token != LoginDao.getBoardingPass() ||
        _origin != BackendConst.buildUri('/').origin) {
      throw StateError('账号或后端已切换，请重新打开页面');
    }
  }

  Future<Map<String, dynamic>> request(String path,
      {Map<String, dynamic>? body}) async {
    verifyCurrent();
    final account = LoginDao.getAccountHash();
    final token = LoginDao.getBoardingPass();
    if (account == null || token == null || LoginDao.isGuest()) {
      throw StateError('请先登录账号');
    }
    final relative = Uri.parse(path);
    final uri = BackendConst.buildUri(relative.path,
        relative.queryParameters.isEmpty ? null : relative.queryParameters);
    final resolved = client ?? http.Client();
    try {
      final headers = {...hiHeaders(), 'Content-Type': 'application/json'};
      final response = await (body == null
              ? resolved.get(uri, headers: headers)
              : resolved.post(uri, headers: headers, body: jsonEncode(body)))
          .timeout(const Duration(seconds: 20));
      if (LoginDao.getAccountHash() != account ||
          LoginDao.getBoardingPass() != token ||
          _origin != BackendConst.buildUri('/').origin) {
        throw StateError('账号或后端已切换，请重新打开页面');
      }
      if (response.statusCode == 401) throw StateError('登录已过期，请重新登录');
      if (response.statusCode == 429) throw StateError('操作过于频繁或额度已用完，请稍后重试');
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('服务暂不可用，请稍后重试');
      }
      final value = jsonDecode(utf8.decode(response.bodyBytes));
      if (value is! Map || value['code'] != 0 || value['data'] is! Map) {
        throw StateError('服务响应无效');
      }
      return Map<String, dynamic>.from(value['data']);
    } finally {
      if (client == null) resolved.close();
    }
  }
}
