import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/usage_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/usage_record.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

class UsageStatsSnapshot {
  final List<UsageAggregate> byModel;
  final List<UsageAggregate> byProvider;
  final List<UsageAggregate> byDate;
  final List<UsageAggregate> byProject;
  final List<UsageAggregate> byConversation;

  const UsageStatsSnapshot({
    this.byModel = const [],
    this.byProvider = const [],
    this.byDate = const [],
    this.byProject = const [],
    this.byConversation = const [],
  });

  int get totalTokens => byModel.fold(0, (sum, item) => sum + item.totalTokens);

  double get totalCost => byModel.fold(0, (sum, item) => sum + item.cost);

  bool get hasEstimated => byModel.any((item) => item.estimated);

  bool get isEmpty =>
      byModel.isEmpty &&
      byProvider.isEmpty &&
      byDate.isEmpty &&
      byProject.isEmpty &&
      byConversation.isEmpty;
}

typedef UsageStatsLoader = Future<UsageStatsSnapshot> Function();

class UsageStatsExportFormatter {
  const UsageStatsExportFormatter._();

  static String buildText(UsageStatsSnapshot snapshot) {
    final buffer = StringBuffer()
      ..writeln('用量统计')
      ..writeln('总 Token：${snapshot.totalTokens}')
      ..writeln('估算成本：${snapshot.totalCost.toStringAsFixed(4)}')
      ..writeln('数据来源：${snapshot.hasEstimated ? '含估算' : '真实 usage'}');
    _writeSection(buffer, '按模型', snapshot.byModel);
    _writeSection(buffer, '按服务商', snapshot.byProvider);
    _writeSection(buffer, '按日期', snapshot.byDate);
    _writeSection(buffer, '按项目', snapshot.byProject);
    _writeSection(buffer, '按会话', snapshot.byConversation);
    return buffer.toString().trimRight();
  }

  static void _writeSection(
    StringBuffer buffer,
    String title,
    List<UsageAggregate> items,
  ) {
    buffer
      ..writeln()
      ..writeln('[$title]');
    if (items.isEmpty) {
      buffer.writeln('暂无数据');
      return;
    }
    for (final item in items) {
      buffer.writeln(
        '${item.key}：调用 ${item.calls} 次，'
        '输入 ${item.promptTokens}，缓存输入 ${item.cachedPromptTokens}，'
        '未缓存输入 ${item.uncachedPromptTokens}，输出 ${item.completionTokens}，'
        '总计 ${item.totalTokens}，成本 ${item.cost.toStringAsFixed(4)}'
        '${item.estimated ? '，含估算' : ''}',
      );
    }
  }
}

/// 用户侧用量统计页。
///
/// 后端代理会优先落真实 usage；本地直连/流式缺 usage 时使用估算并在页面标注。
class UsageStatsPage extends StatefulWidget {
  final UsageStatsLoader? loader;

  const UsageStatsPage({super.key, this.loader});

  static Future<UsageStatsSnapshot> loadDefault() async {
    final storage =
        await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    final dao = await UsageDao.create(storage);
    return UsageStatsSnapshot(
      byModel: await dao.aggregateByModel(),
      byProvider: await dao.aggregateByProvider(),
      byDate: await dao.aggregateByDate(),
      byProject: await dao.aggregateByProject(),
      byConversation: await dao.aggregateByConversation(),
    );
  }

  @override
  State<UsageStatsPage> createState() => _UsageStatsPageState();
}

