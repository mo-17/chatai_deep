import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

const cloudDisabledNotice = '云任务暂未启用，离线退出策略尚待确认';
const cloudConsentVersion = 'cloud-text-v1';
const cloudRoles = ['analysis', 'writing', 'review'];
const cloudStates = {
  'queued',
  'running',
  'paused',
  'needs_configuration',
  'budget_exhausted',
  'cancelling',
  'cancelled',
  'complete',
  'failed',
  'unknown',
  'deleted',
};

/// 生产没有环境变量/路由/query入口可打开此闸门。测试只能显式注入。
class CloudSubmissionPolicy {
  final bool realSubmissionEnabled;
  const CloudSubmissionPolicy.production() : realSubmissionEnabled = false;
  @visibleForTesting
  const CloudSubmissionPolicy.synthetic() : realSubmissionEnabled = true;
  void verify(bool serverAvailable) {
    if (!realSubmissionEnabled || !serverAvailable) {
      throw StateError(cloudDisabledNotice);
    }
  }
}

String cloudHash(String text) => sha256.convert(utf8.encode(text)).toString();
String cloudCanonical(Object? value) {
  if (value is List) {
    return '[${value.map(cloudCanonical).join(',')}]';
  }
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${cloudCanonical(value[k])}').join(',')}}';
  }
  return jsonEncode(value);
}

Never _invalid() => throw const FormatException('云任务数据格式或范围无效');
Map<String, dynamic> cloudObject(Object? v, {List<String>? keys}) {
  if (v is! Map<String, dynamic>) {
    _invalid();
  }
  if (keys != null &&
      (v.length != keys.length || v.keys.any((k) => !keys.contains(k)))) {
    _invalid();
  }
  return v;
}

int cloudInt(Object? v, {int min = 1, int max = 9007199254740991}) {
  if (v is! int || v < min || v > max) {
    _invalid();
  }
  return v;
}

String cloudUuid(Object? v) {
  if (v is! String ||
      !RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
              caseSensitive: false)
          .hasMatch(v)) {
    _invalid();
  }
  return v.toLowerCase();
}

String cloudDigest(Object? v) {
  if (v is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(v)) {
    _invalid();
  }
  return v;
}

String cloudText(Object? v, int maxBytes, {bool empty = false}) {
  if (v is! String ||
      (!empty && v.trim().isEmpty) ||
      v.contains('\u0000') ||
      utf8.encode(v).length > maxBytes ||
      v.runes.any((r) => r >= 0xd800 && r <= 0xdfff)) {
    _invalid();
  }
  return v;
}

String cloudState(Object? v) {
  if (v is! String || !cloudStates.contains(v)) {
    _invalid();
  }
  return v;
}

Object? _frozen(Object? value) {
  if (value is List) {
    return List.unmodifiable(value.map(_frozen));
  }
  if (value is Map<String, dynamic>) {
    return Map<String, dynamic>.unmodifiable(
        value.map((k, v) => MapEntry(k, _frozen(v))));
  }
  return value;
}

class CloudLocalSource {
  final int cid, revision;
  final String messageId, contentHash;
  const CloudLocalSource(
      this.cid, this.messageId, this.revision, this.contentHash);
  Map<String, dynamic> toJson() => {
        'kind': 'local_message',
        'cid': cid,
        'messageId': messageId,
        'revision': revision,
        'contentHash': contentHash
      };
  factory CloudLocalSource.fromJson(Object? value) {
    final p = cloudObject(value,
        keys: ['kind', 'cid', 'messageId', 'revision', 'contentHash']);
    if (p['kind'] != 'local_message') {
      _invalid();
    }
    return CloudLocalSource(cloudInt(p['cid']), cloudUuid(p['messageId']),
        cloudInt(p['revision']), cloudDigest(p['contentHash']));
  }
}

class CloudProfileChoice {
  final int providerId, modelRowId;
  final String modelId, providerName, modelName;
  const CloudProfileChoice(this.providerId, this.modelRowId, this.modelId,
      this.providerName, this.modelName);
  factory CloudProfileChoice.fromJson(Object? value) {
    final p = cloudObject(value, keys: [
      'providerId',
      'modelRowId',
      'modelId',
      'providerName',
      'modelName'
    ]);
    return CloudProfileChoice(
        cloudInt(p['providerId'], max: 2147483647),
        cloudInt(p['modelRowId'], max: 2147483647),
        cloudText(p['modelId'], 1000),
        cloudText(p['providerName'], 1000),
        cloudText(p['modelName'], 1000));
  }
  Map<String, dynamic> reference() =>
      {'providerId': providerId, 'modelRowId': modelRowId};
}

