/// 一次 JS 脚本执行的结果。独立成文件、不依赖 flutter_js，
/// 这样工具层（ToolActionContext / builtin_tools）可引用它做注入与单测，
/// 而不必把原生 JS 引擎拖进来（也保证 OHOS / 测试环境可编译）。
class JsExecResult {
  /// 是否成功执行（无异常、引擎未报错）。
  final bool ok;

  /// 脚本输出（约定为最后一个表达式的字符串值 / 脚本自行 stringify 的结果）。
  final String output;

  /// 失败原因（ok=false 时有值）。
  final String? error;

  const JsExecResult({required this.ok, this.output = '', this.error});

  const JsExecResult.ok(this.output)
      : ok = true,
        error = null;

  const JsExecResult.fail(this.error)
      : ok = false,
        output = '';
}
