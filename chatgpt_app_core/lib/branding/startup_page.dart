import 'package:flutter/material.dart';

import 'app_branding.dart';

/// 原生闪屏交接后的第一帧，真实初始化结束后立即进入应用。
class StartupPage extends StatelessWidget {
  const StartupPage({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final foreground =
        dark ? AppBranding.darkForeground : AppBranding.lightForeground;
    final muted = dark ? AppBranding.darkMuted : AppBranding.lightMuted;
    return Scaffold(
      backgroundColor:
          dark ? AppBranding.darkBackground : AppBranding.lightBackground,
      body: Stack(
        fit: StackFit.expand,
        children: [
          ExcludeSemantics(
            child: Image.asset(
              dark
                  ? 'assets/images/aipu-splash-backdrop-dark.png'
                  : 'assets/images/aipu-splash-backdrop-light.png',
              package: 'chatgpt_app_core',
              fit: BoxFit.cover,
            ),
          ),
          SafeArea(
            child: LayoutBuilder(builder: (context, constraints) {
              final compact = constraints.maxHeight < 400;
              return Stack(
                fit: StackFit.expand,
                children: [
                  Align(
                    alignment: Alignment(0, compact ? 0 : -.12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: compact ? 160 : 240,
                          height: compact ? 108 : 176,
                          child: OverflowBox(
                            maxWidth: compact ? 160 : 240,
                            maxHeight: compact ? 160 : 240,
                            child: Image.asset(
                                'assets/images/aipu-splash-symbol.png',
                                package: 'chatgpt_app_core',
                                width: compact ? 160 : 240,
                                height: compact ? 160 : 240,
                                excludeFromSemantics: true),
                          ),
                        ),
                        Text(AppBranding.name,
                            style: TextStyle(
                                color: foreground,
                                fontSize: compact ? 26 : 32,
                                fontWeight: FontWeight.w500,
                                letterSpacing: 10,
                                height: 1.4)),
                        const SizedBox(height: 12),
                        ExcludeSemantics(
                          child: Text('AIPU',
                              style: TextStyle(
                                  color: muted,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w500,
                                  letterSpacing: 7)),
                        ),
                      ],
                    ),
                  ),
                  if (!compact)
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 40),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Semantics(
                              label: '正在启动${AppBranding.name}，请稍候',
                              liveRegion: true,
                              child: ExcludeSemantics(
                                child: SizedBox(
                                  width: 56,
                                  height: 2,
                                  child: reducedMotion
                                      ? DecoratedBox(
                                          decoration: BoxDecoration(
                                              color: muted.withValues(alpha: .5),
                                              borderRadius:
                                                  BorderRadius.circular(1)))
                                      : LinearProgressIndicator(
                                          color: dark
                                              ? const Color(0xFFAFA8F7)
                                              : AppBranding.primary,
                                          backgroundColor:
                                              muted.withValues(alpha: .15),
                                          borderRadius:
                                              BorderRadius.circular(1)),
                                ),
                              ),
                            ),
                            const SizedBox(height: 24),
                            Text('对话 · 灵感 · 创作',
                                style: TextStyle(
                                    color: muted,
                                    fontSize: 11,
                                    letterSpacing: 2)),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            }),
          ),
        ],
      ),
    );
  }
}
