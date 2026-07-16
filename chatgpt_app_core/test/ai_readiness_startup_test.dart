import 'package:chatgpt_app_core/ai_readiness/ai_readiness_startup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('readiness 严格排在设置加载与 guest migration 完成之后', () async {
    final events = <String>[];

    final initialized = await initializeAIReadinessAfterGuestMigration(
      loadSettings: () async => events.add('settings'),
      settleGuestMigration: () async {
        events.add('migration');
        return true;
      },
      initializeReadiness: () async => events.add('readiness'),
    );

    expect(initialized, isTrue);
    expect(events, ['settings', 'migration', 'readiness']);
  });

  test('guest migration 未完成时不初始化 readiness', () async {
    final events = <String>[];

    final initialized = await initializeAIReadinessAfterGuestMigration(
      loadSettings: () async => events.add('settings'),
      settleGuestMigration: () async {
        events.add('migration-failed');
        return false;
      },
      initializeReadiness: () async => events.add('readiness'),
    );

    expect(initialized, isFalse);
    expect(events, ['settings', 'migration-failed']);
  });

  test('页面在任一步骤后销毁时停止后续初始化', () async {
    final events = <String>[];
    var active = true;

    final initialized = await initializeAIReadinessAfterGuestMigration(
      loadSettings: () async {
        events.add('settings');
        active = false;
      },
      settleGuestMigration: () async {
        events.add('migration');
        return true;
      },
      initializeReadiness: () async => events.add('readiness'),
      canContinue: () => active,
    );

    expect(initialized, isFalse);
    expect(events, ['settings']);
  });
}
