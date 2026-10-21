import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 只有可见、前台且允许动画时订阅动态图；其余时间只解码静态封面。
/// 使用 Flutter 自带图片流，无额外定时器，也不重建消息正文。
class ChatAnimatedFrameImage extends StatefulWidget {
  final String asset;
  final String posterAsset;
  final bool animated;
  final int? pixels;
  final double? scale;
  final Rect? centerSlice;
  final BoxFit fit;
  final FilterQuality filterQuality;
  final Widget fallback;

  const ChatAnimatedFrameImage(
      {super.key,
      required this.asset,
      required this.posterAsset,
      required this.animated,
      this.pixels,
      this.scale,
      this.centerSlice,
      this.fit = BoxFit.contain,
      required this.filterQuality,
      required this.fallback});

  @override
  State<ChatAnimatedFrameImage> createState() => _ChatAnimatedFrameImageState();
}

class _ChatAnimatedFrameImageState extends State<ChatAnimatedFrameImage>
    with WidgetsBindingObserver {
  ScrollPosition? _position;
  bool _visible = false;
  bool _measurePending = false;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (position != _position) {
      _position?.removeListener(_scheduleMeasure);
      _position = position;
      _position?.addListener(_scheduleMeasure);
    }
    _scheduleMeasure();
  }

  void _scheduleMeasure() {
    if (_measurePending || !mounted || !widget.animated) return;
    _measurePending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measurePending = false;
      if (!mounted) return;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) return;
      var viewport = Offset.zero & MediaQuery.sizeOf(context);
      final RenderObject? scrollViewport = RenderAbstractViewport.maybeOf(box);
      if (scrollViewport is RenderBox && scrollViewport.hasSize) {
        viewport = viewport.intersect(
            scrollViewport.localToGlobal(Offset.zero) & scrollViewport.size);
      }
      final bounds = box.localToGlobal(Offset.zero) & box.size;
      final visible = !viewport.isEmpty && bounds.overlaps(viewport);
      if (visible != _visible) setState(() => _visible = visible);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground != _foreground) setState(() => _foreground = foreground);
  }

  @override
  void dispose() {
    _position?.removeListener(_scheduleMeasure);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _scheduleMeasure();
    final playing = widget.animated &&
        _visible &&
        _foreground &&
        TickerMode.of(context) &&
        !MediaQuery.disableAnimationsOf(context);
    return RepaintBoundary(
      child: Image.asset(playing ? widget.asset : widget.posterAsset,
          package: 'chat_message',
          scale: widget.scale,
          cacheWidth: widget.pixels,
          cacheHeight: widget.pixels,
          centerSlice: widget.centerSlice,
          fit: widget.fit,
          filterQuality: widget.filterQuality,
          errorBuilder: (_, __, ___) => widget.fallback),
    );
  }
}
