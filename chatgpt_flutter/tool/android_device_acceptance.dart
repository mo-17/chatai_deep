// 仅供 flutter attach --target=tool/android_device_acceptance.dart 热重启验收。
// 复用正常应用入口、账号与安全存储；不导出密钥，不覆盖用户模型设置。
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ui' as ui;

import 'package:chatgpt_app_core/chat/application/ocr_service.dart';
import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/voice/speech_input.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import 'package:chatgpt_flutter/main.dart' as app;

final _results = <String, Object?>{};
final _speechAttempts = <Map<String, Object?>>[];
final _speech = SystemSpeechInput();
final _tts = FlutterTtsReadAloudService();
String? _busy;
final _speechHint = ValueNotifier('点击开始后，看到“正在收音”再说测试句。');
bool _speechPanelOpen = false;

Future<void> main() async {
  if (!kDebugMode) throw StateError('此入口仅限 debug 真机验收');
  await app.main();
  developer.registerExtension('ext.chatai.deviceAcceptance', (_, args) async {
    try {
      return developer.ServiceExtensionResponse.result(
          jsonEncode(await _command(args)));
    } catch (error) {
      return developer.ServiceExtensionResponse.result(jsonEncode({
        'error': error.runtimeType.toString(),
        if (error is ArgumentError) 'message': error.message,
      }));
    }
  });
}

Future<Map<String, Object?>> _command(Map<String, String> args) async {
  final action = args['action'] ?? 'status';
  if (action == 'status') {
    final account = LoginDao.getAccountHash();
    final settings =
        account == null ? null : await AISettingsDao.loadForAsync(account);
    return {
      'busy': _busy,
      'loggedIn': LoginDao.getBoardingPass() != null,
      'guest': LoginDao.isGuest(),
      'backendOrigin': BackendConfig.buildUri('/').origin,
      'speechAvailable': stt.SpeechToText().isAvailable,
      'speechListening': stt.SpeechToText().isListening,
      'speechLastError': stt.SpeechToText().lastError?.errorMsg,
      'settings': settings == null
          ? null
          : {
              'mode': settings.mode.name,
              'model': settings.effectiveModel,
              'localSelectionValid': settings.localSelectionValid,
              'providers': [
                for (final p in settings.providers.where((p) => p.enabled))
                  {
                    'name': p.name,
                    'model': p.selectedModelId,
                    'keyConfigured': p.apiKey.trim().isNotEmpty,
                  },
              ],
            },
      'results': _results,
      'speechAttempts': _speechAttempts,
    };
  }
  if (action == 'tap') {
    return _tap(args['label'] ?? '');
  }
  if (action == 'fillLogin') {
    return _fillLogin(args['field'] ?? '', args['text'] ?? '');
  }
  if (action == 'fillChatProbe') {
    return _fillLogin('chat', '真机代理验收：请只回复“界面流式测试成功”。');
  }
  if (action == 'submitChatProbe') {
    return _fillLogin('chat', '真机代理验收：请只回复“界面流式测试成功”。', submit: true);
  }
  if (action == 'agreeLogin') {
    final choices = <Checkbox>[];
    void visit(Element element) {
      if (element.widget case Offstage(offstage: true)) return;
      if (element.widget case final Checkbox checkbox) choices.add(checkbox);
      element.visitChildren(visit);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return {'error': 'no_root'};
    visit(root);
    if (choices.length != 1) return {'error': 'ambiguous_agreement'};
    choices.single.onChanged?.call(true);
    return {'agreementChecked': true};
  }
  if (action == 'backendTarget') {
    BackendConfig.host = 'kushui.shop';
    BackendConfig.useHttps = true;
    final response = await http
        .get(BackendConfig.buildUri('/healthz'))
        .timeout(const Duration(seconds: 15));
    return {
      'origin': BackendConfig.buildUri('/').origin,
      'healthStatus': response.statusCode,
    };
  }
  if (action == 'speechPanel') {
    return _showSpeechPanel();
  }
  if (action == 'speechTrace') {
    if (_busy != null) return {'error': 'busy', 'action': _busy};
    if (!stt.SpeechToText().isAvailable) {
      await stt.SpeechToText()
          .initialize(debugLogging: args['enabled'] != 'false');
    }
    final available =
        await const MethodChannel('plugin.csdcorp.com/speech_to_text')
            .invokeMethod<bool>(
                'initialize', {'debugLogging': args['enabled'] != 'false'});
    return {'available': available, 'trace': args['enabled'] != 'false'};
  }
  if (action == 'stop') {
    await _speech.cancel();
    await _tts.stop();
    return {'stopped': true};
  }
  // 照片权限等待不占用麦克风，可独立核对系统朗读；保留相机的原 Future。
  if (action == 'tts' && _busy == 'camera') {
    final result = {'state': 'completed', ...await _speak()};
    _results['tts'] = result;
    return result;
  }
  if (_busy != null) return {'error': 'busy', 'action': _busy};
  final Future<Map<String, Object?>> Function() work;
  switch (action) {
    case 'camera':
      work = _camera;
    case 'speech':
      work = _listen;
    case 'tts':
      work = _speak;
    case 'model':
      work = () => _model(stream: args['stream'] == 'true');
    default:
      throw ArgumentError('不支持的验收动作');
  }
  _busy = action;
  _results[action] = {'state': 'running'};
  if (action == 'speech') _speechHint.value = '正在准备系统识别服务…';
  unawaited(() async {
    try {
      _results[action] = {'state': 'completed', ...await work()};
    } catch (error) {
      _results[action] = {
        'state': 'failed',
        'error': error.runtimeType.toString(),
        if (error is PlatformException) 'code': error.code,
        if (error is SpeechInputFailure) 'message': error.message,
        if (error is ChatTransportException) 'message': error.safeMessage,
        if (error is ChatTransportException) 'code': error.safeCode,
        if (error is ChatTransportException) 'kind': error.failureKind.name,
        if (error is ChatTransportException) 'statusCode': error.statusCode,
      };
    } finally {
      _busy = null;
      if (action == 'speech') {
        final result = _results['speech']! as Map<String, Object?>;
        _speechAttempts.add(Map.of(result));
        if (_speechAttempts.length > 10) _speechAttempts.removeAt(0);
        _speechHint.value = result['state'] == 'failed'
            ? '${result['message'] ?? result['error']}'
            : '已结束：${result['characters'] ?? 0} 字；测试句匹配：${result['matchesTestPhrase'] == true ? '通过' : '未通过'}';
      }
    }
  }());
  return {'started': action};
}

Map<String, Object?> _showSpeechPanel() {
  if (_speechPanelOpen) return {'panel': 'already_open'};
  NavigatorState? navigator;
  void visit(Element element) {
    if (element is StatefulElement && element.state is NavigatorState) {
      navigator ??= element.state as NavigatorState;
    }
    element.visitChildren(visit);
  }

  final root = WidgetsBinding.instance.rootElement;
  if (root == null) return {'error': 'no_root'};
  visit(root);
  if (navigator == null) return {'error': 'no_navigator'};
  _speechPanelOpen = true;
  unawaited(showDialog<void>(
      context: navigator!.context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
            title: const Text('真机语音验收'),
            content: ValueListenableBuilder<String>(
                valueListenable: _speechHint,
                builder: (context, hint, _) => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('测试句：我正在测试语音识别，今天天气很好'),
                        const SizedBox(height: 16),
                        Text(hint),
                        const SizedBox(height: 16),
                        FilledButton(
                            onPressed: _busy == null
                                ? () =>
                                    unawaited(_command({'action': 'speech'}))
                                : null,
                            child: const Text('开始语音测试')),
                      ],
                    )),
            actions: [
              TextButton(
                  onPressed: () async {
                    await _speech.cancel();
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: const Text('关闭验收')),
            ],
          )).whenComplete(() => _speechPanelOpen = false));
  return {'panel': 'opened'};
}

