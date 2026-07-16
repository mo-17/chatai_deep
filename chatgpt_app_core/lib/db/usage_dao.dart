import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/schema_guard.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/model/usage_record.dart';

abstract class IUsageDao {
  Future<int> insert(UsageRecord usage);
  Future<List<UsageRecord>> queryZeroCostRecords();
  Future<int> updateCost(int id, double cost);
  Future<List<UsageRecord>> queryByConversation(int cid,
      {int pageSize = 50, int? page});
  Future<List<UsageAggregate>> aggregateByModel({
    int? fromAt,
    int? toAt,
    int? projectId,
    int? cid,
    String? providerId,
    String? modelId,
  });
  Future<List<UsageAggregate>> aggregateByProvider({
    int? fromAt,
    int? toAt,
    int? projectId,
    int? cid,
    String? modelId,
  });
  Future<List<UsageAggregate>> aggregateByDate({
    int? fromAt,
    int? toAt,
    int? projectId,
    int? cid,
    String? providerId,
  });
  Future<List<UsageAggregate>> aggregateByProject({
    int? fromAt,
    int? toAt,
    int? cid,
    String? providerId,
    String? modelId,
  });
  Future<List<UsageAggregate>> aggregateByConversation({
    int? fromAt,
    int? toAt,
    int? projectId,
    String? providerId,
    String? modelId,
  });
}

class UsageDao extends IUsageDao implements ITable {
  final HiDBManager storage;

  @override
  String tableName = 'tb_usage';

  UsageDao._(this.storage);

  static Future<UsageDao> create(HiDBManager storage) async {
    await storage.db.execute(
        'create table if not exists tb_usage (id integer primary key autoincrement'
        ', modelId text not null, providerId text, projectId integer, cid integer'
        ', promptTokens integer not null, cachedPromptTokens integer not null default 0'
        ', completionTokens integer not null'
        ', cost real not null, estimated integer not null'
        ', createdAt integer not null);');
    await SchemaGuard.ensureColumns(
      storage.db,
      table: 'tb_usage',
      columns: const {
        'estimated': 'integer',
        'projectId': 'integer',
        'providerId': 'text',
        'cachedPromptTokens': 'integer default 0',
      },
    );
    await storage.db.execute(
        'create index if not exists tb_usage_model_idx on tb_usage(modelId)');
    await storage.db.execute(
        'create index if not exists tb_usage_cid_idx on tb_usage(cid)');
    await storage.db.execute(
        'create index if not exists tb_usage_project_idx on tb_usage(projectId)');
    await storage.db.execute(
        'create index if not exists tb_usage_created_idx on tb_usage(createdAt)');
    return UsageDao._(storage);
  }

  @override
  Future<int> insert(UsageRecord usage) async {
    return storage.db.insert(tableName, usage.toJson());
  }

  @override
  Future<List<UsageRecord>> queryZeroCostRecords() async {
    final rows = await storage.db.query(
      tableName,
      where: 'cost <= 0 and (promptTokens > 0 or completionTokens > 0)',
      orderBy: 'createdAt asc',
    );
    return rows.map((r) => UsageRecord.fromJson(r)).toList();
  }

