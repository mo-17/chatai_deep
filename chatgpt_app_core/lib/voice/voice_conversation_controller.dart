import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';
import 'speech_input.dart';
import 'sentence_speech_queue.dart';
import 'voice_audio_route.dart';

enum VoiceConversationPhase {
  idle,
  preparing,
  listening,
  thinking,
  speaking,
  paused,
  error,
  ended
}

class VoiceTurnContext {
  final bool Function() _current;
  final Future<void> cancelled;
  final void Function(String)? onText;
  VoiceTurnContext(this._current, this.cancelled, {this.onText});
  void emitText(String cumulativeText) {
    if (isCurrent) onText?.call(cumulativeText);
  }

  bool get isCurrent => _current();
}

typedef VoiceSend = Future<String> Function(String text, VoiceTurnContext turn);

class VoiceConversationController extends ChangeNotifier {
  final SpeechInput speech;
  final ReadAloudService voice;
  final VoiceSend send;
  final Future<void> Function() cancelReply;
  final bool Function() isCurrent;
  final String? locale, voiceStyle;
  final double rate;
  final Duration echoDelay, replyTimeout;
  final int maxTurns;
  final bool streamReplies;
  final VoiceAudioRoute? audioRoute;
  bool handsFree = false;
  VoiceConversationController(
      {required this.speech,
      required this.voice,
      required this.send,
      required this.cancelReply,
      required this.isCurrent,
      this.locale,
      this.voiceStyle,
      this.rate = 1,
      this.echoDelay = const Duration(milliseconds: 400),
      this.replyTimeout = const Duration(minutes: 2),
      this.streamReplies = false,
      this.audioRoute,
      this.maxTurns = 20});

  VoiceConversationPhase phase = VoiceConversationPhase.idle;
  String heard = '', reply = '', note = '';
  int _epoch = 0;
  bool _disposed = false;
  bool _releaseFailed = false;
  Completer<void>? _abort;
  Future<void> _cleanup = Future.value();
  bool get active => const {
        VoiceConversationPhase.preparing,
        VoiceConversationPhase.listening,
        VoiceConversationPhase.thinking,
        VoiceConversationPhase.speaking
      }.contains(phase);
  bool _current(int epoch) => !_disposed && _epoch == epoch && isCurrent();
  void _set(VoiceConversationPhase value, [String message = '']) {
    if (_disposed) return;
    phase = value;
    note = message;
    notifyListeners();
  }

  Future<void> start() async {
    if (_disposed || active || phase == VoiceConversationPhase.ended) return;
    final epoch = ++_epoch;
    _abort = Completer<void>();
    final abort = _abort!.future;
    _set(VoiceConversationPhase.preparing);
    await _cleanup;
    if (_releaseFailed) {
      _set(VoiceConversationPhase.error, '语音设备未能释放，请结束此会话后重试');
      return;
    }
    if (!_current(epoch)) {
      if (!_disposed && _epoch == epoch) await pause('会话环境已变化，请重新打开');
      return;
    }
    if (handsFree) {
      final connected = await audioRoute?.prepareHeadset() ?? false;
      if (!_current(epoch)) {
        await audioRoute?.release();
        return;
      }
      if (!connected) {
        handsFree = false;
        note = '未检测到可用耳机，已使用轮流对话';
      }
    }
    unawaited(_run(epoch, abort));
  }

  Future<void> enableHandsFree(bool enable) async {
    if (active || _disposed) return;
    final available = enable && (await audioRoute?.prepareHeadset() ?? false);
    await audioRoute?.release();
    if (_disposed) return;
    handsFree = available;
    note = available
        ? '耳机说话打断已开启，使用系统语音识别'
        : enable
            ? '请连接有线或蓝牙通话耳机；当前设备不支持时可用按钮打断'
            : '';
    notifyListeners();
  }

