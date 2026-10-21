import 'dart:async';
import 'dart:convert';
import 'attachment_ocr.dart';
import 'package:login_sdk/platform/app_io.dart';
import 'package:crypto/crypto.dart';
import 'package:chatgpt_app_core/chat/application/attachment_batch_budget.dart';
import 'package:chatgpt_app_core/chat/application/chat_block_store.dart';
import 'package:chatgpt_app_core/chat/application/conversation_draft_store.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_service.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_scope.dart';
import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/chat/application/conversation_run_tools.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/composer_reference.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/util/account_resource_scope.dart';
import 'package:chatgpt_app_core/util/bounded_file_reader.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';

/// 输入值在按钮提交时复制；不保存页面、controller 或弹窗闭包。
final class ComposerGenerationPreparation
    implements
        ConversationTurnPreparation,
        AcceptedConversationPreparation,
        UnacceptedConversationPreparation,
        SubmittedDraftOwnership,
        ConfigurationAwareConversationPreparation {
  final ConversationDraftStore draftStore;
  final String text;
  final List<String> images, files;
  final List<ComposerReference> references;
  final List<MessageBlock> extraUserBlocks;
  final ToolRegistry? tools;
  final ConversationRunTools? runTools;
  final AttachmentOcrHandler Function(ConversationGenerationRun)? createOcr;
  final Future<Directory> Function() _resourceRoot;
  late final Future<DraftManifestToken?> _manifest;
  late final Future<DraftSubmissionToken?> _submission;
  bool _accepted = false;
  _GenerationResources? _resources;
  bool _released = false;
  Future<PreparedConversationTurn>? _preparing;
  String? get resourceNotice =>
      _resources?.cleanupError == null ? null : '本次独占附件清理未完成，原文件未改动';

  ComposerGenerationPreparation({
    required this.draftStore,
    required this.text,
    List<String> images = const [],
    List<String> files = const [],
    List<ComposerReference> references = const [],
    List<MessageBlock> extraUserBlocks = const [],
    this.tools,
    this.runTools,
    this.createOcr,
    Future<Directory> Function()? resourceRoot,
  })  : images = List.unmodifiable(images),
        files = List.unmodifiable(files),
        references = List.unmodifiable(references.map((r) =>
            ComposerReference.fromJson(jsonDecode(jsonEncode(r.toJson()))))),
        extraUserBlocks = List.unmodifiable(extraUserBlocks.map(
            (b) => MessageBlock.fromJson(jsonDecode(jsonEncode(b.toJson()))))),
        _resourceRoot =
            resourceRoot ?? (() async => ManagedAttachmentStore.rootDirectory) {
    // 同步捕获原 manifest 代次；读取失败只会保留原草稿，不影响准备副本。
    final capturedScope =
        ConversationGenerationScope(account: draftStore.accountHash);
    _manifest = draftStore.captureManifest(verify: capturedScope.verify);
    _manifest.ignore();
    _submission = draftStore.captureSubmission(verify: capturedScope.verify);
    _submission.ignore();
  }

  @override
  Future<PreparedConversationTurn> prepare(ConversationGenerationRun run) =>
      _preparing ??= _prepare(run);

  Future<PreparedConversationTurn> _prepare(
      ConversationGenerationRun run) async {
    if (_released ||
        draftStore.accountHash != run.scope.account ||
        draftStore.conversationId != run.input.cid.toString() ||
        images.length > 4 ||
        files.length > 10 ||
        text != run.input.user.content) {
      throw const DraftStorageException('发送快照身份或附件数量不匹配');
    }
    final resources = _resources = _GenerationResources(run, _resourceRoot);
    return resources.operation(() async {
      await run.guard();
      final paths = {...images, ...files};
      for (final reference in references) {
        if (!reference.available ||
            (reference.kind == ComposerReferenceKind.historyMessage
                ? reference.historySnapshot?.accountToken !=
                    AccountResourceScope.tokenFor(run.scope.account)
                : !(reference.kind == ComposerReferenceKind.photo
                    ? images.contains(reference.attachmentPath)
                    : files.contains(reference.attachmentPath)))) {
          throw const DraftStorageException('引用已失效，请重新选择');
        }
      }
      final limits = run.profile.settings.attachmentProcessingLimits;
      final preflight = AttachmentBatchBudget(limits: limits);
      await preflight.preflightPaths(paths, isCancelled: () => !run.current);
      final owned = <String, String>{};
      for (final path in paths) {
        await run.guard();
        final reference =
            references.where((r) => r.attachmentPath == path).firstOrNull;
        final singleLimit = images.contains(path)
            ? FileProcessor.maxImageBytes
            : path.toLowerCase().endsWith('.pdf')
                ? FileProcessor.defaultPdfLimit
                : limits.normalized.maxTextFileBytes;
        owned[path] = await resources.copy(path,
            maxBytes: singleLimit < preflight.remainingBytes
                ? singleLimit
                : preflight.remainingBytes,
            consumeBytes: preflight.consumeBytes,
            expectedDigest: reference?.snapshotDigest.isEmpty == false
                ? reference!.snapshotDigest
                : null);
      }
      final budget = AttachmentBatchBudget(
          limits: limits, snapshotFile: resources.snapshot);
      final imageData = await FileProcessor.encodeImages(
          images.map((p) => owned[p]!).toList(),
          batchBudget: budget,
          abortTrigger: run.abortTrigger,
          isCancelled: () => !run.current);
      final settings = run.profile.settings;
      final caps = ChatService.capabilitiesFor(settings);
      final officialDeepSeek = (settings.mode.name == 'backend' &&
              ModelCapabilities.isDeepSeekVisionModel(
                  settings.effectiveModel)) ||
          (settings.mode.name == 'local' &&
              Uri.tryParse(settings.activeLocal.baseUrl)?.host.toLowerCase() ==
                  'api.deepseek.com');
      final processed = await FileProcessor.process(
          files.map((p) => owned[p]!).toList(),
          officialDeepSeek ? caps.copyWith(pdf: false) : caps,
          batchBudget: budget,
          limits: limits,
          ocr: createOcr?.call(run),
          onProgress: run.requestOptions.onProgress,
          abortTrigger: run.abortTrigger,
          isCancelled: () => !run.current);
      final referenceText = historyReferencesExtraText(references);
      if (referenceText.isNotEmpty) {
        budget.consumeText(
            '${processed.extraText.isEmpty ? '' : '\n\n'}$referenceText');
      }
      if (processed.hasWarnings &&
          !await run.confirm(
              '附件发送说明',
              processed.diagnostics
                  .map((d) => '${d.filename}：${d.message}')
                  .join('\n'))) {
        throw const DraftStorageException('附件说明尚未确认，原输入已保留');
      }
      await run.guard();
      final at = run.input.user.createdAt;
      final messageId = chatMessageKey(at);
      return PreparedConversationTurn(
          prompt: text,
          attachments: ChatAttachments(
              images: imageData,
              nativeFiles: processed.nativeFiles,
              extraText: [processed.extraText, referenceText]
                  .where((s) => s.isNotEmpty)
                  .join('\n\n')),
          tools: runTools == null ? tools : await runTools!.create(run),
          userBlocks: [
            for (var i = 0; i < images.length; i++)
              ImageBlock(
                  id: '${run.runId}:image:$i',
                  messageId: messageId,
                  createdAt: at,
                  status: MessageBlockStatus.success,
                  filePath: owned[images[i]]),
            for (var i = 0; i < processed.metas.length; i++)
              FileBlock(
                  id: '${run.runId}:file:$i',
                  messageId: messageId,
                  createdAt: at,
                  status: MessageBlockStatus.success,
                  file: processed.metas[i]),
            for (var i = 0; i < references.length; i++)
              if (references[i].kind == ComposerReferenceKind.historyMessage)
                ReferenceBlock(
                    id: '${run.runId}:reference:$i',
                    messageId: messageId,
                    createdAt: at,
                    status: MessageBlockStatus.success,
                    reference: references[i]),
            if (text.isNotEmpty)
              MainTextBlock(
                  id: '${run.runId}:text',
                  messageId: messageId,
                  createdAt: at,
                  status: MessageBlockStatus.success,
                  content: text),
            ...extraUserBlocks,
          ]);
    });
  }

  @override
  void userAccepted() {
    _accepted = true;
    _resources?.publish();
  }

  @override
  Future<bool> ownsSubmission(DraftSubmissionToken token) async {
    final captured = await _submission;
    return captured != null && draftStore.sameSubmission(captured, token);
  }

  @override
  Future<void> preserveUnacceptedDraft(ConversationGenerationRun run,
      ConversationGenerationScope writeScope) async {
    if (_accepted) return;
    final token = await writeScope.wait(_submission, writeScope.whenCancelled);
    writeScope.verify();
    if (token == null || _accepted) return;
    await draftStore.preserveSubmission(token,
        text: text,
        images: images,
        files: files,
        references: references,
        verify: writeScope.verify,
        abortTrigger: writeScope.whenCancelled,
        stableMutation: (action) => writeScope.stable(() async {
              if (_accepted || run.retired) {
                throw const ConversationGenerationStale();
              }
              final record = run.record;
              await run.dao.storage.db.transaction((tx) async {
                if (record != null) {
                  await run.dao.validateSavedSource(tx, writeScope, record);
                } else {
                  final rows = await tx.query('tb_conversation_list',
                      where: 'cid=?', whereArgs: [run.input.cid]);
                  if (run.input.conversationRowId == null
                      ? rows.isNotEmpty
                      : rows.length != 1 ||
                          rows.single['id'] != run.input.conversationRowId ||
                          rows.single['assistantId'] != run.input.assistantId) {
                    throw const ConversationGenerationStale();
                  }
                }
              });
              writeScope.verify();
              await action();
            }));
  }

  @override
  Future<void> clearAcceptedDraft(ConversationGenerationRun run) async {
    final token = await run.scope.wait(_manifest, run.abortTrigger);
    run.verify();
    if (token == null) return;
    // 草稿队尾和目录 resolver 可能长期等待，必须先在账号许可外完成。
    // 只有实际删除使用原运行的可撤销短许可，迟到队列不能继续取得写权限。
    await draftStore.clearCapturedManifest(token,
        verify: run.verify,
        abortTrigger: run.abortTrigger,
        stableMutation: (action) => run.scope.stable(action));
  }

  @override
  Future<void> verifyToolConfiguration() async =>
      runTools?.verifyConfiguration();

  @override
  Future<void> release() async {
    _released = true;
    runTools?.release();
    await _resources?.release();
    if (resourceNotice != null) throw DraftStorageException(resourceNotice!);
  }
}

