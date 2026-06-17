import 'dart:io';

import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/util/app_events.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:openai_flutter/utils/ai_logger.dart';
import 'package:share_plus/share_plus.dart';

/// 转发面板（对话气泡 / 精彩内容共用）。底部弹出三类去向：
/// - 分享到其他应用：系统分享（share_plus）；鸿蒙无原生实现，降级为复制到剪贴板。
/// - 新建对话并转发：建一个新会话，把 [content] 作为一条「发送方」消息写入。
/// - 转发到已有对话：把 [content] 追加进所选会话。
///
/// 写入只落库 + 发 [AppEvents.notifyConversationsChanged]（会话列表页 keepAlive，
/// 据此刷新），不强行跳转——用户回到会话列表即可看到。
Future<void> showForwardSheet(BuildContext context,
    {required String content}) async {
  final text = content.trim();
  final messenger = ScaffoldMessenger.of(context);
  if (text.isEmpty) {
    messenger.showSnackBar(const SnackBar(content: Text('内容为空，无法转发')));
    return;
  }

  // 预加载会话列表（置顶 + 普通）。失败不阻断分享/新建。
  final storage =
      await HiDBManager.instance(dbName: HiDBManager.getAccountHash());
  final convDao = await ConversationListDao.create(storage);
  List<ConversationModel> conversations = const [];
  try {
    final stick = await convDao.getStickConversationList();
    final normal = await convDao.getConversationList(pageSize: 100);
    conversations = [...stick, ...normal];
  } catch (e) {
    AILogger.log('forward: load conversations failed: $e');
  }
  if (!context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (_) => _ForwardSheet(
      content: text,
      conversations: conversations,
      storage: storage,
      convDao: convDao,
      messenger: messenger,
    ),
  );
}

class _ForwardSheet extends StatelessWidget {
  final String content;
  final List<ConversationModel> conversations;
  final HiDBManager storage;
  final ConversationListDao convDao;
  final ScaffoldMessengerState messenger;

