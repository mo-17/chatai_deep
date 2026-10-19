import 'package:login_sdk/config/login_sdk_config.dart';
import 'package:login_sdk/dao/login_dao.dart';

/// 接口所需请求 header 信息。
///
/// 返回结果合并三部分：
///   1. [LoginSdkConfig.instance.syncHeaders] 提供的通用 header（默认含 auth-token / course-flag）
///   2. 当前账号的 Bearer JWT，以及兼容旧接口的 boarding-pass
///   3. 留给 host 通过 [LoginSdkConfig] 注入额外 header 的位置
///
/// 历史调用点（DAO 里散落的 `hiHeaders()`）无需改动；想换 header 形态只需要
/// `LoginSdkConfig.install(...)` 时传入新的 [syncHeaders]。
Map<String, String> hiHeaders() {
  final token = LoginDao.getBoardingPass();
  final headers = {
    ...LoginSdkConfig.instance.syncHeaders(),
    'boarding-pass': token ?? '',
  };
  if (token != null && token.isNotEmpty && token != LoginDao.kGuestToken) {
    // 账号登录态优先于宿主可能缓存的旧 Authorization，字段名按 HTTP 大小写无关处理。
    headers.removeWhere((name, _) => name.toLowerCase() == 'authorization');
    headers['Authorization'] = 'Bearer $token';
  }
  return headers;
}