class CloudTextSnapshot {
  final String title, text;
  const CloudTextSnapshot(this.title, this.text);
  Map<String, dynamic> toJson() => {
        'title': cloudText(title, 240),
        'text': cloudText(text, 12000),
        'contentHash': cloudHash(text)
      };
}

/// 深拷贝后只暴露序列化副本，确认/发送期间不共享可变 Map。
class CloudConfirmedPayload {
  final String encoded, digest, key;
  final CloudLocalSource source;
  CloudConfirmedPayload._(this.encoded, this.digest, this.key, this.source);
  factory CloudConfirmedPayload(
      {required String key,
      required String clientInstanceId,
      required CloudLocalSource source,
      required String task,
      required List<CloudTextSnapshot> inputs,
      required Map<String, CloudProfileChoice> profiles,
      Map<String, dynamic>? acceptance,
      Map<String, dynamic>? budget,
      int grantDurationMs = 600000}) {
    final a = acceptance ??
        {
          'format': 'md',
          'outputName': 'result.md',
          'minChars': 0,
          'maxChars': 12000,
          'requiredTerms': <String>[],
          'requireFullRead': true
        };
    cloudObject(a, keys: [
      'format',
      'outputName',
      'minChars',
      'maxChars',
      'requiredTerms',
      'requireFullRead'
    ]);
    if (!['txt', 'md', 'csv'].contains(a['format']) ||
        a['requireFullRead'] is! bool) {
      _invalid();
    }
    final name = cloudText(a['outputName'], 120);
    if (!RegExp(r'^[A-Za-z0-9_\-\u4e00-\u9fff][A-Za-z0-9_.\-\u4e00-\u9fff]{0,100}\.(txt|md|csv)$')
            .hasMatch(name) ||
        !name.endsWith('.${a['format']}')) {
      _invalid();
    }
    if (cloudInt(a['minChars'], min: 0, max: 12000) >
        cloudInt(a['maxChars'], max: 12000)) {
      _invalid();
    }
    final terms = a['requiredTerms'];
    if (terms is! List || terms.length > 20) {
      _invalid();
    }
    final checkedTerms = terms.map((x) => cloudText(x, 120)).toList();
    if (checkedTerms.toSet().length != checkedTerms.length) {
      _invalid();
    }
    final b = budget ??
        {
          'attempts': 8,
          'estimatedTokens': 32000,
          'outputTokens': 2048,
          'durationMs': 600000,
          'reworks': 1
        };
    cloudObject(b, keys: [
      'attempts',
      'estimatedTokens',
      'outputTokens',
      'durationMs',
      'reworks'
    ]);
    cloudInt(b['attempts'], max: 8);
    cloudInt(b['estimatedTokens'], min: 2048, max: 32000);
    cloudInt(b['outputTokens'], max: 2048);
    cloudInt(b['durationMs'], max: 600000);
    cloudInt(b['reworks'], min: 0, max: 1);
    CloudLocalSource.fromJson(source.toJson());
    if (source.contentHash != cloudHash(cloudText(task, 12000))) {
      _invalid();
    }
    if (inputs.length > 4 ||
        inputs.fold<int>(0, (n, v) => n + utf8.encode(v.text).length) > 24000) {
      _invalid();
    }
    if (profiles.length != 3 ||
        cloudRoles.any((r) => !profiles.containsKey(r))) {
      _invalid();
    }
    final p = {
      'version': 2,
      'consentVersion': cloudConsentVersion,
      'idempotencyKey': cloudUuid(key),
      'clientInstanceId': cloudUuid(clientInstanceId),
      'source': source.toJson(),
      'task': task,
      'acceptance': a,
      'inputs': inputs.map((v) => v.toJson()).toList(),
      'profiles': {for (final r in cloudRoles) r: profiles[r]!.reference()},
      'budget': b,
      'grantDurationMs': cloudInt(grantDurationMs, max: 600000)
    };
    for (final ref in profiles.values) {
      cloudInt(ref.providerId, max: 2147483647);
      cloudInt(ref.modelRowId, max: 2147483647);
    }
    final encoded = cloudCanonical(p);
    if (utf8.encode(encoded).length > 48000) {
      _invalid();
    }
    return CloudConfirmedPayload._(
        encoded, cloudHash(encoded), cloudUuid(key), source);
  }
  Map<String, dynamic> toJson() => cloudObject(jsonDecode(encoded));
}

