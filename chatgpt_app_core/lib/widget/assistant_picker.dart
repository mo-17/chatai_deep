import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/pages/assistant_list_page.dart';
import 'package:chatgpt_app_core/widget/assistant_avatar.dart';
import 'package:flutter/material.dart';

/// 助手选择结果。区分「取消」（showAssistantPicker 返回 null）与
/// 「明确选择不使用助手」（assistant 为 null）。
class AssistantPickResult {
  final AssistantModel? assistant;

  const AssistantPickResult(this.assistant);
}

/// 弹出助手选择底部弹窗（阶段七）。
/// - 一个助手都没有时不打扰用户，直接返回「不使用助手」；
/// - [selectedId] 当前绑定的助手 id，用于高亮勾选；
/// - 底部「管理助手」入口跳转列表页，返回后刷新选项。
Future<AssistantPickResult?> showAssistantPicker(BuildContext context,
    {int? selectedId}) async {
  final dbManager =
      await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
  final dao = await AssistantDao.create(dbManager);
  var assistants = await dao.getAssistants();
  if (assistants.isEmpty && selectedId == null) {
    // 没有任何助手：新建会话不弹窗（零打扰）；会话内切换仍弹（可去新建）。
    return const AssistantPickResult(null);
  }
  if (!context.mounted) return null;
  return showModalBottomSheet<AssistantPickResult>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheetState) {
        Widget item({
          required Widget leading,
          required String title,
          String? subtitle,
          bool selected = false,
          required VoidCallback onTap,
        }) =>
            ListTile(
              leading: leading,
              title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: subtitle != null && subtitle.isNotEmpty
                  ? Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis)
                  : null,
              trailing: selected
                  ? Icon(Icons.check, color: Theme.of(ctx).primaryColor)
                  : null,
              onTap: onTap,
            );

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('选择助手', style: Theme.of(ctx).textTheme.titleMedium),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    item(
                      leading: const Icon(Icons.chat_bubble_outline),
                      title: '不使用助手',
                      selected: selectedId == null,
                      onTap: () =>
                          Navigator.pop(ctx, const AssistantPickResult(null)),
                    ),
                    for (final a in assistants)
                      item(
                        leading: AssistantAvatar(assistant: a),
                        title: a.name,
                        subtitle:
                            a.description.isEmpty ? a.prompt : a.description,
                        selected: a.id == selectedId,
                        onTap: () => Navigator.pop(ctx, AssistantPickResult(a)),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('管理助手'),
                onTap: () async {
                  await Navigator.push(
                      ctx,
                      MaterialPageRoute(
                          builder: (_) => const AssistantListPage()));
                  // 返回后刷新选项（可能新建/删除了助手）。
                  assistants = await dao.getAssistants();
                  if (ctx.mounted) setSheetState(() {});
                },
              ),
            ],
          ),
        );
      },
    ),
  );
}