  Future<T> _wait<T>(Future<T> task, Future<void> abort) =>
      Future.any([task, abort.then<T>((_) => throw const _Cancelled())]);

  Future<void> _cooldown(Future<void> abort) async {
    final done = Completer<void>();
    final timer = Timer(echoDelay, () => done.complete());
    try {
      await _wait(done.future, abort);
    } finally {
      timer.cancel();
    }
  }

  Future<void> _run(int epoch, Future<void> abort) async {
    var silent = 0;
    String? nextInput;
    Timer? routeWatch;
    var checkingRoute = false;
    if (handsFree) {
      routeWatch = Timer.periodic(const Duration(milliseconds: 200), (_) async {
        if (checkingRoute || !_current(epoch)) return;
        checkingRoute = true;
        try {
          if (!(await audioRoute?.headsetStillConnected() ?? false) &&
              _current(epoch)) {
            await pause('耳机已断开，语音已暂停；请确认音频输出后继续');
          }
        } finally {
          checkingRoute = false;
        }
      });
    }
    try {
      for (var turnIndex = 0; turnIndex < maxTurns && _current(epoch);) {
        heard = '';
        _set(VoiceConversationPhase.preparing);
        final text = (nextInput ??
                await _wait<String>(
                    speech.listen(
                        locale: locale,
                        onListening: () {
                          if (_current(epoch)) {
                            _set(VoiceConversationPhase.listening);
                          }
                        },
                        onPartial: (text) {
                          if (_current(epoch)) {
                            heard = text;
                            notifyListeners();
                          }
                        }),
                    abort))
            .trim();
        nextInput = null;
        if (!_current(epoch)) break;
        await _wait(speech.cancel(), abort);
        if (text.isEmpty) {
          if (++silent >= 2) {
            await pause('暂未听到说话，点击继续再试');
            return;
          }
          await _cooldown(abort);
          continue;
        }
        if (text.length > 2000) {
          await pause('本句过长，请改用文字输入');
          return;
        }
        silent = 0;
        heard = text;
        reply = '';
        _set(VoiceConversationPhase.thinking);
        var barged = false, watchDone = false;
        final turnAbort = Completer<void>();
        final turnCancelled = Future.any([abort, turnAbort.future]);
        Future<void>? stopOutput;
        void barge(String partial) {
          if (!_current(epoch) || partial.trim().length < 2) return;
          heard = partial;
          if (!barged) {
            barged = true;
            turnAbort.complete();
            stopOutput =
                Future.wait([voice.stop(), cancelReply()]).then<void>((_) {});
            // 立即挂接异常处理，之后仍 await 原 Future 以报告设备失败。
            unawaited(stopOutput!.catchError((Object _) {}));
          }
          _set(VoiceConversationPhase.listening, '已听到插话，正在接收完整提问');
        }

        Future<String> watch() async {
          while (_current(epoch) && !watchDone) {
            final value = await speech.listen(locale: locale, onPartial: barge);
            if (!_current(epoch)) return '';
            if (value.trim().length >= 2) {
              barge(value);
              return value.trim();
            }
            if (barged) return '';
            await _cooldown(abort);
          }
          return '';
        }

        Future<String>? bargeResult;
        if (handsFree) {
          bargeResult = watch().catchError((Object _) {
            if (_current(epoch) && !barged) {
              handsFree = false;
              note = '系统暂不支持同时收音，本轮可用按钮打断';
              notifyListeners();
            }
            return '';
          });
        }
        final queue = streamReplies
            ? SentenceSpeechQueue(
                voice: voice,
                current: () => _current(epoch) && !barged,
                locale: ReadAloudCoordinator.normalizeLocale(locale),
                rate: ReadAloudCoordinator.normalizeRate(rate),
                voiceStyle: voiceStyle,
                onSentence: () => _set(VoiceConversationPhase.speaking),
                onFailure: () {
                  if (_current(epoch)) {
                    unawaited(pause('分句播报未完成，已停止本轮，请查看聊天记录'));
                  }
                })
            : null;
        try {
          final answer = await _wait(
              send(
                      text,
                      VoiceTurnContext(
                          () => _current(epoch) && !barged, turnCancelled,
                          onText: queue?.update))
                  .timeout(replyTimeout),
              turnCancelled);
          if (!_current(epoch)) break;
          if (answer.trim().isEmpty) {
            throw const SpeechInputFailure('没有可播报的回答，请查看聊天记录后重试');
          }
          reply = answer;
          if (queue != null) {
            await _wait(queue.finish(answer), turnCancelled);
          } else {
            _set(VoiceConversationPhase.speaking);
            await _wait(
                voice.speak(ReadAloudRequest(
                    text: answer,
                    locale: ReadAloudCoordinator.normalizeLocale(locale),
                    rate: ReadAloudCoordinator.normalizeRate(rate),
                    voiceStyle: voiceStyle,
                    throwOnError: true,
                    isCancelled: () => !_current(epoch) || barged)),
                turnCancelled);
          }
        } on _Cancelled {
          if (!barged || !_current(epoch)) rethrow;
        } finally {
          watchDone = true;
          if (!barged && bargeResult != null) await speech.cancel();
        }
        if (barged) {
          await _wait(stopOutput!, abort);
          final heardNext = await _wait<String>(bargeResult!, abort);
          if (heardNext.isEmpty) {
            await pause('已打断，但未收到完整提问；请点击继续');
            return;
          }
          nextInput = heardNext;
        } else if (bargeResult != null) {
          await _wait(bargeResult, abort);
        }
        if (!_current(epoch)) break;
        turnIndex++;
        if (nextInput == null) await _cooldown(abort);
      }
      if (_current(epoch)) await pause('已完成本组对话，点击继续');
    } on _Cancelled {
      return;
    } catch (error) {
      if (!_current(epoch)) return;
      final message = error is SpeechInputFailure
          ? error.message
          : '本轮未完成，请检查聊天记录、网络、额度或语音设置后重试';
      await pause(message);
      if (!_disposed && _epoch == epoch + 1) {
        _set(VoiceConversationPhase.error, message);
      }
    } finally {
      routeWatch?.cancel();
      if (!_disposed && _epoch == epoch && !isCurrent()) {
        await pause('会话环境已变化，语音已暂停');
      }
    }
  }