class CloudServerReceipt {
  final String taskId, state, payloadHash, publicationId;
  final int ownerId, revision;
  final String? finalResultId;
  final Map<String, dynamic>? source;
  const CloudServerReceipt(this.taskId, this.ownerId, this.state, this.revision,
      this.payloadHash, this.source, this.publicationId, this.finalResultId);
  factory CloudServerReceipt.fromJson(Object? value) {
    final p = cloudObject(value, keys: [
      'id',
      'ownerId',
      'state',
      'revision',
      'payloadHash',
      'source',
      'publicationId',
      'finalResultId'
    ]);
    final source = p['source'] == null ? null : cloudObject(p['source']);
    return CloudServerReceipt(
        cloudUuid(p['id']),
        cloudInt(p['ownerId']),
        cloudState(p['state']),
        cloudInt(p['revision']),
        cloudDigest(p['payloadHash']),
        source,
        cloudUuid(p['publicationId']),
        p['finalResultId'] == null ? null : cloudUuid(p['finalResultId']));
  }
}

class CloudTaskDetail {
  final Map<String, dynamic> parent;
  final List<Map<String, dynamic>> steps;
  CloudTaskDetail._(this.parent, this.steps);
  String get taskId => parent['id'];
  String get state => parent['state'];
  int get revision => parent['revision'];
  int get ownerId => parent['owner_id'];
  bool get terminal => const {
        'complete',
        'failed',
        'unknown',
        'cancelled',
        'deleted'
      }.contains(state);
  factory CloudTaskDetail.fromJson(Object? value) {
    final p = cloudObject(value);
    final parent = cloudObject(p['parent']);
    cloudUuid(parent['id']);
    cloudUuid(parent['publication_id']);
    cloudState(parent['state']);
    cloudInt(parent['owner_id']);
    cloudInt(parent['revision']);
    cloudDigest(parent['payload_hash']);
    if (parent['state'] != 'deleted' &&
        cloudHash(cloudCanonical(parent['payload'])) !=
            parent['payload_hash']) {
      throw const FormatException('云任务确认内容指纹不一致');
    }
    for (final k in ['attempts_used', 'estimated_tokens']) {
      cloudInt(parent[k], min: 0);
    }
    if (parent['final_result_id'] != null) {
      cloudUuid(parent['final_result_id']);
    }
    final list = p['steps'];
    if (list is! List || list.length != 3) {
      _invalid();
    }
    final steps = list.map(cloudObject).toList();
    for (final s in steps) {
      cloudUuid(s['id']);
      cloudInt(s['revision']);
      cloudInt(s['result_version'], min: 0);
      if (!cloudRoles.contains(s['role']) ||
          !const {'queued', 'running', 'complete', 'failed', 'unknown'}
              .contains(s['state'])) {
        _invalid();
      }
    }
    if (steps.map((s) => s['role']).toSet().length != 3) {
      _invalid();
    }
    return CloudTaskDetail._(
        _frozen(parent) as Map<String, dynamic>,
        List.unmodifiable(
            steps.map((s) => Map<String, dynamic>.unmodifiable(s))));
  }
}

class CloudWritingResult {
  final String resultId, stepId, content, contentHash, publicationId;
  final int version;
  const CloudWritingResult(this.resultId, this.stepId, this.version,
      this.content, this.contentHash, this.publicationId);
  factory CloudWritingResult.fromJson(Object? value) {
    final p = cloudObject(value);
    final content = cloudText(p['content'], 48000);
    if (content.runes.length > 12000 ||
        cloudDigest(p['content_hash']) != cloudHash(content)) {
      _invalid();
    }
    return CloudWritingResult(
        cloudUuid(p['id']),
        cloudUuid(p['step_id']),
        cloudInt(p['version']),
        content,
        cloudDigest(p['content_hash']),
        cloudUuid(p['publication_id']));
  }
  void verifyFinal(CloudTaskDetail detail) {
    final writer = detail.steps.singleWhere((s) => s['role'] == 'writing');
    if (detail.state != 'complete' ||
        detail.parent['final_result_id'] != resultId ||
        detail.parent['publication_id'] != publicationId ||
        writer['id'] != stepId ||
        writer['state'] != 'complete' ||
        writer['result_version'] != version) {
      _invalid();
    }
  }
}
