import 'dart:async';
import 'dart:convert';
import 'package:login_sdk/platform/app_io.dart';

import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/sync/local_sync_service.dart';
import 'package:chatgpt_app_core/util/account_resource_scope.dart';
import 'package:chatgpt_app_core/util/hi_const.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:http/http.dart' as http;
import 'package:login_sdk/dao/header_util.dart';
import 'package:login_sdk/dao/login_dao.dart';

typedef CloudSyncDatabaseResolver = Future<HiDBManager> Function(
  String accountHash,
);

class CloudSyncClient {
  final LocalSyncService localSync;
  final SyncCursorStore cursorStore;
  final Map<String, String> Function() headersBuilder;
  final http.Client _client;
  final bool _ownClient;
  final Duration timeout;
  final DateTime Function() nowProvider;
  final int maxPushBodyBytes;
  final int maxRetries;
  final Future<void> Function(Duration) retryDelay;

  static const int defaultMaxPushBodyBytes = 4 * 1024 * 1024;
  static const int maxPushChanges = 500;

  CloudSyncClient({
    required this.localSync,
    required this.cursorStore,
    this.headersBuilder = hiHeaders,
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
    this.maxPushBodyBytes = defaultMaxPushBodyBytes,
    this.maxRetries = 2,
    this.retryDelay = Future<void>.delayed,
    DateTime Function()? nowProvider,
  })  : _client = client ?? http.Client(),
        _ownClient = client == null,
        nowProvider = nowProvider ?? DateTime.now;

  void close() {
    if (_ownClient) _client.close();
  }

  Future<CloudSyncResult> syncOnce({bool auto = false}) async {
    final accountGuard = _LoginAccountGuard.capture();
    if (AccountResourceScope.currentAccountHash() != localSync.accountHash) {
      throw const LoginAccountChangedException();
    }
    final cursor = cursorStore.readCursor();
    final lastPushAt = cursorStore.readLastPushAt();
    final localChanges = await localSync.exportChanges(
        updatedAfter: lastPushAt, knowledgeOrigin: accountGuard._origin);
    accountGuard.verify();

    final pulled = await _pullAllRemoteChanges(cursor, accountGuard);
    accountGuard.verify();
    final merge = await localSync.applyRemoteChanges(pulled.changes);
    accountGuard.verify();
    await cursorStore.writeCursor(pulled.cursor);

    accountGuard.verify();
    final pushed = localChanges.isEmpty
        ? const PushSyncResult(accepted: [], conflictDetails: [], cursor: 0)
        : await _pushLocalChanges(localChanges, accountGuard);

    final maxAcceptedAt = pushed.accepted.fold<int>(
      lastPushAt,
      (max, change) => change.updatedAt > max ? change.updatedAt : max,
    );
    if (maxAcceptedAt > lastPushAt) {
      accountGuard.verify();
      await cursorStore.writeLastPushAt(maxAcceptedAt);
    }
    final finishedAt = nowProvider().millisecondsSinceEpoch;
    accountGuard.verify();
    await cursorStore.writeLastSyncAt(finishedAt);

    final localConflictDetails = [
      for (final key in merge.conflicts)
        SyncConflictDetail.fromKey(key,
            reason: key.startsWith('knowledge_document_v2:')
                ? 'knowledge_revision_conflict'
                : key.startsWith('knowledge_')
                    ? 'knowledge_legacy_identity'
                    : 'local_same_timestamp'),
    ];
    final conflictDetails = [
      ...localConflictDetails,
      ...pushed.conflictDetails,
    ];

    return CloudSyncResult(
      pulled: pulled.changes.length,
      pushed: pushed.accepted.length,
      stale: merge.rejectedStale.length,
      conflicts: conflictDetails.map((detail) => detail.key).toList(),
      conflictDetails: conflictDetails,
      cursor: pulled.cursor,
      finishedAt: finishedAt,
      auto: auto,
    );
  }

  Future<PullSyncResult> _pullAllRemoteChanges(
    int cursor,
    _LoginAccountGuard accountGuard,
  ) async {
    final changes = <SyncChange>[];
    var pullCursor = cursor;
    var resultCursor = cursor;
    // CHARX 资源上限 100MB，服务端按约 4MB 响应分页。
    // 留出普通行变更空间，同时保留防死循环上限。
    const maxPages = 100;

    for (var page = 0; page < maxPages; page++) {
      accountGuard.verify();
      final pageResult = await pullRemoteChanges(cursor: pullCursor);
      accountGuard.verify();
      changes.addAll(pageResult.changes);
      resultCursor = pageResult.cursor;
      if (!pageResult.hasMore) {
        return PullSyncResult(
          cursor: resultCursor,
          changes: changes,
          hasMore: false,
        );
      }
      if (pageResult.cursor <= pullCursor) {
        throw const CloudSyncException('云同步拉取分页游标未前进');
      }
      pullCursor = pageResult.cursor;
    }
    throw const CloudSyncException('云同步分页过多，请稍后重试');
  }

