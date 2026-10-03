import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/data/provider_presets.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:http/http.dart' as http;

/// 服务商账号接口，仅使用当前配置直连；不混用后端代理的账号信息。
class AiProviderApi {
  static const _maxResponseBytes = 1024 * 1024;
  static const _maxModels = 1000;
  static const _maxFiles = 1000;
  static final _fileIdPattern = RegExp(r'^file-api-[A-Za-z0-9_-]+$');

  final http.Client? _client;
  final Duration timeout;

  AiProviderApi(
      {http.Client? client, this.timeout = const Duration(seconds: 20)})
      : _client = client;

  /// 保留 OpenAI 兼容服务的路径前缀，DeepSeek 官方账号接口使用根路径。
  static Uri endpointFor(AiProvider provider, String resource) {
    final isFiles = resource == 'files' || resource.startsWith('files/');
    if (resource != 'models' && resource != 'user/balance' && !isFiles) {
      throw const AiProviderApiException('不支持的服务商接口');
    }
    if (resource.startsWith('files/')) {
      _validateFileId(resource.substring('files/'.length));
    }
    final host = provider.apiHost.trim().isNotEmpty
        ? provider.apiHost
        : ProviderPresets.byId(provider.id)?.apiHost ?? '';
    final uri = Uri.tryParse(AiProvider.buildChatCompletionsUrl(host));
    const suffix = '/chat/completions';
    if (uri == null ||
        !(uri.isScheme('https') || uri.isScheme('http')) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !uri.path.endsWith(suffix)) {
      throw const AiProviderApiException('服务地址无效，请检查 API 地址');
    }
    var prefix = uri.path.substring(0, uri.path.length - suffix.length);
    if (_isOfficialDeepSeek(uri) && (prefix == '/v1' || prefix == '/beta')) {
      prefix = '';
    }
    if (resource == 'user/balance') {
      if (!_isOfficialDeepSeek(uri) || prefix.isNotEmpty) {
        throw const AiProviderApiException('余额查询仅支持 DeepSeek 官方 API 地址');
      }
    }
    if (isFiles && (!_isOfficialDeepSeek(uri) || prefix.isNotEmpty)) {
      throw const AiProviderApiException('云端文件管理仅支持 DeepSeek 官方 API 地址');
    }
    return uri.replace(path: '$prefix/$resource');
  }

  static bool _isOfficialDeepSeek(Uri uri) =>
      uri.isScheme('https') &&
      uri.host.toLowerCase() == 'api.deepseek.com' &&
      uri.port == 443;

  static bool supportsDeepSeekBalance(AiProvider provider) {
    try {
      endpointFor(provider, 'user/balance');
      return true;
    } on AiProviderApiException {
      return false;
    }
  }

  static bool supportsDeepSeekFiles(AiProvider provider) {
    try {
      endpointFor(provider, 'files');
      return true;
    } on AiProviderApiException {
      return false;
    }
  }

  Future<List<AiModel>> fetchModels(
    AiProvider provider, {
    Future<void>? abortTrigger,
  }) async {
    // 编辑页会改变同一个对象；在首个 await 前固定地址、Key 和能力探测来源。
    final snapshot = provider.copy();
    final data = await _requestJson(
      'GET',
      endpointFor(snapshot, 'models'),
      snapshot.apiKey,
      abortTrigger: abortTrigger,
    );
    final rows = data['data'];
    if (rows is! List || rows.length > _maxModels) {
      throw const AiProviderApiException('模型列表响应格式无效或数量过多');
    }
    final ids = <String>{};
    final models = <AiModel>[];
    for (final row in rows) {
      if (row is! Map ||
          row['id'] is! String ||
          (row['id'] as String).trim().isEmpty) {
        throw const AiProviderApiException('模型列表包含无效的模型 ID');
      }
      final id = row['id'] as String;
      if (!ids.add(id)) continue;
      final hints = ModelCapabilities.heuristic(
        id,
        providerCode: snapshot.providerCode,
      );
      final modalities = row['input_modalities'];
      final effort = row['effort'];
      final levels = effort is Map ? effort['supported_levels'] : null;
      models.add(AiModel(
        id: id,
        name: row['name'] is String ? row['name'] as String : null,
        description: _modelDescription(row),
        vision:
            hints.image || (modalities is List && modalities.contains('image')),
        reasoning: hints.reasoning ||
            (levels is List && levels.any((level) => level is String)),
        tool: hints.tool,
      ));
    }
    return models;
  }

