import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// App 的视觉风格。它与系统明暗模式、经典主题强调色彼此独立。
enum AppVisualStyle {
  classic,
  anime;

  String get storageValue => name;

  static AppVisualStyle fromStorage(Object? value) {
    return AppVisualStyle.values.firstWhere(
      (style) => style.storageValue == value,
      orElse: () => AppVisualStyle.classic,
    );
  }
}

/// 页面需要感知的视觉 token。
///
/// 常规组件优先依赖 [ThemeData]；只有装饰性背景、圆角等风格特征才读取本扩展，
/// 这样经典风格可以继续保持历史行为。
@immutable
class AppVisualTheme extends ThemeExtension<AppVisualTheme> {
  final AppVisualStyle style;
  final Color glowPrimary;
  final Color glowSecondary;
  final Color elevatedSurface;
  final double cardRadius;
  final Duration motionDuration;

  const AppVisualTheme({
    required this.style,
    required this.glowPrimary,
    required this.glowSecondary,
    required this.elevatedSurface,
    required this.cardRadius,
    required this.motionDuration,
  });

  static const classic = AppVisualTheme(
    style: AppVisualStyle.classic,
    glowPrimary: Colors.transparent,
    glowSecondary: Colors.transparent,
    elevatedSurface: Colors.white,
    cardRadius: 4,
    motionDuration: Duration(milliseconds: 200),
  );

  static const anime = AppVisualTheme(
    style: AppVisualStyle.anime,
    glowPrimary: Color(0x337C3AED),
    glowSecondary: Color(0x33BE185D),
    elevatedSurface: Color(0xFFFFFBFE),
    cardRadius: 20,
    motionDuration: Duration(milliseconds: 220),
  );

  bool get isAnime => style == AppVisualStyle.anime;

  static AppVisualTheme of(BuildContext context) {
    return Theme.of(context).extension<AppVisualTheme>() ?? classic;
  }

  /// 尊重系统的“减少动态效果”设置，页面动画统一从这里取时长。
  static Duration motionDurationOf(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return Duration.zero;
    return of(context).motionDuration;
  }

  @override
  AppVisualTheme copyWith({
    AppVisualStyle? style,
    Color? glowPrimary,
    Color? glowSecondary,
    Color? elevatedSurface,
    double? cardRadius,
    Duration? motionDuration,
  }) {
    return AppVisualTheme(
      style: style ?? this.style,
      glowPrimary: glowPrimary ?? this.glowPrimary,
      glowSecondary: glowSecondary ?? this.glowSecondary,
      elevatedSurface: elevatedSurface ?? this.elevatedSurface,
      cardRadius: cardRadius ?? this.cardRadius,
      motionDuration: motionDuration ?? this.motionDuration,
    );
  }

  @override
  AppVisualTheme lerp(ThemeExtension<AppVisualTheme>? other, double t) {
    if (other is! AppVisualTheme) return this;
    return AppVisualTheme(
      style: t < 0.5 ? style : other.style,
      glowPrimary: Color.lerp(glowPrimary, other.glowPrimary, t)!,
      glowSecondary: Color.lerp(glowSecondary, other.glowSecondary, t)!,
      elevatedSurface: Color.lerp(elevatedSurface, other.elevatedSurface, t)!,
      cardRadius: cardRadius + (other.cardRadius - cardRadius) * t,
      motionDuration: Duration(
        milliseconds: (motionDuration.inMilliseconds +
                (other.motionDuration.inMilliseconds -
                        motionDuration.inMilliseconds) *
                    t)
            .round(),
      ),
    );
  }
}

/// 业务状态色的统一入口，避免页面继续散落 red/green/orange 等裸色值。
enum AppStatusKind { success, warning, info, error, neutral }

@immutable
class AppStatusPalette {
  final Color foreground;
  final Color container;
  final Color onContainer;

  const AppStatusPalette({
    required this.foreground,
    required this.container,
    required this.onContainer,
  });