/// 只拥有本次 UUID 目录。停止不等待不可取消的解析；迟到工作 finally 清理自有目录。
final class _GenerationResources {
  final ConversationGenerationRun run;
  final Future<Directory> Function() rootResolver;
  Directory? _root, _directory;
  final _digests = <String, String>{};
  bool _released = false, _published = false;
  int _operations = 0;
  Object? cleanupError;
  _GenerationResources(this.run, this.rootResolver);
  void _verify() {
    run.verify();
    if (_released) throw const AttachmentProcessingCancelledException();
  }

  Future<T> operation<T>(Future<T> Function() action) async {
    _operations++;
    try {
      return await action();
    } finally {
      _operations--;
      if (_released && _operations == 0) await _cleanup();
    }
  }

  Future<String> copy(String sourcePath,
      {required int maxBytes,
      required void Function(int) consumeBytes,
      String? expectedDigest}) async {
    _verify();
    final source = appFile(sourcePath);
    if (await appFileType(sourcePath, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const DraftStorageException('附件不可用');
    }
    final before = await source.stat();
    final bytes =
        await readFileBytesBounded(source, maxBytes: maxBytes, label: '发送快照');
    final after = await source.stat();
    _verify();
    if (await appFileType(sourcePath, followLinks: false) !=
            FileSystemEntityType.file ||
        before.modified != after.modified ||
        before.changed != after.changed ||
        before.size != bytes.length ||
        after.size != bytes.length) {
      throw const DraftStorageException('冻结时附件已变化');
    }
    final digest = sha256.convert(bytes).toString();
    if (expectedDigest != null && expectedDigest != digest) {
      throw const DraftStorageException('引用快照校验失败');
    }
    consumeBytes(bytes.length);
    _root ??= await rootResolver();
    _verify();
    final segments = [
      'accounts',
      AccountResourceScope.tokenFor(run.scope.account),
      'generations',
      run.runId
    ];
    _directory = appDirectory('${_root!.path}/${segments.join('/')}');
    final directory = await AccountResourceScope.createManagedDirectory(
        root: _root!,
        relativeSegments: [...segments, digest],
        beforeMutation: _verify);
    final name = sourcePath.split(RegExp(r'[/\\]')).last;
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        utf8.encode(name).length > 240 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
      throw const DraftStorageException('附件名称无效');
    }
    final target = appFile('${directory.path}/$name');
    await AccountResourceScope.ensureNoLinks(
        root: _root!, relativeSegments: [...segments, digest, name]);
    _verify();
    final type = await appFileType(target.path, followLinks: false);
    _verify();
    if (type == FileSystemEntityType.notFound) {
      await target.create(exclusive: true);
      _verify();
      await target.writeAsBytes(bytes, flush: true);
      _verify();
    } else if (type != FileSystemEntityType.file ||
        sha256
                .convert(await readFileBytesBounded(target, maxBytes: maxBytes))
                .toString() !=
            digest) {
      throw const DraftStorageException('发送目录冲突');
    }
    _digests[target.path] = digest;
    return target.path;
  }