  Future<PullSyncResult> pullRemoteChanges(
      {int cursor = 0, int limit = 200}) async {
    final uri = BackendConst.buildUri('uapi/sync/pull', {
      'cursor': '$cursor',
      'limit': '$limit',
    });
    final resp =
        await _retryHttp(() => _client.get(uri, headers: headersBuilder()));
    final json = _decodeResponse(resp, '拉取云同步变更失败');
    final data = (json['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final changes = [
      for (final raw in (data['changes'] as List? ?? const []))
        _changeFromJson((raw as Map).cast<String, dynamic>()),
    ];
    return PullSyncResult(
      cursor: _asInt(data['cursor']),
      changes: changes,
      hasMore: data['hasMore'] == true,
    );
  }

  Future<PushSyncResult> pushLocalChanges(List<SyncChange> changes) =>
      _pushLocalChanges(changes, null);

  Future<PushSyncResult> _pushLocalChanges(
    List<SyncChange> changes,
    _LoginAccountGuard? accountGuard,
  ) async {
    if (changes.isEmpty) {
      return const PushSyncResult(
        accepted: [],
        conflictDetails: [],
        cursor: 0,
      );
    }
    final accepted = <SyncChange>[];
    final conflicts = <SyncConflictDetail>[];
    var cursor = 0;
    final batches = _pushBatches(changes).toList();
    final guard = accountGuard ?? _LoginAccountGuard.capture();
    for (final batch in batches) {
      guard.verify();
      final result = await _pushBatch(batch);
      guard.verify();
      await localSync.acknowledgeUploadedKnowledge([
        for (final uploaded in batch)
          if (result.accepted.any((accepted) =>
              accepted.key == uploaded.key &&
              accepted.updatedAt == uploaded.updatedAt &&
              accepted.op == uploaded.op))
            uploaded
      ], origin: guard._origin);
      guard.verify();
      accepted.addAll(result.accepted);
      conflicts.addAll(result.conflictDetails);
      if (result.cursor > cursor) cursor = result.cursor;
    }
    return PushSyncResult(
      accepted: accepted,
      conflictDetails: conflicts,
      cursor: cursor,
    );
  }

  Future<PushSyncResult> _pushBatch(List<SyncChange> changes) async {
    final uri = BackendConst.buildUri('uapi/sync/push');
    final resp = await _retryHttp(() => _client.post(
          uri,
          headers: {...headersBuilder(), 'content-type': 'application/json'},
          body: jsonEncode({
            'deviceId': cursorStore.deviceId,
            'changes': changes.map(_changeToJson).toList(),
          }),
        ));
    final json = _decodeResponse(resp, '上传云同步变更失败');
    final data = (json['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    return PushSyncResult(
      accepted: [
        for (final raw in (data['accepted'] as List? ?? const []))
          _changeFromJson((raw as Map).cast<String, dynamic>()),
      ],
      conflictDetails: [
        for (final raw in (data['conflicts'] as List? ?? const []))
          _conflictFromJson((raw as Map).cast<String, dynamic>()),
      ],
      cursor: _asInt(data['cursor']),
    );
  }

  Iterable<List<SyncChange>> _pushBatches(List<SyncChange> changes) sync* {
    var batch = <SyncChange>[];
    final envelopeBytes = _encodedPushBody(const []).length;
    var batchBytes = envelopeBytes;
    for (final change in changes) {
      final encodedChangeBytes =
          utf8.encode(jsonEncode(_changeToJson(change))).length;
      final changeBytes = encodedChangeBytes + (batch.isEmpty ? 0 : 1);
      if (envelopeBytes + changeBytes > maxPushBodyBytes) {
        throw CloudSyncException(
          '单条同步变更超过 ${maxPushBodyBytes ~/ 1024}KB 限制',
        );
      }
      if (batch.length >= maxPushChanges ||
          batchBytes + changeBytes > maxPushBodyBytes) {
        yield batch;
        batch = <SyncChange>[];
        batchBytes = envelopeBytes;
      }
      batch.add(change);
      batchBytes += encodedChangeBytes + (batch.length == 1 ? 0 : 1);
    }
    if (batch.isNotEmpty) yield batch;
  }

  List<int> _encodedPushBody(List<SyncChange> changes) => utf8.encode(
        jsonEncode({
          'deviceId': cursorStore.deviceId,
          'changes': changes.map(_changeToJson).toList(),
        }),
      );

  Future<http.Response> _retryHttp(
      Future<http.Response> Function() send) async {
    final guard = _LoginAccountGuard.capture();
    for (var attempt = 0;; attempt++) {
      guard.verify();
      try {
        final response = await send().timeout(timeout);
        guard.verify();
        if (![408, 502, 503, 504].contains(response.statusCode) ||
            attempt >= maxRetries) {
          return response;
        }
      } on TimeoutException {
        if (attempt >= maxRetries) rethrow;
      } on SocketException {
        if (attempt >= maxRetries) rethrow;
      } on http.ClientException {
        if (attempt >= maxRetries) rethrow;
      }
      await retryDelay(Duration(milliseconds: 400 * (attempt + 1)));
      guard.verify();
    }
  }

  Map<String, dynamic> _decodeResponse(http.Response resp, String message) {
    final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
    if (resp.statusCode != 200) {
      throw CloudSyncException('$message HTTP ${resp.statusCode}');
    }
    final json = jsonDecode(body) as Map<String, dynamic>;
    if (json['code'] != 0) throw CloudSyncException('$message，请稍后重试');
    return json;
  }

  static Map<String, dynamic> _changeToJson(SyncChange change) => {
        'entity': change.entity,
        'entityId': change.id,
        'op': change.op.name,
        'updatedAt': change.updatedAt,
        if (change.payload.isNotEmpty) 'payload': change.payload,
      };

  static SyncChange _changeFromJson(Map<String, dynamic> json) => SyncChange(
        entity: '${json['entity']}',
        id: '${json['entityId']}',
        op: json['op'] == 'delete' ? SyncOp.delete : SyncOp.upsert,
        updatedAt: _asInt(json['updatedAt']),
        payload: (json['payload'] as Map?)?.cast<String, dynamic>() ?? const {},
      );

  static SyncConflictDetail _conflictFromJson(Map<String, dynamic> json) =>
      SyncConflictDetail(
        entity: '${json['entity']}',
        entityId: '${json['entityId']}',
        reason: '${json['reason'] ?? 'unknown'}',
      );

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }
}

final class _LoginAccountGuard {
  final String? _accountHash;
  final String? _token;
  final String _origin;
  const _LoginAccountGuard._(this._accountHash, this._token, this._origin);