  static AppStatusPalette of(BuildContext context, AppStatusKind kind) {
    final scheme = Theme.of(context).colorScheme;
    final isAnime = AppVisualTheme.of(context).isAnime;
    if (!isAnime) {
      return switch (kind) {
        AppStatusKind.success => const AppStatusPalette(
            foreground: Color(0xFF2E7D32),
            container: Color(0xFFE8F5E9),
            onContainer: Color(0xFF1B5E20),
          ),
        AppStatusKind.warning => const AppStatusPalette(
            foreground: Color(0xFFEF6C00),
            container: Color(0xFFFFF3E0),
            onContainer: Color(0xFFE65100),
          ),
        AppStatusKind.info => const AppStatusPalette(
            foreground: Color(0xFF455A64),
            container: Color(0xFFECEFF1),
            onContainer: Color(0xFF263238),
          ),
        AppStatusKind.error => const AppStatusPalette(
            foreground: Color(0xFFD32F2F),
            container: Color(0xFFFFEBEE),
            onContainer: Color(0xFFB71C1C),
          ),
        AppStatusKind.neutral => AppStatusPalette(
            foreground: scheme.onSurfaceVariant,
            container: scheme.surfaceContainerHighest,
            onContainer: scheme.onSurface,
          ),
      };
    }
    return switch (kind) {
      AppStatusKind.success => const AppStatusPalette(
          foreground: Color(0xFF166534),
          container: Color(0xFFDCFCE7),
          onContainer: Color(0xFF14532D),
        ),
      AppStatusKind.warning => const AppStatusPalette(
          foreground: Color(0xFF9A3412),
          container: Color(0xFFFFEDD5),
          onContainer: Color(0xFF7C2D12),
        ),
      AppStatusKind.info => AppStatusPalette(
          foreground: scheme.tertiary,
          container: scheme.tertiaryContainer,
          onContainer: scheme.onTertiaryContainer,
        ),
      AppStatusKind.error => AppStatusPalette(
          foreground: scheme.error,
          container: scheme.errorContainer,
          onContainer: scheme.onErrorContainer,
        ),
      AppStatusKind.neutral => AppStatusPalette(
          foreground: scheme.onSurfaceVariant,
          container: scheme.surfaceContainerHighest,
          onContainer: scheme.onSurface,
        ),
    };
  }
}

/// 二次元模式在 Android/桌面使用纯水平翻页。
///
/// 新页面携带自己的全不透明 [AppAnimeRouteSurface] 从屏幕外滑入；底页保持
/// 静止，且不使用 Fade、Scale、Opacity 或 secondary animation。这样既避开
/// 默认 Zoom snapshot，也不会让两个透明 Scaffold 在重叠区域发生混色。
class AppAnimePageTransitionsBuilder extends PageTransitionsBuilder {
  const AppAnimePageTransitionsBuilder();

  static const enterDuration = Duration(milliseconds: 240);
  static const exitDuration = Duration(milliseconds: 200);

  @override
  Duration get transitionDuration => enterDuration;

  @override
  Duration get reverseTransitionDuration => exitDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final page = AppAnimeRouteSurface(child: child);
    if (MediaQuery.disableAnimationsOf(context)) {
      return page;
    }
    return _AnimeRouteSlideTransition(
      animation: animation,
      child: page,
    );
  }
}

class _AnimeRouteSlideTransition extends StatefulWidget {
  final Animation<double> animation;
  final Widget child;

  const _AnimeRouteSlideTransition({
    required this.animation,
    required this.child,
  });

  @override
  State<_AnimeRouteSlideTransition> createState() =>
      _AnimeRouteSlideTransitionState();
}