class _UsageStatsPageState extends State<UsageStatsPage> {
  late Future<UsageStatsSnapshot> _snapshotFuture;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _snapshotFuture = (widget.loader ?? UsageStatsPage.loadDefault)();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('用量统计'),
          centerTitle: true,
          actions: [
            IconButton(
              icon: const Icon(Icons.price_change_outlined),
              tooltip: '成本单价',
              onPressed: () => _openCostSettings(context),
            ),
            PopupMenuButton<_UsageStatsAction>(
              tooltip: '更多',
              onSelected: (action) {
                switch (action) {
                  case _UsageStatsAction.recalculateCost:
                    _recalculateHistoricalCosts(context);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: _UsageStatsAction.recalculateCost,
                  child: Text('重算历史成本'),
                ),
              ],
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: '模型'),
              Tab(text: '服务商'),
              Tab(text: '日期'),
              Tab(text: '项目'),
              Tab(text: '会话'),
            ],
          ),
        ),
        body: FutureBuilder<UsageStatsSnapshot>(
          future: _snapshotFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(child: Text('用量统计加载失败：${snapshot.error}'));
            }
            final data = snapshot.data ?? const UsageStatsSnapshot();
            if (data.isEmpty) {
              return const Center(child: Text('还没有用量记录'));
            }
            return Column(
              children: [
                _Summary(snapshot: data),
                Expanded(
                  child: TabBarView(
                    children: [
                      _AggregateList(items: data.byModel, emptyText: '暂无模型用量'),
                      _AggregateList(
                          items: data.byProvider, emptyText: '暂无服务商用量'),
                      _AggregateList(items: data.byDate, emptyText: '暂无日期用量'),
                      _AggregateList(
                          items: data.byProject, emptyText: '暂无项目用量'),
                      _AggregateList(
                          items: data.byConversation, emptyText: '暂无会话用量'),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _openCostSettings(BuildContext context) async {
    final store = context.read<AISettingsProvider>();
    final result = await showDialog<UsageCostConfig>(
      context: context,
      builder: (_) => _UsageCostSettingsDialog(
        initial: store.settings.usageCostConfig,
      ),
    );
    if (result == null) return;
    final next = store.settings.clone()..usageCostConfig = result;
    await store.update(next);
    if (context.mounted) {
      setState(_reload);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('成本单价已保存')),
      );
    }
  }

  Future<void> _recalculateHistoricalCosts(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final costConfig =
        context.read<AISettingsProvider>().settings.usageCostConfig;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('重算历史成本'),
        content: const Text('将使用当前成本单价，重算历史记录中成本为 0 的用量。已有成本的记录不会被覆盖。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('重算'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final storage =
          await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
      final dao = await UsageDao.create(storage);
      final records = await dao.queryZeroCostRecords();
      var updated = 0;
      var skipped = 0;
      for (final record in records) {
        final id = record.id;
        if (id == null) {
          skipped++;
          continue;
        }
        final rate = costConfig.rateFor(
          providerId: record.providerId,
          modelId: record.modelId,
          at: DateTime.fromMillisecondsSinceEpoch(record.createdAt),
        );
        if (rate.isZero) {
          skipped++;
          continue;
        }
        final cost = rate.costFor(
          promptTokens: record.promptTokens,
          cachedPromptTokens: record.cachedPromptTokens,
          completionTokens: record.completionTokens,
        );
        if (cost <= 0) {
          skipped++;
          continue;
        }
        updated += await dao.updateCost(id, cost);
      }
      if (!mounted) return;
      setState(_reload);
      messenger.showSnackBar(
        SnackBar(content: Text('历史成本已重算：更新 $updated 条，跳过 $skipped 条')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('历史成本重算失败：$e')),
      );
    }
  }
}

enum _UsageStatsAction { recalculateCost }

class _Summary extends StatelessWidget {
  final UsageStatsSnapshot snapshot;

  const _Summary({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _metric('总 Token', snapshot.totalTokens.toString()),
                _metric(
                    '缓存输入',
                    snapshot.byModel
                        .fold<int>(
                            0, (sum, item) => sum + item.cachedPromptTokens)
                        .toString()),
                _metric('估算成本', snapshot.totalCost.toStringAsFixed(4)),
                _metric('数据来源', snapshot.hasEstimated ? '含估算' : '真实 usage'),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy_all_outlined),
            tooltip: '复制汇总',
            onPressed: () => _copySummary(context),
          ),
        ],
      ),
    );
  }

  Future<void> _copySummary(BuildContext context) async {
    await Clipboard.setData(
      ClipboardData(text: UsageStatsExportFormatter.buildText(snapshot)),
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('用量汇总已复制')),
      );
    }
  }

  Widget _metric(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: const TextStyle(fontSize: 12, color: Colors.black54)),
        const SizedBox(height: 2),
        Text(value,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      ],
    );
  }
}

