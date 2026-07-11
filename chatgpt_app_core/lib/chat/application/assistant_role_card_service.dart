import 'dart:convert';
import 'dart:io' show ZLibDecoder;
import 'dart:typed_data';

import 'package:archive/archive.dart' as archive;
import 'package:chatgpt_app_core/chat/application/assistant_example_dialogs.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/world_book.dart';

class AssistantRoleCardService {
  static const format = 'chatai_deep_assistant_card';
  static const version = 1;
  static const fullExportLabel = '完整角色卡';
  static const fullExportDescription = '保留本应用字段，适合备份或发给同款 App';
  static const tavernExportLabel = 'Tavern V2 兼容';
  static const tavernExportDescription = '导出 SillyTavern V2 JSON，适合检查或二次编辑';
  static const tavernPngExportLabel = 'Tavern V2 PNG';
  static const tavernPngExportDescription = '导出酒馆常用 PNG 角色卡，可直接导入 SillyTavern';
  static const charxExportLabel = 'CHARX V3';
  static const charxExportDescription = '导出 Character Card V3 角色卡及资源包';
  // 只写入 memoryBook 的注释行，因此不会参与角色记忆匹配或系统提示注入。
  static const _tavernRawMarker = '# [chatai_deep.tavern_raw.v1] ';
  static const _tavernPreferredLocaleKeys = [
    'zh-CN',
    'zh_CN',
    'zh-Hans',
    'zh_Hans',
    'zh',
    'cn',
    '中文',
    'chinese',
    'en-US',
    'en_US',
    'en',
    'default',
  ];

  static String exportJson(AssistantModel assistant, {DateTime? exportedAt}) {
    final card = <String, dynamic>{
      'format': format,
      'version': version,
      'exportedAt': (exportedAt ?? DateTime.now()).toIso8601String(),
      'assistant': _assistantPayload(assistant),
    };
    return const JsonEncoder.withIndent('  ').convert(card);
  }

  static String exportTavernV2Json(
    AssistantModel assistant, {
    DateTime? exportedAt,
  }) {
    final rawCard = _tavernRawCardPayload(assistant.memoryBook);
    final data = rawCard == null
        ? _tavernDataFromAssistant(assistant, exportedAt: exportedAt)
        : _tavernDataFromRawCard(
            assistant,
            rawCard,
            exportedAt: exportedAt,
          );
    if (rawCard == null) {
      data.removeWhere((key, value) => _isEmptyTavernValue(value));
    }
    final card = <String, dynamic>{
      'spec': rawCard?['spec'] is String
          ? rawCard!['spec'] as String
          : 'chara_card_v2',
      'spec_version': rawCard?['spec_version'] is String
          ? rawCard!['spec_version'] as String
          : '2.0',
      'data': data,
    };
    return const JsonEncoder.withIndent('  ').convert(card);
  }

  static Uint8List exportTavernV2Png(
    AssistantModel assistant, {
    DateTime? exportedAt,
    List<int>? basePngBytes,
  }) {
    final json = exportTavernV2Json(assistant, exportedAt: exportedAt);
    final payload = base64.encode(utf8.encode(json));
    final base =
        basePngBytes != null && _isPng(basePngBytes) ? basePngBytes : null;
    return _writePngTextChunk(
      base ?? _defaultTavernCardPngBytes(),
      keyword: 'chara',
      text: payload,
    );
  }

  /// 导出 CHARX。传入导入结果时会携带已解析的资源清单和包内字节；传入
  /// [AssistantModel] 时也可通过 [resources] / [avatarPngBytes] 提供资源。
  /// 该 API 只生成 ZIP，不访问网络、不执行资源文件。
  static Uint8List exportCharx(
    Object source, {
    DateTime? exportedAt,
    List<AssistantRoleCardResource> resources = const [],
    List<int>? avatarPngBytes,
    Map<String, List<int>> resourceBytes = const {},
  }) {
    final assistant = source is AssistantRoleCardImportResult
        ? source.assistant
        : source is AssistantModel
            ? source
            : throw ArgumentError.value(source, 'source', '不是角色卡导入结果');
    final sourceResources = source is AssistantRoleCardImportResult
        ? source.resources
        : const <AssistantRoleCardResource>[];
    final effectiveResources = [
      ...(resources.isEmpty ? sourceResources : resources),
    ];
    final imageBytes = avatarPngBytes ??
        (source is AssistantRoleCardImportResult
            ? source.avatarPngBytes
            : null);
    if (imageBytes != null &&
        !_hasIconResource(effectiveResources) &&
        (_isPng(imageBytes) || _isJpeg(imageBytes))) {
      final ext = _isJpeg(imageBytes) ? 'jpg' : 'png';
      effectiveResources.add(AssistantRoleCardResource(
        type: 'icon',
        uri: 'embeded://assets/icon/main.$ext',
        name: 'main',
        ext: ext,
        archivePath: 'assets/icon/main.$ext',
        mimeType: _mimeTypeForExtension(ext),
        size: imageBytes.length,
        bytes: Uint8List.fromList(imageBytes),
      ));
    }

    final card = jsonDecode(exportTavernV2Json(
      assistant,
      exportedAt: exportedAt,
    )) as Map<String, dynamic>;
    card['spec'] = 'chara_card_v3';
    card['spec_version'] = '3.0';
    final data = Map<String, dynamic>.from(card['data'] as Map);
    if (effectiveResources.any((resource) => resource.includeInCard)) {
      data['assets'] = [
        for (final resource in effectiveResources)
          if (resource.includeInCard) resource.toCardJson(),
      ];
    }
    card['data'] = data;

    final output = archive.Archive()
      ..addFile(archive.ArchiveFile.bytes(
        'card.json',
        utf8.encode(const JsonEncoder.withIndent('  ').convert(card)),
      ));
    final emittedPaths = <String>{'card.json'};
    for (final resource in effectiveResources) {
      final path = _charxArchivePath(resource);
      if (path == null || !emittedPaths.add(path)) continue;
      final bytes = resource.bytes ??
          resourceBytes[resource.archivePath] ??
          resourceBytes[resource.uri];
      if (bytes == null || bytes.isEmpty) continue;
      output.addFile(archive.ArchiveFile.bytes(path, bytes));
    }
    return Uint8List.fromList(archive.ZipEncoder().encodeBytes(output));
  }

  static Uint8List exportCharxImportResult(
    AssistantRoleCardImportResult result, {
    DateTime? exportedAt,
    Map<String, List<int>> resourceBytes = const {},
  }) =>
      exportCharx(
        result,
        exportedAt: exportedAt,
        resourceBytes: resourceBytes,
      );

  static AssistantModel importBytes(List<int> bytes, {String? filename}) {
    return importPackageBytes(bytes, filename: filename).assistant;
  }

  static AssistantRoleCardImportResult importPackageBytes(List<int> bytes,
      {String? filename}) {
    if (_isZip(bytes, filename: filename)) {
      return _isCharx(bytes, filename: filename)
          ? _importCharx(bytes, filename: filename)
          : _importZip(bytes);
    }
    if (_isPng(bytes)) {
      final json = _extractPngRoleCardJson(bytes);
      return _importJsonResult(
        json,
        sourceName: filename,
        avatarPngBytes: bytes,
      );
    }
    try {
      return _importJsonResult(
        utf8.decode(bytes),
        sourceName: filename,
      );
    } catch (_) {
      return _importJsonResult(
        latin1.decode(bytes),
        sourceName: filename,
      );
    }
  }