  Future<DeepSeekBalance> fetchDeepSeekBalance(
    AiProvider provider, {
    Future<void>? abortTrigger,
  }) async {
    final snapshot = provider.copy();
    final data = await _requestJson(
      'GET',
      endpointFor(snapshot, 'user/balance'),
      snapshot.apiKey,
      abortTrigger: abortTrigger,
    );
    final available = data['is_available'];
    final rows = data['balance_infos'];
    if (available is! bool || rows is! List || rows.length > 1000) {
      throw const AiProviderApiException('DeepSeek 余额响应格式无效');
    }
    final balances = <DeepSeekBalanceInfo>[];
    for (final row in rows) {
      if (row is! Map ||
          row['currency'] is! String ||
          !RegExp(r'^[A-Z]{3}$').hasMatch(row['currency'] as String)) {
        throw const AiProviderApiException('DeepSeek 余额响应格式无效');
      }
      balances.add(DeepSeekBalanceInfo(
        currency: row['currency'] as String,
        totalBalance: _decimal(row['total_balance']),
        grantedBalance: _decimal(row['granted_balance']),
        toppedUpBalance: _decimal(row['topped_up_balance']),
      ));
    }
    return DeepSeekBalance(isAvailable: available, balances: balances);
  }

  Future<DeepSeekFilePage> listDeepSeekFiles(
    AiProvider provider, {
    String? after,
    int limit = 25,
    Future<void>? abortTrigger,
  }) async {
    final snapshot = provider.copy();
    if (limit < 1 || limit > _maxFiles) {
      throw const AiProviderApiException('文件分页数量必须在 1 到 1000 之间');
    }
    if (after != null) _validateFileId(after);
    final endpoint = endpointFor(snapshot, 'files').replace(queryParameters: {
      'limit': '$limit',
      'order': 'desc',
      'purpose': 'user_data',
      if (after != null) 'after': after,
    });
    final data = await _requestJson(
      'GET',
      endpoint,
      snapshot.apiKey,
      abortTrigger: abortTrigger,
    );
    final rows = data['data'];
    final hasMore = data['has_more'];
    if (data['object'] != 'list' ||
        rows is! List ||
        rows.length > _maxFiles ||
        hasMore is! bool) {
      throw const AiProviderApiException('DeepSeek 文件列表响应格式无效');
    }
    final files = <DeepSeekCloudFile>[];
    final ids = <String>{};
    for (final row in rows) {
      final file = _parseFile(row);
      if (!ids.add(file.id)) {
        throw const AiProviderApiException('DeepSeek 文件列表包含重复文件');
      }
      files.add(file);
    }
    final firstId = _optionalFileId(data['first_id']);
    final lastId = _optionalFileId(data['last_id']);
    // 防止错误游标导致「加载更多」重复读取同一页。
    if ((files.isEmpty && (firstId != null || lastId != null || hasMore)) ||
        (files.isNotEmpty &&
            (lastId != files.last.id ||
                (firstId != null && firstId != files.first.id))) ||
        (hasMore && lastId == after)) {
      throw const AiProviderApiException('DeepSeek 文件列表分页信息无效');
    }
    return DeepSeekFilePage(files: files, lastId: lastId, hasMore: hasMore);
  }

  Future<DeepSeekCloudFile> getDeepSeekFile(
    AiProvider provider,
    String fileId, {
    Future<void>? abortTrigger,
  }) async {
    final snapshot = provider.copy();
    _validateFileId(fileId);
    final data = await _requestJson(
      'GET',
      endpointFor(snapshot, 'files/$fileId'),
      snapshot.apiKey,
      abortTrigger: abortTrigger,
    );
    final file = _parseFile(data);
    if (file.id != fileId) {
      throw const AiProviderApiException('DeepSeek 返回的文件与请求不一致');
    }
    return file;
  }