  factory _LoginAccountGuard.capture() => _LoginAccountGuard._(
      LoginDao.getAccountHash(),
      LoginDao.getBoardingPass(),
      BackendConst.buildUri('/').origin);

  void verify() {
    if (LoginDao.getAccountHash() != _accountHash ||
        LoginDao.getBoardingPass() != _token ||
        BackendConst.buildUri('/').origin != _origin) {
      throw const LoginAccountChangedException();
    }
  }
}

class CloudSyncCoordinator {
  CloudSyncCoordinator._();

  static bool _running = false;
  static const Duration autoSyncCooldown = Duration(minutes: 10);

  static Future<CloudSyncClient> createClient({
    http.Client? httpClient,
    CloudSyncDatabaseResolver? databaseResolver,
  }) async {
    final accountGuard = _LoginAccountGuard.capture();
    final accountHash = HiDBManager.getAccountHash();
    final storage = databaseResolver == null
        ? await HiDBManager.instance(dbName: accountHash)
        : await databaseResolver(accountHash);
    accountGuard.verify();
    return CloudSyncClient(
      localSync: LocalSyncService(storage, accountHash: accountHash),
      cursorStore: HiCacheSyncCursorStore(),
      client: httpClient,
    );
  }

  static int readLastSyncAt() => HiCacheSyncCursorStore().readLastSyncAt();

  static void syncOnLogin() {
    if (LoginDao.isGuest() || _running) return;
    final store = HiCacheSyncCursorStore();
    final lastSyncAt = store.readLastSyncAt();
    if (!shouldAutoSync(lastSyncAt, DateTime.now().millisecondsSinceEpoch)) {
      return;
    }
    unawaited(runSync(auto: true).catchError((Object _) {
      // 登录钩子只做机会性同步，失败不阻断登录流程。
      return const CloudSyncResult(
          pulled: 0, pushed: 0, stale: 0, conflicts: [], cursor: 0);
    }));
  }

  static Future<CloudSyncResult> runSync({
    Future<CloudSyncClient> Function() factory = createClient,
    bool auto = false,
  }) async {
    if (_running) throw const CloudSyncException('同步正在进行，请稍后刷新');
    _running = true;
    CloudSyncClient? client;
    try {
      client = await factory();
      return await client.syncOnce(auto: auto);
    } finally {
      client?.close();
      _running = false;
    }
  }

