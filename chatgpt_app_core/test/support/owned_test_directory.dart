import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 常规回归自建隔离目录；显式验收环境仍校验原来的所有权标记。
/// 在 main 中先注册，清理会在该文件其余 tearDownAll 完成后执行。
class OwnedTestDirectory {
  late Directory directory;
  bool _created = false;

  OwnedTestDirectory({
    required String rootKey,
    required String nonceKey,
    required String legacyPrefix,
  }) {
    setUpAll(() {
      final root = Platform.environment[rootKey];
      final nonce = Platform.environment[nonceKey];
      if (root != null || nonce != null) {
        expect(nonce, isNotNull, reason: '显式验收目录必须提供 nonce');
        expect(root, '$legacyPrefix$nonce');
        directory = Directory(root!);
        expect(
          jsonDecode(File('${directory.path}/fixture-sentinel.json')
              .readAsStringSync()),
          {'nonce': nonce},
        );
        return;
      }
      directory = Directory.systemTemp.createTempSync('chatai-regression-');
      _created = true;
    });
    tearDownAll(() {
      if (_created && directory.existsSync()) {
        directory.deleteSync(recursive: true);
      }
    });
  }
}