  @override
  Future<int> updateCost(int id, double cost) async {
    return storage.db.update(
      tableName,
      {'cost': cost},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<List<UsageRecord>> queryByConversation(int cid,
      {int pageSize = 50, int? page}) async {
    final p = page == null || page < 1 ? 0 : page;
    final rows = await storage.db.query(
      tableName,
      where: 'cid = ?',
      whereArgs: [cid],
      orderBy: 'createdAt desc',
      limit: pageSize,
      offset: p * pageSize,
    );
    return rows.map((r) => UsageRecord.fromJson(r)).toList();
  }

  @override
  Future<List<UsageAggregate>> aggregateByModel({
    int? fromAt,
    int? toAt,
    int? projectId,
    int? cid,
    String? providerId,
    String? modelId,
  }) async {
    final where = _buildWhere(
      fromAt: fromAt,
      toAt: toAt,
      projectId: projectId,
      cid: cid,
      providerId: providerId,
      modelId: modelId,
    );
    final rows = await storage.db.rawQuery('''
      select modelId as key,
             coalesce(sum(promptTokens), 0) as promptTokens,
             coalesce(sum(cachedPromptTokens), 0) as cachedPromptTokens,
             coalesce(sum(completionTokens), 0) as completionTokens,
             coalesce(sum(cost), 0) as cost,
             count(*) as calls,
             max(estimated) as estimated
        from tb_usage
       ${where.$1}
       group by key
       order by (coalesce(sum(promptTokens),0)+coalesce(sum(completionTokens),0)) desc
    ''', where.$2);

    return rows
        .where((r) => (r['key'] as String?)?.isNotEmpty == true)
        .map((r) => UsageAggregate(
              key: r['key'] as String,
              promptTokens: ((r['promptTokens'] as num?) ?? 0).toInt(),
              cachedPromptTokens:
                  ((r['cachedPromptTokens'] as num?) ?? 0).toInt(),
              completionTokens: ((r['completionTokens'] as num?) ?? 0).toInt(),
              cost: ((r['cost'] as num?) ?? 0).toDouble(),
              calls: ((r['calls'] as num?) ?? 0).toInt(),
              estimated: ((r['estimated'] as num?) ?? 0) == 1,
            ))
        .toList();
  }

  @override
  Future<List<UsageAggregate>> aggregateByProvider({
    int? fromAt,
    int? toAt,
    int? projectId,
    int? cid,
    String? modelId,
  }) async {
    final where = _buildWhere(
      fromAt: fromAt,
      toAt: toAt,
      projectId: projectId,
      cid: cid,
      modelId: modelId,
    );
    final rows = await storage.db.rawQuery('''
      select providerId as key,
             coalesce(sum(promptTokens), 0) as promptTokens,
             coalesce(sum(cachedPromptTokens), 0) as cachedPromptTokens,
             coalesce(sum(completionTokens), 0) as completionTokens,
             coalesce(sum(cost), 0) as cost,
             count(*) as calls,
             max(estimated) as estimated
        from tb_usage
       ${where.$1}
       group by key
       order by (coalesce(sum(promptTokens),0)+coalesce(sum(completionTokens),0)) desc
    ''', where.$2);

    return rows
        .where((r) => (r['key'] as String?)?.isNotEmpty == true)
        .map((r) => UsageAggregate(
              key: r['key'] as String,
              promptTokens: ((r['promptTokens'] as num?) ?? 0).toInt(),
              cachedPromptTokens:
                  ((r['cachedPromptTokens'] as num?) ?? 0).toInt(),
              completionTokens: ((r['completionTokens'] as num?) ?? 0).toInt(),
              cost: ((r['cost'] as num?) ?? 0).toDouble(),
              calls: ((r['calls'] as num?) ?? 0).toInt(),
              estimated: ((r['estimated'] as num?) ?? 0) == 1,
            ))
        .toList();
  }

  @override
  Future<List<UsageAggregate>> aggregateByDate({
    int? fromAt,
    int? toAt,
    int? projectId,
    int? cid,
    String? providerId,
  }) async {
    final where = _buildWhere(
      fromAt: fromAt,
      toAt: toAt,
      projectId: projectId,
      cid: cid,
      providerId: providerId,
    );
    final rows = await storage.db.rawQuery('''
      select strftime('%Y-%m-%d', createdAt / 1000, 'unixepoch') as key,
             coalesce(sum(promptTokens), 0) as promptTokens,
             coalesce(sum(cachedPromptTokens), 0) as cachedPromptTokens,
             coalesce(sum(completionTokens), 0) as completionTokens,
             coalesce(sum(cost), 0) as cost,
             count(*) as calls,
             max(estimated) as estimated
        from tb_usage
       ${where.$1}
       group by key
       order by key desc
    ''', where.$2);

    return rows
        .where((r) => (r['key'] as String?)?.isNotEmpty == true)
        .map((r) => UsageAggregate(
              key: r['key'] as String,
              promptTokens: ((r['promptTokens'] as num?) ?? 0).toInt(),
              cachedPromptTokens:
                  ((r['cachedPromptTokens'] as num?) ?? 0).toInt(),
              completionTokens: ((r['completionTokens'] as num?) ?? 0).toInt(),
              cost: ((r['cost'] as num?) ?? 0).toDouble(),
              calls: ((r['calls'] as num?) ?? 0).toInt(),
              estimated: ((r['estimated'] as num?) ?? 0) == 1,
            ))
        .toList();
  }

  @override
  Future<List<UsageAggregate>> aggregateByProject({
    int? fromAt,
    int? toAt,
    int? cid,
    String? providerId,
    String? modelId,
  }) async {
    final where = _buildWhere(
      fromAt: fromAt,
      toAt: toAt,
      cid: cid,
      providerId: providerId,
      modelId: modelId,
      tableAlias: 'u',
    );
    final hasProjectTable = await _tableExists('tb_project');
    final rows = hasProjectTable ? await storage.db.rawQuery('''
      select case
               when u.projectId is null then '未分类'
               when p.name is null or p.name = '' then '项目 #' || u.projectId
               else p.name
             end as key,
             coalesce(sum(u.promptTokens), 0) as promptTokens,
             coalesce(sum(u.cachedPromptTokens), 0) as cachedPromptTokens,
             coalesce(sum(u.completionTokens), 0) as completionTokens,
             coalesce(sum(u.cost), 0) as cost,
             count(*) as calls,
             max(u.estimated) as estimated
        from tb_usage u
        left join tb_project p on p.id = u.projectId
       ${where.$1}
       group by u.projectId, p.name
       order by (coalesce(sum(u.promptTokens),0)+coalesce(sum(u.completionTokens),0)) desc
    ''', where.$2) : await storage.db.rawQuery('''
      select case
               when u.projectId is null then '未分类'
               else '项目 #' || u.projectId
             end as key,
             coalesce(sum(u.promptTokens), 0) as promptTokens,
             coalesce(sum(u.cachedPromptTokens), 0) as cachedPromptTokens,
             coalesce(sum(u.completionTokens), 0) as completionTokens,
             coalesce(sum(u.cost), 0) as cost,
             count(*) as calls,
             max(u.estimated) as estimated
        from tb_usage u
       ${where.$1}
       group by u.projectId
       order by (coalesce(sum(u.promptTokens),0)+coalesce(sum(u.completionTokens),0)) desc
    ''', where.$2);

    return rows
        .where((r) => (r['key'] as String?)?.isNotEmpty == true)
        .map((r) => UsageAggregate(
              key: r['key'] as String,
              promptTokens: ((r['promptTokens'] as num?) ?? 0).toInt(),
              cachedPromptTokens:
                  ((r['cachedPromptTokens'] as num?) ?? 0).toInt(),
              completionTokens: ((r['completionTokens'] as num?) ?? 0).toInt(),
              cost: ((r['cost'] as num?) ?? 0).toDouble(),
              calls: ((r['calls'] as num?) ?? 0).toInt(),
              estimated: ((r['estimated'] as num?) ?? 0) == 1,
            ))
        .toList();
  }

  @override
  Future<List<UsageAggregate>> aggregateByConversation({
    int? fromAt,
    int? toAt,
    int? projectId,
    String? providerId,
    String? modelId,
  }) async {
    final where = _buildWhere(
      fromAt: fromAt,
      toAt: toAt,
      projectId: projectId,
      providerId: providerId,
      modelId: modelId,
    );
    final cidWhere = where.$1.isEmpty
        ? 'where cid is not null'
        : '${where.$1} and cid is not null';
    final rows = await storage.db.rawQuery('''
      select cast(cid as text) as key,
             coalesce(sum(promptTokens), 0) as promptTokens,
             coalesce(sum(cachedPromptTokens), 0) as cachedPromptTokens,
             coalesce(sum(completionTokens), 0) as completionTokens,
             coalesce(sum(cost), 0) as cost,
             count(*) as calls,
             max(estimated) as estimated
        from tb_usage
       $cidWhere
       group by key
       order by key desc
    ''', where.$2);

    return rows
        .where((r) => (r['key'] as String?)?.isNotEmpty == true)
        .map((r) => UsageAggregate(
              key: r['key'] as String,
              promptTokens: ((r['promptTokens'] as num?) ?? 0).toInt(),
              cachedPromptTokens:
                  ((r['cachedPromptTokens'] as num?) ?? 0).toInt(),
              completionTokens: ((r['completionTokens'] as num?) ?? 0).toInt(),
              cost: ((r['cost'] as num?) ?? 0).toDouble(),
              calls: ((r['calls'] as num?) ?? 0).toInt(),
              estimated: ((r['estimated'] as num?) ?? 0) == 1,
            ))
        .toList();
  }

  (String, List<Object?>) _buildWhere({
    int? fromAt,
    int? toAt,
    int? projectId,
    int? cid,
    String? providerId,
    String? modelId,
    String? tableAlias,
  }) {
    final clauses = <String>[];
    final args = <Object?>[];
    final prefix =
        tableAlias == null || tableAlias.isEmpty ? '' : '$tableAlias.';

    if (fromAt != null) {
      clauses.add('${prefix}createdAt >= ?');
      args.add(fromAt);
    }
    if (toAt != null) {
      clauses.add('${prefix}createdAt <= ?');
      args.add(toAt);
    }
    if (projectId != null) {
      clauses.add('${prefix}projectId = ?');
      args.add(projectId);
    }
    if (cid != null) {
      clauses.add('${prefix}cid = ?');
      args.add(cid);
    }
    if (providerId != null && providerId.isNotEmpty) {
      clauses.add('${prefix}providerId = ?');
      args.add(providerId);
    }
    if (modelId != null && modelId.isNotEmpty) {
      clauses.add('${prefix}modelId = ?');
      args.add(modelId);
    }

    final where = clauses.isEmpty ? '' : 'where ${clauses.join(' and ')}';

    return (where, args);
  }

  Future<bool> _tableExists(String table) async {
    final rows = await storage.db.rawQuery(
      "select name from sqlite_master where type = 'table' and name = ?",
      [table],
    );
    return rows.isNotEmpty;
  }
}