  Future<void> pause([String message = '已暂停，麦克风已关闭']) {
    if (_disposed) return _cleanup;
    ++_epoch;
    if (_abort?.isCompleted == false) _abort!.complete();
    _set(VoiceConversationPhase.paused, message);
    return _queueCleanup();
  }

  Future<void> _queueCleanup() {
    final previous = _cleanup;
    _cleanup = () async {
      await previous;
      final results = await Future.wait([
        _safely(speech.cancel),
        _safely(voice.stop),
        _safely(cancelReply),
        if (audioRoute != null) _safely(audioRoute!.release)
      ]);
      _releaseFailed = results.any((ok) => !ok);
      if (_releaseFailed &&
          !_disposed &&
          phase == VoiceConversationPhase.paused) {
        _set(VoiceConversationPhase.error, '语音设备未能释放，请结束此会话后重试');
      }
    }();
    return _cleanup;
  }

  Future<bool> _safely(Future<void> Function() action) async {
    try {
      await action();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> interrupt() async {
    final stopping = pause('已打断，准备听你说');
    final epoch = _epoch;
    await stopping;
    if (!_disposed && _epoch == epoch && isCurrent()) await start();
  }

  Future<void> end() {
    final stopping = pause('已结束');
    _set(VoiceConversationPhase.ended, '已结束');
    return stopping;
  }

  @override
  void dispose() {
    ++_epoch;
    if (_abort?.isCompleted == false) _abort!.complete();
    _disposed = true;
    unawaited(_queueCleanup());
    super.dispose();
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}