  Future<void> deleteDeepSeekFile(
    AiProvider provider,
    String fileId, {
    Future<void>? abortTrigger,
  }) async {
    final snapshot = provider.copy();
    _validateFileId(fileId);
    final data = await _requestJson(
      'DELETE',
      endpointFor(snapshot, 'files/$fileId'),
      snapshot.apiKey,
      abortTrigger: abortTrigger,
    );
    if (data['id'] != fileId ||
        data['object'] != 'file' ||
        data['deleted'] != true) {
      throw const AiProviderApiException('DeepSeek 未确认文件删除成功，请刷新列表确认');
    }
  }

  static void _validateFileId(String fileId) {
    if (fileId.length > 256 || !_fileIdPattern.hasMatch(fileId)) {
      throw const AiProviderApiException('DeepSeek 文件 ID 无效');
    }
  }

  static String? _optionalFileId(Object? value) {
    if (value == null || value == '') return null;
    if (value is! String) {
      throw const AiProviderApiException('DeepSeek 文件列表分页信息无效');
    }
    _validateFileId(value);
    return value;
  }

  static DeepSeekCloudFile _parseFile(Object? row) {
    if (row is! Map ||
        row['object'] != 'file' ||
        row['id'] is! String ||
        row['filename'] is! String ||
        (row['filename'] as String).trim().isEmpty ||
        (row['filename'] as String).length > 4096 ||
        row['purpose'] != 'user_data' ||
        row['bytes'] is! int ||
        (row['bytes'] as int) < 0 ||
        !_isUnixTime(row['created_at']) ||
        (row['expires_at'] != null && !_isUnixTime(row['expires_at']))) {
      throw const AiProviderApiException('DeepSeek 文件信息响应格式无效');
    }
    final id = row['id'] as String;
    _validateFileId(id);
    return DeepSeekCloudFile(
      id: id,
      filename: row['filename'] as String,
      purpose: row['purpose'] as String,
      bytes: row['bytes'] as int,
      createdAt: row['created_at'] as int,
      expiresAt: row['expires_at'] as int?,
    );
  }

  // 限制到 Dart DateTime 可表示范围，避免无效上游时间戳导致详情页崩溃。
  static bool _isUnixTime(Object? value) =>
      value is int && value >= 0 && value <= 8640000000000;

  static String _decimal(Object? value) {
    if (value is! String || !RegExp(r'^-?\d+(?:\.\d+)?$').hasMatch(value)) {
      throw const AiProviderApiException('DeepSeek 余额响应格式无效');
    }
    // 金额按原始十进制字符串保留，避免 double 转换损失精度。
    return value;
  }

  static String? _modelDescription(Map row) {
    final parts = <String>[];
    final description = row['description'];
    if (description is String && description.trim().isNotEmpty) {
      parts.add(description);
    }
    final context = row['context_length'] ?? row['context_window'];
    final output = row['max_output_tokens'] ?? row['max_completion_tokens'];
    if (context is int && context > 0) parts.add('上下文：$context tokens');
    if (output is int && output > 0) parts.add('最大输出：$output tokens');
    return parts.isEmpty ? null : parts.join(' · ');
  }