Map<String, Object?> _tap(String label) {
  if (label.isEmpty) throw ArgumentError('需要可见按钮的标签');
  final matches = <RenderBox>[];
  void visit(Element element) {
    if (element.widget case Offstage(offstage: true)) return;
    final widget = element.widget;
    final hit = widget is Text &&
            (widget.data ?? widget.textSpan?.toPlainText()) == label ||
        widget is IconButton && widget.tooltip == label;
    if (hit) {
      final box = element.findRenderObject();
      if (box is RenderBox &&
          box.attached &&
          box.hasSize &&
          !box.size.isEmpty) {
        matches.add(box);
      }
    }
    element.visitChildren(visit);
  }

  final root = WidgetsBinding.instance.rootElement;
  if (root == null) return {'error': 'no_root'};
  visit(root);
  if (matches.length != 1) {
    return {'error': 'ambiguous', 'matches': matches.length};
  }
  final box = matches.single;
  final position = box.localToGlobal(box.size.center(Offset.zero));
  GestureBinding.instance.handlePointerEvent(PointerDownEvent(
      pointer: 71, position: position, kind: ui.PointerDeviceKind.touch));
  GestureBinding.instance.handlePointerEvent(PointerUpEvent(
      pointer: 71, position: position, kind: ui.PointerDeviceKind.touch));
  return {'tapped': label};
}

Map<String, Object?> _fillLogin(String field, String value,
    {bool submit = false}) {
  if (!['email', 'code', 'chat'].contains(field)) {
    throw ArgumentError('仅支持验收字段');
  }
  if (field == 'code' && !RegExp(r'^\d{6}$').hasMatch(value)) {
    throw ArgumentError('验证码需为六位数字');
  }
  final fields = <TextField>[];
  void visit(Element element) {
    if (element.widget case Offstage(offstage: true)) return;
    if (element.widget case final TextField input) {
      if (field == 'email' &&
              input.keyboardType == TextInputType.emailAddress ||
          field == 'code' &&
              input.key == const ValueKey('verification-code-editor') ||
          field == 'chat' && input.decoration?.hintText == '请输入') {
        fields.add(input);
      }
    }
    element.visitChildren(visit);
  }

  final root = WidgetsBinding.instance.rootElement;
  if (root == null) return {'error': 'no_root'};
  visit(root);
  if (fields.length != 1) return {'error': 'ambiguous_field'};
  final input = fields.single;
  if (input.controller == null) return {'error': 'no_controller'};
  input.controller!.value = TextEditingValue(
      text: value, selection: TextSelection.collapsed(offset: value.length));
  input.onChanged?.call(value);
  if (submit) {
    if (input.onSubmitted == null) return {'error': 'no_submit_handler'};
    input.onSubmitted!.call(value);
    return {'submitted': field};
  }
  return {'filled': field};
}