class _AnimeRouteSlideTransitionState
    extends State<_AnimeRouteSlideTransition> {
  late CurvedAnimation _curvedAnimation;
  late Animation<Offset> _position;

  @override
  void initState() {
    super.initState();
    _createAnimations();
  }

  @override
  void didUpdateWidget(covariant _AnimeRouteSlideTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      _curvedAnimation.dispose();
      _createAnimations();
    }
  }

  void _createAnimations() {
    _curvedAnimation = CurvedAnimation(
      parent: widget.animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _position = Tween<Offset>(
      begin: const Offset(1, 0),
      end: Offset.zero,
    ).animate(_curvedAnimation);
  }

  @override
  void dispose() {
    _curvedAnimation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      key: const ValueKey('anime_page_transition'),
      position: _position,
      textDirection: Directionality.of(context),
      child: widget.child,
    );
  }
}

/// iOS/macOS 完整继承 Cupertino 的原生时长、边缘返回手势、取消手势和
/// delegated transition；这里只给路由内容补上全不透明二次元背景。
class AppAnimeCupertinoPageTransitionsBuilder
    extends CupertinoPageTransitionsBuilder {
  const AppAnimeCupertinoPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return super.buildTransitions(
      route,
      context,
      animation,
      secondaryAnimation,
      AppAnimeRouteSurface(child: child),
    );
  }
}

abstract final class AppThemeFactory {
  static const animePrimary = Color(0xFF6D28D9);
  static const animeSecondary = Color(0xFFBE185D);
  static const animeTertiary = Color(0xFF2563EB);
  static const animeBackground = Color(0xFFFAF5FF);
  static const animeForeground = Color(0xFF1E1B2E);

  /// 经典主题必须保持原 ThemeData 构造方式，确保用户能真正切回旧外观。
  static ThemeData classic(MaterialColor color) {
    return ThemeData(primarySwatch: color).copyWith(
      extensions: const <ThemeExtension<dynamic>>[AppVisualTheme.classic],
    );
  }

  static ThemeData anime() {
    final scheme = ColorScheme.fromSeed(
      seedColor: animePrimary,
      brightness: Brightness.light,
    ).copyWith(
      primary: animePrimary,
      onPrimary: Colors.white,
      primaryContainer: const Color(0xFFEDE9FE),
      onPrimaryContainer: const Color(0xFF2E1065),
      secondary: animeSecondary,
      onSecondary: Colors.white,
      secondaryContainer: const Color(0xFFFCE7F3),
      onSecondaryContainer: const Color(0xFF500724),
      tertiary: animeTertiary,
      onTertiary: Colors.white,
      tertiaryContainer: const Color(0xFFDBEAFE),
      onTertiaryContainer: const Color(0xFF172554),
      surface: const Color(0xFFFFFBFE),
      onSurface: animeForeground,
      onSurfaceVariant: const Color(0xFF514A63),
      outline: const Color(0xFF786F85),
      outlineVariant: const Color(0xFFE7DFF1),
      error: const Color(0xFFB91C1C),
      onError: Colors.white,
      errorContainer: const Color(0xFFFEE2E2),
      onErrorContainer: const Color(0xFF450A0A),
      surfaceTint: animePrimary,
    );

    final typography = Typography.material2021(
      platform: defaultTargetPlatform,
      colorScheme: scheme,
    );
    final resolvedTextTheme = typography.englishLike.merge(typography.black);
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // 每个路由由 [AppAnimeRouteSurface] 提供独立背景。
      scaffoldBackgroundColor: Colors.transparent,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      typography: typography,
    );
    final textTheme = resolvedTextTheme.copyWith(
      headlineSmall: resolvedTextTheme.headlineSmall?.copyWith(
        color: animeForeground,
        fontWeight: FontWeight.w700,
      ),
      titleLarge: resolvedTextTheme.titleLarge?.copyWith(
        color: animeForeground,
        fontWeight: FontWeight.w700,
      ),
      titleMedium: resolvedTextTheme.titleMedium?.copyWith(
        color: animeForeground,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: resolvedTextTheme.bodyLarge?.copyWith(
        color: animeForeground,
        height: 1.5,
      ),
      bodyMedium: resolvedTextTheme.bodyMedium?.copyWith(
        color: animeForeground,
        height: 1.5,
      ),
    );
    final roundedRectangle = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
    );

