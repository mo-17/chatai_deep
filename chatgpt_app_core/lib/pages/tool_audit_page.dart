import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/tool_audit_dao.dart';
import 'package:chatgpt_app_core/model/tool_audit_record.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/widget/app_visual_widgets.dart';
import 'package:flutter/material.dart';

typedef ToolAuditLoader = Future<List<ToolAuditRecord>> Function();

class ToolAuditPage extends StatelessWidget {
  final ToolAuditLoader? loader;

  const ToolAuditPage({super.key, this.loader});

  static Future<List<ToolAuditRecord>> loadDefault() async {
    final storage =
        await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    final dao = await ToolAuditDao.create(storage);
    return dao.latest(limit: 100);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('工具审计'),
        centerTitle: true,
      ),
      body: FutureBuilder<List<ToolAuditRecord>>(
        future: (loader ?? loadDefault)(),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return AppVisualEmptyState(
              animeKey: const ValueKey('tool_audit_error_state'),
              icon: Icons.cloud_off_outlined,
              title: '工具审计加载失败',
              message: '${snapshot.error}',
              classic: Center(child: Text('工具审计加载失败：${snapshot.error}')),
            );
          }
          final records = snapshot.data ?? const <ToolAuditRecord>[];
          if (records.isEmpty) {
            return const AppVisualEmptyState(
              animeKey: ValueKey('tool_audit_empty_state'),
              icon: Icons.fact_check_outlined,
              title: '还没有工具调用记录',
              message: '调用外部工具后，这里会展示来源、权限与执行结果。',
              classic: Center(child: Text('还没有工具调用记录')),
            );
          }
          final anime = AppVisualTheme.of(context).isAnime;
          return ListView.separated(
            padding: anime
                ? const EdgeInsets.fromLTRB(12, 12, 12, 24)
                : const EdgeInsets.symmetric(vertical: 8),
            itemCount: records.length,
            separatorBuilder: (_, __) =>
                anime ? const SizedBox(height: 8) : const Divider(height: 1),
            itemBuilder: (context, index) {
              final tile = _AuditTile(record: records[index]);
              if (!anime) return tile;
              return AppVisualSurface(
                padding: EdgeInsets.zero,
                clip: true,
                child: tile,
              );
            },
          );
        },
      ),
    );
  }
}

class _AuditTile extends StatelessWidget {
  final ToolAuditRecord record;

  const _AuditTile({required this.record});

  @override
  Widget build(BuildContext context) {
    final anime = AppVisualTheme.of(context).isAnime;
    final kind = record.success
        ? AppStatusKind.success
        : record.approved
            ? AppStatusKind.warning
            : AppStatusKind.error;
    final color = anime
        ? AppStatusPalette.of(context, kind).foreground
        : record.success
            ? Colors.green
            : record.approved
                ? Colors.orange
                : Colors.red;
    return ExpansionTile(
      leading: Icon(record.success ? Icons.check_circle : Icons.error_outline,
          color: color),
      title: Text(record.toolName),
      subtitle: Text('${record.sourceName} · ${_statusText(record)}'),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: [
        _kv('来源', '${record.sourceType}/${record.sourceId}'),
        _kv(
            '属性',
            [
              if (record.trusted) '信任源' else '非信任源',
              if (record.readOnly) '只读' else '可写/外部动作',
              if (record.approved) '已确认' else '已拒绝',
            ].join(' · ')),
        _kv('参数', record.argsPreview.isEmpty ? '(无参数)' : record.argsPreview),
        if (record.resultPreview.isNotEmpty) _kv('结果', record.resultPreview),
        if (record.error != null && record.error!.isNotEmpty)
          _kv('错误', record.error!),
      ],
    );
  }

  static String _statusText(ToolAuditRecord record) {
    if (!record.approved) return '已拒绝';
    return record.success ? '成功' : '失败';
  }

  Widget _kv(String key, String value) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text('$key：$value'),
      ),
    );
  }
}
