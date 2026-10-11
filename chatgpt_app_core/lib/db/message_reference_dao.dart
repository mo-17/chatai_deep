import 'package:chatgpt_app_core/chat/domain/composer_reference.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/util/account_resource_scope.dart';

class MessageReferenceCandidate {
  final int id;
  final String title;
  final String preview;
  final bool selectable;
  const MessageReferenceCandidate(
      {required this.id,
      required this.title,
      required this.preview,
      required this.selectable});
}

/// 选择器只查询正文预览；确认时再有界读取完整正文，不读取 Base64 和块。
class MessageReferenceDao {
  final HiDBManager storage;
  final String accountHash;
  const MessageReferenceDao(this.storage, {required this.accountHash});

  Future<List<MessageReferenceCandidate>> search(
      {String query = '', int? beforeId, int limit = 30}) async {
    if (limit < 1 || limit > 50 || query.length > 256) {
      throw ArgumentError('历史查询范围无效');
    }
    final escaped = query
        .replaceAll('\\', '\\\\')
        .replaceAll('%', '\\%')
        .replaceAll('_', '\\_');
    final rows = await storage.db.rawQuery(
        'select m.id, substr(coalesce(c.title, "未命名对话"), 1, 512) as title, '
        'substr(m.content, 1, 160) as preview, length(m.content) as characters '
        'from tb_messages m left join tb_conversation_list c on c.cid = m.cid '
        'where m.content is not null and length(m.content) > 0 '
        '${beforeId == null ? '' : 'and m.id < ? '}'
        'and (m.content like ? escape "\\" or c.title like ? escape "\\") '
        'order by m.id desc limit ?',
        [if (beforeId != null) beforeId, '%$escaped%', '%$escaped%', limit]);
    return rows
        .map((r) => MessageReferenceCandidate(
            id: r['id'] as int,
            title: r['title'] as String,
            preview: r['preview'] as String,
            selectable: (r['characters'] as int) <=
                HistoryMessageSnapshot.maxContentCharacters))
        .toList();
  }

  Future<HistoryMessageSnapshot?> snapshot(int id) async {
    final rows = await storage.db.rawQuery(
        'select m.id, m.cid, m.createdAt, m.ownerType, m.content, '
        'substr(coalesce(c.title, "未命名对话"), 1, 512) as title '
        'from tb_messages m left join tb_conversation_list c on c.cid = m.cid '
        'where m.id = ? and length(m.content) <= ? limit 1',
        [id, HistoryMessageSnapshot.maxContentCharacters]);
    if (rows.isEmpty) return null;
    final r = rows.single;
    return HistoryMessageSnapshot(
        accountToken: AccountResourceScope.tokenFor(accountHash),
        conversationId: r['cid'] as int,
        messageId: r['id'] as int,
        createdAt: r['createdAt'] as int,
        title: r['title'] as String,
        role: r['ownerType'] == 'OwnerType.receiver' ? 'assistant' : 'user',
        content: r['content'] as String,
        selectedAt: DateTime.now().millisecondsSinceEpoch);
  }

  Future<bool> sourceStillMatches(HistoryMessageSnapshot source) async {
    if (source.accountToken != AccountResourceScope.tokenFor(accountHash)) {
      return false;
    }
    final current = await snapshot(source.messageId);
    return current?.sourceIdentity == source.sourceIdentity;
  }
}
