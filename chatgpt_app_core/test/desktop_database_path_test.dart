import 'dart:io';

import 'package:chatgpt_app_core/db/desktop_database_path.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temporary, support, legacy;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('desktop_db_test');
    support = Directory('${temporary.path}/user-data');
    legacy = Directory('${temporary.path}/old-working-directory');
  });
  tearDown(() => temporary.delete(recursive: true));

  test('新库写入用户目录，账号之间保持独立', () async {
    final first = await resolveDesktopDatabasePath('guest.db',
        supportDirectory: support, legacyDirectory: legacy);
    final second = await resolveDesktopDatabasePath('user.db',
        supportDirectory: support, legacyDirectory: legacy);
    expect(first, File('${support.path}/databases/guest.db').absolute.path);
    expect(second, File('${support.path}/databases/user.db').absolute.path);
    expect(await Directory('${support.path}/databases').exists(), isTrue);
    expect(await legacy.exists(), isFalse);
  });

  test('旧库继续使用原路径与内容', () async {
    await legacy.create();
    final old = await File('${legacy.path}/guest.db').writeAsString('existing');
    final result = await resolveDesktopDatabasePath('guest.db',
        supportDirectory: support, legacyDirectory: legacy);
    expect(result, old.absolute.path);
    expect(await old.readAsString(), 'existing');
    expect(await support.exists(), isFalse);
  });

  test('拒绝数据库名中注入路径', () async {
    for (final name in ['../guest.db', r'..\guest.db', 'C:guest.db', '']) {
      await expectLater(
          resolveDesktopDatabasePath(name,
              supportDirectory: support, legacyDirectory: legacy),
          throwsArgumentError);
    }
  });

  test('已在用户目录使用的新库优先于遗留副本', () async {
    final target = File(await resolveDesktopDatabasePath('guest.db',
        supportDirectory: support, legacyDirectory: legacy));
    await target.writeAsString('current');
    await legacy.create();
    await File('${legacy.path}/guest.db').writeAsString('old');
    expect(
        await resolveDesktopDatabasePath('guest.db',
            supportDirectory: support, legacyDirectory: legacy),
        target.path);
    expect(await target.readAsString(), 'current');
  });
}
