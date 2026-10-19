import 'dart:async';
import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';

/// 只播放已完成的句子；模型流继续产生文字时串行合成，取消代次后不再播放。
class SentenceSpeechQueue {
  final ReadAloudService voice;
  final bool Function() current;
  final void Function() onSentence;
  final void Function() onFailure;
  final String? locale, voiceStyle;
  final double rate;
  Future<void> _tail = Future.value();
  String _seen = '', _pending = '';
  bool _fenced = false, _failed = false;
  SentenceSpeechQueue(
      {required this.voice,
      required this.current,
      required this.onSentence,
      required this.onFailure,
      this.locale,
      this.voiceStyle,
      this.rate = 1});
  void update(String fullText, {bool finalText = false}) {
    if (!current() || _failed) return;
    if (!fullText.startsWith(_seen) || fullText.length > 24000) {
      _fail();
      return;
    }
    _pending += fullText.substring(_seen.length);
    _seen = fullText;
    while (_pending.isNotEmpty) {
      final end = _pending.indexOf(
          RegExp(finalText ? r'[。！？!?\n]|\.(?:\s|$)' : r'[。！？!?\n]|\.\s'));
      if (end < 0 && !finalText && _pending.length < 250) break;
      var take = end >= 0
          ? end + 1
          : finalText
              ? _pending.length
              : 250;
      if (end < 0 && !finalText) {
        while (take > 0 && _pending[take - 1] == '`') {
          take--;
        }
        if (take == 0) break;
      }
      final chunk = _pending.substring(0, take);
      _pending = _pending.substring(take);
      // 完整围栏中的代码不口播。围栏跨 SSE 分片由 pending 累积处理。
      final pieces = chunk.split('```');
      final spoken = StringBuffer();
      for (var i = 0; i < pieces.length; i++) {
        if (!_fenced) spoken.write(pieces[i]);
        if (i < pieces.length - 1) _fenced = !_fenced;
      }
      final text =
          spoken.toString().replaceAll(RegExp(r'[*#`]|\[[0-9]+\]'), '').trim();
      if (text.isEmpty) continue;
      _tail = _tail.then((_) async {
        if (!current() || _failed) return;
        onSentence();
        await voice.speak(ReadAloudRequest(
            text: text,
            locale: locale,
            rate: rate,
            voiceStyle: voiceStyle,
            throwOnError: true,
            isCancelled: () => !current()));
      }).catchError((Object _, StackTrace __) {
        _fail();
      });
    }
  }

  void _fail() {
    if (_failed) return;
    _failed = true;
    onFailure();
  }

  Future<void> finish(String fullText) async {
    update(fullText, finalText: true);
    await _tail;
    if (_failed) throw StateError('sentence speech failed');
  }
}
