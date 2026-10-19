import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

abstract interface class SpeechInput {
  Future<String> listen(
      {String? locale,
      void Function(String)? onPartial,
      VoidCallback? onListening});
  Future<void> cancel();
}

class SpeechInputFailure implements Exception {
  final String message;
  const SpeechInputFailure(this.message);
}

bool get continuousSpeechSupported =>
    (Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.operatingSystem == 'ohos') &&
    !brokenIosSpeechSimulator;

bool get brokenIosSpeechSimulator {
  if (!Platform.isIOS ||
      !Platform.environment.containsKey('SIMULATOR_DEVICE_NAME')) {
    return false;
  }
  final match = RegExp(r'Version (\d+)\.(\d+)')
      .firstMatch(Platform.operatingSystemVersion);
  return match != null &&
      int.parse(match[1]!) == 17 &&
      int.parse(match[2]!) < 5;
}

String? pickSpeechLocaleId(List<stt.LocaleName> locales,
    {String? preferredLocale, String? systemLocale}) {
  String? normalize(String? value) => value == null || value.trim().isEmpty
      ? null
      : value.trim().replaceAll('-', '_').toLowerCase();
  final ids =
      locales.map((l) => l.localeId.trim()).where((s) => s.isNotEmpty).toList();
  if (ids.isEmpty) return null;
  final preferred = normalize(preferredLocale) ??
      normalize(systemLocale) ??
      normalize(Platform.localeName);
  for (final id in ids) {
    if (normalize(id) == preferred) return id;
  }
  for (final id in ids) {
    if (normalize(id)?.split('_').first == preferred?.split('_').first) {
      return id;
    }
  }
  return ids.first;
}

class _Result {
  final String text;
  final String? error;
  const _Result(this.text, [this.error]);
}

class _Lease {
  final Object owner;
  final result = Completer<_Result>();
  _Lease(this.owner);
  void finish(_Result value) {
    if (!result.isCompleted) result.complete(value);
  }
}

/// speech_to_text 是进程单例，initialize 成功后不会更新回调；所有输入入口共用租约。
class SpeechInputBroker {
  static final instance = SpeechInputBroker();
  final stt.SpeechToText _speech;
  final Duration resultTimeout;
  Future<void> _tail = Future.value();
  _Lease? _active;
  Object? _cancelOwner;
  SpeechInputBroker(
      {stt.SpeechToText? speech,
      this.resultTimeout = const Duration(seconds: 25)})
      : _speech = speech ?? stt.SpeechToText();

  Future<void> _serial(Future<void> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  bool _current(_Lease lease) =>
      identical(_active, lease) && !lease.result.isCompleted;

  Future<String> listen(Object owner,
      {String? locale,
      void Function(String)? onPartial,
      VoidCallback? onListening}) async {
    _active?.finish(const _Result(''));
    final lease = _Lease(owner);
    _active = lease;
    final deadline = Timer(resultTimeout, () {
      if (_current(lease)) lease.finish(const _Result('', '未收到完整识别结果，请重试'));
    });
    unawaited(_serial(() async {
      if (_speech.isAvailable) await _speech.cancel();
      _cancelOwner = null;
      if (!_current(lease)) return;
      if (brokenIosSpeechSimulator) {
        lease.finish(const _Result('', '当前设备暂不支持语音识别'));
        return;
      }
      final available = await _speech.initialize(debugLogging: false);
      if (!_current(lease)) return;
      if (!available) {
        lease.finish(const _Result('', '请开启麦克风和语音识别权限，并确认系统识别服务可用'));
        return;
      }
      // 显式换绑当前租约，兼容插件 initialize 的一次性回调语义。
      _speech.errorListener = (error) {
        if (!_current(lease)) return;
        if (['error_no_match', 'error_speech_timeout']
            .contains(error.errorMsg)) {
          lease.finish(const _Result(''));
        } else {
          lease.finish(const _Result('', '语音识别失败，请检查权限、网络及识别语言后重试'));
        }
      };
      _speech.statusListener = (status) {
        // notListening 可能先于最终结果；只接收插件保证结算后的 done。
        if (_current(lease) && status == stt.SpeechToText.doneStatus) {
          lease.finish(const _Result(''));
        }
      };
      final locales = await _speech.locales();
      if (!_current(lease)) return;
      await _speech.listen(
        localeId: pickSpeechLocaleId(locales, preferredLocale: locale),
        listenFor: const Duration(seconds: 20),
        pauseFor: const Duration(seconds: 2),
        listenOptions: stt.SpeechListenOptions(
            partialResults: true,
            cancelOnError: true,
            listenMode: stt.ListenMode.dictation),
        onResult: (result) {
          if (!_current(lease)) return;
          onPartial?.call(result.recognizedWords);
          if (result.finalResult) {
            lease.finish(_Result(result.recognizedWords.trim()));
          }
        },
      );
      if (_current(lease)) onListening?.call();
    }).catchError((Object _, StackTrace __) {
      if (_current(lease)) {
        lease.finish(const _Result('', '语音服务未能启动，请重试或使用文字输入'));
      }
    }));
    try {
      final result = await lease.result.future;
      if (result.error != null) throw SpeechInputFailure(result.error!);
      return result.text;
    } finally {
      deadline.cancel();
      if (identical(_active, lease)) await cancel(owner);
    }
  }

  Future<void> cancel(Object owner) {
    if (_active?.owner == owner) {
      _active!.finish(const _Result(''));
      _active = null;
    } else if (_active != null || _cancelOwner != owner) {
      return Future.value();
    }
    _cancelOwner = owner;
    return _serial(() async {
      // 新租约的 start 在本 cancel 后排队，不会取消后来才开始的录音。
      if (_speech.isAvailable) await _speech.cancel();
      if (_cancelOwner == owner) _cancelOwner = null;
    });
  }
}

class SystemSpeechInput implements SpeechInput {
  final SpeechInputBroker _broker;
  final Object _owner = Object();
  SystemSpeechInput({SpeechInputBroker? broker})
      : _broker = broker ?? SpeechInputBroker.instance;
  @override
  Future<String> listen(
          {String? locale,
          void Function(String)? onPartial,
          VoidCallback? onListening}) =>
      _broker.listen(_owner,
          locale: locale, onPartial: onPartial, onListening: onListening);
  @override
  Future<void> cancel() => _broker.cancel(_owner);
}
