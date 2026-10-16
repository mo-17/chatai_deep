import 'dart:async';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter/material.dart';
import 'package:login_sdk/dao/backend_host.dart';

/// 只返回明确选择；保存由原编辑会话/CAS执行，不发模型或更改全局设置。
Future<BackendSelection?> pickBackendSelection(
  BuildContext context, {
  required AiCatalogIdentity identity,
  BackendSelection? selected,
  String? legacyModelId,
  String followLabel = '跟随父层',
}) async {
  void check() {
    if (!identity.current || !identity.authenticated) {
      throw const BackendSelectionEditorExpired();
    }
  }

  check();
  if (ModelCatalog.displaySnapshot.status == CatalogDisplayStatus.initial) {
    unawaited(ModelCatalog.refreshFromBackend(joinOngoing: true));
  }
  final picked = await showModalBottomSheet<_Choice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => AnimatedBuilder(
        animation: Listenable.merge([
          ModelCatalog.displayChanges,
          AiCatalogIdentity.changes,
          BackendConfig.changes
        ]),
        builder: (ctx, _) => SafeArea(
                child: ListView(shrinkWrap: true, children: [
              ListTile(title: Text(_catalogMessage())),
              TextButton.icon(
                  onPressed: identity.current
                      ? () => unawaited(
                          ModelCatalog.refreshFromBackend(joinOngoing: true))
                      : null,
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新模型清单')),
              ListTile(
                  key: const ValueKey('backend_follow'),
                  title: Text(followLabel),
                  onTap: identity.current
                      ? () => Navigator.pop(ctx, const _Follow())
                      : null),
              for (final option
                  in identity.current ? _options() : const <ModelOption>[])
                ListTile(
                    key: ValueKey(option.pairKey),
                    title: Text(option.backendLabel),
                    trailing: selected?.providerCode == option.providerCode &&
                            selected?.modelId == option.id
                        ? const Icon(Icons.check)
                        : null,
                    onTap: () => Navigator.pop(
                        ctx, _Pair(option.providerCode!, option.id))),
              ListTile(
                  key: const ValueKey('backend_custom'),
                  title: const Text('自定义服务商与模型...'),
                  onTap: identity.current
                      ? () => Navigator.pop(ctx, const _Custom())
                      : null),
            ]))),
  );
  if (picked == null) return null;
  check();
  if (picked is _Follow) return BackendSelection.follow();
  _Pair? pair;
  if (picked is _Pair) pair = picked;
  if (picked is _Custom) {
    if (!context.mounted) return null;
    pair = await showDialog<_Pair>(
        context: context,
        builder: (_) => _PairDialog(
            code: selected?.providerCode ?? '',
            model: selected?.modelId ?? legacyModelId ?? ''));
    if (pair == null) return null;
  }
  check();
  return BackendSelection.pair(
      providerCode: pair!.code,
      modelId: pair.model,
      accountHash: identity.account!,
      origin: identity.endpoint.origin);
}

String backendSelectionLabel(BackendSelection? selected,
    {String? legacyModelId, String followLabel = '跟随父层'}) {
  if (selected == null) {
    return legacyModelId?.trim().isNotEmpty == true
        ? '旧选择 · $legacyModelId（服务商待确认）'
        : followLabel;
  }
  if (selected.isFollow) return followLabel;
  if (!selected.isPair) return '原后端选择无法识别，请重新选择';
  final identity = AiCatalogIdentity.capture();
  final same = selected.matchesScope(
      accountHash: identity.account ?? '', origin: identity.endpoint.origin);
  final matches = same
      ? ModelCatalog.displaySnapshot.options
          .where((o) =>
              o.providerCode == selected.providerCode &&
              o.id == selected.modelId)
          .toList()
      : const <ModelOption>[];
  final label = matches.length == 1
      ? matches.single.backendLabel
      : '${selected.providerCode} · ${selected.modelId}';
  if (!same) {
    return '$label（其它账号或地址，请重新选择）';
  }
  if (!ModelCatalog.backendProfileAvailable(selected.modelId!,
      account: identity.account ?? '', providerCode: selected.providerCode)) {
    return '$label（已删除或停用，请重新选择）';
  }
  return label;
}

List<ModelOption> _options() {
  final snapshot = ModelCatalog.displaySnapshot;
  if (!snapshot.hasSnapshot) return const [];
  final keys = <String>{};
  for (final o in snapshot.options) {
    if (o.providerCode == null ||
        o.providerCode!.trim().isEmpty ||
        o.id.trim().isEmpty ||
        !keys.add(o.pairKey)) {
      return const [];
    }
  }
  return snapshot.options;
}

String _catalogMessage() {
  final snapshot = ModelCatalog.displaySnapshot;
  if (snapshot.hasSnapshot) {
    if (snapshot.options.isNotEmpty && _options().isEmpty) {
      return '上次清单缺少完整服务商信息，请刷新或明确填写';
    }
    return snapshot.message;
  }
  return switch (snapshot.status) {
    CatalogDisplayStatus.forbidden => '服务器未开放模型目录，请联系管理员或明确填写服务商与模型',
    CatalogDisplayStatus.notAuthenticated => '请登录后选择服务商与模型',
    CatalogDisplayStatus.timeout => '获取模型目录超时，请刷新或明确填写',
    CatalogDisplayStatus.failed => '获取模型目录失败，请刷新或明确填写',
    CatalogDisplayStatus.loading => '正在加载模型清单…',
    _ => '尚未确认模型清单，请刷新或明确填写',
  };
}

class BackendSelectionEditorExpired implements Exception {
  const BackendSelectionEditorExpired();
  @override
  String toString() => '编辑账号、登录或后端来源已变化，请重新打开模型选择';
}

sealed class _Choice {
  const _Choice();
}

class _Follow extends _Choice {
  const _Follow();
}

class _Custom extends _Choice {
  const _Custom();
}

class _Pair extends _Choice {
  final String code, model;
  const _Pair(this.code, this.model);
}

class _PairDialog extends StatefulWidget {
  final String code, model;
  const _PairDialog({required this.code, required this.model});
  @override
  State<_PairDialog> createState() => _PairDialogState();
}

class _PairDialogState extends State<_PairDialog> {
  late final code = TextEditingController(text: widget.code);
  late final model = TextEditingController(text: widget.model);
  bool invalid = false;
  @override
  void dispose() {
    code.dispose();
    model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: const Text('后端服务商与模型'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                key: const ValueKey('backend_provider_code'),
                controller: code,
                decoration: InputDecoration(
                    labelText: '服务商 code',
                    errorText: invalid && code.text.trim().isEmpty
                        ? '请输入服务商 code'
                        : null)),
            TextField(
                key: const ValueKey('backend_model_id'),
                controller: model,
                decoration: InputDecoration(
                    labelText: '模型 id',
                    errorText: invalid && model.text.trim().isEmpty
                        ? '请输入模型 id'
                        : null)),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消')),
            FilledButton(
                onPressed: () {
                  if (code.text.trim().isEmpty || model.text.trim().isEmpty) {
                    setState(() => invalid = true);
                    return;
                  }
                  Navigator.pop(context, _Pair(code.text, model.text));
                },
                child: const Text('保存')),
          ]);
}
