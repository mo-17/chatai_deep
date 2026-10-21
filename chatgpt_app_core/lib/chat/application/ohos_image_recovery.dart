import 'dart:convert';
import 'package:login_sdk/platform/app_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

/// 原生只记录已复制到沙箱的图片；系统尚未返回的选择在重启后需要重新选择。
class OhosImageRecovery {
  const OhosImageRecovery({this.supported});
  final bool Function()? supported;
  bool get isSupported =>
      supported?.call() ?? Platform.operatingSystem == 'ohos';
  static const _channel = MethodChannel('com.hzb.flutter_ai/image_picker');
  static String scopeFor(String accountConversation) =>
      sha256.convert(utf8.encode(accountConversation)).toString();

  static String conversationScope(
          {required String account,
          required int cid,
          required bool persisted,
          int? assistantId,
          int? projectId}) =>
      jsonEncode([
        account,
        persisted ? ['conversation', cid] : ['draft', assistantId, projectId],
      ]);

  Future<String?> begin(String scope, String text, List<String> images) =>
      _channel.invokeMethod<String>('setRecoveryContext', {
        'scope': scopeFor(scope),
        'text': text,
        'images': images,
      });

  Future<Map<String, dynamic>?> retrieve(String scope) =>
      _channel.invokeMapMethod<String, dynamic>(
          'retrieveLostData', {'scope': scopeFor(scope)});

  Future<void> acknowledge(String scope, String id) => _channel
      .invokeMethod<void>('ackRecovery', {'scope': scopeFor(scope), 'id': id});
}