  Future<Map<String, dynamic>> _requestJson(
    String method,
    Uri endpoint,
    String apiKey, {
    Future<void>? abortTrigger,
  }) async {
    final key = apiKey.trim();
    if (key.isEmpty) {
      throw const AiProviderApiException('请先填写 API Key');
    }
    var cancelled = false;
    if (abortTrigger != null) {
      unawaited(abortTrigger.then((_) => cancelled = true, onError: (_) {
        cancelled = true;
      }));
      await Future<void>.value();
      if (cancelled) throw const AiProviderApiException('请求已取消');
    }
    final abort = Completer<void>();
    var timedOut = false;
    void cancel() {
      if (!abort.isCompleted) abort.complete();
    }

    final timer = Timer(timeout, () {
      timedOut = true;
      cancel();
    });
    if (abortTrigger != null) {
      unawaited(abortTrigger.then((_) => cancel(), onError: (_) => cancel()));
    }
    AiProviderApiException abortError() => AiProviderApiException(
          timedOut ? '请求超时，请检查网络后重试' : '请求已取消',
        );
    Future<T> race<T>(Future<T> operation) => Future.any<T>([
          operation,
          abort.future.then<T>((_) => throw abortError()),
        ]);

    final client = _client ?? http.Client();
    try {
      final request = http.AbortableRequest(
        method,
        endpoint,
        abortTrigger: abort.future,
      )
        ..followRedirects = false
        ..headers['Authorization'] = 'Bearer $key'
        ..headers['Accept'] = 'application/json';
      final sending = client.send(request);
      // 注入的 Client 也可能忽略 abort；晚到的响应及时取消，不继续读取正文。
      unawaited(sending.then((response) {
        if (abort.isCompleted) _cancelResponse(response);
      }, onError: (_) {}));
      final response = await race(sending);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _cancelResponse(response);
        throw AiProviderApiException(
          _statusMessage(response.statusCode),
          statusCode: response.statusCode,
        );
      }
      if ((response.contentLength ?? 0) > _maxResponseBytes) {
        _cancelResponse(response);
        throw const AiProviderApiException('服务商响应过大，请稍后重试');
      }
      final bytes = BytesBuilder(copy: false);
      final iterator = StreamIterator<List<int>>(response.stream);
      var size = 0;
      // 每次响应只挂一次取消监听，避免细碎分片为取消 Future 累积大量回调。
      unawaited(abort.future.then((_) {
        unawaited(iterator.cancel().catchError((_) {}));
      }));
      try {
        await race((() async {
          while (await iterator.moveNext()) {
            size += iterator.current.length;
            if (size > _maxResponseBytes) {
              throw const AiProviderApiException('服务商响应过大，请稍后重试');
            }
            bytes.add(iterator.current);
          }
        })());
        if (abort.isCompleted) throw abortError();
      } finally {
        unawaited(iterator.cancel().catchError((_) {}));
      }
      final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (decoded is! Map<String, dynamic>) {
        throw const AiProviderApiException('服务商响应格式无效');
      }
      return decoded;
    } on AiProviderApiException {
      rethrow;
    } on http.RequestAbortedException {
      throw abortError();
    } on FormatException {
      throw const AiProviderApiException('服务商响应格式无效');
    } catch (_) {
      // 不把响应正文、请求地址、底层异常或 Key 显示给用户。
      throw const AiProviderApiException('请求失败，请检查 API 地址和网络后重试');
    } finally {
      timer.cancel();
      cancel();
      if (_client == null) client.close();
    }
  }

  static void _cancelResponse(http.StreamedResponse response) {
    unawaited(response.stream
        .listen((_) {}, onError: (Object _, StackTrace __) {})
        .cancel()
        .catchError((_) {}));
  }

  static String _statusMessage(int status) {
    switch (status) {
      case 401:
      case 403:
        return '鉴权失败，请检查 API Key';
      case 402:
        return '账号余额不足，请充值后重试';
      case 404:
        return '服务商未提供此接口，请检查 API 地址';
      case 429:
        return '请求过多，请稍后重试';
      default:
        return '请求失败（HTTP $status），请稍后重试';
    }
  }
}

class DeepSeekCloudFile {
  final String id;
  final String filename;
  final String purpose;
  final int bytes;
  final int createdAt;
  final int? expiresAt;

  const DeepSeekCloudFile({
    required this.id,
    required this.filename,
    required this.purpose,
    required this.bytes,
    required this.createdAt,
    this.expiresAt,
  });
}

class DeepSeekFilePage {
  final List<DeepSeekCloudFile> files;
  final String? lastId;
  final bool hasMore;

  DeepSeekFilePage({
    required List<DeepSeekCloudFile> files,
    required this.lastId,
    required this.hasMore,
  }) : files = List.unmodifiable(files);
}

class DeepSeekBalance {
  final bool isAvailable;
  final List<DeepSeekBalanceInfo> balances;

  DeepSeekBalance(
      {required this.isAvailable, required List<DeepSeekBalanceInfo> balances})
      : balances = List.unmodifiable(balances);
}

class DeepSeekBalanceInfo {
  final String currency;
  final String totalBalance;
  final String grantedBalance;
  final String toppedUpBalance;

  const DeepSeekBalanceInfo({
    required this.currency,
    required this.totalBalance,
    required this.grantedBalance,
    required this.toppedUpBalance,
  });
}

class AiProviderApiException implements Exception {
  final String message;
  final int? statusCode;

  const AiProviderApiException(this.message, {this.statusCode});

  @override
  String toString() => message;
}