    return base.copyWith(
      textTheme: textTheme,
      // Android/桌面避免默认 Zoom snapshot 的整页缩放；iOS/macOS 保留原生
      // Cupertino 转场及侧滑返回手势。
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: AppAnimePageTransitionsBuilder(),
          TargetPlatform.fuchsia: AppAnimePageTransitionsBuilder(),
          TargetPlatform.windows: AppAnimePageTransitionsBuilder(),
          TargetPlatform.linux: AppAnimePageTransitionsBuilder(),
          TargetPlatform.iOS: AppAnimeCupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: AppAnimeCupertinoPageTransitionsBuilder(),
        },
      ),
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 1,
        toolbarHeight: 60,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: textTheme.titleLarge,
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shadowColor: animePrimary.withValues(alpha: 0.12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppVisualTheme.anime.cardRadius),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: scheme.surface,
        selectedItemColor: scheme.primary,
        unselectedItemColor: scheme.onSurfaceVariant,
        selectedLabelStyle:
            resolvedTextTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700),
        unselectedLabelStyle:
            resolvedTextTheme.labelSmall?.copyWith(fontWeight: FontWeight.w500),
        type: BottomNavigationBarType.fixed,
        elevation: 12,
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 72,
        elevation: 0,
        backgroundColor: scheme.surface,
        indicatorColor: scheme.secondaryContainer,
        indicatorShape: const StadiumBorder(),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          return IconThemeData(
            color: states.contains(WidgetState.selected)
                ? scheme.secondary
                : scheme.onSurfaceVariant,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          return resolvedTextTheme.labelMedium?.copyWith(
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurfaceVariant,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
          );
        }),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.secondaryContainer,
        foregroundColor: scheme.secondary,
        elevation: 3,
        focusElevation: 4,
        hoverElevation: 4,
        highlightElevation: 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      searchBarTheme: SearchBarThemeData(
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: WidgetStatePropertyAll(scheme.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        side: WidgetStatePropertyAll(
          BorderSide(color: scheme.outlineVariant),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 16),
        ),
        textStyle: WidgetStatePropertyAll(resolvedTextTheme.bodyLarge),
        hintStyle: WidgetStatePropertyAll(
          resolvedTextTheme.bodyLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        constraints: const BoxConstraints(minHeight: 52),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(48, 44)),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.selected)
                ? scheme.onPrimaryContainer
                : scheme.onSurfaceVariant;
          }),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.selected)
                ? scheme.primaryContainer
                : scheme.surface;
          }),
          side: WidgetStatePropertyAll(
            BorderSide(color: scheme.outlineVariant),
          ),
          shape: const WidgetStatePropertyAll(StadiumBorder()),
          textStyle: WidgetStatePropertyAll(
            resolvedTextTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        selectedIcon: Icon(Icons.check_rounded, color: scheme.primary),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      expansionTileTheme: ExpansionTileThemeData(
        iconColor: scheme.primary,
        collapsedIconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
        collapsedTextColor: scheme.onSurface,
        backgroundColor: scheme.surface.withValues(alpha: 0.72),
        collapsedBackgroundColor: scheme.surface.withValues(alpha: 0.72),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        collapsedShape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: scheme.primary,
        unselectedLabelColor: scheme.onSurfaceVariant,
        indicatorColor: scheme.secondary,
        dividerColor: scheme.outlineVariant,
        labelStyle: resolvedTextTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelStyle: resolvedTextTheme.labelLarge,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.primaryContainer,
        circularTrackColor: scheme.primaryContainer,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFF7F3FD),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: roundedRectangle,
          textStyle: resolvedTextTheme.labelLarge
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(48, 48),
          elevation: 0,
          shape: roundedRectangle,
          textStyle: resolvedTextTheme.labelLarge
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: roundedRectangle,
          side: BorderSide(color: scheme.outline),
          textStyle: resolvedTextTheme.labelLarge
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: resolvedTextTheme.labelLarge
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: const CircleBorder(),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: scheme.surface,
        selectedColor: scheme.primaryContainer,
        secondarySelectedColor: scheme.secondaryContainer,
        side: BorderSide(color: scheme.outlineVariant),
        shape: const StadiumBorder(),
        labelStyle: resolvedTextTheme.labelLarge?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        secondaryLabelStyle: resolvedTextTheme.labelLarge?.copyWith(
          color: scheme.onPrimaryContainer,
          fontWeight: FontWeight.w700,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected)
              ? scheme.onPrimary
              : scheme.outline;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.surfaceContainerHighest;
        }),
      ),
      checkboxTheme: CheckboxThemeData(
        checkColor: WidgetStatePropertyAll(scheme.onPrimary),
        fillColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected)
              ? scheme.primary
              : Colors.transparent;
        }),
        side: BorderSide(color: scheme.outline, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.outline;
        }),
      ),
      sliderTheme: base.sliderTheme.copyWith(
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.primaryContainer,
        thumbColor: scheme.primary,
        overlayColor: scheme.primary.withValues(alpha: 0.12),
        valueIndicatorColor: scheme.inverseSurface,
        valueIndicatorTextStyle: resolvedTextTheme.labelMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.primary,
        minTileHeight: 56,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: resolvedTextTheme.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(10),
        ),
        textStyle: resolvedTextTheme.bodySmall?.copyWith(
          color: scheme.onInverseSurface,
        ),
        waitDuration: const Duration(milliseconds: 450),
      ),
      extensions: const <ThemeExtension<dynamic>>[AppVisualTheme.anime],
    );
  }
}

