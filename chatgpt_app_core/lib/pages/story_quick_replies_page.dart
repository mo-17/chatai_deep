import 'dart:convert';

import 'package:chatgpt_app_core/model/story_quick_reply.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/widget/story_visual_widgets.dart';
import 'package:flutter/material.dart';

typedef StoryQuickRepliesSave = Future<void> Function(StoryRoomModel room);

class StoryQuickRepliesPage extends StatefulWidget {
  final StoryRoomModel room;
  final StoryQuickRepliesSave onSave;

  const StoryQuickRepliesPage({
    super.key,
    required this.room,
    required this.onSave,
  });

  @override
  State<StoryQuickRepliesPage> createState() => _StoryQuickRepliesPageState();
}

class _StoryQuickRepliesPageState extends State<StoryQuickRepliesPage> {
  late StoryQuickReplyCollectionModel _collection;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _collection = StoryQuickReplyCollectionModel.tryParse(
      widget.room.quickRepliesJson,
    );
    if (_collection.roomId == 0 && widget.room.id != null) {
      _collection.roomId = widget.room.id!;
    }
    for (final group in _collection.groups) {
      if (group.roomId == 0 && widget.room.id != null) {
        group.roomId = widget.room.id!;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = _collection.sortedGroups();
    return Scaffold(
      key: const ValueKey('story_quick_replies_page'),
      appBar: AppBar(
        title: const Text('快捷回复'),
        actions: [
          IconButton(
            key: const ValueKey('story_quick_replies_save'),
            tooltip: '保存快捷回复',
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
          ),
        ],
      ),
      body: groups.isEmpty
          ? _buildEmptyState()
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
              itemCount: groups.length,
              separatorBuilder: (_, __) => storyUsesAnimeStyle(context)
                  ? const SizedBox.shrink()
                  : const Divider(height: 1),
              itemBuilder: (context, index) =>
                  _buildGroup(context, groups[index], index, groups.length),
            ),
      floatingActionButton: FloatingActionButton(
        key: const ValueKey('story_quick_replies_add_group'),
        tooltip: '新增分组',
        onPressed: _addGroup,
        child: const Icon(Icons.create_new_folder_outlined),
      ),
    );
  }