  const _ForwardSheet({
    required this.content,
    required this.conversations,
    required this.storage,
    required this.convDao,
    required this.messenger,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text('转发', style: tt.titleMedium),
            ),
            ListTile(
              leading: CircleAvatar(
                backgroundColor: cs.primaryContainer,
                child: Icon(Icons.ios_share_rounded, color: cs.onPrimaryContainer),
              ),
              title: const Text('分享到其他应用'),
              subtitle: const Text('通过系统分享到微信 / QQ / 备忘录等'),
              onTap: () async {
                await _shareToOtherApps(context, content, messenger);
                if (context.mounted) Navigator.pop(context);
              },
            ),
            ListTile(
              leading: CircleAvatar(
                backgroundColor: cs.secondaryContainer,
                child: Icon(Icons.add_comment_outlined,
                    color: cs.onSecondaryContainer),
              ),
              title: const Text('新建对话并转发'),
              onTap: () async {
                Navigator.pop(context);
                await _forwardToNewConversation(
                    storage, convDao, content, messenger);
              },
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text('转发到对话',
                  style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
            ),
            if (conversations.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: Text('暂无其他对话，可选择上方「新建对话并转发」',
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 12),
                  itemCount: conversations.length,
                  itemBuilder: (_, i) {
                    final c = conversations[i];
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: cs.surfaceContainerHighest,
                        child: Icon(Icons.chat_bubble_outline_rounded,
                            size: 20, color: cs.onSurfaceVariant),
                      ),
                      title: Text(c.title ?? '新对话',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: (c.lastMessage?.isNotEmpty ?? false)
                          ? Text(c.lastMessage!,
                              maxLines: 1, overflow: TextOverflow.ellipsis)
                          : null,
                      onTap: () async {
                        Navigator.pop(context);
                        await _forwardToConversation(
                            storage, convDao, c, content, messenger);
                      },
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 系统分享。鸿蒙无 share_plus 原生实现（OHOS 壳 override 到空 stub），
/// 这里以 `ohos` 守卫降级为复制到剪贴板，避免触达 stub。
Future<void> _shareToOtherApps(BuildContext context, String content,
    ScaffoldMessengerState messenger) async {
  if (Platform.operatingSystem == 'ohos') {
    await Clipboard.setData(ClipboardData(text: content));
    messenger.showSnackBar(
        const SnackBar(content: Text('鸿蒙暂不支持系统分享，已复制到剪贴板')));
    return;
  }
  try {
    await SharePlus.instance.share(ShareParams(
      text: content,
      // iPad 上系统分享是 popover，需要锚点矩形，否则可能抛异常。
      sharePositionOrigin: _shareOrigin(context),
    ));
  } catch (e) {
    AILogger.log('share failed: $e');
    messenger.showSnackBar(SnackBar(content: Text('分享失败：$e')));
  }
}

/// 由触发控件的 RenderBox 推导系统分享 popover 的锚点（iPad 必需）。
Rect? _shareOrigin(BuildContext context) {
  final box = context.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// 新建会话并写入转发内容（作为一条发送方消息）。
Future<void> _forwardToNewConversation(HiDBManager storage,
    ConversationListDao convDao, String content,
    ScaffoldMessengerState messenger) async {
  try {
    final now = DateTime.now().millisecondsSinceEpoch;
    final conv = ConversationModel(
      cid: now,
      icon: AiCatalogDao.avatarUrl(),
      title: _previewTitle(content),
      updateAt: now,
      lastMessage: content,
      messageCount: 1,
    );
    await convDao.saveConversation(conv);
    final msgDao = await MessageDao.create(storage, cid: now);
    msgDao.saveMessage(_forwardMessage(content, now));
    AppEvents.notifyConversationsChanged();
    messenger.showSnackBar(const SnackBar(content: Text('已新建对话并转发')));
  } catch (e) {
    AILogger.log('forward to new conversation failed: $e');
    messenger.showSnackBar(SnackBar(content: Text('转发失败：$e')));
  }
}

/// 把转发内容追加进已有会话（作为一条发送方消息），并刷新该会话的预览/时间。
Future<void> _forwardToConversation(HiDBManager storage,
    ConversationListDao convDao, ConversationModel conv, String content,
    ScaffoldMessengerState messenger) async {
  try {
    final now = DateTime.now().millisecondsSinceEpoch;
    final msgDao = await MessageDao.create(storage, cid: conv.cid);
    msgDao.saveMessage(_forwardMessage(content, now));
    conv.lastMessage = content;
    conv.updateAt = now;
    conv.messageCount = (conv.messageCount ?? 0) + 1;
    conv.title ??= _previewTitle(content);
    await convDao.saveConversation(conv);
    AppEvents.notifyConversationsChanged();
    messenger
        .showSnackBar(SnackBar(content: Text('已转发到「${conv.title ?? '对话'}」')));
  } catch (e) {
    AILogger.log('forward to conversation failed: $e');
    messenger.showSnackBar(SnackBar(content: Text('转发失败：$e')));
  }
}

/// 转发消息统一构造成「发送方」消息（带上当前登录用户的昵称/头像）。
MessageModel _forwardMessage(String content, int createdAt) {
  final user = LoginDao.getUserInfo();
  return MessageModel(
    ownerType: OwnerType.sender,
    content: content,
    createdAt: createdAt,
    ownerName: (user?['userName'] as String?) ?? '我',
    avatar: (user?['avatar'] as String?) ?? '',
  );
}

/// 新建/无标题会话的标题预览：折叠空白、截断到 20 字。
String _previewTitle(String content) {
  final oneLine = content.replaceAll(RegExp(r'\s+'), ' ').trim();
  return oneLine.length <= 20 ? oneLine : '${oneLine.substring(0, 20)}…';
}