class _AggregateList extends StatelessWidget {
  final List<UsageAggregate> items;
  final String emptyText;

  const _AggregateList({required this.items, required this.emptyText});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return Center(child: Text(emptyText));
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final item = items[index];
        return ListTile(
          title: Text(item.key),
          subtitle: Text(
            '调用 ${item.calls} 次 · 输入 ${item.promptTokens} · 缓存 ${item.cachedPromptTokens} · 未缓存 ${item.uncachedPromptTokens} · 输出 ${item.completionTokens}',
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('${item.totalTokens} token',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              if (item.estimated)
                const Text('含估算',
                    style: TextStyle(fontSize: 12, color: Colors.orange)),
            ],
          ),
        );
      },
    );
  }
}

class _UsageCostSettingsDialog extends StatefulWidget {
  final UsageCostConfig initial;

  const _UsageCostSettingsDialog({required this.initial});

  @override
  State<_UsageCostSettingsDialog> createState() =>
      _UsageCostSettingsDialogState();
}

class _UsageCostSettingsDialogState extends State<_UsageCostSettingsDialog> {
  late final TextEditingController _defaultCachedInputCtl;
  late final TextEditingController _defaultInputCtl;
  late final TextEditingController _defaultOutputCtl;
  late final TextEditingController _providerCtl;
  late final TextEditingController _modelCtl;
  late final TextEditingController _overrideCachedInputCtl;
  late final TextEditingController _overrideInputCtl;
  late final TextEditingController _overrideOutputCtl;

  @override
  void initState() {
    super.initState();
    final d = widget.initial.defaultRate;
    _defaultCachedInputCtl = TextEditingController(
        text: _formatRate(d.effectiveCachedInputCostPer1K));
    _defaultInputCtl =
        TextEditingController(text: _formatRate(d.inputCostPer1K));
    _defaultOutputCtl =
        TextEditingController(text: _formatRate(d.outputCostPer1K));
    _providerCtl = TextEditingController();
    _modelCtl = TextEditingController();
    _overrideCachedInputCtl = TextEditingController();
    _overrideInputCtl = TextEditingController();
    _overrideOutputCtl = TextEditingController();
  }

  @override
  void dispose() {
    _defaultCachedInputCtl.dispose();
    _defaultInputCtl.dispose();
    _defaultOutputCtl.dispose();
    _providerCtl.dispose();
    _modelCtl.dispose();
    _overrideCachedInputCtl.dispose();
    _overrideInputCtl.dispose();
    _overrideOutputCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final overrideCount = widget.initial.overrides.entries
        .where((entry) => !_isBuiltinOverride(entry.key, entry.value))
        .length;
    return AlertDialog(
      title: const Text('成本单价'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('默认单价（每 1M token）'),
            const SizedBox(height: 8),
            _rateFields(
                _defaultCachedInputCtl, _defaultInputCtl, _defaultOutputCtl),
            const SizedBox(height: 16),
            _builtinRatesSection(context),
            const SizedBox(height: 16),
            Text('新增或覆盖服务商规则（已有 $overrideCount 条）'),
            const SizedBox(height: 8),
            TextField(
              controller: _providerCtl,
              decoration: const InputDecoration(
                labelText: '服务商 ID（可选）',
                hintText: 'openai',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _modelCtl,
              decoration: const InputDecoration(
                labelText: '模型 ID（可选，留空表示该服务商默认）',
                hintText: 'gpt-4o 或留空',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            _rateFields(
                _overrideCachedInputCtl, _overrideInputCtl, _overrideOutputCtl),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }

  Widget _builtinRatesSection(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('内置价格'),
            const SizedBox(width: 8),
            _sourceChip('内置'),
          ],
        ),
        const SizedBox(height: 8),
        for (final entry in UsageCostConfig.builtinOverrides.entries) ...[
          _builtinRateTile(
            context,
            title: entry.key,
            subtitle: '平时价格',
            rate: entry.value,
          ),
          const SizedBox(height: 8),
        ],
        if (UsageCostConfig.builtinTimeRules.isNotEmpty) ...[
          Text(
            '分时价格',
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.black54),
          ),
          const SizedBox(height: 8),
          for (final rule in UsageCostConfig.builtinTimeRules) ...[
            _builtinRateTile(
              context,
              title: rule.key,
              subtitle:
                  '${_minuteLabel(rule.startMinute)}-${_minuteLabel(rule.endMinute)} 北京时间',
              rate: rule.rate,
            ),
            const SizedBox(height: 8),
          ],
        ],
      ],
    );
  }

