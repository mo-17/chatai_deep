import 'dart:async';
import 'dart:convert';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/domain/cloud_workflow.dart';
import 'package:http/http.dart' as http;
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/header_util.dart';
import 'package:login_sdk/dao/login_dao.dart';

class CloudHttpFailure implements Exception {
  final int status;
  const CloudHttpFailure(this.status);
  @override
  String toString() => '云任务请求失败（HTTP $status）';
}

class CloudCapability {
  final int ownerId;
  final bool available;
  const CloudCapability(this.ownerId, this.available);
  factory CloudCapability.parse(Object? value) {
    final p = cloudObject(value);
    if (p['available'] is! bool ||
        p['destination'] != 'cloud' ||
        p['consentVersion'] != cloudConsentVersion) {
      throw const FormatException('云能力合同无效');
    }
    return CloudCapability(cloudInt(p['ownerId']), p['available']);
  }
}

/// 后端分页合同。每页最多4张完整payload，保留512KiB响应硬限制。
class CloudTaskPage {
  final List<Map<String, dynamic>> items;
  final String? nextCursor;
  const CloudTaskPage(this.items, this.nextCursor);
}

/// 每个观察会话固定账号/JWT/origin；不借用全局客户端的迟到401注销行为。
class CloudWorkflowApi {
  final AgentWorkflowScope scope;
  final String origin;
  final CloudSubmissionPolicy policy;
  final String Function() currentOrigin;
  final http.Client _client;
  final Map<String, String> _headers;
  final _pending = <Completer<void>>{};
  bool _closed = false;
  CloudWorkflowApi(
      {required this.scope,
      required this.origin,
      required String token,
      required this.currentOrigin,
      http.Client? client,
      Map<String, String> headers = const {},
      this.policy = const CloudSubmissionPolicy.production()})
      : _client = client ?? http.Client(),
        _headers = Map.unmodifiable({
          ...headers,
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json'
        }) {
    final uri = Uri.parse(origin);
    if (!['http', 'https'].contains(uri.scheme) ||
        uri.origin != origin ||
        uri.userInfo.isNotEmpty ||
        token.isEmpty ||
        token == LoginDao.kGuestToken ||
        scope.accountHash == 'guest') {
      throw StateError('请先登录后查看云任务');
    }
    verify();
  }
  factory CloudWorkflowApi.capture({required AgentWorkflowScope scope}) {
    if (LoginDao.isGuest() || LoginDao.getBoardingPass() == null) {
      throw StateError('请先登录后查看云任务');
    }
    final origin = BackendConfig.buildUri('/').origin;
    return CloudWorkflowApi(
        scope: scope,
        origin: origin,
        token: LoginDao.getBoardingPass()!,
        headers: hiHeaders(),
        currentOrigin: () => BackendConfig.buildUri('/').origin);
  }
  void verify() {
    scope.verify();
    if (_closed || currentOrigin() != origin) {
      throw StateError('云任务观察会话已变化');
    }
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    for (final c in _pending.toList()) {
      if (!c.isCompleted) {
        c.complete();
      }
    }
    _client.close();
  }

  Future<Object?> _request(String method, String path, {String? body}) async {
    verify();
    final abort = Completer<void>();
    _pending.add(abort);
    final timer = Timer(const Duration(seconds: 15), () {
      if (!abort.isCompleted) {
        abort.complete();
      }
    });
    try {
      final req = http.AbortableRequest(
          method, Uri.parse('$origin/uapi/cloud-workflows$path'),
          abortTrigger: abort.future)
        ..headers.addAll(_headers)
        ..followRedirects = false;
      if (body != null) {
        req.body = body;
      }
      final response = await _client.send(req);
      verify();
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        verify();
        if (bytes.length + chunk.length > 512 * 1024) {
          if (!abort.isCompleted) {
            abort.complete();
          }
          throw const FormatException('云任务响应超过限制');
        }
        bytes.addAll(chunk);
      }
      verify();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw CloudHttpFailure(response.statusCode);
      }
      final value = jsonDecode(utf8.decode(bytes));
      _bounded(value);
      return value;
    } catch (_) {
      verify();
      rethrow;
    } finally {
      timer.cancel();
      _pending.remove(abort);
    }
  }

  static void _bounded(Object? v, [int depth = 0]) {
    if (depth > 12 ||
        (v is List && v.length > 200) ||
        (v is Map && v.length > 100)) {
      throw const FormatException('云响应结构超限');
    }
    if (v is List) {
      for (final c in v) {
        _bounded(c, depth + 1);
      }
    }
    if (v is Map) {
      for (final c in v.values) {
        _bounded(c, depth + 1);
      }
    }
  }

  Future<CloudCapability> capability() async =>
      CloudCapability.parse(await _request('GET', '/capability'));
  Future<List<CloudProfileChoice>> profiles() async {
    final v = await _request('GET', '/profiles');
    if (v is! List || v.length > 200) {
      throw const FormatException('模型清单超限');
    }
    return List.unmodifiable(v.map(CloudProfileChoice.fromJson));
  }

  Future<CloudTaskPage> list({String? cursor}) async {
    final v = await _request('GET',
        '?limit=4${cursor == null ? '' : '&cursor=${cloudUuid(cursor)}'}');
    final page = cloudObject(v, keys: ['items', 'nextCursor']);
    final rows = page['items'];
    if (rows is! List || rows.length > 4) {
      throw const FormatException('云任务列表无效');
    }
    final items = rows.map((row) {
      final p = cloudObject(row);
      cloudUuid(p['id']);
      cloudState(p['state']);
      cloudInt(p['revision']);
      cloudInt(p['owner_id']);
      // 列表不向UI透出完整任务/输入，正文只在明确打开详情后展示。
      return Map<String, dynamic>.unmodifiable({
        'id': p['id'],
        'owner_id': p['owner_id'],
        'state': p['state'],
        'revision': p['revision']
      });
    }).toList();
    final next =
        page['nextCursor'] == null ? null : cloudUuid(page['nextCursor']);
    if (items.map((p) => p['id']).toSet().length != items.length ||
        (next != null &&
            (items.isEmpty || items.last['id'] != next || next == cursor))) {
      throw const FormatException('云任务分页游标无效');
    }
    return CloudTaskPage(List.unmodifiable(items), next);
  }

  Future<CloudServerReceipt> byKey(String key) async =>
      CloudServerReceipt.fromJson(
          await _request('GET', '/by-idempotency/${cloudUuid(key)}'));
  Future<void> create(
      CloudCapability capability, CloudConfirmedPayload payload) async {
    policy.verify(capability.available);
    verify();
    // 只发确认后精确序列化的body。超时/解析失败也不能暗换key重发。
    await _request('POST', '', body: payload.encoded);
  }

  Future<CloudTaskDetail> detail(String task) async =>
      CloudTaskDetail.fromJson(await _request('GET', '/${cloudUuid(task)}'));
  Future<List<CloudWritingResult>> results(String task) async {
    final v = await _request('GET', '/${cloudUuid(task)}/result');
    if (v is! List || v.length > 8) {
      throw const FormatException('云成果数量无效');
    }
    return List.unmodifiable(v.map(CloudWritingResult.fromJson));
  }

  Future<void> stop(String task, String operation, int revision) async {
    await _request('POST', '/${cloudUuid(task)}/stop',
        body: cloudCanonical({
          'operationId': cloudUuid(operation),
          'expectedRevision': cloudInt(revision)
        }));
  }
}
