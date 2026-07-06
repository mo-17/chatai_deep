import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/pages/story_room_page.dart';
import 'package:chatgpt_app_core/util/hi_dialog.dart';
import 'package:flutter/material.dart';

class StoryRoomListPage extends StatefulWidget {
  const StoryRoomListPage({super.key});

  @override
  State<StoryRoomListPage> createState() => _StoryRoomListPageState();
}

class _StoryRoomListPageState extends State<StoryRoomListPage> {
  StoryRoomDao? _dao;
  List<StoryRoomModel> _rooms = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
    final dao = await StoryRoomDao.create(db);
    final rooms = await dao.getRooms();
    if (!mounted) return;
    setState(() {
      _dao = dao;
      _rooms = rooms;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('创作 / 酒馆')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _rooms.isEmpty
              ? const Center(child: Text('暂无创作房间'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    itemCount: _rooms.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, index) {
                      final room = _rooms[index];
                      return ListTile(
                        leading: CircleAvatar(
                          child: Icon(room.mode == StoryRoomMode.tavern
                              ? Icons.forum_outlined
                              : Icons.theater_comedy_outlined),
                        ),
                        title: Text(room.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          room.publicContext.isEmpty
                              ? StoryRoomMode.labelOf(room.mode)
                              : '${StoryRoomMode.labelOf(room.mode)} · ${room.publicContext}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: PopupMenuButton<String>(
                          tooltip: '房间操作',
                          onSelected: (value) {
                            if (value == 'rename') {
                              _renameRoom(room);
                            } else if (value == 'delete') {
                              _deleteRoom(room);
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'rename',
                              child: Row(
                                children: [
                                  Icon(Icons.drive_file_rename_outline),
                                  SizedBox(width: 8),
                                  Text('重命名'),
                                ],
                              ),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: Row(
                                children: [
                                  Icon(Icons.delete_outline),
                                  SizedBox(width: 8),
                                  Text('删除'),
                                ],
                              ),
                            ),
                          ],
                        ),
                        onTap: () => _openRoom(room),
                      );
                    },
                  ),
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showCreateRoomSheet,
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _showCreateRoomSheet() async {
    final mode = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const CircleAvatar(
                  child: Icon(Icons.theater_comedy_outlined),
                ),
                title: const Text('新建创作房间'),
                subtitle: const Text('适合小说写作，默认包含作者和旁白'),
                onTap: () => Navigator.pop(ctx, StoryRoomMode.creation),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: const CircleAvatar(
                  child: Icon(Icons.forum_outlined),
                ),
                title: const Text('新建酒馆房间'),
                subtitle: const Text('适合角色扮演，只使用角色卡参与对话'),
                onTap: () => Navigator.pop(ctx, StoryRoomMode.tavern),
              ),
            ],
          ),
        ),
      ),
    );
    if (mode == null) return;
    await _createRoom(mode);
  }

  Future<void> _createRoom(String mode) async {
    final dao = _dao;
    if (dao == null) return;
    final isTavern = mode == StoryRoomMode.tavern;
    final room = StoryRoomModel(
      title: isTavern ? '新的酒馆房间' : '新的创作房间',
      mode: mode,
      replyMode: isTavern ? StoryReplyMode.autoSingle : StoryReplyMode.manual,
      maxAutoReplies: 1,
      publicContext: isTavern
          ? '在这里写角色关系、当前场景、已发生事件或对话规则。'
          : '在这里写公共世界观、当前章节、场景、时间线或写作要求。',
    );
    await dao.saveRoom(room);
    if (!isTavern) {
      await _seedDefaultParticipants(dao, room.id!);
    }
    if (!mounted) return;
    await _openRoom(room);
    await _load();
  }

  Future<void> _seedDefaultParticipants(StoryRoomDao dao, int roomId) async {
    await dao.saveParticipant(StoryParticipantModel(
      roomId: roomId,
      role: StoryParticipantRole.author,
      name: '作者',
      sortOrder: 0,
    ));
    await dao.saveParticipant(StoryParticipantModel(
      roomId: roomId,
      role: StoryParticipantRole.narrator,
      name: '旁白',
      sortOrder: 1,
    ));
  }

  Future<void> _renameRoom(StoryRoomModel room) async {
    final dao = _dao;
    final roomId = room.id;
    if (dao == null || roomId == null) return;
    final title = await showDialog<String>(
      context: context,
      builder: (_) => _RenameRoomDialog(initialTitle: room.title),
    );
    if (title == null || title.isEmpty || title == room.title) return;
    final updated = StoryRoomModel(
      id: roomId,
      title: title,
      mode: room.mode,
      replyMode: room.replyMode,
      maxAutoReplies: room.maxAutoReplies,
      publicContext: room.publicContext,
      createdAt: room.createdAt,
      updatedAt: room.updatedAt,
    );
    try {
      await dao.saveRoom(updated);
      if (!mounted) return;
      await _load();
    } catch (e) {
      if (!mounted) return;
      HiDialog.showSnackBar(context, '重命名失败：$e');
    }
  }

  Future<void> _deleteRoom(StoryRoomModel room) async {
    final dao = _dao;
    final id = room.id;
    if (dao == null || id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除房间'),
        content: Text('确定删除「${room.title}」吗？房间内的角色和消息也会一起删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await dao.deleteRoom(id);
    if (!mounted) return;
    await _load();
  }

  Future<void> _openRoom(StoryRoomModel room) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => StoryRoomPage(room: room)),
    );
  }
}

class _RenameRoomDialog extends StatefulWidget {
  final String initialTitle;

  const _RenameRoomDialog({required this.initialTitle});

  @override
  State<_RenameRoomDialog> createState() => _RenameRoomDialogState();
}

class _RenameRoomDialogState extends State<_RenameRoomDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialTitle);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重命名房间'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          labelText: '房间名称',
          border: OutlineInputBorder(),
        ),
        onSubmitted: _submit,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => _submit(_controller.text),
          child: const Text('保存'),
        ),
      ],
    );
  }

  void _submit(String value) => Navigator.pop(context, value.trim());
}
