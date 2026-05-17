import 'package:login_sdk/config/login_sdk_config.dart';
import 'package:login_sdk/dao/login_dao.dart';

/// 接口所需请求 header 信息。
///
/// 返回结果合并三部分：
///   1. [LoginSdkConfig.instance.syncHeaders] 提供的通用 header（默认含 auth-token / course-flag）
///   2. 当前已登录用户的 boarding-pass（从 [LoginSdkConfig.storage] 同步读）
///   3. 留给 host 通过 [LoginSdkConfig] 注入额外 header 的位置
///
/// 历史调用点（DAO 里散落的 `hiHeaders()`）无需改动；想换 header 形态只需要
/// `LoginSdkConfig.install(...)` 时传入新的 [syncHeaders]。
Map<String, String> hiHeaders() {
  return {
    ...LoginSdkConfig.instance.syncHeaders(),
    'boarding-pass': LoginDao.getBoardingPass() ?? '',
  };
}