Future<Map<String, Object?>> _camera() async {
  final file = await ImagePicker().pickImage(
      source: ImageSource.camera,
      maxWidth: 2400,
      maxHeight: 2400,
      imageQuality: 85);
  if (file == null) return {'cancelled': true};
  final length = await file.length();
  if (length > 8 * 1024 * 1024) throw StateError('测试照片超过 8 MiB');
  final codec = await ui.instantiateImageCodec(await file.readAsBytes());
  final frame = await codec.getNextFrame();
  try {
    final text = await OcrService.recognizeImageFile(file.path);
    return {
      'bytes': length,
      'width': frame.image.width,
      'height': frame.image.height,
      'ocrCharacters': text.length,
    };
  } finally {
    frame.image.dispose();
    codec.dispose();
  }
}

Future<Map<String, Object?>> _listen() async {
  var partials = 0;
  var listening = false;
  final watch = Stopwatch()..start();
  final text = await _speech.listen(
      locale: 'zh-CN',
      onPartial: (_) {
        partials++;
        _speechHint.value = '正在识别，已收到 $partials 次结果…';
      },
      onListening: () {
        listening = stt.SpeechToText().isListening;
        _results['speech'] = {'state': 'listening'};
        _speechHint.value = '正在收音，请说测试句';
      });
  return {
    'characters': text.length,
    'partialResults': partials,
    'matchesTestPhrase': text.contains('测试') && text.contains('语音'),
    'listeningStarted': listening,
    'milliseconds': watch.elapsedMilliseconds,
  };
}

Future<Map<String, Object?>> _speak() async {
  final stages = <String>[];
  await _tts
      .speak(ReadAloudRequest(
          text: '这是真机语音播放测试。相机和语音测试正在进行。',
          locale: 'zh-CN',
          throwOnError: true,
          onStage: (stage) => stages.add(stage.name)))
      .timeout(const Duration(seconds: 30), onTimeout: () async {
    await _tts.stop();
    throw TimeoutException('系统朗读未在 30 秒内完成');
  });
  return {'stages': stages, 'engineCompleted': true};
}

Future<Map<String, Object?>> _model({required bool stream}) async {
  final account = LoginDao.getAccountHash();
  if (account == null) return {'blocked': 'login_required'};
  final settings = (await AISettingsDao.loadForAsync(account)).clone();
  if (settings.mode == AIMode.local &&
      (!settings.localSelectionValid ||
          settings.activeProvider.apiKey.trim().isEmpty)) {
    return {'blocked': 'configure_local_provider_first'};
  }
  if (settings.mode == AIMode.backend && LoginDao.isGuest()) {
    return {'blocked': 'backend_requires_account_login'};
  }
  settings.maxOutputTokens = 128;
  final service = ChatService.from(settings);
  final cancelled = Completer<void>();
  final deadline = Timer(const Duration(seconds: 45), cancelled.complete);
  final options = ChatRequestOptions(
      abortTrigger: cancelled.future,
      reasoningPolicy: ChatReasoningPolicy.offIfSupported,
      nonStreamingTimeout: const Duration(seconds: 40),
      maxOutputTokensOverride: 256,
      maxAutoRetries: 0);
  const prompt = '请只回复一句：真机模型连通测试成功。';
  final watch = Stopwatch()..start();
  try {
    if (!stream) {
      final result = await service.chatWithUsageWithOptions(
          prompt: prompt, history: const [], options: options);
      return {
        'stream': false,
        'model': settings.effectiveModel,
        'reply': result.content,
        'promptTokens': result.promptTokens,
        'completionTokens': result.completionTokens,
        'estimated': result.estimated,
        'milliseconds': watch.elapsedMilliseconds,
      };
    }
    final text = StringBuffer();
    var chunks = 0;
    int? promptTokens, completionTokens;
    await for (final event in service.chatStreamEventsWithOptions(
        prompt: prompt, history: const [], options: options)) {
      if (event.type == StreamEventType.text) {
        chunks++;
        text.write(event.delta);
      } else if (event.type == StreamEventType.usage) {
        promptTokens = event.promptTokens;
        completionTokens = event.completionTokens;
      }
    }
    return {
      'stream': true,
      'model': settings.effectiveModel,
      'reply': text.toString(),
      'textChunks': chunks,
      'promptTokens': promptTokens,
      'completionTokens': completionTokens,
      'milliseconds': watch.elapsedMilliseconds,
    };
  } finally {
    deadline.cancel();
    if (!cancelled.isCompleted) cancelled.complete();
  }
}