/// 二次元页面自己的全屏、全不透明氛围背景。
///
/// 它必须位于 route transition 的 child 内，让滑动中的新页面从背景到内容都
/// 是一张不透明表面。[_ModalScope] 已为页面提供 RepaintBoundary，这里不再
/// 叠加额外缓存层。
class AppAnimeRouteSurface extends StatelessWidget {
  final Widget child;

  const AppAnimeRouteSurface({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final visualTheme = AppVisualTheme.of(context);
    if (!visualTheme.isAnime) return child;
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox.expand(
      child: DecoratedBox(
        key: const ValueKey('anime_route_surface'),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Color(0xFFFCF9FF),
              AppThemeFactory.animeBackground,
              Color(0xFFFFF7FB),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: CustomPaint(
          isComplex: true,
          painter: _AnimeBackdropPainter(
            primary: colorScheme.primary,
            secondary: colorScheme.secondary,
            tertiary: colorScheme.tertiary,
          ),
          child: child,
        ),
      ),
    );
  }
}

class _AnimeBackdropPainter extends CustomPainter {
  final Color primary;
  final Color secondary;
  final Color tertiary;

  const _AnimeBackdropPainter({
    required this.primary,
    required this.secondary,
    required this.tertiary,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 装饰圆允许在 route 内从边缘探入，但不能在翻页时越界染到旧页面。
    canvas
      ..save()
      ..clipRect(Offset.zero & size);
    canvas
      ..drawCircle(
        Offset(-24, size.height * 0.16),
        118,
        Paint()..color = primary.withValues(alpha: 0.055),
      )
      ..drawCircle(
        Offset(size.width + 18, size.height * 0.46),
        96,
        Paint()..color = secondary.withValues(alpha: 0.050),
      )
      ..drawCircle(
        Offset(size.width * 0.35, size.height + 34),
        144,
        Paint()..color = tertiary.withValues(alpha: 0.040),
      )
      ..restore();
  }

  @override
  bool shouldRepaint(covariant _AnimeBackdropPainter oldDelegate) {
    return oldDelegate.primary != primary ||
        oldDelegate.secondary != secondary ||
        oldDelegate.tertiary != tertiary;
  }
}