  Widget _buildEmptyState() {
    return StoryAdaptiveEmptyState(
      classicChild: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.forum_outlined, size: 48),
              const SizedBox(height: 12),
              const Text('还没有快捷回复分组'),
              const SizedBox(height: 6),
              Text(
                '把常用的故事回应收进房间里，需要时一键发送。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                key: const ValueKey('story_quick_replies_empty_add'),
                onPressed: _addGroup,
                icon: const Icon(Icons.add),
                label: const Text('新增分组'),
              ),
            ],
          ),
        ),
      ),
      icon: Icons.forum_outlined,
      title: '还没有快捷回复分组',
      subtitle: '把常用的故事回应收进房间里，需要时一键发送。',
      action: FilledButton.icon(
        key: const ValueKey('story_quick_replies_empty_add'),
        onPressed: _addGroup,
        icon: const Icon(Icons.add),
        label: const Text('新增分组'),
      ),
    );
  }

  Widget _buildGroup(
    BuildContext context,
    StoryQuickReplyGroupModel group,
    int index,
    int groupCount,
  ) {
    final items = group.sortedItems();
    return StoryAdaptiveListItem(
      animeMargin: const EdgeInsets.symmetric(vertical: 5),
      child: ExpansionTile(
        key: PageStorageKey<String>('story_quick_reply_group_${group.key}'),
        initiallyExpanded: true,
        tilePadding: const EdgeInsets.symmetric(horizontal: 4),
        childrenPadding: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
        title: Text(
          group.label.isEmpty ? group.key : group.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${items.length} 条 · ${group.enabled ? '已启用' : '已停用'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: _buildGroupActions(group, index, groupCount),
        children: [
          if (items.isEmpty)
            const Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.fromLTRB(8, 4, 8, 12),
                child: Text('这个分组还没有条目'),
              ),
            ),
          for (var itemIndex = 0; itemIndex < items.length; itemIndex++)
            _buildItem(
              context,
              group,
              items[itemIndex],
              itemIndex,
              items.length,
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: ValueKey('story_quick_replies_add_item_${group.key}'),
              onPressed: () => _addItem(group),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('新增条目'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupActions(
    StoryQuickReplyGroupModel group,
    int index,
    int groupCount,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Switch(
          key: ValueKey('story_quick_replies_group_enabled_${group.key}'),
          value: group.enabled,
          onChanged: (value) => setState(() => group.enabled = value),
        ),
        _compactIconButton(
          key: ValueKey('story_quick_replies_group_up_${group.key}'),
          tooltip: '分组上移',
          icon: Icons.keyboard_arrow_up,
          onPressed: index == 0 ? null : () => _moveGroup(group, -1),
        ),
        _compactIconButton(
          key: ValueKey('story_quick_replies_group_down_${group.key}'),
          tooltip: '分组下移',
          icon: Icons.keyboard_arrow_down,
          onPressed:
              index == groupCount - 1 ? null : () => _moveGroup(group, 1),
        ),
        PopupMenuButton<String>(
          key: ValueKey('story_quick_replies_group_menu_${group.key}'),
          tooltip: '分组操作',
          onSelected: (value) {
            if (value == 'edit') _editGroup(group);
            if (value == 'delete') _deleteGroup(group);
          },
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: 'edit',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.edit_outlined),
                title: Text('编辑分组'),
              ),
            ),
            PopupMenuItem(
              value: 'delete',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.delete_outline),
                title: Text('删除分组'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildItem(
    BuildContext context,
    StoryQuickReplyGroupModel group,
    StoryQuickReplyModel item,
    int index,
    int itemCount,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  item.label.isEmpty ? item.key : item.label,
                  key: ValueKey('story_quick_replies_item_label_${item.key}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '启用',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              Switch(
                key: ValueKey('story_quick_replies_item_enabled_${item.key}'),
                value: item.enabled,
                onChanged: (value) => setState(() => item.enabled = value),
              ),
            ],
          ),
          if (item.content.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8, top: 2),
              child: Text(
                item.content,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          const SizedBox(height: 4),
          if (storyUsesAnimeStyle(context))
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              runSpacing: 4,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('立即发送', style: Theme.of(context).textTheme.labelSmall),
                    Switch(
                      key: ValueKey(
                        'story_quick_replies_item_immediate_${item.key}',
                      ),
                      value: item.sendImmediately,
                      onChanged: (value) =>
                          setState(() => item.sendImmediately = value),
                    ),
                  ],
                ),
                _itemMoveUpButton(group, item, index),
                _itemMoveDownButton(group, item, index, itemCount),
                _itemEditButton(group, item),
                _itemMenu(group, item),
              ],
            )
          else
            Row(
              children: [
                Text('立即发送', style: Theme.of(context).textTheme.labelSmall),
                Switch(
                  key: ValueKey(
                    'story_quick_replies_item_immediate_${item.key}',
                  ),
                  value: item.sendImmediately,
                  onChanged: (value) =>
                      setState(() => item.sendImmediately = value),
                ),
                const Spacer(),
                _itemMoveUpButton(group, item, index),
                _itemMoveDownButton(group, item, index, itemCount),
                _itemEditButton(group, item),
                _itemMenu(group, item),
              ],
            ),
          if (index < itemCount - 1) const Divider(height: 16),
        ],
      ),
    );
  }

  Widget _itemMoveUpButton(
    StoryQuickReplyGroupModel group,
    StoryQuickReplyModel item,
    int index,
  ) =>
      _compactIconButton(
        key: ValueKey('story_quick_replies_item_up_${item.key}'),
        tooltip: '条目上移',
        icon: Icons.keyboard_arrow_up,
        onPressed: index == 0 ? null : () => _moveItem(group, item, -1),
      );

  Widget _itemMoveDownButton(
    StoryQuickReplyGroupModel group,
    StoryQuickReplyModel item,
    int index,
    int itemCount,
  ) =>
      _compactIconButton(
        key: ValueKey('story_quick_replies_item_down_${item.key}'),
        tooltip: '条目下移',
        icon: Icons.keyboard_arrow_down,
        onPressed:
            index == itemCount - 1 ? null : () => _moveItem(group, item, 1),
      );

  Widget _itemEditButton(
    StoryQuickReplyGroupModel group,
    StoryQuickReplyModel item,
  ) =>
      _compactIconButton(
        key: ValueKey('story_quick_replies_item_edit_${item.key}'),
        tooltip: '编辑条目',
        icon: Icons.edit_outlined,
        onPressed: () => _editItem(group, item),
      );

  Widget _itemMenu(
    StoryQuickReplyGroupModel group,
    StoryQuickReplyModel item,
  ) =>
      PopupMenuButton<String>(
        key: ValueKey('story_quick_replies_item_menu_${item.key}'),
        tooltip: '条目操作',
        onSelected: (value) {
          if (value == 'delete') _deleteItem(group, item);
        },
        itemBuilder: (_) => const [
          PopupMenuItem(
            value: 'delete',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.delete_outline),
              title: Text('删除条目'),
            ),
          ),
        ],
      );

  Widget _compactIconButton({
    required Key key,
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    final dimension =
        storyUsesAnimeStyle(context) ? kStoryMinTouchTarget : 36.0;
    return IconButton(
      key: key,
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      visualDensity: storyUsesAnimeStyle(context)
          ? VisualDensity.standard
          : VisualDensity.compact,
      constraints: BoxConstraints(
        minWidth: dimension,
        minHeight: dimension,
      ),
      padding: EdgeInsets.zero,
    );
  }

  Future<void> _addGroup() async {
    if (_collection.groups.length >= StoryQuickReplyLimits.maxGroups) {
      _showValidation('最多创建 ${StoryQuickReplyLimits.maxGroups} 个分组');
      return;
    }
    final group = await _showGroupDialog();
    if (!mounted || group == null) return;
    if (_collection.groups.any((item) => item.key == group.key)) {
      _showValidation('分组 key 已存在');
      return;
    }
    group
      ..roomId = _collection.roomId
      ..sortOrder = _collection.groups.length;
    setState(() => _collection.groups.add(group));
  }

  Future<void> _editGroup(StoryQuickReplyGroupModel group) async {
    final edited = await _showGroupDialog(group: group);
    if (!mounted || edited == null) return;
    if (_collection.groups
        .any((item) => !identical(item, group) && item.key == edited.key)) {
      _showValidation('分组 key 已存在');
      return;
    }
    edited
      ..roomId = group.roomId
      ..sortOrder = group.sortOrder
      ..items = group.items;
    setState(() {
      final index = _collection.groups.indexOf(group);
      if (index >= 0) _collection.groups[index] = edited;
    });
  }

  Future<void> _deleteGroup(StoryQuickReplyGroupModel group) async {
    final confirmed = await _confirmDelete('删除分组「${group.label}」及其全部条目？');
    if (!mounted || !confirmed) return;
    setState(() => _collection.groups.remove(group));
  }

  Future<void> _addItem(StoryQuickReplyGroupModel group) async {
    if (group.items.length >= StoryQuickReplyLimits.maxItemsPerGroup ||
        _collection.filterItems(enabledOnly: false).length >=
            StoryQuickReplyLimits.maxItems) {
      _showValidation('快捷回复数量已达到上限');
      return;
    }
    final item = await _showItemDialog();
    if (!mounted || item == null) return;
    if (item.content.trim().isEmpty) {
      _showValidation('发送内容不能为空');
      return;
    }
    if (group.items.any((value) => value.key == item.key)) {
      _showValidation('条目 key 已存在');
      return;
    }
    item.sortOrder = group.items.length;
    setState(() => group.items.add(item));
  }

  Future<void> _editItem(
    StoryQuickReplyGroupModel group,
    StoryQuickReplyModel item,
  ) async {
    final edited = await _showItemDialog(item: item);
    if (!mounted || edited == null) return;
    if (edited.content.trim().isEmpty) {
      _showValidation('发送内容不能为空');
      return;
    }
    if (group.items
        .any((value) => !identical(value, item) && value.key == edited.key)) {
      _showValidation('条目 key 已存在');
      return;
    }
    edited.sortOrder = item.sortOrder;
    setState(() {
      final index = group.items.indexOf(item);
      if (index >= 0) group.items[index] = edited;
    });
  }

  Future<void> _deleteItem(
    StoryQuickReplyGroupModel group,
    StoryQuickReplyModel item,
  ) async {
    final confirmed = await _confirmDelete('删除条目「${item.label}」？');
    if (!mounted || !confirmed) return;
    setState(() => group.items.remove(item));
  }

  void _moveGroup(StoryQuickReplyGroupModel group, int delta) {
    final sorted = _collection.sortedGroups();
    final from = sorted.indexOf(group);
    final to = from + delta;
    if (from < 0 || to < 0 || to >= sorted.length) return;
    final moved = sorted.removeAt(from);
    sorted.insert(to, moved);
    for (var index = 0; index < sorted.length; index++) {
      sorted[index].sortOrder = index;
    }
    setState(() => _collection.groups = sorted);
  }

  void _moveItem(
    StoryQuickReplyGroupModel group,
    StoryQuickReplyModel item,
    int delta,
  ) {
    final sorted = group.sortedItems();
    final from = sorted.indexOf(item);
    final to = from + delta;
    if (from < 0 || to < 0 || to >= sorted.length) return;
    final moved = sorted.removeAt(from);
    sorted.insert(to, moved);
    for (var index = 0; index < sorted.length; index++) {
      sorted[index].sortOrder = index;
    }
    setState(() => group.items = sorted);
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final raw = jsonEncode(_collection.toJson());
    widget.room.quickRepliesJson = raw;
    try {
      await widget.onSave(widget.room);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('快捷回复已保存')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败：$error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showValidation(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<bool> _confirmDelete(String message) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('确认删除'),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                style: storyUsesAnimeStyle(context)
                    ? FilledButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.error,
                        foregroundColor: Theme.of(context).colorScheme.onError,
                      )
                    : null,
                child: const Text('删除'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<StoryQuickReplyGroupModel?> _showGroupDialog({
    StoryQuickReplyGroupModel? group,
  }) async {
    var keyValue = group?.key ?? '';
    var labelValue = group?.label ?? '';
    return showDialog<StoryQuickReplyGroupModel>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(group == null ? '新增分组' : '编辑分组'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: const ValueKey('story_quick_reply_group_key'),
                initialValue: keyValue,
                onChanged: (value) => keyValue = value,
                decoration: const InputDecoration(
                  labelText: '稳定 key',
                  hintText: '例如：common',
                ),
                maxLength: StoryQuickReplyLimits.maxKeyLength,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('story_quick_reply_group_label'),
                initialValue: labelValue,
                onChanged: (value) => labelValue = value,
                decoration: const InputDecoration(labelText: '分组名称'),
                maxLength: StoryQuickReplyLimits.maxLabelLength,
                textInputAction: TextInputAction.done,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('story_quick_reply_dialog_save'),
            onPressed: () {
              final label = labelValue.trim();
              Navigator.pop(
                context,
                StoryQuickReplyGroupModel(
                  key: keyValue,
                  label: label.isEmpty ? '未命名分组' : label,
                  enabled: group?.enabled ?? true,
                ),
              );
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Future<StoryQuickReplyModel?> _showItemDialog({
    StoryQuickReplyModel? item,
  }) async {
    var keyValue = item?.key ?? '';
    var labelValue = item?.label ?? '';
    var contentValue = item?.content ?? '';
    return showDialog<StoryQuickReplyModel>(
      context: context,
      builder: (context) {
        var enabled = item?.enabled ?? true;
        var sendImmediately = item?.sendImmediately ?? false;
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(item == null ? '新增条目' : '编辑条目'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    key: const ValueKey('story_quick_reply_item_key'),
                    initialValue: keyValue,
                    onChanged: (value) => keyValue = value,
                    decoration: const InputDecoration(
                      labelText: '稳定 key',
                      hintText: '例如：greeting',
                    ),
                    maxLength: StoryQuickReplyLimits.maxKeyLength,
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const ValueKey('story_quick_reply_item_label'),
                    initialValue: labelValue,
                    onChanged: (value) => labelValue = value,
                    decoration: const InputDecoration(labelText: '显示名称'),
                    maxLength: StoryQuickReplyLimits.maxLabelLength,
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const ValueKey('story_quick_reply_item_content'),
                    initialValue: contentValue,
                    onChanged: (value) => contentValue = value,
                    decoration: const InputDecoration(
                      labelText: '发送内容',
                      hintText: '支持 {{char}}、{{user}}、{{room}}、{{input}}',
                    ),
                    minLines: 3,
                    maxLines: 7,
                    maxLength: StoryQuickReplyLimits.maxContentLength,
                  ),
                  const SizedBox(height: 4),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用'),
                    value: enabled,
                    onChanged: (value) => setDialogState(() => enabled = value),
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('立即发送'),
                    value: sendImmediately,
                    onChanged: (value) => setDialogState(
                      () => sendImmediately = value,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                key: const ValueKey('story_quick_reply_dialog_save'),
                onPressed: () {
                  final label = labelValue.trim();
                  Navigator.pop(
                    context,
                    StoryQuickReplyModel(
                      key: keyValue,
                      label: label.isEmpty ? '未命名条目' : label,
                      content: contentValue,
                      enabled: enabled,
                      sendImmediately: sendImmediately,
                    ),
                  );
                },
                child: const Text('保存'),
              ),
            ],
          ),
        );
      },
    );
  }
}