  Widget _builtinRateTile(
    BuildContext context, {
    required String title,
    required String subtitle,
    required UsageCostRate rate,
  }) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              _sourceChip('内置'),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.black54),
          ),
          const SizedBox(height: 8),
          Text(
            '缓存 ${_formatRate(rate.effectiveCachedInputCostPer1K)} / 未缓存 ${_formatRate(rate.inputCostPer1K)} / 输出 ${_formatRate(rate.outputCostPer1K)} 元 / 1M',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _sourceChip(String label) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFE8F5E9),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          label,
          style: const TextStyle(fontSize: 12, color: Color(0xFF2E7D32)),
        ),
      ),
    );
  }

  Widget _rateFields(
    TextEditingController cachedInputCtl,
    TextEditingController inputCtl,
    TextEditingController outputCtl,
  ) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: cachedInputCtl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: '缓存输入 / 1M',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: inputCtl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: '输入 / 1M',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: outputCtl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: '输出 / 1M',
              border: OutlineInputBorder(),
            ),
          ),
        ),
      ],
    );
  }

  void _save() {
    final overrides = Map<String, UsageCostRate>.of(widget.initial.overrides);
    final provider = _providerCtl.text.trim();
    final model = _modelCtl.text.trim();
    final overrideTouched = provider.isNotEmpty ||
        model.isNotEmpty ||
        _overrideCachedInputCtl.text.trim().isNotEmpty ||
        _overrideInputCtl.text.trim().isNotEmpty ||
        _overrideOutputCtl.text.trim().isNotEmpty;
    if (overrideTouched && provider.isNotEmpty) {
      final key = model.isEmpty ? '$provider/*' : '$provider/$model';
      overrides[key] = UsageCostRate(
        cachedInputCostPer1K: _parseNullableRate(_overrideCachedInputCtl.text),
        inputCostPer1K: _parseRate(_overrideInputCtl.text),
        outputCostPer1K: _parseRate(_overrideOutputCtl.text),
      );
    }
    Navigator.pop(
      context,
      UsageCostConfig(
        defaultRate: UsageCostRate(
          cachedInputCostPer1K: _parseNullableRate(_defaultCachedInputCtl.text),
          inputCostPer1K: _parseRate(_defaultInputCtl.text),
          outputCostPer1K: _parseRate(_defaultOutputCtl.text),
        ),
        overrides: overrides,
        timeRules: widget.initial.timeRules,
      ),
    );
  }

  static double _parseRate(String raw) =>
      double.tryParse(raw.trim().replaceAll(',', '')) ?? 0;

  static double? _parseNullableRate(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    return double.tryParse(value.replaceAll(',', '')) ?? 0;
  }

  static String _formatRate(double value) => value == 0
      ? ''
      : value
          .toStringAsFixed(6)
          .replaceFirst(RegExp(r'0+$'), '')
          .replaceFirst(RegExp(r'\.$'), '');

  static String _minuteLabel(int minute) {
    final hour = minute ~/ 60;
    final min = minute % 60;
    return '${hour.toString().padLeft(2, '0')}:${min.toString().padLeft(2, '0')}';
  }

  static bool _isBuiltinOverride(String key, UsageCostRate rate) {
    final builtin = UsageCostConfig.builtinOverrides[key];
    return builtin != null && builtin.sameValue(rate);
  }
}
