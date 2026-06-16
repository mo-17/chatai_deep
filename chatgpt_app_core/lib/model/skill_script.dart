/// 技能（Agent Skill）随包导入的一段可执行脚本（`scripts/*.js`）。
/// 绑定到导入生成的助手（[assistantId]），由 `run_script` 工具按 [name] 查取执行。
/// 执行有沙箱（无文件/网络）兜底，并按 [auditLevel] 在执行前向用户呈现审计结论。
class SkillScript {
  /// 审计状态常量。
  static const levelPending = 'pending'; // 未审计（无 key / 尚未审计）
  static const levelSafe = 'safe';
  static const levelWarn = 'warn';
  static const levelDanger = 'danger';
  static const levelUnknown = 'unknown'; // 审计失败/无法判定

  int? id;
  int assistantId;

  /// 脚本文件名（如 `normalize-punctuation.js`），模型按它调用。
  String name;
  String code;

  /// AI 审计等级（见上面常量）。
  String auditLevel;

  /// AI 审计的一句话说明（展示给用户）。
  String auditSummary;

  int createdAt;

  SkillScript({
    this.id,
    required this.assistantId,
    required this.name,
    required this.code,
    this.auditLevel = levelPending,
    this.auditSummary = '',
    this.createdAt = 0,
  });

  factory SkillScript.fromJson(Map<String, dynamic> json) => SkillScript(
        id: json['id'] as int?,
        assistantId: json['assistantId'] as int? ?? 0,
        name: json['name'] as String? ?? '',
        code: json['code'] as String? ?? '',
        auditLevel: json['auditLevel'] as String? ?? levelPending,
        auditSummary: json['auditSummary'] as String? ?? '',
        createdAt: json['createdAt'] as int? ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'assistantId': assistantId,
        'name': name,
        'code': code,
        'auditLevel': auditLevel,
        'auditSummary': auditSummary,
        'createdAt': createdAt,
      };
}
