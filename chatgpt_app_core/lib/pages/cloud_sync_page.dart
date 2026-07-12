import 'package:chatgpt_app_core/sync/cloud_sync_client.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/widget/app_visual_widgets.dart';
import 'package:flutter/material.dart';
import 'package:login_sdk/dao/login_dao.dart';

typedef CloudSyncClientFactory = Future<CloudSyncClient> Function();
typedef CloudSyncAction = Future<CloudSyncResult> Function();
typedef LastSyncAtLoader = Future<int> Function();

class CloudSyncPage extends StatefulWidget {
  final CloudSyncClientFactory clientFactory;
  final CloudSyncAction? syncAction;
  final LastSyncAtLoader lastSyncAtLoader;

  const CloudSyncPage({
    super.key,
    this.clientFactory = CloudSyncCoordinator.createClient,
    this.syncAction,
    this.lastSyncAtLoader = _defaultLastSyncAtLoader,
  });

  @override
  State<CloudSyncPage> createState() => _CloudSyncPageState();
}

class _CloudSyncPageState extends State<CloudSyncPage> {
  bool _syncing = false;
  CloudSyncResult? _lastResult;
  int _lastSyncAt = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadLastSyncAt();
  }

  @override
  Widget build(BuildContext context) {
    final isGuest = LoginDao.isGuest();
    return Scaffold(
      appBar: AppBar(title: const Text('跨设备云同步')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StatusPanel(
              syncing: _syncing,
              result: _lastResult,
              lastSyncAt: _lastSyncAt,
              error: _error,
              guest: isGuest,
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: isGuest || _syncing ? null : _syncNow,
                icon: _syncing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
                label: Text(_syncing ? '同步中...' : '立即同步'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _syncNow() async {
    setState(() {
      _syncing = true;
      _error = null;
    });
    CloudSyncClient? client;
    try {
      final result = widget.syncAction == null
          ? await () async {
              client = await widget.clientFactory();
              return client!.syncOnce();
            }()
          : await widget.syncAction!();
      if (!mounted) return;
      setState(() {
        _lastResult = result;
        _lastSyncAt = result.finishedAt;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    } finally {
      client?.close();
      if (mounted) {
        setState(() {
          _syncing = false;
        });
      }
    }
  }

  Future<void> _loadLastSyncAt() async {
    final value = await widget.lastSyncAtLoader();
    if (!mounted) return;
    setState(() {
      _lastSyncAt = value;
    });
  }
}

class _StatusPanel extends StatelessWidget {
  final bool syncing;
  final bool guest;
  final CloudSyncResult? result;
  final int lastSyncAt;
  final String? error;

  const _StatusPanel({
    required this.syncing,
    required this.guest,
    required this.lastSyncAt,
    this.result,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    final visual = AppVisualTheme.of(context);
    if (!visual.isAnime) return _classicStatus();

    final kind = switch ((
      guest,
      error != null,
      syncing,
      result != null,
    )) {
      (true, _, _, _) => AppStatusKind.neutral,
      (_, true, _, _) => AppStatusKind.error,
      (_, _, true, _) => AppStatusKind.info,
      (_, _, _, true) => AppStatusKind.success,
      _ => AppStatusKind.info,
    };
    final icon = switch (kind) {
      AppStatusKind.neutral => Icons.person_off_outlined,
      AppStatusKind.error => Icons.cloud_off_outlined,
      AppStatusKind.success => Icons.cloud_done_outlined,
      _ when syncing => Icons.sync_rounded,
      _ => Icons.cloud_sync_outlined,
    };
    final palette = AppStatusPalette.of(context, kind);

    return AppVisualSurface(
      animeKey: const ValueKey('cloud_sync_status_surface'),
      child: Padding(
        padding: EdgeInsets.zero,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 44,
              height: 44,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: palette.container,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: palette.foreground),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _statusText(),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _classicStatus() {
    if (guest) {
      return const Text('游客模式暂不支持云同步，请登录后使用。');
    }
    if (error != null) {
      return Text('同步失败：$error', style: const TextStyle(color: Colors.red));
    }
    if (syncing) {
      return const Text('正在同步当前账号的数据...');
    }
    return Text(_statusText());
  }

  String _statusText() {
    if (guest) return '游客模式暂不支持云同步，请登录后使用。';
    if (error != null) return '同步失败：$error';
    if (syncing) return '正在同步当前账号的数据...';
    final r = result;
    if (r == null) {
      return '可将会话、助手、知识库等本地数据同步到当前账号云端。\n'
          '${_lastSyncText(lastSyncAt)}';
    }
    final conflict = r.hasConflict ? '，冲突 ${_conflictCount(r)} 条' : '';
    final conflictDetail = _conflictDetailText(r);
    return '同步完成（${r.auto ? '自动' : '手动'}）：拉取 ${r.pulled} 条，'
        '上传 ${r.pushed} 条，陈旧 ${r.stale} 条$conflict，'
        '云端游标 ${r.cursor}。\n'
        '${_lastSyncText(lastSyncAt)}$conflictDetail';
  }

  static int _conflictCount(CloudSyncResult result) {
    if (result.conflictDetails.isNotEmpty) return result.conflictDetails.length;
    return result.conflicts.length;
  }

  static String _conflictDetailText(CloudSyncResult result) {
    if (!result.hasConflict) return '';
    final details = result.conflictDetails.isNotEmpty
        ? result.conflictDetails.take(3).map(_formatConflictDetail).join('、')
        : result.conflicts.take(3).map(_formatConflictKey).join('、');
    final more = _conflictCount(result) > 3 ? ' 等' : '';
    return '\n冲突：$details$more';
  }

  static String _formatConflictDetail(SyncConflictDetail detail) {
    final entity = _entityLabel(detail.entity);
    final id = detail.entityId.isEmpty ? '' : ' ${detail.entityId}';
    return '$entity$id：${_reasonLabel(detail.reason)}';
  }

  static String _formatConflictKey(String key) {
    final detail = SyncConflictDetail.fromKey(key);
    return _formatConflictDetail(detail);
  }

  static String _entityLabel(String entity) => switch (entity) {
        'project' => '项目',
        'conversation' => '会话',
        'message' => '消息',
        'assistant' => '助手',
        'favorite' => '收藏',
        'knowledge_doc' => '知识库文档',
        'knowledge_chunk' => '知识库片段',
        'project_knowledge' => '项目知识库绑定',
        _ => entity,
      };

  static String _reasonLabel(String reason) => switch (reason) {
        'remote_newer' => '远端更新，本机已跳过',
        'same_timestamp' => '同时间内容不同',
        'local_same_timestamp' => '本地同时间内容不同',
        'unknown' => '未知原因',
        _ => reason,
      };

  static String _lastSyncText(int timestamp) {
    if (timestamp <= 0) return '尚未同步';
    final time = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final y = time.year.toString().padLeft(4, '0');
    final m = time.month.toString().padLeft(2, '0');
    final d = time.day.toString().padLeft(2, '0');
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    return '上次同步：$y-$m-$d $hh:$mm';
  }
}

Future<int> _defaultLastSyncAtLoader() async =>
    CloudSyncCoordinator.readLastSyncAt();
