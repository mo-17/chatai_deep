/// 标识符校验工具
class IdentifierValidator {
  /// 邮箱格式校验
  static bool isValidEmail(String email) {
    return RegExp(r'^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$').hasMatch(email);
  }

  /// E.164 手机号校验：+ 后跟 1-3 位区号 + 数字（总长 ≤ 15）
  static bool isValidE164Phone(String phone) {
    return RegExp(r'^\+\d{7,15}$').hasMatch(phone);
  }
}