  static bool shouldAutoSync(
    int lastSyncAt,
    int nowMs, {
    Duration cooldown = autoSyncCooldown,
  }) {
    if (lastSyncAt <= 0) return true;
    return nowMs - lastSyncAt >= cooldown.inMilliseconds;
  }
}

abstract class SyncCursorStore {
  String get deviceId;
  int readCursor();
  int readLastPushAt();
  int readLastSyncAt();
  Future<void> writeCursor(int cursor);
  Future<void> writeLastPushAt(int timestamp);
  Future<void> writeLastSyncAt(int timestamp);
}

class HiCacheSyncCursorStore implements SyncCursorStore {
  static const _deviceIdKey = 'cloud_sync_device_id';
  static const _cursorPrefix = 'cloud_sync_cursor_v1_';
  static const _pushPrefix = 'cloud_sync_last_push_at_v1_';
  static const _syncPrefix = 'cloud_sync_last_sync_at_v1_';

  String get _accountHash => LoginDao.getAccountHash() ?? 'test';
  String get _cursorKey => '$_cursorPrefix$_accountHash';
  String get _pushKey => '$_pushPrefix$_accountHash';
  String get _syncKey => '$_syncPrefix$_accountHash';

  @override
  String get deviceId {
    final cache = HiCache.getInstance();
    final existing = cache.get(_deviceIdKey)?.toString();
    if (existing != null && existing.isNotEmpty) return existing;
    final next = 'd${DateTime.now().microsecondsSinceEpoch}';
    unawaited(cache.setString(_deviceIdKey, next));
    return next;
  }

  @override
  int readCursor() =>
      int.tryParse('${HiCache.getInstance().get(_cursorKey) ?? 0}') ?? 0;

  @override
  int readLastPushAt() =>
      int.tryParse('${HiCache.getInstance().get(_pushKey) ?? 0}') ?? 0;

  @override
  int readLastSyncAt() =>
      int.tryParse('${HiCache.getInstance().get(_syncKey) ?? 0}') ?? 0;

  @override
  Future<void> writeCursor(int cursor) async {
    await HiCache.getInstance().setString(_cursorKey, '$cursor');
  }

  @override
  Future<void> writeLastPushAt(int timestamp) async {
    await HiCache.getInstance().setString(_pushKey, '$timestamp');
  }

  @override
  Future<void> writeLastSyncAt(int timestamp) async {
    await HiCache.getInstance().setString(_syncKey, '$timestamp');
  }
}

class MemorySyncCursorStore implements SyncCursorStore {
  @override
  final String deviceId;
  int cursor;
  int lastPushAt;
  int lastSyncAt;

  MemorySyncCursorStore({
    this.deviceId = 'test-device',
    this.cursor = 0,
    this.lastPushAt = 0,
    this.lastSyncAt = 0,
  });

  @override
  int readCursor() => cursor;

  @override
  int readLastPushAt() => lastPushAt;

  @override
  int readLastSyncAt() => lastSyncAt;

  @override
  Future<void> writeCursor(int cursor) async {
    this.cursor = cursor;
  }

  @override
  Future<void> writeLastPushAt(int timestamp) async {
    lastPushAt = timestamp;
  }

  @override
  Future<void> writeLastSyncAt(int timestamp) async {
    lastSyncAt = timestamp;
  }
}

class PullSyncResult {
  final int cursor;
  final List<SyncChange> changes;
  final bool hasMore;

  const PullSyncResult({
    required this.cursor,
    required this.changes,
    required this.hasMore,
  });
}

class SyncConflictDetail {
  final String entity;
  final String entityId;
  final String reason;

  const SyncConflictDetail({
    required this.entity,
    required this.entityId,
    required this.reason,
  });

  factory SyncConflictDetail.fromKey(
    String key, {
    String reason = 'unknown',
  }) {
    final splitAt = key.indexOf(':');
    if (splitAt < 0) {
      return SyncConflictDetail(
        entity: key,
        entityId: '',
        reason: reason,
      );
    }
    return SyncConflictDetail(
      entity: key.substring(0, splitAt),
      entityId: key.substring(splitAt + 1),
      reason: reason,
    );
  }

  String get key => '$entity:$entityId';
}

class PushSyncResult {
  final List<SyncChange> accepted;
  final List<SyncConflictDetail> conflictDetails;
  final int cursor;

  const PushSyncResult({
    required this.accepted,
    required this.conflictDetails,
    required this.cursor,
  });

  List<String> get conflicts =>
      conflictDetails.map((detail) => detail.key).toList();
}

class CloudSyncResult {
  final int pulled;
  final int pushed;
  final int stale;
  final List<String> conflicts;
  final List<SyncConflictDetail> conflictDetails;
  final int cursor;
  final int finishedAt;
  final bool auto;

  const CloudSyncResult({
    required this.pulled,
    required this.pushed,
    required this.stale,
    required this.conflicts,
    this.conflictDetails = const [],
    required this.cursor,
    this.finishedAt = 0,
    this.auto = false,
  });

  bool get hasConflict => conflicts.isNotEmpty || conflictDetails.isNotEmpty;
}

class CloudSyncException implements Exception {
  final String message;
  const CloudSyncException(this.message);

  @override
  String toString() => message;
}
