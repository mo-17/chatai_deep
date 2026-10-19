import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:chatgpt_app_core/voice/speech_input.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugin.csdcorp.com/speech_to_text');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late SpeechInputBroker broker;
  late SystemSpeechInput a, b;
  Completer<bool>? permission;
  bool failCancel = false;
  setUp(() {
    calls = [];
    permission = null;
    failCancel = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'initialize':
          return permission == null ? true : await permission!.future;
        case 'cancel':
          if (failCancel) {
            throw PlatformException(code: 'synthetic_cancel_failure');
          }
          return null;
        case 'listen':
          return true;
        case 'locales':
          return ['zh_CN:中文', 'en_US:English'];
        default:
          return null;
      }
    });
    broker = SpeechInputBroker(speech: stt.SpeechToText.withMethodChannel());
    a = SystemSpeechInput(broker: broker);
    b = SystemSpeechInput(broker: broker);
  });
  tearDown(() async {
    await a.cancel();
    await b.cancel();
    messenger.setMockMethodCallHandler(channel, null);
  });
  int count(String method) => calls.where((c) => c.method == method).length;
  Future<void> until(bool Function() predicate) async {
    for (var i = 0; i < 80 && !predicate(); i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(predicate(), isTrue);
  }

  Future<void> emit(String method, Object value) async {
    final done = Completer<void>();
    // ignore: deprecated_member_use
    await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, value)),
        (_) => done.complete());
    await done.future;
  }

  Future<void> words(String text, {bool finalResult = true}) => emit(
      'textRecognition',
      jsonEncode({
        'recognizedWords': text,
        'alternates': [
          {'recognizedWords': text, 'confidence': 0.9}
        ],
        'finalResult': finalResult
      }));

  test(
      'final result ends exactly once; notListening cannot prematurely submit partial text',
      () async {
    final partial = <String>[];
    final result = a.listen(locale: 'zh-CN', onPartial: partial.add);
    await until(() => count('listen') == 1);
    await emit('notifyStatus', 'listening');
    await words('半句话', finalResult: false);
    var complete = false;
    result.then((_) => complete = true);
    await emit('notifyStatus', 'notListening');
    expect(complete, isFalse);
    await words('完整一句');
    await emit('notifyStatus', 'done');
    expect(await result, '完整一句');
    expect(partial.last, '完整一句');
    expect(
        (calls.firstWhere((c) => c.method == 'listen').arguments
            as Map)['localeId'],
        'zh_CN');
    expect(count('cancel'), greaterThan(0));
  });
  test(
      'new lease cancels previous; disposed old input cannot cancel new microphone',
      () async {
    final first = a.listen();
    await until(() => count('listen') == 1);
    final second = b.listen();
    await until(() => count('listen') == 2);
    expect(await first, '');
    final before = count('cancel');
    await a.cancel();
    expect(count('cancel'), before);
    await words('新会话');
    expect(await second, '新会话');
    expect(count('initialize'), 1);
    final initialize =
        calls.firstWhere((c) => c.method == 'initialize').arguments as Map;
    expect(initialize['debugLogging'], false);
  });
  test(
      'cancel while waiting for permission cannot start listening after late permission grant',
      () async {
    permission = Completer<bool>();
    final result = a.listen();
    await until(() => count('initialize') == 1);
    final stopping = a.cancel();
    permission!.complete(true);
    await stopping;
    expect(await result, '');
    expect(count('listen'), 0);
  });
  test(
      'failed native cancellation cannot return transcript; original owner can retry release',
      () async {
    final result = a.listen();
    final expected = expectLater(result, throwsA(isA<PlatformException>()));
    await until(() => count('listen') == 1);
    failCancel = true;
    await words('不得在释放失败后发送');
    await expected;
    final before = count('cancel');
    failCancel = false;
    await a.cancel();
    expect(count('cancel'), before + 1);
  });

  test('native recognition error resolves as safe recoverable error', () async {
    final result = a.listen();
    final expected = expectLater(result, throwsA(isA<SpeechInputFailure>()));
    await until(() => count('listen') == 1);
    await emit('notifyError',
        jsonEncode({'errorMsg': 'error_network', 'permanent': false}));
    await expected;
  });
  test(
      'silence status sends empty result and timeout never submits partial transcript',
      () async {
    final result = a.listen();
    await until(() => count('listen') == 1);
    await emit('notifyError',
        jsonEncode({'errorMsg': 'error_no_match', 'permanent': false}));
    expect(await result, '');
    final shortBroker = SpeechInputBroker(
        speech: stt.SpeechToText.withMethodChannel(),
        resultTimeout: const Duration(milliseconds: 20));
    final session = SystemSpeechInput(broker: shortBroker);
    await expectLater(session.listen(), throwsA(isA<SpeechInputFailure>()));
    await session.cancel();
  });
}
