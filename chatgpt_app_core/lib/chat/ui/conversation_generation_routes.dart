import 'package:flutter/widgets.dart';

/// 路由变化只影响可见确认主机；不会停止应用级普通生成。
final class ConversationGenerationRoutes extends NavigatorObserver {
  static final instance = ConversationGenerationRoutes();
  final changes = _RouteChanges();
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      changes.changed();
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      changes.changed();
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      changes.changed();
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      changes.changed();
}

final class _RouteChanges extends ChangeNotifier {
  void changed() => notifyListeners();
}