  Future<AttachmentBatchSnapshot> snapshot(File source, int maxBytes) async {
    _verify();
    final digest = _digests[source.path];
    if (digest == null ||
        await appFileType(source.path, followLinks: false) !=
            FileSystemEntityType.file ||
        !await AccountResourceScope.isCanonicalWithin(source, _directory!)) {
      throw const DraftStorageException('附件不属于本次运行');
    }
    final bytes =
        await readFileBytesBounded(source, maxBytes: maxBytes, label: '发送快照');
    _verify();
    if (await appFileType(source.path, followLinks: false) !=
            FileSystemEntityType.file ||
        sha256.convert(bytes).toString() != digest) {
      throw const DraftStorageException('快照已变化');
    }
    return AttachmentBatchSnapshot(path: source.path, bytes: bytes);
  }

  void publish() {
    _published = true;
  }

  Future<void> release() async {
    _released = true;
    if (_operations == 0) await _cleanup();
  }

  Future<void> _cleanup() async {
    if (_published || _directory == null) return;
    try {
      await AccountResourceScope.ensureNoLinks(root: _root!, relativeSegments: [
        'accounts',
        AccountResourceScope.tokenFor(run.scope.account),
        'generations',
        run.runId
      ]);
      if (await appFileType(_directory!.path, followLinks: false) ==
          FileSystemEntityType.directory) {
        await _directory!
            .delete(recursive: true)
            .timeout(const Duration(seconds: 3));
      }
    } catch (error) {
      cleanupError = error;
    }
  }
}
