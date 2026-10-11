/// 本地保守白名单。无法确认是本人普通偏好时不生成候选。
class PersonalMemoryRules {
  static bool containsCredential(String text) =>
      RegExp(
        r'(password|passwd|api[ _-]?key|access[ _-]?token|bearer\s|secret|private[ _-]?key|cookie|sk-[A-Za-z0-9]|密码|密钥|口令|验证码|私钥|凭证)',
        caseSensitive: false,
      ).hasMatch(text) ||
      RegExp(r'[A-Za-z0-9_+/=-]{28,}').hasMatch(text);

  static String? suggest(String input) {
    final text = input.trim();
    if (text.runes.length < 5 ||
        text.runes.length > 100 ||
        containsCredential(text)) {
      return null;
    }
    // 整句、语法和值均封闭。其他个人事实只允许用户主动手动新增，
    // 不用不断扩充敏感词来猜测任意「我喜欢」后缀是否安全。
    final allowed = RegExp(
      r'^(?:我希望(?:你)?回答|以后回答请|回答时请)(?:简短|简洁|简短清楚|详细|详细清楚|通俗易懂|多举例|举例说明|分点说明|使用中文|使用英文|用中文|用英文)[。！!]?$',
    );
    return allowed.hasMatch(text) ? text : null;
  }
}