  static AssistantRoleCardImportResult _importJsonResult(
    String json, {
    String? sourceName,
    List<int>? avatarPngBytes,
  }) {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('角色卡 JSON 必须是对象');
    }
    return AssistantRoleCardImportResult(
      assistant: importJson(json),
      avatarPngBytes: avatarPngBytes,
      avatarExtension: avatarPngBytes == null
          ? null
          : (_isJpeg(avatarPngBytes) ? '.jpg' : '.png'),
      resources: _resourcesFromDecoded(decoded),
      sourceName: sourceName,
      tavernMeta: tavernMetaFromJson(json),
    );
  }

  static AssistantRoleCardImportResult _importCharx(
    List<int> bytes, {
    String? filename,
  }) {
    final roleArchive = _decodeRoleArchive(bytes);
    archive.ArchiveFile? cardFile;
    for (final file in roleArchive.files) {
      if (file.isFile == true && file.name == 'card.json') {
        cardFile = file;
        break;
      }
    }
    if (cardFile == null) {
      throw const FormatException('CHARX 根目录缺少 card.json');
    }
    final cardBytes = cardFile.readBytes();
    if (cardBytes == null || cardBytes.isEmpty) {
      throw const FormatException('CHARX 的 card.json 为空');
    }
    final json = utf8.decode(cardBytes);
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic> ||
        _string(decoded['spec']) != 'chara_card_v3') {
      throw const FormatException('CHARX 的 card.json 必须是 Character Card V3');
    }
    final resources = _resourcesFromCharx(decoded, roleArchive);
    final avatar = _selectAvatarResource(resources);
    return AssistantRoleCardImportResult(
      assistant: importJson(json),
      avatarPngBytes: avatar?.bytes,
      avatarExtension:
          avatar == null ? null : (_isJpeg(avatar.bytes!) ? '.jpg' : '.png'),
      resources: resources,
      sourceName: filename ?? 'card.json',
      tavernMeta: tavernMetaFromJson(json),
    );
  }

  static archive.Archive _decodeRoleArchive(List<int> bytes) {
    try {
      return archive.ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const FormatException('无法解析角色卡 ZIP');
    }
  }

  static List<AssistantRoleCardResource> _resourcesFromDecoded(
    Map<String, dynamic> decoded,
  ) {
    final data = decoded['data'];
    final cardData = data is Map<String, dynamic> ? data : decoded;
    return _resourcesFromAssetList(cardData['assets']);
  }

  static List<AssistantRoleCardResource> _resourcesFromCharx(
    Map<String, dynamic> decoded,
    archive.Archive roleArchive,
  ) {
    final files = <String, List<int>>{};
    for (final file in roleArchive.files) {
      if (file.isFile != true || file.name == 'card.json') continue;
      final path = _safeArchivePath(file.name);
      if (path == null) continue;
      final bytes = file.readBytes();
      if (bytes != null) files[path] = Uint8List.fromList(bytes);
    }
    final resources = <AssistantRoleCardResource>[];
    final referenced = <String>{};
    final data = decoded['data'];
    final cardData = data is Map<String, dynamic> ? data : decoded;
    final assets = cardData['assets'];
    if (assets is List) {
      for (final raw in assets) {
        if (raw is! Map) continue;
        final asset = Map<String, dynamic>.from(raw);
        final uri = _string(asset['uri']);
        final embeddedPath = _embeddedAssetPath(uri);
        if (embeddedPath != null) referenced.add(embeddedPath);
        final bytes = embeddedPath == null ? null : files[embeddedPath];
        final ext = _assetExtension(asset['ext'], embeddedPath);
        resources.add(AssistantRoleCardResource(
          type: _string(asset['type'], fallback: 'other'),
          uri: uri,
          name:
              _string(asset['name'], fallback: _basename(embeddedPath ?? uri)),
          ext: ext,
          archivePath: embeddedPath ?? '',
          mimeType: _mimeTypeForExtension(ext),
          size: bytes?.length ?? 0,
          bytes: bytes == null ? null : Uint8List.fromList(bytes),
        ));
      }
    }
    for (final entry in files.entries) {
      if (referenced.contains(entry.key)) continue;
      final ext = _assetExtension('', entry.key);
      resources.add(AssistantRoleCardResource(
        type: _assetTypeForPath(entry.key),
        uri: 'embeded://${entry.key}',
        name: _basename(entry.key),
        ext: ext,
        archivePath: entry.key,
        mimeType: _mimeTypeForExtension(ext),
        size: entry.value.length,
        bytes: Uint8List.fromList(entry.value),
        includeInCard: false,
      ));
    }
    return resources;
  }

  static List<AssistantRoleCardResource> _resourcesFromAssetList(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) _resourceFromAsset(Map<String, dynamic>.from(item)),
    ];
  }

  static AssistantRoleCardResource _resourceFromAsset(
    Map<String, dynamic> asset,
  ) {
    final uri = _string(asset['uri']);
    final embeddedPath = _embeddedAssetPath(uri);
    final ext = _assetExtension(asset['ext'], embeddedPath);
    return AssistantRoleCardResource(
      type: _string(asset['type'], fallback: 'other'),
      uri: uri,
      name: _string(asset['name'], fallback: _basename(embeddedPath ?? uri)),
      ext: ext,
      archivePath: embeddedPath ?? '',
      mimeType: _mimeTypeForExtension(ext),
      size: 0,
    );
  }

  static bool _hasIconResource(List<AssistantRoleCardResource> resources) =>
      resources.any((resource) =>
          resource.includeInCard && resource.type.toLowerCase() == 'icon');

  static AssistantRoleCardResource? _selectAvatarResource(
    List<AssistantRoleCardResource> resources,
  ) {
    final icons = resources.where((resource) {
      final type = resource.type.toLowerCase();
      return resource.includeInCard &&
          type == 'icon' &&
          resource.bytes != null &&
          (_isPng(resource.bytes!) || _isJpeg(resource.bytes!));
    }).toList();
    icons.sort((a, b) {
      final aMain = a.name.toLowerCase() == 'main' ? 0 : 1;
      final bMain = b.name.toLowerCase() == 'main' ? 0 : 1;
      return aMain == bMain ? a.name.compareTo(b.name) : aMain - bMain;
    });
    return icons.isEmpty ? null : icons.first;
  }

  static String? _charxArchivePath(AssistantRoleCardResource resource) {
    final original = _safeArchivePath(resource.archivePath);
    if (original != null && original != 'card.json') return original;
    final type = _safePathPart(resource.type, fallback: 'other');
    final name = _safePathPart(resource.name, fallback: 'asset');
    final ext = resource.ext.trim().toLowerCase().replaceFirst('.', '');
    return 'assets/$type/$name${ext.isEmpty ? '' : '.$ext'}';
  }

  static String? _safeArchivePath(String raw) {
    final value = raw.replaceAll('\\', '/').trim();
    if (value.isEmpty || value.startsWith('/') || value.contains(':')) {
      return null;
    }
    final parts = value.split('/');
    if (parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
      return null;
    }
    return parts.join('/');
  }

  static String? _embeddedAssetPath(String uri) {
    final lower = uri.toLowerCase();
    const prefixes = ['embeded://', 'embedded://'];
    for (final prefix in prefixes) {
      if (lower.startsWith(prefix)) {
        return _safeArchivePath(uri.substring(prefix.length));
      }
    }
    return null;
  }

  static String _assetExtension(Object? raw, String? path) {
    final explicit = _string(raw).toLowerCase().replaceFirst('.', '');
    if (explicit.isNotEmpty) return explicit;
    final value = path ?? '';
    final dot = value.lastIndexOf('.');
    return dot >= 0 && dot + 1 < value.length
        ? value.substring(dot + 1).toLowerCase()
        : 'unknown';
  }

  static String _assetTypeForPath(String path) {
    final lower = path.toLowerCase();
    if (lower.contains('/audio/')) return 'audio';
    if (lower.contains('/background/')) return 'background';
    if (lower.contains('/icon/')) return 'icon';
    return 'other';
  }

  static String _mimeTypeForExtension(String ext) {
    switch (ext.toLowerCase()) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'webp':
        return 'image/webp';
      case 'gif':
        return 'image/gif';
      case 'mp3':
        return 'audio/mpeg';
      case 'wav':
        return 'audio/wav';
      case 'ogg':
        return 'audio/ogg';
      case 'm4a':
        return 'audio/mp4';
      default:
        return 'application/octet-stream';
    }
  }

  static String _safePathPart(String raw, {required String fallback}) {
    final value = raw.trim().replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return value.isEmpty ? fallback : value;
  }

  static String _basename(String path) {
    final value = path.replaceAll('\\', '/');
    final slash = value.lastIndexOf('/');
    return slash < 0 ? value : value.substring(slash + 1);
  }

  static bool _isJpeg(List<int> bytes) =>
      bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff;

  static AssistantRoleCardTavernMeta? tavernMetaFromJson(String jsonText) {
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! Map<String, dynamic>) return null;
      return _tavernMetaFromDecoded(decoded);
    } catch (_) {
      return null;
    }
  }

  /// 从导入卡写入的注释标记恢复原卡元信息，供后续创建酒馆房间时使用。
  static AssistantRoleCardTavernMeta? tavernMetaFromAssistant(
    AssistantModel assistant,
  ) {
    final rawCard = _tavernRawCardPayload(assistant.memoryBook);
    return rawCard == null ? null : _tavernMetaFromDecoded(rawCard);
  }

  /// 识别仍需要沙箱/插件宿主的 Tavern 扩展。Prompt Manager 与纯文本
  /// Quick Replies 与声明式正则替换由受控解析器消费；第三方脚本和快捷命令不执行。
  static TavernExtensionSafetyReport extensionSafetyReport(
    AssistantModel assistant,
  ) {
    final raw = _tavernRawCardPayload(assistant.memoryBook);
    if (raw == null) return const TavernExtensionSafetyReport();
    final detected = <String>{};
    void scan(Object? value) {
      if (value is List) {
        for (final item in value) {
          scan(item);
        }
        return;
      }
      if (value is! Map) return;
      for (final entry in value.entries) {
        final key = '${entry.key}'.trim().toLowerCase().replaceAll('-', '_');
        if (_tavernExecutableExtensionLabels.containsKey(key) &&
            !_isEmptyTavernValue(entry.value)) {
          detected.add(_tavernExecutableExtensionLabels[key]!);
        }
        scan(entry.value);
      }
    }

    scan(raw);
    return TavernExtensionSafetyReport(
      blockedExtensionLabels: detected.toList()..sort(),
    );
  }

  /// 返回角色卡中的声明式 Tavern 扩展副本，供受控 Prompt Manager、
  /// Quick Replies 等解析器读取。这里只复制 JSON，不执行脚本或命令。
  static Map<String, dynamic> tavernDeclarativeExtensions(
    AssistantModel assistant,
  ) {
    final raw = _tavernRawCardPayload(assistant.memoryBook);
    if (raw == null) return const {};
    final data = _mapStringDynamic(raw['data']) ?? raw;
    final extensions = _mapStringDynamic(data['extensions']);
    return extensions == null ? const {} : _copyJsonMap(extensions);
  }

  static const Map<String, String> _tavernExecutableExtensionLabels = {
    'scripts': '脚本',
    'javascript': 'JavaScript',
    'regex_scripts': 'Regex Scripts（受控文本替换）',
    'regexscripts': 'Regex Scripts（受控文本替换）',
    'quick_replies': 'Quick Replies 命令',
    'quickreplies': 'Quick Replies 命令',
  };

  /// 移除仅用于往返导出的内部标记，供运行时世界书消费方使用。
  static String memoryBookForRuntime(String memoryBook) =>
      _withoutTavernRawCardMarker(memoryBook);

  static List<AssistantRoleCardImportResult> importPackageBytesList(
      List<int> bytes,
      {String? filename}) {
    return importPackageBatchBytes(bytes, filename: filename).results;
  }

  static AssistantRoleCardImportBatchResult importPackageBatchBytes(
      List<int> bytes,
      {String? filename}) {
    if (_isZip(bytes, filename: filename)) {
      if (_isCharx(bytes, filename: filename)) {
        return AssistantRoleCardImportBatchResult(
          results: [importPackageBytes(bytes, filename: filename)],
        );
      }
      return _importZipBatch(bytes);
    }
    return AssistantRoleCardImportBatchResult(
      results: [importPackageBytes(bytes, filename: filename)],
    );
  }

  static AssistantRoleCardImportResult _importZip(List<int> bytes) {
    return _importZipBatch(bytes).results.first;
  }

  static AssistantRoleCardImportBatchResult _importZipBatch(List<int> bytes) {
    final roleArchive = _decodeRoleArchive(bytes);

    final candidates = roleArchive.files.where((file) {
      if (file.isFile != true) return false;
      final name = file.name.toLowerCase();
      return name.endsWith('.json') || name.endsWith('.png');
    }).toList()
      ..sort((a, b) {
        final aName = a.name.toLowerCase();
        final bName = b.name.toLowerCase();
        final aScore = aName.endsWith('.json') ? 0 : 1;
        final bScore = bName.endsWith('.json') ? 0 : 1;
        return aScore == bScore ? a.name.compareTo(b.name) : aScore - bScore;
      });

    final results = <AssistantRoleCardImportResult>[];
    final skipped = <AssistantRoleCardSkippedImport>[];
    for (final file in candidates) {
      try {
        final content = file.readBytes();
        if (content == null || content.isEmpty) {
          skipped.add(AssistantRoleCardSkippedImport(
            name: file.name,
            reason: '文件为空',
          ));
          continue;
        }
        results.add(importPackageBytes(content, filename: file.name));
      } catch (e) {
        final message = e is FormatException ? e.message : e.toString();
        skipped.add(AssistantRoleCardSkippedImport(
          name: file.name,
          reason: message,
        ));
        continue;
      }
    }
    if (results.isNotEmpty) {
      return AssistantRoleCardImportBatchResult(
        results: results,
        skipped: skipped,
      );
    }
    final detail = skipped.isEmpty
        ? ''
        : '（${skipped.map((item) => '${item.name}: ${item.reason}').join('；')}）';
    throw FormatException('ZIP 中未找到可导入的角色卡 JSON 或 PNG$detail');
  }

  static bool _isCharx(List<int> bytes, {String? filename}) {
    if (filename?.toLowerCase().endsWith('.charx') == true) return true;
    if (!_isZip(bytes, filename: filename)) return false;
    try {
      final roleArchive = _decodeRoleArchive(bytes);
      for (final file in roleArchive.files) {
        if (file.isFile != true || file.name != 'card.json') continue;
        final content = file.readBytes();
        if (content == null || content.isEmpty) return false;
        final decoded = jsonDecode(utf8.decode(content));
        return decoded is Map<String, dynamic> &&
            _string(decoded['spec']) == 'chara_card_v3';
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  static AssistantModel importJson(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('角色卡 JSON 必须是对象');
    }
    final payload = _extractAssistantPayload(decoded);
    final name = (payload['name'] as String? ?? '').trim();
    if (name.isEmpty) {
      throw const FormatException('角色卡缺少助手名称');
    }
    return AssistantModel(
      name: name,
      emoji: _string(payload['emoji'], fallback: '🤖'),
      prompt: _string(payload['prompt']),
      description: _string(payload['description']),
      openingMessage: _string(payload['openingMessage']),
      exampleDialogs: _string(payload['exampleDialogs']),
      memoryBook: _string(payload['memoryBook']),
      worldBookJson: _string(payload['worldBookJson']),
      roleCardAssets: _string(payload['roleCardAssets']),
      defaultVoiceStyle: _string(payload['defaultVoiceStyle']),
      providerId: _string(payload['providerId']),
      model: _string(payload['model']),
      useTools: payload['useTools'] is bool
          ? payload['useTools'] as bool
          : (payload['useTools'] as int? ?? 1) != 0,
      toolIds: _toolIds(payload),
    );
  }

  static AssistantModel sanitizeForImport(
    AssistantModel assistant, {
    bool keepTools = false,
    bool keepModelOverride = false,
    bool keepDefaultVoice = false,
  }) {
    return AssistantModel(
      name: assistant.name,
      emoji: assistant.emoji,
      prompt: assistant.prompt,
      description: assistant.description,
      openingMessage: assistant.openingMessage,
      exampleDialogs: assistant.exampleDialogs,
      memoryBook: assistant.memoryBook,
      worldBookJson: assistant.worldBookJson,
      roleCardAssets: assistant.roleCardAssets,
      defaultVoiceStyle:
          keepDefaultVoice ? assistant.defaultVoiceStyle.trim() : '',
      providerId: keepModelOverride ? assistant.providerId.trim() : '',
      model: keepModelOverride ? assistant.model.trim() : '',
      useTools: keepTools ? assistant.useTools : true,
      toolIds: keepTools ? assistant.toolIds : null,
    );
  }

  static void preserveLocalOverwriteSettings(
    AssistantModel imported,
    AssistantModel existing, {
    bool keepIncomingTools = false,
    bool keepIncomingModelOverride = false,
    bool keepIncomingDefaultVoice = false,
  }) {
    if (!keepIncomingTools) {
      imported.useTools = existing.useTools;
      imported.toolIds = existing.toolIds;
    }
    if (!keepIncomingModelOverride) {
      imported.providerId = existing.providerId;
      imported.model = existing.model;
    }
    if (!keepIncomingDefaultVoice) {
      imported.defaultVoiceStyle = existing.defaultVoiceStyle;
    }
  }

  static String importResultText({
    required int createdCount,
    required int updatedCount,
    int skippedCount = 0,
  }) {
    final parts = <String>[
      if (createdCount > 0) '新增 $createdCount 张',
      if (updatedCount > 0) '更新 $updatedCount 张',
      if (skippedCount > 0) '跳过 $skippedCount 个文件',
    ];
    return parts.isEmpty ? '未保存角色卡' : '角色卡已保存：${parts.join('，')}';
  }

  static String filenameFor(AssistantModel assistant) {
    final name = assistant.name.trim().isEmpty ? 'assistant' : assistant.name;
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
    return 'assistant_$safe.json';
  }

  static String tavernFilenameFor(AssistantModel assistant) {
    final name = assistant.name.trim().isEmpty ? 'character' : assistant.name;
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
    return 'tavern_$safe.json';
  }

  static String tavernPngFilenameFor(AssistantModel assistant) {
    final name = assistant.name.trim().isEmpty ? 'character' : assistant.name;
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
    return 'tavern_$safe.png';
  }

  static String charxFilenameFor(AssistantModel assistant) {
    final name = assistant.name.trim().isEmpty ? 'character' : assistant.name;
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
    return 'character_$safe.charx';
  }

  static String uniqueImportName(
    String desiredName,
    Iterable<String> usedNames,
  ) {
    final baseName = desiredName.trim().isEmpty ? '未命名角色' : desiredName.trim();
    final normalizedUsed = usedNames
        .map((name) => _normalizeAssistantNameForConflict(name))
        .where((name) => name.isNotEmpty)
        .toSet();
    if (!normalizedUsed
        .contains(_normalizeAssistantNameForConflict(baseName))) {
      return baseName;
    }
    for (var index = 2; index < 10000; index++) {
      final candidate = '$baseName ($index)';
      if (!normalizedUsed.contains(
        _normalizeAssistantNameForConflict(candidate),
      )) {
        return candidate;
      }
    }
    return '$baseName (${DateTime.now().millisecondsSinceEpoch})';
  }

  static AssistantRoleCardSummary summarize(AssistantModel assistant) {
    final memoryEntries = parseMemoryEntries(
      assistant.memoryBook,
      structuredJson: assistant.worldBookJson,
    );
    final toolIds = assistant.toolIds ?? const <String>[];
    final exampleText = exampleDialogPromptText(assistant.exampleDialogs);
    final alternateGreetingCount =
        alternateGreetings(assistant.exampleDialogs).length;
    return AssistantRoleCardSummary(
      promptChars: assistant.prompt.trim().length,
      openingChars: assistant.openingMessage.trim().length,
      exampleDialogLines: exampleText
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .length,
      alternateGreetingCount: alternateGreetingCount,
      memoryEntries: memoryEntries,
      toolCount: toolIds.length,
      hasDefaultVoice: assistant.defaultVoiceStyle.trim().isNotEmpty,
      hasModelOverride: assistant.providerId.trim().isNotEmpty ||
          assistant.model.trim().isNotEmpty,
    );
  }

  static String importPreviewSummaryText(
    AssistantModel assistant, {
    bool hasAvatar = false,
  }) {
    final summary = summarize(assistant);
    final memoryParts = <String>[
      if (summary.alwaysOnMemoryCount > 0) '常驻 ${summary.alwaysOnMemoryCount}',
      if (summary.keywordMemoryCount > 0) '关键词 ${summary.keywordMemoryCount}',
      if (summary.disabledMemoryCount > 0) '禁用 ${summary.disabledMemoryCount}',
    ];
    final highImpactParts = <String>[
      if (!assistant.useTools) '工具关闭',
      if (summary.toolCount > 0) '工具 ${summary.toolCount}',
      if (summary.hasModelOverride) '模型覆盖',
      if (summary.hasDefaultVoice) '默认语音',
    ];
    final parts = <String>[
      '提示词 ${summary.promptChars} 字',
      summary.openingChars == 0 ? '无开场' : '开场 ${summary.openingChars} 字',
      if (summary.exampleDialogLines > 0) '示例 ${summary.exampleDialogLines} 行',
      if (summary.alternateGreetingCount > 0)
        '备选开场 ${summary.alternateGreetingCount}',
      if (summary.memoryCount > 0)
        memoryParts.isEmpty
            ? '世界书 ${summary.memoryCount} 条'
            : '世界书 ${summary.memoryCount} 条（${memoryParts.join(' / ')}）',
      if (highImpactParts.isNotEmpty) highImpactParts.join(' / '),
      if (hasAvatar) '含头像',
    ];
    return parts.join(' · ');
  }

  static List<AssistantMemoryEntryPreview> parseMemoryEntries(
    String raw, {
    String structuredJson = '',
  }) =>
      WorldBookCodec.decode(
        structuredJson: structuredJson,
        legacyText: raw,
      ).map(AssistantMemoryEntryPreview.fromWorldBook).toList();

  static List<AssistantMemoryEntryPreview> matchMemoryEntries(
    String raw,
    String userText, {
    int maxEntries = 6,
    List<String> recentTexts = const [],
    String structuredJson = '',
    String characterName = '',
    String personaDescription = '',
    String characterDescription = '',
    String characterPersonality = '',
    String characterDepthPrompt = '',
    String scenario = '',
    String creatorNotes = '',
    int messageCount = 0,
    int generationSeed = 0,
    Map<String, WorldBookActivation> activations = const {},
  }) =>
      matchWorldBookEntries(
        raw,
        userText,
        maxEntries: maxEntries,
        recentTexts: recentTexts,
        structuredJson: structuredJson,
        characterName: characterName,
        personaDescription: personaDescription,
        characterDescription: characterDescription,
        characterPersonality: characterPersonality,
        characterDepthPrompt: characterDepthPrompt,
        scenario: scenario,
        creatorNotes: creatorNotes,
        messageCount: messageCount,
        generationSeed: generationSeed,
        activations: activations,
      ).entries.map(AssistantMemoryEntryPreview.fromWorldBook).toList();

  static WorldBookMatchResult matchWorldBookEntries(
    String raw,
    String userText, {
    int maxEntries = 6,
    List<String> recentTexts = const [],
    String structuredJson = '',
    String characterName = '',
    String personaDescription = '',
    String characterDescription = '',
    String characterPersonality = '',
    String characterDepthPrompt = '',
    String scenario = '',
    String creatorNotes = '',
    int messageCount = 0,
    int generationSeed = 0,
    Map<String, WorldBookActivation> activations = const {},
  }) =>
      WorldBookMatcher.match(
        WorldBookCodec.decode(
          structuredJson: structuredJson,
          legacyText: raw,
        ),
        WorldBookMatchContext(
          input: userText,
          recentTexts: recentTexts,
          characterName: characterName,
          personaDescription: personaDescription,
          characterDescription: characterDescription,
          characterPersonality: characterPersonality,
          characterDepthPrompt: characterDepthPrompt,
          scenario: scenario,
          creatorNotes: creatorNotes,
          messageCount: messageCount,
          generationSeed: generationSeed,
          activations: activations,
        ),
        maxEntries: maxEntries.clamp(1, 50),
      );

  static String memoryHitSummary(List<AssistantMemoryEntryPreview> hits) {
    if (hits.isEmpty) return '未命中角色记忆';
    final alwaysOnCount = hits.where((entry) => entry.alwaysOn).length;
    final keywordCount = hits.length - alwaysOnCount;
    return '命中角色记忆 ${hits.length} 条（常驻 $alwaysOnCount / 关键词 $keywordCount）';
  }

  static String memoryHitPreviewLine(AssistantMemoryEntryPreview entry) {
    return '${entry.label}：${_compactPreviewText(entry.content)}';
  }

  static String memoryEntryCopyLine(AssistantMemoryEntryPreview entry) {
    return '${entry.label}：${_normalizePreviewText(entry.content)}';
  }

  static String memoryHitCopyText(List<AssistantMemoryEntryPreview> hits) {
    if (hits.isEmpty) return '';
    return [
      AssistantRoleCardService.memoryHitSummary(hits),
      for (final hit in hits) '- ${memoryEntryCopyLine(hit)}',
    ].join('\n');
  }

  static String formatMemoryBookEntry({
    required String keywords,
    required String content,
    bool enabled = true,
    int priority = 0,
  }) {
    final normalizedContent = _normalizeWorldBookContent(content);
    if (normalizedContent.isEmpty) return '';
    final normalizedKeywords = keywords
        .split(RegExp(r'[,，、|/]+'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .join(', ');
    final prefixes = <String>[
      if (!enabled) '[off]',
      if (priority != 0) '[p=$priority]',
    ];
    final body = normalizedKeywords.isEmpty
        ? normalizedContent
        : '$normalizedKeywords => $normalizedContent';
    return [...prefixes, body].join(' ');
  }

  static bool hasDuplicateMemoryContent(String raw, String content) {
    final normalized = _dedupeMemoryContent(content);
    if (normalized.isEmpty) return false;
    return parseMemoryEntries(raw)
        .map((entry) => _dedupeMemoryContent(entry.content))
        .any((item) => item == normalized);
  }

  static String mergeMemoryBooks(String current, String incoming) {
    return mergeMemoryBookPreview(current, incoming).mergedText;
  }

  static AssistantMemoryBookMergePreview mergeMemoryBookPreview(
    String current,
    String incoming,
  ) {
    final merged = current
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    final seen = parseMemoryEntries(current)
        .map((entry) => _dedupeMemoryContent(entry.content))
        .where((content) => content.isNotEmpty)
        .toSet();
    var appendedCount = 0;
    var skippedDuplicateCount = 0;
    var skippedInvalidCount = 0;
    final appendedLines = <String>[];
    for (final originalLine in incoming.split('\n')) {
      final line = originalLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final entries = parseMemoryEntries(line);
      if (entries.isEmpty) {
        skippedInvalidCount++;
        continue;
      }
      final contentKey = _dedupeMemoryContent(entries.first.content);
      if (contentKey.isEmpty) {
        skippedInvalidCount++;
        continue;
      }
      if (!seen.add(contentKey)) {
        skippedDuplicateCount++;
        continue;
      }
      merged.add(line);
      appendedLines.add(line);
      appendedCount++;
    }
    return AssistantMemoryBookMergePreview(
      mergedText: merged.join('\n'),
      existingCount: parseMemoryEntries(current).length,
      incomingCount: parseMemoryEntries(incoming).length,
      appendedCount: appendedCount,
      skippedDuplicateCount: skippedDuplicateCount,
      skippedInvalidCount: skippedInvalidCount,
      appendedLines: appendedLines,
    );
  }

  static String appendMemoryBookEntry(
    String raw, {
    required String keywords,
    required String content,
    bool enabled = true,
    int priority = 0,
  }) {
    final line = formatMemoryBookEntry(
      keywords: keywords,
      content: content,
      enabled: enabled,
      priority: priority,
    );
    if (line.isEmpty) return raw.trim();
    final existing = raw
        .split('\n')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
    existing.add(line);
    return existing.join('\n');
  }

  static String _compactPreviewText(String value) {
    final text = _normalizePreviewText(value);
    if (text.length <= 48) return text;
    return '${text.substring(0, 48)}...';
  }

  static String _normalizePreviewText(String value) {
    return value.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  static String _normalizeWorldBookContent(String value) {
    return value.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  static String _dedupeMemoryContent(String value) {
    return value.trim().replaceAll(RegExp(r'\s+'), '');
  }

  static String _normalizeAssistantNameForConflict(String value) {
    return value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  }

  static List<String> examplePreviewSnippets(String raw, {int maxItems = 3}) {
    final limit = maxItems.clamp(1, 20);
    final snippets = <String>[];
    final examples = exampleDialogPromptText(raw);
    for (final block in examples.split(RegExp(r'\n{2,}'))) {
      final text = block.trim();
      if (text.isEmpty) continue;
      snippets.add(text);
      if (snippets.length >= limit) return snippets;
    }
    for (final greeting in alternateGreetings(raw)) {
      snippets.add('备选开场：$greeting');
      if (snippets.length >= limit) return snippets;
    }
    return snippets;
  }

  static String exampleDialogPromptText(String raw) {
    return AssistantExampleDialogs.promptText(raw);
  }

  static List<String> alternateGreetings(String raw) {
    return AssistantExampleDialogs.alternateGreetings(raw);
  }

  static String formatExampleDialogTurn({
    required String userMessage,
    required String assistantMessage,
  }) {
    final user = _normalizeDialogLine(userMessage);
    final assistant = _normalizeDialogLine(assistantMessage);
    final lines = <String>[
      if (user.isNotEmpty) '用户：$user',
      if (assistant.isNotEmpty) '助手：$assistant',
    ];
    return lines.join('\n');
  }

  static String appendExampleDialog(String raw, String snippet) {
    final normalized = _normalizeExampleDialogSnippet(snippet);
    if (normalized.isEmpty) return raw.trim();
    final existing = raw.replaceAll('\r\n', '\n').trim();
    if (existing.isEmpty) return normalized;
    final lines = existing.split('\n');
    final alternateIndex = lines.indexWhere(
      (line) => AssistantExampleDialogs.isAlternateGreetingHeader(line.trim()),
    );
    if (alternateIndex >= 0) {
      final before = lines.take(alternateIndex).join('\n').trim();
      final alternateBlock = lines.skip(alternateIndex).join('\n').trim();
      return [
        if (before.isNotEmpty) before,
        normalized,
        if (alternateBlock.isNotEmpty) alternateBlock,
      ].join('\n\n');
    }
    return '$existing\n\n$normalized';
  }

  static bool hasDuplicateExampleDialog(String raw, String snippet) {
    final normalized = _dedupeExampleDialog(snippet);
    if (normalized.isEmpty) return false;
    final examples = exampleDialogPromptText(raw);
    for (final block in examples.split(RegExp(r'\n{2,}'))) {
      if (_dedupeExampleDialog(block) == normalized) return true;
    }
    return false;
  }

  static String _normalizeExampleDialogSnippet(String value) {
    return value
        .replaceAll('\r\n', '\n')
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join('\n');
  }

  static String _normalizeDialogLine(String value) {
    return AssistantExampleDialogs.normalizeDialogLine(value);
  }

  static String _dedupeExampleDialog(String value) {
    return value.trim().replaceAll(RegExp(r'\s+'), '');
  }

  static Map<String, String> _promptSections(String raw) {
    final sections = <String, String>{};
    final buffer = StringBuffer();
    String? current;

    void flush() {
      final title = current;
      if (title == null) return;
      final value = buffer.toString().trim();
      if (value.isNotEmpty) sections[title] = value;
      buffer.clear();
    }

    for (final line in raw.replaceAll('\r\n', '\n').split('\n')) {
      final match =
          RegExp(r'^\[(系统提示|角色设定|性格|场景|后续指令)\]\s*$').firstMatch(line.trim());
      if (match != null) {
        flush();
        current = match.group(1);
        continue;
      }
      if (current == null) continue;
      buffer.writeln(line);
    }
    flush();
    return sections;
  }

  static List<String> _exportTags(AssistantModel assistant) {
    final tags = <String>[];
    if (assistant.defaultVoiceStyle.trim().isNotEmpty) tags.add('有默认音色');
    if (assistant.memoryBook.trim().isNotEmpty) tags.add('世界书');
    if ((assistant.toolIds ?? const <String>[]).isNotEmpty) tags.add('工具');
    return tags;
  }

  static Map<String, dynamic> _tavernWorldBookPayload(
    String raw, {
    String structuredJson = '',
  }) {
    final entries = <Map<String, dynamic>>[];
    for (final entry in parseMemoryEntries(
      raw,
      structuredJson: structuredJson,
    )) {
      final item = <String, dynamic>{
        'content': entry.content,
        'enabled': entry.enabled,
      };
      if (entry.alwaysOn) {
        item['constant'] = true;
      } else {
        item['keys'] = entry.keywords;
      }
      if (entry.secondaryKeywords.isNotEmpty) {
        item['selective'] = true;
        item['secondary_keys'] = entry.secondaryKeywords;
        if (entry.selectiveLogic != 0) {
          item['selectiveLogic'] = entry.selectiveLogic;
        }
      }
      if (entry.excludeKeywords.isNotEmpty) {
        item['exclude_keys'] = entry.excludeKeywords;
      }
      if (entry.priority != 0) item['priority'] = entry.priority;
      if (entry.regex) item['regex'] = true;
      if (entry.caseSensitive) item['case_sensitive'] = true;
      if (entry.wholeWords) item['match_whole_words'] = true;
      if (entry.position.trim().isNotEmpty) item['position'] = entry.position;
      if (entry.depth != null) item['depth'] = entry.depth;
      if (entry.probability != null || !entry.probabilityEnabled) {
        item['probability'] = entry.probability ?? 100;
        item['useProbability'] = entry.probabilityEnabled;
      }
      if (entry.excludeFromRecursion) item['excludeRecursion'] = true;
      if (entry.group.trim().isNotEmpty) item['group'] = entry.group.trim();
      if (entry.groupWeight != 0) item['groupWeight'] = entry.groupWeight;
      if (entry.groupOverride) item['groupOverride'] = true;
      if (entry.useGroupScoring) item['useGroupScoring'] = true;
      if (entry.sticky > 0) item['sticky'] = entry.sticky;
      if (entry.cooldown > 0) item['cooldown'] = entry.cooldown;
      if (entry.delay > 0) item['delay'] = entry.delay;
      if (entry.characterFilterNames.isNotEmpty ||
          entry.characterFilterExclude) {
        item['characterFilter'] = {
          'names': entry.characterFilterNames,
          'tags': const <String>[],
          'isExclude': entry.characterFilterExclude,
        };
      }
      if (entry.matchPersonaDescription) {
        item['matchPersonaDescription'] = true;
      }
      if (entry.matchCharacterDescription) {
        item['matchCharacterDescription'] = true;
      }
      if (entry.matchCharacterPersonality) {
        item['matchCharacterPersonality'] = true;
      }
      if (entry.matchCharacterDepthPrompt) {
        item['matchCharacterDepthPrompt'] = true;
      }
      if (entry.matchScenario) item['matchScenario'] = true;
      if (entry.matchCreatorNotes) item['matchCreatorNotes'] = true;
      entries.add(item);
    }
    return {'entries': entries};
  }

  static bool _isEmptyTavernValue(Object? value) {
    if (value == null) return true;
    if (value is String) return value.trim().isEmpty;
    if (value is List) return value.isEmpty;
    if (value is Map) {
      final entries = value['entries'];
      return entries is List && entries.isEmpty;
    }
    return false;
  }

  static List<String> _splitMemoryKeywords(String raw, {required bool regex}) {
    final normalized = raw.trim();
    if (normalized.isEmpty) return const [];
    final splitter = regex ? RegExp(r'\s*\|\|\s*') : RegExp(r'[,，、|/ ]+');
    return normalized
        .split(splitter)
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  static bool _keywordsHit(
    List<String> keywords,
    String userText,
    String lowerUserText, {
    required bool regex,
    required bool caseSensitive,
    required bool wholeWords,
  }) {
    for (final keyword in keywords) {
      if (regex) {
        if (_regexHit(
          keyword,
          userText,
          caseSensitive: caseSensitive,
          wholeWords: wholeWords,
        )) {
          return true;
        }
      } else if (_plainKeywordHit(
        keyword,
        userText,
        lowerUserText,
        caseSensitive: caseSensitive,
        wholeWords: wholeWords,
      )) {
        return true;
      }
    }
    return false;
  }

  static bool _regexHit(
    String pattern,
    String userText, {
    bool caseSensitive = false,
    bool wholeWords = false,
  }) {
    try {
      final source = wholeWords ? _wholeWordPattern(pattern) : pattern;
      return RegExp(source, caseSensitive: caseSensitive).hasMatch(userText);
    } catch (_) {
      return false;
    }
  }

  static bool _plainKeywordHit(
    String keyword,
    String userText,
    String lowerUserText, {
    required bool caseSensitive,
    required bool wholeWords,
  }) {
    if (!wholeWords) {
      return caseSensitive
          ? userText.contains(keyword)
          : lowerUserText.contains(keyword.toLowerCase());
    }
    final source = _wholeWordPattern(RegExp.escape(keyword));
    return RegExp(source, caseSensitive: caseSensitive).hasMatch(userText);
  }

  static String _wholeWordPattern(String source) =>
      '(^|[^A-Za-z0-9_])(?:$source)([^A-Za-z0-9_]|\$)';

  // ignore: unused_element
  static bool _secondaryHit(
    AssistantMemoryEntryPreview entry,
    String userText,
    String lowerUserText,
  ) {
    if (entry.secondaryKeywords.isEmpty) return true;
    return _keywordsHit(
      entry.secondaryKeywords,
      userText,
      lowerUserText,
      regex: entry.regex,
      caseSensitive: entry.caseSensitive,
      wholeWords: entry.wholeWords,
    );
  }

  // ignore: unused_element
  static bool _excludeHit(
    AssistantMemoryEntryPreview entry,
    String userText,
    String lowerUserText,
  ) {
    if (entry.excludeKeywords.isEmpty) return false;
    return _keywordsHit(
      entry.excludeKeywords,
      userText,
      lowerUserText,
      regex: entry.regex,
      caseSensitive: entry.caseSensitive,
      wholeWords: entry.wholeWords,
    );
  }

  // ignore: unused_element
  static bool _probabilityHit(
    AssistantMemoryEntryPreview entry,
    String scanText,
  ) {
    final probability = entry.probability;
    if (probability == null || probability >= 100) return true;
    if (probability <= 0) return false;
    final seed = [
      entry.keywords.join('|'),
      entry.secondaryKeywords.join('|'),
      entry.content,
      scanText,
    ].join('\n');
    return _stablePercent(seed) < probability;
  }

  static int _stablePercent(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash % 100;
  }

  // ignore: unused_element
  static _MemoryPreviewMeta _parseMemoryMeta(String line) {
    var rest = line.trim();
    var enabled = true;
    var priority = 0;
    var regex = false;
    var secondaryKeywords = const <String>[];
    var excludeKeywords = const <String>[];
    var caseSensitive = false;
    var wholeWords = false;
    String position = '';
    int? depth;
    int? probability;
    var excludeFromRecursion = false;
    var group = '';
    var groupWeight = 0;
    var changed = true;
    while (changed && rest.startsWith('[')) {
      changed = false;
      final end = rest.indexOf(']');
      if (end <= 0) break;
      final rawTag = rest.substring(1, end).trim();
      final tag = rawTag.toLowerCase();
      if (tag == 'off' || tag == 'disabled') {
        enabled = false;
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag == 'on' || tag == 'enabled') {
        enabled = true;
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag.startsWith('p=')) {
        priority = int.tryParse(tag.substring(2).trim()) ?? priority;
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag == 're' || tag == 'regex') {
        regex = true;
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag == 'cs' || tag == 'case') {
        caseSensitive = true;
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag == 'ww' || tag == 'whole') {
        wholeWords = true;
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag.startsWith('sec=') || tag.startsWith('secondary=')) {
        final rawValue = rawTag.substring(rawTag.indexOf('=') + 1);
        secondaryKeywords = _splitMemoryKeywords(rawValue, regex: regex);
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag.startsWith('exclude=') ||
          tag.startsWith('excludes=') ||
          tag.startsWith('exclude_keys=') ||
          tag.startsWith('excludekeys=')) {
        final rawValue = rawTag.substring(rawTag.indexOf('=') + 1);
        excludeKeywords = _splitMemoryKeywords(rawValue, regex: regex);
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag.startsWith('pos=') || tag.startsWith('position=')) {
        position = rawTag.substring(rawTag.indexOf('=') + 1).trim();
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag.startsWith('depth=')) {
        depth = int.tryParse(tag.substring(6).trim()) ?? depth;
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag.startsWith('prob=') || tag.startsWith('probability=')) {
        probability =
            int.tryParse(rawTag.substring(rawTag.indexOf('=') + 1).trim()) ??
                probability;
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag == 'norec' ||
          tag == 'nonrec' ||
          tag == 'no_recursion' ||
          tag == 'exclude_recursion' ||
          tag == 'prevent_recursion') {
        excludeFromRecursion = true;
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag.startsWith('group=')) {
        group = rawTag.substring(rawTag.indexOf('=') + 1).trim();
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      } else if (tag.startsWith('gw=') || tag.startsWith('groupweight=')) {
        groupWeight =
            int.tryParse(rawTag.substring(rawTag.indexOf('=') + 1).trim()) ??
                groupWeight;
        rest = rest.substring(end + 1).trimLeft();
        changed = true;
      }
    }
    return _MemoryPreviewMeta(
      body: rest,
      enabled: enabled,
      priority: priority,
      regex: regex,
      secondaryKeywords: secondaryKeywords,
      excludeKeywords: excludeKeywords,
      caseSensitive: caseSensitive,
      wholeWords: wholeWords,
      position: position,
      depth: depth,
      probability: probability,
      excludeFromRecursion: excludeFromRecursion,
      group: group,
      groupWeight: groupWeight,
    );
  }

  static Map<String, dynamic> _assistantPayload(AssistantModel assistant) => {
        'name': assistant.name,
        'emoji': assistant.emoji,
        'description': assistant.description,
        'prompt': assistant.prompt,
        'openingMessage': assistant.openingMessage,
        'exampleDialogs': assistant.exampleDialogs,
        'memoryBook': assistant.memoryBook,
        'worldBookJson': assistant.worldBookJson,
        'roleCardAssets': assistant.roleCardAssets,
        'defaultVoiceStyle': assistant.defaultVoiceStyle,
        'providerId': assistant.providerId,
        'model': assistant.model,
        'useTools': assistant.useTools,
        'toolIds': assistant.toolIds ?? const <String>[],
      };

  static bool _isPng(List<int> bytes) {
    const signature = [137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.length < signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) return false;
    }
    return true;
  }

  static Uint8List _defaultTavernCardPngBytes() {
    return base64.decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=',
    );
  }

  static Uint8List _writePngTextChunk(
    List<int> bytes, {
    required String keyword,
    required String text,
  }) {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    if (!_isPng(data)) {
      return _writePngTextChunk(
        _defaultTavernCardPngBytes(),
        keyword: keyword,
        text: text,
      );
    }
    final textChunk = _pngTextChunk(keyword: keyword, text: text);
    final output = BytesBuilder(copy: false)..add(data.sublist(0, 8));
    var offset = 8;
    while (offset + 12 <= data.length) {
      final chunkStart = offset;
      final length = _uint32(data, offset);
      final typeOffset = offset + 4;
      final dataOffset = typeOffset + 4;
      final crcEnd = dataOffset + length + 4;
      if (length < 0 || crcEnd > data.length) break;
      final type = ascii.decode(data.sublist(typeOffset, dataOffset));
      final chunk = data.sublist(dataOffset, dataOffset + length);
      if (type == 'IEND') {
        output
          ..add(textChunk)
          ..add(data.sublist(chunkStart, crcEnd));
        return output.toBytes();
      }
      if (!_isRoleCardPngTextChunk(type, chunk)) {
        output.add(data.sublist(chunkStart, crcEnd));
      }
      offset = crcEnd;
    }
    return _writePngTextChunk(
      _defaultTavernCardPngBytes(),
      keyword: keyword,
      text: text,
    );
  }

  static Uint8List _pngTextChunk({
    required String keyword,
    required String text,
  }) {
    final type = ascii.encode('tEXt');
    final chunkData = <int>[
      ...latin1.encode(keyword),
      0,
      ...latin1.encode(text),
    ];
    final crc = _crc32([...type, ...chunkData]);
    return Uint8List.fromList([
      ..._uint32Bytes(chunkData.length),
      ...type,
      ...chunkData,
      ..._uint32Bytes(crc),
    ]);
  }

  static List<int> _uint32Bytes(int value) {
    final bytes = ByteData(4)..setUint32(0, value);
    return bytes.buffer.asUint8List();
  }

  static int _crc32(List<int> bytes) {
    var crc = 0xffffffff;
    for (final byte in bytes) {
      crc ^= byte;
      for (var i = 0; i < 8; i++) {
        crc = (crc & 1) == 1 ? 0xedb88320 ^ (crc >> 1) : crc >> 1;
      }
    }
    return (crc ^ 0xffffffff) & 0xffffffff;
  }

  static bool _isRoleCardPngTextChunk(String type, Uint8List chunk) {
    if (type != 'tEXt' && type != 'zTXt' && type != 'iTXt') return false;
    final nul = chunk.indexOf(0);
    if (nul <= 0) return false;
    final keyword = latin1.decode(chunk.sublist(0, nul)).trim().toLowerCase();
    return _isRoleCardTextKey(keyword);
  }

  static bool _isZip(List<int> bytes, {String? filename}) {
    if (filename != null && filename.toLowerCase().endsWith('.zip')) {
      return true;
    }
    return bytes.length >= 4 &&
        bytes[0] == 0x50 &&
        bytes[1] == 0x4b &&
        (bytes[2] == 0x03 || bytes[2] == 0x05 || bytes[2] == 0x07) &&
        (bytes[3] == 0x04 || bytes[3] == 0x06 || bytes[3] == 0x08);
  }

  static String _extractPngRoleCardJson(List<int> bytes) {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    var offset = 8;
    final candidates = <String>[];
    while (offset + 12 <= data.length) {
      final length = _uint32(data, offset);
      offset += 4;
      if (length < 0 || offset + 4 + length + 4 > data.length) break;
      final type = ascii.decode(data.sublist(offset, offset + 4));
      offset += 4;
      final chunk = data.sublist(offset, offset + length);
      offset += length + 4; // skip data + crc
      if (type == 'tEXt') {
        final text = _parseTextChunk(chunk);
        if (text != null) candidates.add(text);
      } else if (type == 'iTXt') {
        final text = _parseInternationalTextChunk(chunk);
        if (text != null) candidates.add(text);
      } else if (type == 'zTXt') {
        final text = _parseCompressedTextChunk(chunk);
        if (text != null) candidates.add(text);
      } else if (type == 'IEND') {
        break;
      }
    }
    for (final candidate in candidates) {
      final json = _decodeRoleCardText(candidate);
      if (json != null) return json;
    }
    throw const FormatException('PNG 中没有找到可识别的角色卡元数据');
  }

  static int _uint32(Uint8List data, int offset) =>
      ByteData.sublistView(data, offset, offset + 4).getUint32(0);

  static String? _parseTextChunk(Uint8List chunk) {
    final nul = chunk.indexOf(0);
    if (nul <= 0 || nul >= chunk.length - 1) return null;
    final keyword = latin1.decode(chunk.sublist(0, nul)).trim().toLowerCase();
    if (!_isRoleCardTextKey(keyword)) return null;
    return latin1.decode(chunk.sublist(nul + 1)).trim();
  }

  static String? _parseCompressedTextChunk(Uint8List chunk) {
    final nul = chunk.indexOf(0);
    if (nul <= 0 || nul >= chunk.length - 2) return null;
    final keyword = latin1.decode(chunk.sublist(0, nul)).trim().toLowerCase();
    if (!_isRoleCardTextKey(keyword)) return null;
    final method = chunk[nul + 1];
    if (method != 0) return null;
    try {
      return utf8.decode(
        ZLibDecoder().convert(chunk.sublist(nul + 2)),
      );
    } catch (_) {
      return null;
    }
  }

  static String? _parseInternationalTextChunk(Uint8List chunk) {
    var offset = 0;
    final keywordEnd = _indexOfZero(chunk, offset);
    if (keywordEnd <= 0 || keywordEnd + 2 >= chunk.length) return null;
    final keyword =
        latin1.decode(chunk.sublist(offset, keywordEnd)).trim().toLowerCase();
    if (!_isRoleCardTextKey(keyword)) return null;
    offset = keywordEnd + 1;
    final compressionFlag = chunk[offset++];
    final compressionMethod = chunk[offset++];
    final languageEnd = _indexOfZero(chunk, offset);
    if (languageEnd < 0) return null;
    offset = languageEnd + 1;
    final translatedEnd = _indexOfZero(chunk, offset);
    if (translatedEnd < 0) return null;
    offset = translatedEnd + 1;
    final textBytes = chunk.sublist(offset);
    try {
      if (compressionFlag == 1 && compressionMethod == 0) {
        return utf8.decode(ZLibDecoder().convert(textBytes));
      }
      if (compressionFlag == 0) return utf8.decode(textBytes);
    } catch (_) {
      return null;
    }
    return null;
  }

  static int _indexOfZero(Uint8List data, int start) {
    for (var i = start; i < data.length; i++) {
      if (data[i] == 0) return i;
    }
    return -1;
  }

  static bool _isRoleCardTextKey(String keyword) {
    return keyword == 'chara' ||
        keyword == 'chara_card' ||
        keyword == 'character' ||
        keyword == 'ccv3';
  }

  static String? _decodeRoleCardText(String raw) {
    final text = raw.trim();
    if (text.startsWith('{')) return text;
    try {
      return utf8.decode(base64.decode(text));
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic> _extractAssistantPayload(
      Map<String, dynamic> decoded) {
    final wrapped = decoded['assistant'];
    if (wrapped is Map<String, dynamic>) {
      final f = decoded['format'];
      if (f != null && f != format) {
        throw FormatException('不支持的角色卡格式：$f');
      }
      final v = decoded['version'];
      if (v is int && v > version) {
        throw FormatException('角色卡版本过新：$v');
      }
      return wrapped;
    }
    final data = decoded['data'];
    if (_looksLikeTavernData(data)) {
      final tavernData = data as Map<String, dynamic>;
      return _fromTavernData(
        tavernData,
        rawCard: _tavernRawCard(decoded, tavernData),
      );
    }
    if (_looksLikeTavernData(decoded)) {
      return _fromTavernData(
        decoded,
        rawCard: _tavernRawCard(decoded, decoded),
      );
    }
    // 兼容直接导出的 AssistantModel JSON。
    return decoded;
  }

  static bool _looksLikeTavernData(Object? value) {
    if (value is! Map<String, dynamic>) return false;
    return value['name'] is String &&
        (value.containsKey('first_mes') ||
            value.containsKey('mes_example') ||
            value.containsKey('personality') ||
            value.containsKey('scenario') ||
            value.containsKey('character_book') ||
            value.containsKey('characterBook'));
  }

  static Map<String, dynamic> _fromTavernData(
    Map<String, dynamic> data, {
    required Map<String, dynamic> rawCard,
  }) {
    final name = _string(data['name']);
    final promptName = _tavernPromptName(data);
    final extension = _chataiDeepTavernExtension(data);
    final promptParts = <String>[
      _sectionText(
        '系统提示',
        _tavernLocalizedText(data['system_prompt'], promptName),
      ),
      _sectionText(
        '角色设定',
        _tavernLocalizedText(data['description'], promptName),
      ),
      _sectionText('性格', _tavernLocalizedText(data['personality'], promptName)),
      _sectionText('场景', _tavernLocalizedText(data['scenario'], promptName)),
      _sectionText('后续指令',
          _tavernLocalizedText(data['post_history_instructions'], promptName)),
    ].where((part) => part.isNotEmpty).toList();
    final description = _tavernDescription(
      data,
      promptName,
      preferCreatorNotes: extension.isNotEmpty,
    );
    final exampleDialogs = _tavernExampleDialogs(data, promptName);
    final characterBook = _tavernCharacterBook(data);
    final payload = <String, dynamic>{
      'name': name,
      'emoji': '🤖',
      'description':
          description.isNotEmpty ? description : _compactDescription(data),
      'prompt': promptParts.join('\n\n'),
      'openingMessage': _tavernLocalizedText(data['first_mes'], promptName),
      'exampleDialogs': exampleDialogs,
      'memoryBook': _tavernWorldBook(characterBook, promptName),
      'worldBookJson': _canonicalWorldBookJson(characterBook, promptName),
      'defaultVoiceStyle': _string(extension['defaultVoiceStyle']),
      'providerId': _string(extension['providerId']),
      'model': _string(extension['model']),
      'useTools':
          extension['useTools'] is bool ? extension['useTools'] as bool : true,
      'toolIds': _toolIds(extension),
    };
    if (_shouldPreserveTavernRawCard(rawCard, data)) {
      payload['memoryBook'] = _withTavernRawCardMarker(
        _string(payload['memoryBook']),
        rawCard,
        _assistantSnapshot(payload),
      );
    }
    return payload;
  }

  static Map<String, dynamic> _chataiDeepTavernExtension(
    Map<String, dynamic> data,
  ) {
    final extensions = data['extensions'];
    if (extensions is! Map) return const {};
    final value = extensions['chatai_deep'];
    if (value is! Map) return const {};
    return {
      for (final entry in value.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
  }

  static Map<String, dynamic> _tavernRawCard(
    Map<String, dynamic> decoded,
    Map<String, dynamic> data,
  ) =>
      {
        'spec': _string(decoded['spec']).isEmpty
            ? 'chara_card_v2'
            : _string(decoded['spec']),
        'spec_version': _string(decoded['spec_version']).isEmpty
            ? '2.0'
            : _string(decoded['spec_version']),
        'data': _copyJsonMap(data),
      };

  static Map<String, dynamic>? _tavernRawCardFromMemoryBook(String raw) {
    for (final line in raw.replaceAll('\r\n', '\n').split('\n')) {
      if (!line.startsWith(_tavernRawMarker)) continue;
      final encoded = line.substring(_tavernRawMarker.length).trim();
      if (encoded.isEmpty) continue;
      try {
        final decoded = jsonDecode(utf8.decode(base64Url.decode(encoded)));
        if (decoded is Map) return _mapStringDynamic(decoded);
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  static String _withoutTavernRawCardMarker(String raw) => raw
      .replaceAll('\r\n', '\n')
      .split('\n')
      .where((line) => !line.startsWith(_tavernRawMarker))
      .join('\n')
      .trim();

  static String _withTavernRawCardMarker(
    String memoryBook,
    Map<String, dynamic> rawCard,
    Map<String, dynamic> snapshot,
  ) {
    final payload = <String, dynamic>{
      'card': rawCard,
      'snapshot': snapshot,
    };
    final marker =
        '$_tavernRawMarker${base64Url.encode(utf8.encode(jsonEncode(payload)))}';
    final book = _withoutTavernRawCardMarker(memoryBook);
    return book.isEmpty ? marker : '$marker\n$book';
  }

  static Map<String, dynamic> _assistantSnapshot(
          Map<String, dynamic> payload) =>
      {
        'name': _string(payload['name']),
        'description': _string(payload['description']),
        'prompt': _string(payload['prompt']),
        'openingMessage': _string(payload['openingMessage']),
        'exampleDialogs': _string(payload['exampleDialogs']),
        'memoryBook': _withoutTavernRawCardMarker(
          _string(payload['memoryBook']),
        ),
      };

  static Map<String, dynamic>? _tavernRawCardPayload(String memoryBook) {
    final marker = _tavernRawCardFromMemoryBook(memoryBook);
    if (marker == null) return null;
    final card = marker['card'];
    if (card is Map) return _mapStringDynamic(card);
    // 兼容早期只保存卡对象、未包一层 snapshot 的内部标记。
    return marker.containsKey('data') ? marker : null;
  }

  static Map<String, dynamic>? _tavernRawSnapshot(String memoryBook) {
    final marker = _tavernRawCardFromMemoryBook(memoryBook);
    if (marker == null) return null;
    final snapshot = marker['snapshot'];
    return snapshot is Map ? _mapStringDynamic(snapshot) : null;
  }

  static Map<String, dynamic> _tavernDataFromAssistant(
    AssistantModel assistant, {
    DateTime? exportedAt,
  }) {
    final sections = _promptSections(assistant.prompt);
    final description = sections['角色设定'] ?? assistant.prompt.trim();
    return <String, dynamic>{
      'name': assistant.name,
      'description': description,
      'personality': sections['性格'] ?? '',
      'scenario': sections['场景'] ?? '',
      'first_mes': assistant.openingMessage.trim(),
      'mes_example': exampleDialogPromptText(assistant.exampleDialogs),
      'creator_notes': assistant.description.trim(),
      'system_prompt': sections['系统提示'] ?? '',
      'post_history_instructions': sections['后续指令'] ?? '',
      'alternate_greetings': alternateGreetings(assistant.exampleDialogs),
      'character_book': _tavernWorldBookPayload(
        assistant.memoryBook,
        structuredJson: assistant.worldBookJson,
      ),
      'tags': _exportTags(assistant),
      'extensions': {
        'chatai_deep': _chataiDeepExportExtension(
          assistant,
          exportedAt: exportedAt,
        ),
      },
    };
  }

  static Map<String, dynamic> _tavernDataFromRawCard(
    AssistantModel assistant,
    Map<String, dynamic> rawCard, {
    DateTime? exportedAt,
  }) {
    final rawData = rawCard['data'];
    if (rawData is! Map) {
      return _tavernDataFromAssistant(assistant, exportedAt: exportedAt);
    }
    final data =
        _copyJsonMap(_mapStringDynamic(rawData) ?? <String, dynamic>{});
    final snapshot = _tavernRawSnapshot(assistant.memoryBook);
    final sections = _promptSections(assistant.prompt);
    final description = sections['角色设定'] ?? assistant.prompt.trim();

    if (!_snapshotMatches(snapshot, 'name', assistant.name)) {
      data['name'] = assistant.name;
    }
    if (!_snapshotMatches(snapshot, 'description', assistant.description)) {
      _writeTavernText(data, 'creator_notes', assistant.description.trim());
    }
    if (!_snapshotMatches(snapshot, 'prompt', assistant.prompt)) {
      _writeTavernText(data, 'description', description);
      _writeTavernText(data, 'personality', sections['性格'] ?? '');
      _writeTavernText(data, 'scenario', sections['场景'] ?? '');
      _writeTavernText(data, 'system_prompt', sections['系统提示'] ?? '');
      _writeTavernText(
        data,
        'post_history_instructions',
        sections['后续指令'] ?? '',
      );
    }
    if (!_snapshotMatches(
      snapshot,
      'openingMessage',
      assistant.openingMessage,
    )) {
      _writeTavernText(data, 'first_mes', assistant.openingMessage.trim());
    }
    if (!_snapshotMatches(
      snapshot,
      'exampleDialogs',
      assistant.exampleDialogs,
    )) {
      _writeTavernText(
        data,
        'mes_example',
        exampleDialogPromptText(assistant.exampleDialogs),
      );
      data['alternate_greetings'] =
          alternateGreetings(assistant.exampleDialogs);
    }
    if (!_snapshotMatches(
      snapshot,
      'memoryBook',
      _withoutTavernRawCardMarker(assistant.memoryBook),
    )) {
      data['character_book'] = _tavernWorldBookPayload(
        assistant.memoryBook,
        structuredJson: assistant.worldBookJson,
      );
    }

    final extensions =
        _mapStringDynamic(data['extensions']) ?? <String, dynamic>{};
    final hasChataiDeep = extensions['chatai_deep'] is Map;
    if (hasChataiDeep || _hasAssistantExportSettings(assistant)) {
      final appExtension =
          _mapStringDynamic(extensions['chatai_deep']) ?? <String, dynamic>{};
      appExtension.addAll(_chataiDeepExportExtension(
        assistant,
        exportedAt: exportedAt,
      ));
      extensions['chatai_deep'] = appExtension;
      data['extensions'] = extensions;
    }
    return data;
  }

  static Map<String, dynamic> _chataiDeepExportExtension(
    AssistantModel assistant, {
    DateTime? exportedAt,
  }) =>
      {
        'format': format,
        'version': version,
        'exportedAt': (exportedAt ?? DateTime.now()).toIso8601String(),
        'defaultVoiceStyle': assistant.defaultVoiceStyle,
        'providerId': assistant.providerId,
        'model': assistant.model,
        'useTools': assistant.useTools,
        'toolIds': assistant.toolIds ?? const <String>[],
      };

  static bool _hasAssistantExportSettings(AssistantModel assistant) =>
      assistant.defaultVoiceStyle.trim().isNotEmpty ||
      assistant.providerId.trim().isNotEmpty ||
      assistant.model.trim().isNotEmpty ||
      !assistant.useTools ||
      (assistant.toolIds ?? const <String>[]).isNotEmpty;

  static bool _snapshotMatches(
    Map<String, dynamic>? snapshot,
    String key,
    String value,
  ) =>
      snapshot != null && snapshot[key] == value;

  static void _writeTavernText(
    Map<String, dynamic> data,
    String key,
    String value,
  ) {
    final current = data[key];
    if (current is! Map) {
      data[key] = value;
      return;
    }
    final localized = _mapStringDynamic(current);
    if (localized == null) {
      data[key] = value;
      return;
    }
    final locale = _tavernPreferredLocaleKeys.firstWhere(
      (key) => localized.containsKey(key),
      orElse: () => localized.keys.firstWhere(
        (item) => localized[item] is String,
        orElse: () => 'zh-CN',
      ),
    );
    localized[locale] = value;
    data[key] = localized;
  }

  static Map<String, dynamic> _copyJsonMap(Map<String, dynamic> source) {
    final copied = jsonDecode(jsonEncode(source));
    return copied is Map
        ? _mapStringDynamic(copied) ?? <String, dynamic>{}
        : {};
  }

  static Map<String, dynamic>? _mapStringDynamic(Object? value) {
    if (value is! Map) return null;
    return {
      for (final entry in value.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
  }

  static String _tavernPromptName(Map<String, dynamic> data) {
    final nickname = _string(data['nickname']);
    return nickname.isEmpty ? _string(data['name']) : nickname;
  }

  static Object? _tavernCharacterBook(Map<String, dynamic> data) =>
      data['character_book'] ?? data['characterBook'];

  static bool _shouldPreserveTavernRawCard(
    Map<String, dynamic> rawCard,
    Map<String, dynamic> data,
  ) {
    if (_string(rawCard['spec']).toLowerCase() == 'chara_card_v3') return true;
    if (_hasTavernLocalizedVariants(data)) return true;
    if (const {
      'nickname',
      'group_only_greetings',
      'source',
      'assets',
      'creation_date',
      'modification_date',
    }.any(data.containsKey)) {
      return true;
    }
    final extensions = _mapStringDynamic(data['extensions']);
    if (extensions != null &&
        extensions.keys.any((key) => key != 'chatai_deep')) {
      return true;
    }
    return _tavernCharacterBookNeedsRawPreservation(
      _mapStringDynamic(_tavernCharacterBook(data)),
    );
  }

  static bool _hasTavernLocalizedVariants(Map<String, dynamic> data) {
    for (final key in const [
      'description',
      'personality',
      'scenario',
      'first_mes',
      'mes_example',
      'creator_notes',
      'creator_notes_multilingual',
      'system_prompt',
      'post_history_instructions',
      'alternate_greetings',
    ]) {
      if (data[key] is Map) return true;
    }
    return false;
  }

  static bool _tavernCharacterBookNeedsRawPreservation(
    Map<String, dynamic>? book,
  ) {
    if (book == null) return false;
    if (book.keys.any((key) => key != 'entries')) return true;
    for (final entry in _tavernWorldBookEntries(book['entries'])) {
      if (entry.containsKey('comment') ||
          entry.containsKey('name') ||
          entry.containsKey('id') ||
          entry.containsKey('insertion_order') ||
          entry.containsKey('insertionOrder')) {
        return true;
      }
      final extensions = _mapStringDynamic(entry['extensions']);
      if (extensions != null &&
          extensions.keys
              .any((key) => !_supportedWorldBookExtensionKeys.contains(key))) {
        return true;
      }
    }
    return false;
  }

  static const _supportedWorldBookExtensionKeys = {
    'position',
    'depth',
    'probability',
    'useProbability',
    'use_probability',
    'excludeRecursion',
    'exclude_recursion',
    'preventRecursion',
    'prevent_recursion',
    'disabled',
    'disable',
    'group',
    'group_name',
    'groupName',
    'group_weight',
    'groupWeight',
    'group_override',
    'groupOverride',
    'use_group_scoring',
    'useGroupScoring',
    'selectiveLogic',
    'selective_logic',
    'sticky',
    'cooldown',
    'delay',
    'characterFilter',
    'character_filter',
    'characterFilterNames',
    'characterFilterExclude',
    'character_filter_exclude',
    'matchPersonaDescription',
    'match_persona_description',
    'matchCharacterDescription',
    'match_character_description',
    'matchCharacterPersonality',
    'match_character_personality',
    'matchCharacterDepthPrompt',
    'match_character_depth_prompt',
    'matchScenario',
    'match_scenario',
    'matchCreatorNotes',
    'match_creator_notes',
    'case_sensitive',
    'caseSensitive',
    'match_whole_words',
    'matchWholeWords',
    'regex',
    'use_regex',
    'useRegex',
    'secondary_keys',
    'secondaryKeys',
    'secondary_key',
    'keysecondary',
    'keySecondary',
    'exclude_keys',
    'excludeKeys',
    'exclusion_keys',
    'exclusionKeys',
    'exclusions',
    'priority',
    'order',
  };

  static AssistantRoleCardTavernMeta? _tavernMetaFromDecoded(
    Map<String, dynamic> decoded,
  ) {
    final nested = decoded['data'];
    final tavernData = _looksLikeTavernData(nested)
        ? nested as Map<String, dynamic>
        : _looksLikeTavernData(decoded)
            ? decoded
            : null;
    if (tavernData == null) return null;
    final promptName = _tavernPromptName(tavernData);
    final book = _mapStringDynamic(_tavernCharacterBook(tavernData));
    final bookExtensions =
        book == null ? null : _mapStringDynamic(book['extensions']);
    final extensions = _mapStringDynamic(tavernData['extensions']);
    final depthPrompt = extensions == null
        ? null
        : _mapStringDynamic(extensions['depth_prompt']);
    final sources = _tavernSources(tavernData, promptName);

    Object? bookValue(List<String> keys) {
      if (book == null) return null;
      for (final key in keys) {
        if (book.containsKey(key)) return book[key];
        if (bookExtensions?.containsKey(key) == true) {
          return bookExtensions![key];
        }
      }
      return null;
    }

    return AssistantRoleCardTavernMeta(
      spec: _string(decoded['spec']).isNotEmpty
          ? _string(decoded['spec'])
          : _string(tavernData['spec']),
      specVersion: _string(decoded['spec_version']).isNotEmpty
          ? _string(decoded['spec_version'])
          : _string(tavernData['spec_version']),
      creator: _firstTavernText(tavernData, promptName, const [
        'creator',
        'created_by',
        'createdBy',
      ]),
      characterVersion: _firstTavernText(tavernData, promptName, const [
        'character_version',
        'characterVersion',
        'version',
      ]),
      createDate: _firstTavernText(tavernData, promptName, const [
        'create_date',
        'createDate',
        'created_at',
        'createdAt',
      ]),
      updateDate: _firstTavernText(tavernData, promptName, const [
        'update_date',
        'updateDate',
        'updated_at',
        'updatedAt',
      ]),
      source: sources.isEmpty ? '' : sources.first,
      sources: sources,
      nickname: _string(tavernData['nickname']),
      creationTimestamp: _intOrNull(tavernData['creation_date']),
      modificationTimestamp: _intOrNull(tavernData['modification_date']),
      creatorNotes: _firstTavernText(tavernData, promptName, const [
        'creator_notes',
        'creatorcomment',
        'creator_comment',
        'creatorNotes',
        'creator_notes_multilingual',
        'creator_notes_i18n',
        'creatorNotesMultilingual',
        'creatorCommentMultilingual',
      ]),
      systemPrompt:
          _tavernLocalizedText(tavernData['system_prompt'], promptName),
      postHistoryInstructions: _tavernLocalizedText(
        tavernData['post_history_instructions'],
        promptName,
      ),
      tags: _tavernTags(tavernData['tags']),
      alternateGreetings: _tavernAlternateGreetings(
        tavernData['alternate_greetings'],
        promptName,
      ),
      groupOnlyGreetings: _tavernAlternateGreetings(
        tavernData['group_only_greetings'],
        promptName,
      ),
      talkativeness:
          extensions == null ? null : _numOrNull(extensions['talkativeness']),
      extensionWorld: extensions == null
          ? ''
          : _tavernLocalizedText(extensions['world'], promptName),
      characterDepthPrompt: depthPrompt == null
          ? ''
          : _tavernLocalizedText(depthPrompt['prompt'], promptName),
      characterDepthPromptDepth:
          depthPrompt == null ? null : _intOrNull(depthPrompt['depth']),
      characterDepthPromptRole:
          depthPrompt == null ? '' : _string(depthPrompt['role']),
      characterBookName:
          book == null ? '' : _tavernLocalizedText(book['name'], promptName),
      characterBookScanDepth:
          _intOrNull(bookValue(const ['scan_depth', 'scanDepth'])),
      characterBookTokenBudget:
          _intOrNull(bookValue(const ['token_budget', 'tokenBudget'])),
      characterBookRecursiveScanning: _boolOrNull(
        bookValue(const ['recursive_scanning', 'recursiveScanning']),
      ),
      characterBookEntryCount:
          book == null ? 0 : _tavernWorldBookEntries(book['entries']).length,
    );
  }

  static List<String> _tavernSources(
    Map<String, dynamic> data,
    String promptName,
  ) {
    final values = <String>[];
    for (final key in const ['source', 'source_url', 'sourceUrl']) {
      final raw = data[key];
      if (raw is List) {
        values.addAll([
          for (final item in raw)
            if (_normalizeTavernText(item, promptName).isNotEmpty)
              _normalizeTavernText(item, promptName),
        ]);
      } else {
        final value = _normalizeTavernText(raw, promptName);
        if (value.isNotEmpty) values.add(value);
      }
    }
    final seen = <String>{};
    return [
      for (final value in values)
        if (seen.add(value)) value
    ];
  }

  static num? _numOrNull(Object? raw) {
    if (raw is num) return raw;
    if (raw is String) return num.tryParse(raw.trim());
    return null;
  }

  static String _sectionText(String title, Object? value) {
    final text = _string(value);
    return text.isEmpty ? '' : '[$title]\n$text';
  }

  static String _compactDescription(
    Map<String, dynamic> data, {
    String? promptName,
  }) {
    final text = _tavernLocalizedText(
      data['description'],
      promptName ?? _tavernPromptName(data),
    );
    if (text.length <= 80) return text;
    return '${text.substring(0, 80)}...';
  }

  static String _tavernDescription(
    Map<String, dynamic> data,
    String name, {
    bool preferCreatorNotes = false,
  }) {
    final notes = _firstTavernText(data, name, const [
      'creator_notes',
      'creatorcomment',
      'creator_comment',
      'creatorNotes',
      'creator_notes_multilingual',
      'creator_notes_i18n',
      'creatorNotesMultilingual',
      'creatorCommentMultilingual',
    ]);
    final roleSummary = _compactDescription(data, promptName: name);
    final tags = _tavernTags(data['tags']);
    final tagLine = tags.isEmpty ? '' : '标签：${tags.join('、')}';
    final parts = <String>[];
    if (preferCreatorNotes) {
      if (notes.isNotEmpty) parts.add(notes);
    } else {
      if (roleSummary.isNotEmpty) parts.add(roleSummary);
      if (notes.isNotEmpty &&
          _normalizeDescriptionForDedupe(notes) !=
              _normalizeDescriptionForDedupe(roleSummary)) {
        parts.add(notes);
      }
    }
    if (tagLine.isNotEmpty) parts.add(tagLine);
    return parts.join('\n');
  }

  static String _normalizeDescriptionForDedupe(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), '');

  static String _firstTavernText(
    Map<String, dynamic> data,
    String name,
    List<String> keys,
  ) {
    for (final key in keys) {
      final text = _tavernLocalizedText(data[key], name);
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  static String _tavernLocalizedText(Object? value, String name) {
    final direct = _normalizeTavernText(value, name);
    if (direct.isNotEmpty) return direct;
    final localized = _tavernPreferredLocalizedValue(value);
    if (localized == null || identical(localized, value)) return '';
    return _tavernLocalizedText(localized, name);
  }

  static Object? _tavernPreferredLocalizedValue(Object? value) {
    if (value is! Map) return value;
    for (final key in _tavernPreferredLocaleKeys) {
      final candidate = value[key];
      if (_hasTavernLocalizedContent(candidate)) return candidate;
    }
    for (final entry in value.entries) {
      if (_hasTavernLocalizedContent(entry.value)) return entry.value;
    }
    return null;
  }

  static bool _hasTavernLocalizedContent(Object? value) {
    if (value is String) return value.trim().isNotEmpty;
    if (value is List) {
      return value.any((item) => _hasTavernLocalizedContent(item));
    }
    if (value is Map) {
      return value.values.any((item) => _hasTavernLocalizedContent(item));
    }
    return false;
  }

  static List<String> _tavernTags(Object? raw) {
    if (raw is List) {
      return [
        for (final item in raw)
          if (item is String && item.trim().isNotEmpty) item.trim(),
      ];
    }
    if (raw is String && raw.trim().isNotEmpty) {
      return raw
          .split(RegExp(r'[,，、|/]+'))
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList();
    }
    return const [];
  }

  static int? _intOrNull(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }

  static bool? _boolOrNull(Object? raw) {
    if (raw is bool) return raw;
    if (raw is num) {
      if (raw == 1) return true;
      if (raw == 0) return false;
    }
    if (raw is String) {
      final value = raw.trim().toLowerCase();
      if (const {'true', '1', 'yes', 'y', 'on'}.contains(value)) return true;
      if (const {'false', '0', 'no', 'n', 'off'}.contains(value)) return false;
    }
    return null;
  }

  static String _tavernExampleDialogs(Map<String, dynamic> data, String name) {
    final parts = <String>[];
    final example = _tavernLocalizedText(data['mes_example'], name);
    if (example.isNotEmpty) parts.add(example);
    final alternateLines = _tavernAlternateGreetings(
      data['alternate_greetings'],
      name,
    );
    if (alternateLines.isNotEmpty) {
      parts.add('[备选开场白]\n${alternateLines.join('\n\n')}');
    }
    return parts.join('\n\n');
  }

  static List<String> _tavernAlternateGreetings(Object? raw, String name) {
    final lines = <String>[];
    if (raw is List) {
      for (final item in raw) {
        final text = _normalizeTavernText(item, name);
        if (text.isNotEmpty) lines.add(text);
      }
    } else if (raw is String) {
      for (final line in raw.replaceAll('\r\n', '\n').split('\n')) {
        final text = _normalizeTavernText(line, name);
        if (text.isNotEmpty) lines.add(text);
      }
    } else if (raw is Map) {
      final localized = _tavernPreferredLocalizedValue(raw);
      if (localized != null && !identical(localized, raw)) {
        lines.addAll(_tavernAlternateGreetings(localized, name));
      }
    }
    final seen = <String>{};
    return [
      for (final line in lines)
        if (seen.add(line.replaceAll(RegExp(r'\s+'), ''))) line,
    ];
  }

  static String _tavernWorldBook(Object? raw, String name) {
    final book = _mapStringDynamic(raw);
    if (book == null) return '';
    final lines = <String>[];
    for (final item in _tavernWorldBookEntries(book['entries'])) {
      final content = _normalizeTavernText(item['content'], name);
      if (content.isEmpty) continue;
      final comment = _tavernEntryComment(item, name);
      if (comment.isNotEmpty) lines.add('# $comment');
      final selective = _tavernEntryUsesSelective(item);
      final secondaryKeys = selective
          ? _tavernSecondaryKeys(item, name, regex: _tavernEntryUsesRegex(item))
          : const <String>[];
      final prefix = _tavernWorldBookPrefix(item, secondaryKeys: secondaryKeys);
      final constant = _tavernEntryConstant(item);
      final keys = _tavernKeys(item, name, includeSecondary: !selective);
      if (constant || keys.isEmpty) {
        lines.add('$prefix$content');
      } else {
        final separator = _tavernEntryUsesRegex(item) ? ' || ' : ',';
        lines.add('$prefix${keys.join(separator)} => $content');
      }
    }
    return lines.join('\n');
  }

  static String _canonicalWorldBookJson(Object? raw, String name) {
    final legacy = _tavernWorldBook(raw, name);
    if (legacy.trim().isEmpty) return '';
    return WorldBookCodec.encode(
      WorldBookCodec.decode(legacyText: legacy),
    );
  }

  static String _tavernEntryComment(Map<String, dynamic> item, String name) {
    for (final key in const [
      'comment',
      'comments',
      'note',
      'notes',
      'name',
      'title',
      'displayName',
      'display_name',
    ]) {
      final text = _normalizeTavernText(item[key], name);
      if (text.isNotEmpty) return text;
    }
    final extensions = item['extensions'];
    if (extensions is Map) {
      for (final key in const [
        'comment',
        'comments',
        'note',
        'notes',
        'name',
        'title',
        'displayName',
        'display_name',
      ]) {
        final text = _normalizeTavernText(extensions[key], name);
        if (text.isNotEmpty) return text;
      }
    }
    return '';
  }

  static Iterable<Map<String, dynamic>> _tavernWorldBookEntries(Object? raw) {
    if (raw is List) {
      return [
        for (final item in raw)
          if (item is Map<String, dynamic>) item,
      ];
    }
    if (raw is Map) {
      final sortedKeys = raw.keys.toList()
        ..sort((a, b) => _compareTavernEntryKeys(a, b));
      return [
        for (final key in sortedKeys)
          if (raw[key] is Map<String, dynamic>)
            raw[key] as Map<String, dynamic>,
      ];
    }
    return const [];
  }

  static int _compareTavernEntryKeys(Object? a, Object? b) {
    final aText = a.toString();
    final bText = b.toString();
    final aNum = num.tryParse(aText);
    final bNum = num.tryParse(bText);
    if (aNum != null && bNum != null) return aNum.compareTo(bNum);
    return aText.compareTo(bText);
  }

  static String _tavernWorldBookPrefix(
    Map<String, dynamic> item, {
    List<String> secondaryKeys = const [],
  }) {
    final parts = <String>[];
    if (_tavernEntryDisabled(item)) parts.add('[off]');
    if (_tavernEntryUsesRegex(item)) parts.add('[re]');
    if (_tavernEntryCaseSensitive(item)) parts.add('[cs]');
    if (_tavernEntryWholeWords(item)) parts.add('[ww]');
    if (secondaryKeys.isNotEmpty) {
      final separator = _tavernEntryUsesRegex(item) ? ' || ' : '|';
      parts.add('[sec=${secondaryKeys.join(separator)}]');
    }
    final excludeKeys = _tavernExcludeKeys(item);
    if (excludeKeys.isNotEmpty) {
      final separator = _tavernEntryUsesRegex(item) ? ' || ' : '|';
      parts.add('[exclude=${excludeKeys.join(separator)}]');
    }
    final priority = _tavernEntryPriority(item);
    if (priority is num && priority != 0) {
      parts.add('[p=${priority.toInt()}]');
    }
    final position = _tavernEntryPosition(item);
    if (position.isNotEmpty) parts.add('[pos=$position]');
    final depth = _tavernEntryDepth(item);
    if (depth != null) parts.add('[depth=$depth]');
    final probability = _tavernEntryProbability(item);
    if (probability != null) parts.add('[prob=$probability]');
    if (!_tavernEntryProbabilityEnabled(item)) parts.add('[prob_disabled]');
    if (_tavernEntryExcludeFromRecursion(item)) parts.add('[norec]');
    final group = _tavernEntryGroup(item);
    if (group.isNotEmpty) parts.add('[group=$group]');
    final groupWeight = _tavernEntryGroupWeight(item);
    if (groupWeight != 0) parts.add('[gw=$groupWeight]');
    if (_tavernEntryGroupOverride(item)) parts.add('[group_override]');
    if (_tavernEntryUseGroupScoring(item)) parts.add('[group_scoring]');
    final selectiveLogic = _tavernEntrySelectiveLogic(item);
    if (secondaryKeys.isNotEmpty && selectiveLogic != 0) {
      parts.add('[logic=$selectiveLogic]');
    }
    final sticky = _tavernEntryInt(item, const ['sticky']);
    if (sticky != null && sticky > 0) parts.add('[sticky=$sticky]');
    final cooldown = _tavernEntryInt(item, const ['cooldown']);
    if (cooldown != null && cooldown > 0) parts.add('[cooldown=$cooldown]');
    final delay = _tavernEntryInt(item, const ['delay']);
    if (delay != null && delay > 0) parts.add('[delay=$delay]');
    final characterFilter = _tavernCharacterFilter(item);
    if (characterFilter.names.isNotEmpty) {
      parts.add('[characters=${characterFilter.names.join('|')}]');
    }
    if (characterFilter.exclude) parts.add('[characters_exclude]');
    if (_tavernEntryFlag(
        item, const ['matchPersonaDescription', 'match_persona_description'])) {
      parts.add('[persona]');
    }
    if (_tavernEntryFlag(item,
        const ['matchCharacterDescription', 'match_character_description'])) {
      parts.add('[character_description]');
    }
    if (_tavernEntryFlag(item,
        const ['matchCharacterPersonality', 'match_character_personality'])) {
      parts.add('[character_personality]');
    }
    if (_tavernEntryFlag(item,
        const ['matchCharacterDepthPrompt', 'match_character_depth_prompt'])) {
      parts.add('[character_depth_prompt]');
    }
    if (_tavernEntryFlag(item, const ['matchScenario', 'match_scenario'])) {
      parts.add('[scenario]');
    }
    if (_tavernEntryFlag(
        item, const ['matchCreatorNotes', 'match_creator_notes'])) {
      parts.add('[creator_notes]');
    }
    return parts.isEmpty ? '' : '${parts.join(' ')} ';
  }

  static String _tavernEntryPosition(Map<String, dynamic> item) {
    final raw = item['position'];
    if (raw is String && raw.trim().isNotEmpty) return raw.trim();
    if (raw is num) return raw.toInt().toString();
    final extensions = item['extensions'];
    if (extensions is Map) {
      final extPosition = extensions['position'];
      if (extPosition is String && extPosition.trim().isNotEmpty) {
        return extPosition.trim();
      }
      if (extPosition is num) return extPosition.toInt().toString();
    }
    return '';
  }

  static List<String> _tavernExcludeKeys(Map<String, dynamic> item) {
    final regex = _tavernEntryUsesRegex(item);
    final keys = <String>[];
    for (final key in const [
      'exclude_keys',
      'excludeKeys',
      'exclusion_keys',
      'exclusionKeys',
      'exclusions',
    ]) {
      keys.addAll(_tavernKeysFrom(item[key], '', regex: regex));
    }
    final extensions = item['extensions'];
    if (extensions is Map) {
      for (final key in const [
        'exclude_keys',
        'excludeKeys',
        'exclusion_keys',
        'exclusionKeys',
        'exclusions',
      ]) {
        keys.addAll(_tavernKeysFrom(extensions[key], '', regex: regex));
      }
    }
    final seen = <String>{};
    return [
      for (final key in keys)
        if (seen.add(key)) key,
    ];
  }

  static int? _tavernEntryDepth(Map<String, dynamic> item) {
    final direct = _intOrNull(item['depth']);
    if (direct != null) return direct;
    final extensions = item['extensions'];
    if (extensions is Map) return _intOrNull(extensions['depth']);
    return null;
  }

  static int? _tavernEntryProbability(Map<String, dynamic> item) {
    final direct = _intOrNull(item['probability']);
    final extensions = item['extensions'];
    final useProbability =
        _tavernBool(item, const ['useProbability', 'use_probability']);
    final extProbability =
        extensions is Map ? _intOrNull(extensions['probability']) : null;
    final value = direct ?? extProbability;
    if (value == null) return null;
    if (useProbability == null && value >= 100) return null;
    return value.clamp(0, 100).toInt();
  }

  static bool _tavernEntryProbabilityEnabled(Map<String, dynamic> item) =>
      _tavernBool(item, const ['useProbability', 'use_probability']) ?? true;

  static num? _tavernEntryPriority(Map<String, dynamic> item) {
    for (final key in const [
      'priority',
      'order',
      'insertion_order',
      'insertionOrder',
    ]) {
      final value = _numOrNull(item[key]);
      if (value != null) return value;
    }
    final extensions = item['extensions'];
    if (extensions is Map) {
      for (final key in const [
        'priority',
        'order',
        'insertion_order',
        'insertionOrder',
      ]) {
        final value = _numOrNull(extensions[key]);
        if (value != null) return value;
      }
    }
    return null;
  }

  static String _tavernEntryGroup(Map<String, dynamic> item) {
    for (final key in const ['group', 'group_name', 'groupName']) {
      final value = _normalizeTavernText(item[key], '');
      if (value.isNotEmpty) return value;
    }
    final extensions = item['extensions'];
    if (extensions is Map) {
      for (final key in const ['group', 'group_name', 'groupName']) {
        final value = _normalizeTavernText(extensions[key], '');
        if (value.isNotEmpty) return value;
      }
    }
    return '';
  }

  static int _tavernEntryGroupWeight(Map<String, dynamic> item) {
    for (final key in const ['group_weight', 'groupWeight']) {
      final value = _intOrNull(item[key]);
      if (value != null) return value;
    }
    final extensions = item['extensions'];
    if (extensions is Map) {
      for (final key in const ['group_weight', 'groupWeight']) {
        final value = _intOrNull(extensions[key]);
        if (value != null) return value;
      }
    }
    return 0;
  }

  static bool _tavernEntryGroupOverride(Map<String, dynamic> item) =>
      _tavernBool(item, const ['group_override', 'groupOverride']) == true;

  static bool _tavernEntryUseGroupScoring(Map<String, dynamic> item) =>
      _tavernBool(item, const ['use_group_scoring', 'useGroupScoring']) == true;

  static int _tavernEntrySelectiveLogic(Map<String, dynamic> item) {
    Object? value = item['selectiveLogic'] ?? item['selective_logic'];
    final extensions = item['extensions'];
    if (value == null && extensions is Map) {
      value = extensions['selectiveLogic'] ?? extensions['selective_logic'];
    }
    final number = _intOrNull(value);
    if (number != null) return number.clamp(0, 3).toInt();
    return switch (value?.toString().trim().toLowerCase()) {
      'not_all' || 'not all' => 1,
      'not_any' || 'not any' => 2,
      'and_all' || 'and all' => 3,
      _ => 0,
    };
  }

  static int? _tavernEntryInt(
    Map<String, dynamic> item,
    List<String> keys,
  ) {
    for (final key in keys) {
      final value = _intOrNull(item[key]);
      if (value != null) return value;
    }
    final extensions = item['extensions'];
    if (extensions is Map) {
      for (final key in keys) {
        final value = _intOrNull(extensions[key]);
        if (value != null) return value;
      }
    }
    return null;
  }

  static bool _tavernEntryFlag(
    Map<String, dynamic> item,
    List<String> keys,
  ) =>
      _tavernBool(item, keys) == true;

  static _TavernCharacterFilter _tavernCharacterFilter(
    Map<String, dynamic> item,
  ) {
    Object? raw = item['characterFilter'] ?? item['character_filter'];
    final extensions = item['extensions'];
    if (raw == null && extensions is Map) {
      raw = extensions['characterFilter'] ?? extensions['character_filter'];
    }
    final filter = raw is Map ? _mapStringDynamic(raw) : null;
    final names = <String>[];
    if (filter != null) {
      names.addAll(_tavernFilterNames(filter['names']));
    }
    names.addAll(_tavernFilterNames(item['characterFilterNames']));
    if (extensions is Map) {
      names.addAll(_tavernFilterNames(extensions['characterFilterNames']));
    }
    final seen = <String>{};
    final uniqueNames = [
      for (final name in names)
        if (name.trim().isNotEmpty && seen.add(name.trim())) name.trim(),
    ];
    final exclude = _boolOrNull(filter?['isExclude']) ??
        _boolOrNull(filter?['is_exclude']) ??
        _tavernBool(item,
            const ['characterFilterExclude', 'character_filter_exclude']) ??
        false;
    return _TavernCharacterFilter(uniqueNames, exclude);
  }

  static List<String> _tavernFilterNames(Object? raw) {
    if (raw is List) {
      return raw
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList();
    }
    if (raw is String) {
      return raw
          .split(RegExp(r'[,，|]+'))
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList();
    }
    return const [];
  }

  static bool _tavernEntryDisabled(Map<String, dynamic> item) {
    return _tavernBool(item, const ['enabled']) == false ||
        _tavernBool(item, const ['disabled', 'disable']) == true;
  }

  static bool _tavernEntryConstant(Map<String, dynamic> item) {
    return _tavernBool(item, const ['constant']) == true;
  }

  static bool _tavernEntryExcludeFromRecursion(Map<String, dynamic> item) {
    return _tavernBool(item, const [
          'excludeRecursion',
          'exclude_recursion',
          'preventRecursion',
          'prevent_recursion',
        ]) ==
        true;
  }

  static bool? _tavernBool(Map<String, dynamic> item, List<String> keys) {
    for (final key in keys) {
      final value = _boolOrNull(item[key]);
      if (value != null) return value;
    }
    final extensions = item['extensions'];
    if (extensions is Map) {
      for (final key in keys) {
        final value = _boolOrNull(extensions[key]);
        if (value != null) return value;
      }
    }
    return null;
  }

  static List<String> _tavernKeys(
    Map<String, dynamic> item,
    String name, {
    bool includeSecondary = true,
  }) {
    final keys = <String>[];
    final regex = _tavernEntryUsesRegex(item);

    keys.addAll(_tavernKeysFrom(item['keys'], name, regex: regex));
    keys.addAll(_tavernKeysFrom(item['key'], name, regex: regex));
    if (includeSecondary) {
      keys.addAll(_tavernSecondaryKeys(item, name, regex: regex));
    }
    final seen = <String>{};
    return [
      for (final key in keys)
        if (seen.add(key)) key,
    ];
  }

  static List<String> _tavernKeysFrom(
    Object? raw,
    String name, {
    required bool regex,
  }) {
    final keys = <String>[];
    if (raw is List) {
      for (final item in raw) {
        final key = _normalizeTavernText(item, name);
        if (key.isNotEmpty) keys.add(key);
      }
      return keys;
    }
    final text = _normalizeTavernText(raw, name);
    if (text.isEmpty) return keys;
    if (regex) return [text];
    return text
        .split(RegExp(r'[,，、|/]+'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }

  static List<String> _tavernSecondaryKeys(
    Map<String, dynamic> item,
    String name, {
    required bool regex,
  }) {
    final keys = <String>[];
    for (final key in const [
      'secondary_keys',
      'secondaryKeys',
      'secondary_key',
      'key_secondary',
      'keysecondary',
      'keySecondary',
    ]) {
      keys.addAll(_tavernKeysFrom(item[key], name, regex: regex));
    }
    final extensions = item['extensions'];
    if (extensions is Map) {
      for (final key in const [
        'secondary_keys',
        'secondaryKeys',
        'secondary_key',
        'key_secondary',
        'keysecondary',
        'keySecondary',
      ]) {
        keys.addAll(_tavernKeysFrom(extensions[key], name, regex: regex));
      }
    }
    final seen = <String>{};
    return [
      for (final key in keys)
        if (seen.add(key)) key,
    ];
  }

  static bool _tavernEntryUsesSelective(Map<String, dynamic> item) {
    return _tavernBool(item, const ['selective']) == true;
  }

  static bool _tavernEntryCaseSensitive(Map<String, dynamic> item) {
    return _tavernBool(item, const ['case_sensitive', 'caseSensitive']) == true;
  }

  static bool _tavernEntryWholeWords(Map<String, dynamic> item) {
    return _tavernBool(item, const [
          'match_whole_words',
          'matchWholeWords',
        ]) ==
        true;
  }

  static bool _tavernEntryUsesRegex(Map<String, dynamic> item) {
    return _tavernBool(item, const ['regex', 'use_regex', 'useRegex']) == true;
  }

  static String _normalizeTavernText(Object? value, String name) {
    if (value is! String) return '';
    final charName = name.trim().isEmpty ? '角色' : name.trim();
    return value
        .replaceAll(
            RegExp(r'\{\{\s*char\s*\}\}', caseSensitive: false), charName)
        .replaceAll(
            RegExp(r'\{\{\s*user\s*\}\}', caseSensitive: false), '{{user}}')
        .replaceAll(RegExp(r'<BOT>', caseSensitive: false), charName)
        .replaceAll(RegExp(r'<USER>', caseSensitive: false), '{{user}}')
        .trim();
  }

  static String _string(Object? value, {String fallback = ''}) =>
      value is String ? value.trim() : fallback;

  static List<String>? _toolIds(Map<String, dynamic> payload) {
    final raw = payload['toolIds'];
    if (raw is List) {
      return [
        for (final item in raw)
          if (item is String && item.trim().isNotEmpty) item.trim(),
      ];
    }
    final legacy = payload['tools'];
    if (legacy is String && legacy.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(legacy);
        if (decoded is List) {
          return [
            for (final item in decoded)
              if (item is String && item.trim().isNotEmpty) item.trim(),
          ];
        }
      } catch (_) {
        return null;
      }
    }
    return null;
  }
}

class AssistantRoleCardSummary {
  final int promptChars;
  final int openingChars;
  final int exampleDialogLines;
  final int alternateGreetingCount;
  final List<AssistantMemoryEntryPreview> memoryEntries;
  final int toolCount;
  final bool hasDefaultVoice;
  final bool hasModelOverride;

  const AssistantRoleCardSummary({
    required this.promptChars,
    required this.openingChars,
    required this.exampleDialogLines,
    required this.alternateGreetingCount,
    required this.memoryEntries,
    required this.toolCount,
    required this.hasDefaultVoice,
    required this.hasModelOverride,
  });

  int get memoryCount => memoryEntries.length;
  int get alwaysOnMemoryCount =>
      memoryEntries.where((entry) => entry.alwaysOn).length;
  int get keywordMemoryCount => memoryCount - alwaysOnMemoryCount;
  int get disabledMemoryCount =>
      memoryEntries.where((entry) => !entry.enabled).length;
}

class AssistantMemoryBookMergePreview {
  final String mergedText;
  final int existingCount;
  final int incomingCount;
  final int appendedCount;
  final int skippedDuplicateCount;
  final int skippedInvalidCount;
  final List<String> appendedLines;

  const AssistantMemoryBookMergePreview({
    required this.mergedText,
    required this.existingCount,
    required this.incomingCount,
    required this.appendedCount,
    required this.skippedDuplicateCount,
    required this.skippedInvalidCount,
    this.appendedLines = const [],
  });

  int get mergedCount => existingCount + appendedCount;

  String get compactSummary {
    final parts = <String>[
      '保留旧 $existingCount',
      '追加新 $appendedCount',
      if (skippedDuplicateCount > 0) '跳过重复 $skippedDuplicateCount',
      if (skippedInvalidCount > 0) '跳过无效 $skippedInvalidCount',
    ];
    return parts.join(' / ');
  }

  List<String> appendedPreviewLines({int maxItems = 3}) {
    final limit = maxItems.clamp(1, 20);
    return appendedLines
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .take(limit)
        .toList(growable: false);
  }
}

class AssistantRoleCardImportResult {
  final AssistantModel assistant;
  final List<int>? avatarPngBytes;

  /// PNG/JPEG 头像的扩展名，兼容旧字段 [avatarPngBytes] 的命名。
  final String? avatarExtension;

  /// V3 `data.assets` 及包内未引用文件的清单。资源不会被执行。
  final List<AssistantRoleCardResource> resources;
  final String? sourceName;
  final AssistantRoleCardTavernMeta? tavernMeta;

  const AssistantRoleCardImportResult({
    required this.assistant,
    this.avatarPngBytes,
    this.avatarExtension,
    this.resources = const [],
    this.sourceName,
    this.tavernMeta,
  });
}

class TavernExtensionSafetyReport {
  final List<String> blockedExtensionLabels;

  const TavernExtensionSafetyReport({
    this.blockedExtensionLabels = const [],
  });

  bool get hasBlockedExtensions => blockedExtensionLabels.isNotEmpty;

  String get warningText => hasBlockedExtensions
      ? '检测到 ${blockedExtensionLabels.join('、')}；声明式正则仅在隔离环境执行文本替换，脚本和命令不会执行。'
      : '';
}

/// CHARX 资源的可序列化元数据和可选包内字节。
///
/// [bytes] 只来自 ZIP 内部，导出时用于恢复包内资源；HTTP、data URL 等外部
/// URI 不会被访问或下载。未知/未引用文件仍保留为清单项，但不会自动加入
/// `card.json` 的 `assets` 数组。
class AssistantRoleCardResource {
  final String type;
  final String uri;
  final String name;
  final String ext;
  final String archivePath;
  final String mimeType;
  final int size;
  final Uint8List? bytes;
  final bool includeInCard;

  const AssistantRoleCardResource({
    required this.type,
    required this.uri,
    required this.name,
    required this.ext,
    this.archivePath = '',
    this.mimeType = 'application/octet-stream',
    this.size = 0,
    this.bytes,
    this.includeInCard = true,
  });

  Map<String, dynamic> toCardJson() => {
        'type': type,
        'uri': uri,
        'name': name,
        'ext': ext,
      };

  Map<String, dynamic> toJson() => {
        ...toCardJson(),
        'archivePath': archivePath,
        'mimeType': mimeType,
        'size': size,
        'includeInCard': includeInCard,
      };

  factory AssistantRoleCardResource.fromJson(Map<String, dynamic> json) =>
      AssistantRoleCardResource(
        type: json['type'] as String? ?? 'other',
        uri: json['uri'] as String? ?? '',
        name: json['name'] as String? ?? '',
        ext: json['ext'] as String? ?? 'unknown',
        archivePath: json['archivePath'] as String? ?? '',
        mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
        size: json['size'] as int? ?? 0,
        includeInCard: json['includeInCard'] as bool? ?? true,
      );
}

class AssistantRoleCardTavernMeta {
  final String spec;
  final String specVersion;
  final String creator;
  final String characterVersion;
  final String createDate;
  final String updateDate;
  final String source;
  final List<String> sources;
  final String nickname;
  final int? creationTimestamp;
  final int? modificationTimestamp;
  final String creatorNotes;
  final String systemPrompt;
  final String postHistoryInstructions;
  final List<String> tags;
  final List<String> alternateGreetings;
  final List<String> groupOnlyGreetings;
  final num? talkativeness;
  final String extensionWorld;
  final String characterDepthPrompt;
  final int? characterDepthPromptDepth;
  final String characterDepthPromptRole;
  final String characterBookName;
  final int? characterBookScanDepth;
  final int? characterBookTokenBudget;
  final bool? characterBookRecursiveScanning;
  final int characterBookEntryCount;

  const AssistantRoleCardTavernMeta({
    this.spec = '',
    this.specVersion = '',
    this.creator = '',
    this.characterVersion = '',
    this.createDate = '',
    this.updateDate = '',
    this.source = '',
    this.sources = const [],
    this.nickname = '',
    this.creationTimestamp,
    this.modificationTimestamp,
    this.creatorNotes = '',
    this.systemPrompt = '',
    this.postHistoryInstructions = '',
    this.tags = const [],
    this.alternateGreetings = const [],
    this.groupOnlyGreetings = const [],
    this.talkativeness,
    this.extensionWorld = '',
    this.characterDepthPrompt = '',
    this.characterDepthPromptDepth,
    this.characterDepthPromptRole = '',
    this.characterBookName = '',
    this.characterBookScanDepth,
    this.characterBookTokenBudget,
    this.characterBookRecursiveScanning,
    this.characterBookEntryCount = 0,
  });

  factory AssistantRoleCardTavernMeta.fromJson(Map<String, dynamic> json) =>
      AssistantRoleCardTavernMeta(
        spec: json['spec'] as String? ?? '',
        specVersion: json['specVersion'] as String? ?? '',
        creator: json['creator'] as String? ?? '',
        characterVersion: json['characterVersion'] as String? ?? '',
        createDate: json['createDate'] as String? ?? '',
        updateDate: json['updateDate'] as String? ?? '',
        source: json['source'] as String? ?? '',
        sources: _stringList(json['sources']),
        nickname: json['nickname'] as String? ?? '',
        creationTimestamp: _intOrNull(json['creationTimestamp']),
        modificationTimestamp: _intOrNull(json['modificationTimestamp']),
        creatorNotes: json['creatorNotes'] as String? ?? '',
        systemPrompt: json['systemPrompt'] as String? ?? '',
        postHistoryInstructions:
            json['postHistoryInstructions'] as String? ?? '',
        tags: _stringList(json['tags']),
        alternateGreetings: _stringList(json['alternateGreetings']),
        groupOnlyGreetings: _stringList(json['groupOnlyGreetings']),
        talkativeness: _numOrNull(json['talkativeness']),
        extensionWorld: json['extensionWorld'] as String? ?? '',
        characterDepthPrompt: json['characterDepthPrompt'] as String? ?? '',
        characterDepthPromptDepth:
            _intOrNull(json['characterDepthPromptDepth']),
        characterDepthPromptRole:
            json['characterDepthPromptRole'] as String? ?? '',
        characterBookName: json['characterBookName'] as String? ?? '',
        characterBookScanDepth: _intOrNull(json['characterBookScanDepth']),
        characterBookTokenBudget: _intOrNull(json['characterBookTokenBudget']),
        characterBookRecursiveScanning:
            json['characterBookRecursiveScanning'] as bool?,
        characterBookEntryCount:
            _intOrNull(json['characterBookEntryCount']) ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'spec': spec,
        'specVersion': specVersion,
        'creator': creator,
        'characterVersion': characterVersion,
        'createDate': createDate,
        'updateDate': updateDate,
        'source': source,
        'sources': sources,
        'nickname': nickname,
        'creationTimestamp': creationTimestamp,
        'modificationTimestamp': modificationTimestamp,
        'creatorNotes': creatorNotes,
        'systemPrompt': systemPrompt,
        'postHistoryInstructions': postHistoryInstructions,
        'tags': tags,
        'alternateGreetings': alternateGreetings,
        'groupOnlyGreetings': groupOnlyGreetings,
        'talkativeness': talkativeness,
        'extensionWorld': extensionWorld,
        'characterDepthPrompt': characterDepthPrompt,
        'characterDepthPromptDepth': characterDepthPromptDepth,
        'characterDepthPromptRole': characterDepthPromptRole,
        'characterBookName': characterBookName,
        'characterBookScanDepth': characterBookScanDepth,
        'characterBookTokenBudget': characterBookTokenBudget,
        'characterBookRecursiveScanning': characterBookRecursiveScanning,
        'characterBookEntryCount': characterBookEntryCount,
      };

  AssistantRoleCardTavernMeta copyWith({
    List<String>? alternateGreetings,
  }) {
    return AssistantRoleCardTavernMeta(
      spec: spec,
      specVersion: specVersion,
      creator: creator,
      characterVersion: characterVersion,
      createDate: createDate,
      updateDate: updateDate,
      source: source,
      sources: sources,
      nickname: nickname,
      creationTimestamp: creationTimestamp,
      modificationTimestamp: modificationTimestamp,
      creatorNotes: creatorNotes,
      systemPrompt: systemPrompt,
      postHistoryInstructions: postHistoryInstructions,
      tags: tags,
      alternateGreetings: alternateGreetings ?? this.alternateGreetings,
      groupOnlyGreetings: groupOnlyGreetings,
      talkativeness: talkativeness,
      extensionWorld: extensionWorld,
      characterDepthPrompt: characterDepthPrompt,
      characterDepthPromptDepth: characterDepthPromptDepth,
      characterDepthPromptRole: characterDepthPromptRole,
      characterBookName: characterBookName,
      characterBookScanDepth: characterBookScanDepth,
      characterBookTokenBudget: characterBookTokenBudget,
      characterBookRecursiveScanning: characterBookRecursiveScanning,
      characterBookEntryCount: characterBookEntryCount,
    );
  }

  AssistantRoleCardTavernMeta syncTranslatedOpenings(
    AssistantModel assistant,
  ) {
    final translatedGreetings =
        AssistantRoleCardService.alternateGreetings(assistant.exampleDialogs);
    if (translatedGreetings.isEmpty) return this;
    return copyWith(alternateGreetings: translatedGreetings);
  }

  bool get isEmpty =>
      spec.isEmpty &&
      specVersion.isEmpty &&
      creator.isEmpty &&
      characterVersion.isEmpty &&
      createDate.isEmpty &&
      updateDate.isEmpty &&
      source.isEmpty &&
      sources.isEmpty &&
      nickname.isEmpty &&
      creationTimestamp == null &&
      modificationTimestamp == null &&
      creatorNotes.isEmpty &&
      systemPrompt.isEmpty &&
      postHistoryInstructions.isEmpty &&
      tags.isEmpty &&
      alternateGreetings.isEmpty &&
      groupOnlyGreetings.isEmpty &&
      talkativeness == null &&
      extensionWorld.isEmpty &&
      characterDepthPrompt.isEmpty &&
      characterDepthPromptDepth == null &&
      characterDepthPromptRole.isEmpty &&
      characterBookName.isEmpty &&
      characterBookScanDepth == null &&
      characterBookTokenBudget == null &&
      characterBookRecursiveScanning == null &&
      characterBookEntryCount == 0;

  static List<String> _stringList(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is String && item.trim().isNotEmpty) item.trim(),
    ];
  }

  static int? _intOrNull(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  static num? _numOrNull(Object? raw) {
    if (raw is num) return raw;
    if (raw is String) return num.tryParse(raw.trim());
    return null;
  }
}

class AssistantRoleCardImportBatchResult {
  final List<AssistantRoleCardImportResult> results;
  final List<AssistantRoleCardSkippedImport> skipped;

  const AssistantRoleCardImportBatchResult({
    required this.results,
    this.skipped = const [],
  });

  String get summaryText {
    final imported = results.length;
    final skippedCount = skipped.length;
    if (skippedCount == 0) return '已解析 $imported 张角色卡';
    return '已解析 $imported 张角色卡，$skippedCount 个文件跳过';
  }

  String get skippedDetailText {
    return skipped.map((item) => '${item.name}：${item.reason}').join('\n');
  }
}

class AssistantRoleCardSkippedImport {
  final String name;
  final String reason;

  const AssistantRoleCardSkippedImport({
    required this.name,
    required this.reason,
  });
}

class AssistantMemoryEntryPreview {
  final String id;
  final List<String> keywords;
  final String content;
  final bool alwaysOn;
  final bool enabled;
  final int priority;
  final bool regex;
  final List<String> secondaryKeywords;
  final List<String> excludeKeywords;
  final bool caseSensitive;
  final bool wholeWords;
  final String position;
  final int? depth;
  final int? probability;
  final bool probabilityEnabled;
  final bool excludeFromRecursion;
  final String group;
  final int groupWeight;
  final bool groupOverride;
  final bool useGroupScoring;
  final int selectiveLogic;
  final int sticky;
  final int cooldown;
  final int delay;
  final List<String> characterFilterNames;
  final bool characterFilterExclude;
  final bool matchPersonaDescription;
  final bool matchCharacterDescription;
  final bool matchCharacterPersonality;
  final bool matchCharacterDepthPrompt;
  final bool matchScenario;
  final bool matchCreatorNotes;

  const AssistantMemoryEntryPreview({
    this.id = '',
    required this.keywords,
    required this.content,
    required this.alwaysOn,
    this.enabled = true,
    this.priority = 0,
    this.regex = false,
    this.secondaryKeywords = const [],
    this.excludeKeywords = const [],
    this.caseSensitive = false,
    this.wholeWords = false,
    this.position = '',
    this.depth,
    this.probability,
    this.probabilityEnabled = true,
    this.excludeFromRecursion = false,
    this.group = '',
    this.groupWeight = 0,
    this.groupOverride = false,
    this.useGroupScoring = false,
    this.selectiveLogic = 0,
    this.sticky = 0,
    this.cooldown = 0,
    this.delay = 0,
    this.characterFilterNames = const [],
    this.characterFilterExclude = false,
    this.matchPersonaDescription = false,
    this.matchCharacterDescription = false,
    this.matchCharacterPersonality = false,
    this.matchCharacterDepthPrompt = false,
    this.matchScenario = false,
    this.matchCreatorNotes = false,
  });

  factory AssistantMemoryEntryPreview.fromWorldBook(WorldBookEntry entry) =>
      AssistantMemoryEntryPreview(
        id: entry.id,
        keywords: entry.keywords,
        content: entry.content,
        alwaysOn: entry.alwaysOn,
        enabled: entry.enabled,
        priority: entry.priority,
        regex: entry.regex,
        secondaryKeywords: entry.secondaryKeywords,
        excludeKeywords: entry.excludeKeywords,
        caseSensitive: entry.caseSensitive,
        wholeWords: entry.wholeWords,
        position: entry.position,
        depth: entry.depth,
        probability: entry.probability,
        probabilityEnabled: entry.probabilityEnabled,
        excludeFromRecursion: entry.excludeFromRecursion,
        group: entry.group,
        groupWeight: entry.groupWeight,
        groupOverride: entry.groupOverride,
        useGroupScoring: entry.useGroupScoring,
        selectiveLogic: entry.selectiveLogic.index,
        sticky: entry.sticky,
        cooldown: entry.cooldown,
        delay: entry.delay,
        characterFilterNames: entry.characterFilterNames,
        characterFilterExclude: entry.characterFilterExclude,
        matchPersonaDescription: entry.matchPersonaDescription,
        matchCharacterDescription: entry.matchCharacterDescription,
        matchCharacterPersonality: entry.matchCharacterPersonality,
        matchCharacterDepthPrompt: entry.matchCharacterDepthPrompt,
        matchScenario: entry.matchScenario,
        matchCreatorNotes: entry.matchCreatorNotes,
      );

  WorldBookEntry toWorldBook() => WorldBookEntry.fromJson(toJson());

  factory AssistantMemoryEntryPreview.fromJson(Map<String, dynamic> json) {
    return AssistantMemoryEntryPreview(
      id: json['id'] as String? ?? '',
      keywords: [
        for (final item in (json['keywords'] as List? ?? const []))
          if (item is String) item,
      ],
      content: json['content'] as String? ?? '',
      alwaysOn: json['alwaysOn'] as bool? ?? false,
      enabled: json['enabled'] as bool? ?? true,
      priority: json['priority'] as int? ?? 0,
      regex: json['regex'] as bool? ?? false,
      secondaryKeywords: [
        for (final item in (json['secondaryKeywords'] as List? ?? const []))
          if (item is String) item,
      ],
      excludeKeywords: [
        for (final item in (json['excludeKeywords'] as List? ?? const []))
          if (item is String) item,
      ],
      caseSensitive: json['caseSensitive'] as bool? ?? false,
      wholeWords: json['wholeWords'] as bool? ?? false,
      position: json['position'] as String? ?? '',
      depth: json['depth'] as int?,
      probability: json['probability'] as int?,
      probabilityEnabled: json['probabilityEnabled'] as bool? ?? true,
      excludeFromRecursion: json['excludeFromRecursion'] as bool? ?? false,
      group: json['group'] as String? ?? '',
      groupWeight: json['groupWeight'] as int? ?? 0,
      groupOverride: json['groupOverride'] as bool? ?? false,
      useGroupScoring: json['useGroupScoring'] as bool? ?? false,
      selectiveLogic: json['selectiveLogic'] as int? ?? 0,
      sticky: json['sticky'] as int? ?? 0,
      cooldown: json['cooldown'] as int? ?? 0,
      delay: json['delay'] as int? ?? 0,
      characterFilterNames: [
        for (final item in (json['characterFilterNames'] as List? ?? const []))
          if (item is String) item,
      ],
      characterFilterExclude: json['characterFilterExclude'] as bool? ?? false,
      matchPersonaDescription:
          json['matchPersonaDescription'] as bool? ?? false,
      matchCharacterDescription:
          json['matchCharacterDescription'] as bool? ?? false,
      matchCharacterPersonality:
          json['matchCharacterPersonality'] as bool? ?? false,
      matchCharacterDepthPrompt:
          json['matchCharacterDepthPrompt'] as bool? ?? false,
      matchScenario: json['matchScenario'] as bool? ?? false,
      matchCreatorNotes: json['matchCreatorNotes'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'keywords': keywords,
        'content': content,
        'alwaysOn': alwaysOn,
        'enabled': enabled,
        'priority': priority,
        'regex': regex,
        'secondaryKeywords': secondaryKeywords,
        'excludeKeywords': excludeKeywords,
        'caseSensitive': caseSensitive,
        'wholeWords': wholeWords,
        'position': position,
        'depth': depth,
        'probability': probability,
        'probabilityEnabled': probabilityEnabled,
        'excludeFromRecursion': excludeFromRecursion,
        'group': group,
        'groupWeight': groupWeight,
        'groupOverride': groupOverride,
        'useGroupScoring': useGroupScoring,
        'selectiveLogic': selectiveLogic,
        'sticky': sticky,
        'cooldown': cooldown,
        'delay': delay,
        'characterFilterNames': characterFilterNames,
        'characterFilterExclude': characterFilterExclude,
        'matchPersonaDescription': matchPersonaDescription,
        'matchCharacterDescription': matchCharacterDescription,
        'matchCharacterPersonality': matchCharacterPersonality,
        'matchCharacterDepthPrompt': matchCharacterDepthPrompt,
        'matchScenario': matchScenario,
        'matchCreatorNotes': matchCreatorNotes,
      };

  String get label {
    final base = alwaysOn
        ? '常驻'
        : regex
            ? '正则：${keywords.join(' / ')}'
            : keywords.join(' / ');
    final secondaryLabel = secondaryKeywords.isEmpty
        ? ''
        : ' + 二级：${secondaryKeywords.join(' / ')}';
    final excludeLabel =
        excludeKeywords.isEmpty ? '' : ' · 排除：${excludeKeywords.join(' / ')}';
    final caseLabel = caseSensitive ? ' · 区分大小写' : '';
    final wholeWordsLabel = wholeWords ? ' · 整词' : '';
    final priorityLabel = priority == 0 ? '' : ' · p=$priority';
    final positionLabel = position.isEmpty ? '' : ' · pos=$position';
    final depthLabel = depth == null ? '' : ' · depth=$depth';
    final probabilityLabel = probability == null ? '' : ' · prob=$probability';
    final probabilityEnabledLabel = probabilityEnabled ? '' : ' · 概率关闭';
    final recursionLabel = excludeFromRecursion ? ' · 不参与递归' : '';
    final groupLabel = group.trim().isEmpty ? '' : ' · 组：$group';
    final groupWeightLabel = groupWeight == 0 ? '' : ' · gw=$groupWeight';
    final groupOverrideLabel = groupOverride ? ' · 组优先' : '';
    final timedLabel = [
      if (sticky > 0) 'sticky=$sticky',
      if (cooldown > 0) 'cooldown=$cooldown',
      if (delay > 0) 'delay=$delay',
    ];
    final timedText = timedLabel.isEmpty ? '' : ' · ${timedLabel.join(' / ')}';
    final enabledLabel = enabled ? '' : ' · 已禁用';
    return '$base$secondaryLabel$excludeLabel$caseLabel$wholeWordsLabel$priorityLabel$positionLabel$depthLabel$probabilityLabel$probabilityEnabledLabel$recursionLabel$groupLabel$groupWeightLabel$groupOverrideLabel$timedText$enabledLabel';
  }
}

class _MemoryPreviewMeta {
  final String body;
  final bool enabled;
  final int priority;
  final bool regex;
  final List<String> secondaryKeywords;
  final List<String> excludeKeywords;
  final bool caseSensitive;
  final bool wholeWords;
  final String position;
  final int? depth;
  final int? probability;
  final bool excludeFromRecursion;
  final String group;
  final int groupWeight;

  const _MemoryPreviewMeta({
    required this.body,
    required this.enabled,
    required this.priority,
    this.regex = false,
    this.secondaryKeywords = const [],
    this.excludeKeywords = const [],
    this.caseSensitive = false,
    this.wholeWords = false,
    this.position = '',
    this.depth,
    this.probability,
    this.excludeFromRecursion = false,
    this.group = '',
    this.groupWeight = 0,
  });
}

class _TavernCharacterFilter {
  final List<String> names;
  final bool exclude;

  const _TavernCharacterFilter(this.names, this.exclude);
}
