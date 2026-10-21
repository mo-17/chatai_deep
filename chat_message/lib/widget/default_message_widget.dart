import 'package:login_sdk/platform/app_file_image.dart';
import 'dart:convert';
import 'package:login_sdk/platform/app_io.dart';

import 'package:chat_message/theme/chat_decoration.dart';
import 'chat_bubble_surface.dart';
import 'package:chat_message/util/wechat_date_format.dart';
import 'package:flutter/material.dart';

import '../models/message_model.dart';
import 'message_avatar_builder.dart';

typedef MessageWidgetBuilder = Widget Function(MessageModel message);
typedef OnBubbleClick = void Function(
    MessageModel message, BuildContext ancestor);

/// 只定制气泡「内部内容」的构造器。返回 null 时回退到默认文本/图片渲染。
/// 气泡外壳（头像、气泡形状、时间、长按菜单）仍由 [DefaultMessageWidget] 提供。
typedef MessageContentBuilder = Widget? Function(
    BuildContext context, MessageModel message);

class DefaultMessageWidget extends StatelessWidget {
  final MessageModel message;

  /// the font-family of the [content].
  final String? fontFamily;

  /// the font-size of the [content].
  final double fontSize;

  /// the size of the [avatar].
  final double avatarSize;
  final bool showAvatars;
  final ChatBubbleStyle bubbleStyle;
  final ChatAvatarFrameStyle avatarFrameStyle;

  /// the text-color of the [content].
  final Color? textColor;

  /// Background color of the message
  final Color? backgroundColor;
  final Color? receiverBackgroundColor;
  final Color? senderBackgroundColor;
  final Color? receiverAvatarBackgroundColor;
  final Color? senderAvatarBackgroundColor;
  final Radius? bubbleRadius;
  final MessageWidgetBuilder? messageWidget;

  /// 只替换气泡内部内容（块化渲染）；返回 null 时回退默认渲染。
  final MessageContentBuilder? contentBuilder;
  final MessageAvatarBuilder? avatarBuilder;
  final OnBubbleClick? onBubbleTap;
  final OnBubbleClick? onBubbleLongPress;

  const DefaultMessageWidget({
    required GlobalKey key,
    required this.message,
    this.fontFamily,
    this.fontSize = 16.0,
    this.textColor,
    this.backgroundColor,
    this.receiverBackgroundColor,
    this.senderBackgroundColor,
    this.receiverAvatarBackgroundColor,
    this.senderAvatarBackgroundColor,
    this.bubbleRadius,
    this.avatarSize = 40,
    this.showAvatars = true,
    this.bubbleStyle = ChatBubbleStyle.classic,
    this.avatarFrameStyle = ChatAvatarFrameStyle.none,
    this.messageWidget,
    this.contentBuilder,
    this.avatarBuilder,
    this.onBubbleTap,
    this.onBubbleLongPress,
  }) : super(key: key);

  double get contentMargin => showAvatars ? 16 : 4;

  // 透明头像框和插画气泡自身已有外沿留白，避免再叠加原生头像的间距。
  double get avatarBubbleGap => !showAvatars
      ? 0
      : (avatarFrameStyle == ChatAvatarFrameStyle.none ? 8 : 2);

  String get senderInitials {
    // ownerName 可能为 null，也可能是空串（后端登录响应缺 userName 时，
    // login_sdk 会把它存成 ''）。空串若直接取 [0] 会抛 RangeError，导致气泡
    // build 期间崩溃红屏，故先 trim 判空，再取首个字素（兼容 emoji/中文）。
    final name = message.ownerName?.trim() ?? "";
    if (name.isEmpty) return "";
    final parts = name.split(" ");
    if (parts.length > 1) {
      return parts[0];
    }
    return name.characters.first;
  }

  ///校验是否为合法的 http/https URL，避免 Image.network 把空串/相对路径
  ///解析成 file:/// 抛 "No host specified in URI"
  bool _isValidNetworkUrl(String? url) {
    if (url == null || url.trim().isEmpty) return false;
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return false;
    return (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  Color get _avatarBgColor => message.ownerType == OwnerType.receiver
      ? receiverAvatarBackgroundColor ?? const Color(0xFF2E7D32) // AI 绿色
      : senderAvatarBackgroundColor ?? const Color(0xFF0F3460); // 用户蓝色

  Widget get _initialsAvatar => CircleAvatar(
      radius: avatarSize / 2,
      backgroundColor: _avatarBgColor,
      child: Text(
        senderInitials,
        style: const TextStyle(fontSize: 16, color: Colors.white),
      ));

  Widget _emojiAvatar(String emoji) => CircleAvatar(
        radius: avatarSize / 2,
        backgroundColor: _avatarBgColor,
        child: Text(
          emoji,
          style: TextStyle(fontSize: avatarSize * 0.52),
        ),
      );

  Widget _buildCircleAvatar(BuildContext context) {
    final override = avatarBuilder?.call(context, message, avatarSize);
    if (override != null) return override;
    final avatar = message.avatar?.trim() ?? '';
    if (avatar.isEmpty) return _initialsAvatar;
    if (avatar.startsWith('emoji:')) {
      final emoji = Uri.decodeComponent(avatar.substring('emoji:'.length));
      return emoji.trim().isEmpty ? _initialsAvatar : _emojiAvatar(emoji);
    }
    if (!_isValidNetworkUrl(avatar)) {
      final file = appFile(avatar);
      if (!file.isAbsolute || !file.existsSync()) return _initialsAvatar;
      return ClipOval(
        child: appFileImage(
          file,
          height: avatarSize,
          width: avatarSize,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _initialsAvatar,
        ),
      );
    }
    return ClipOval(
      child: Image.network(
        avatar,
        height: avatarSize,
        width: avatarSize,
        errorBuilder: (_, __, ___) => _initialsAvatar,
        loadingBuilder: (_, child, progress) {
          if (progress == null) return child;
          return _initialsAvatar; // 加载中显示首字母，不空白
        },
      ),
    );
  }

  Color get _background =>
      (message.ownerType == OwnerType.receiver
          ? receiverBackgroundColor
          : senderBackgroundColor) ??
      backgroundColor ??
      (message.ownerType == OwnerType.receiver
          ? const Color(0xFFE9E8FC)
          : Colors.white);

  Widget _framedAvatar(BuildContext context) => ChatAvatarFrame(
        style: avatarFrameStyle,
        size: avatarSize,
        preserveAvatarSize: true,
        child: _buildCircleAvatar(context),
      );

  @override
  Widget build(BuildContext context) {
    if (messageWidget != null) return messageWidget!(message);
    final theme = Theme.of(context);
    final background = _background;
    final opaque = Color.alphaBlend(background, theme.colorScheme.surface);
    // 黑白两色取对比度较高者，支持任意手动输入的颜色。
    final foreground =
        opaque.computeLuminance() > 0.179 ? Colors.black : Colors.white;
    final scheme = ColorScheme.fromSeed(
      seedColor: opaque,
      brightness:
          foreground == Colors.white ? Brightness.dark : Brightness.light,
    ).copyWith(
      onSurface: foreground,
      onSurfaceVariant: foreground,
      primary: foreground,
    );
    return _withCreatedTime(Theme(
      data: theme.copyWith(
        colorScheme: scheme,
        textTheme: theme.textTheme.apply(
          bodyColor: foreground,
          displayColor: foreground,
        ),
        iconTheme: theme.iconTheme.copyWith(color: foreground),
        textSelectionTheme: TextSelectionThemeData(
          selectionColor: foreground.withValues(alpha: 0.25),
          selectionHandleColor: foreground,
        ),
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: foreground),
        child: Builder(
          builder: (bubbleContext) => _buildMessage(bubbleContext, context),
        ),
      ),
    ));
  }

  Widget _buildMessage(BuildContext context, BuildContext actionContext) {
    return message.ownerType == OwnerType.receiver
        ? _buildReceiver(context, actionContext)
        : _buildSender(context, actionContext);
  }

  Widget _withCreatedTime(Widget content) {
    return Column(
      children: [
        if (message.showCreatedTime) _buildCreatedTime(),
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: content,
        ),
      ],
    );
  }

  Widget _buildReceiver(BuildContext context, BuildContext actionContext) {
    return Row(
      mainAxisSize: MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.start,
      children: <Widget>[
        if (showAvatars) _framedAvatar(context),
        Flexible(
          child: ChatBubbleSurface(
            style: bubbleStyle,
            color: _background,
            isUser: false,
            showTail: showAvatars,
            margin: EdgeInsets.fromLTRB(avatarBubbleGap, 0, contentMargin, 0),
            radius: bubbleRadius,
            child: _bubbleChild(TextAlign.left, context, actionContext),
          ),
        ),
      ],
    );
  }

  Widget _buildSender(BuildContext context, BuildContext actionContext) {
    return Row(
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Flexible(
          child: ChatBubbleSurface(
            style: bubbleStyle,
            color: _background,
            isUser: true,
            showTail: showAvatars,
            margin: EdgeInsets.fromLTRB(contentMargin, 0, avatarBubbleGap, 0),
            radius: bubbleRadius,
            child: _bubbleChild(TextAlign.left, context, actionContext),
          ),
        ),
        if (showAvatars) _framedAvatar(context)
      ],
    );
  }

  /// 气泡内部内容：优先用 [contentBuilder]（块化渲染），回退默认文本/图片。
  /// 正文由 SelectionArea 统一处理拖选、长按选词和系统复制快捷键。
  /// 独立操作按钮保留原消息菜单，避免与文本选择竞争手势。
  Widget _bubbleChild(
      TextAlign align, BuildContext context, BuildContext actionContext) {
    // 菜单沿用页面主题；只有气泡正文使用自定义颜色，避免浅色弹层出现白字。
    final content = contentBuilder?.call(context, message) ??
        _buildContentText(align, context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: onBubbleTap == null
              ? null
              : () => onBubbleTap!(message, actionContext),
          onLongPress: onBubbleLongPress == null
              ? null
              : () => onBubbleLongPress!(message, actionContext),
          child: SelectionArea(child: content),
        ),
        if (onBubbleLongPress != null)
          SelectionContainer.disabled(
            child: IconButton(
              tooltip: '消息操作',
              icon: const Icon(Icons.more_horiz, size: 18),
              color: Theme.of(context).colorScheme.onSurface,
              onPressed: () => onBubbleLongPress!(message, actionContext),
            ),
          ),
      ],
    );
  }

  Widget _buildContentText(TextAlign align, BuildContext context) {
    final hasImages =
        message.imageUrlsOrB64 != null && message.imageUrlsOrB64!.isNotEmpty;
    final hasText = message.content.isNotEmpty;

    if (!hasImages) {
      return Text(
        message.content,
        textAlign: align,
        style: TextStyle(
            fontSize: fontSize,
            color: textColor ?? Theme.of(context).colorScheme.onSurface,
            fontFamily: fontFamily),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildImageGrid(context),
        if (hasText) ...[
          const SizedBox(height: 8),
          Text(
            message.content,
            textAlign: align,
            style: TextStyle(
                fontSize: fontSize,
                color: textColor ?? Theme.of(context).colorScheme.onSurface,
                fontFamily: fontFamily),
          ),
        ],
      ],
    );
  }

  Widget _buildImageGrid(BuildContext context) {
    final images = message.imageUrlsOrB64!;
    final count = images.length;
    final itemWidth = count == 1 ? 200.0 : 100.0;
    final itemHeight = count == 1 ? 200.0 : 100.0;

    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: List.generate(count, (i) {
        return GestureDetector(
          onTap: () => _previewImage(context, i),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: _buildImageWidget(images[i], itemWidth, itemHeight),
          ),
        );
      }),
    );
  }

  Widget _buildImageWidget(String img, double w, double h) {
    if (img.startsWith('data:')) {
      // base64 data URI
      final parts = img.split(',');
      if (parts.length < 2) {
        return _imagePlaceholder(w, h);
      }
      final bytes = base64Decode(parts[1]);
      return Image.memory(
        bytes,
        width: w,
        height: h,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _imagePlaceholder(w, h),
      );
    } else if (_isValidNetworkUrl(img)) {
      return Image.network(
        img,
        width: w,
        height: h,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _imagePlaceholder(w, h),
      );
    } else if (img.startsWith('/') || img.contains('://')) {
      // 本地文件路径
      final file = appFile(img);
      if (file.existsSync()) {
        return appFileImage(
          file,
          width: w,
          height: h,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _imagePlaceholder(w, h),
        );
      }
    }
    return _imagePlaceholder(w, h);
  }

  Widget _imagePlaceholder(double w, double h) {
    return Container(
      width: w,
      height: h,
      color: Colors.grey.shade200,
      child: const Icon(Icons.broken_image, color: Colors.grey),
    );
  }

  void _previewImage(BuildContext context, int index) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _ImageViewer(
          images: message.imageUrlsOrB64!,
          initialIndex: index,
        ),
      ),
    );
  }

  _buildCreatedTime() {
    String showT = WechatDateFormat.format(message.createdAt, dayOnly: false);
    return Container(
      padding: const EdgeInsets.only(top: 10),
      child: Text(showT),
    );
  }
}

///全屏图片预览
class _ImageViewer extends StatelessWidget {
  final List<String> images;
  final int initialIndex;

  const _ImageViewer({required this.images, required this.initialIndex});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: PageView.builder(
        controller: PageController(initialPage: initialIndex),
        itemCount: images.length,
        itemBuilder: (_, i) {
          final img = images[i];
          if (img.startsWith('data:')) {
            final parts = img.split(',');
            if (parts.length >= 2) {
              return Center(
                child: Image.memory(
                  base64Decode(parts[1]),
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Icon(Icons.broken_image,
                      color: Colors.white, size: 64),
                ),
              );
            }
          } else if (img.startsWith('http://') || img.startsWith('https://')) {
            return Center(
              child: Image.network(
                img,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Icon(Icons.broken_image,
                    color: Colors.white, size: 64),
              ),
            );
          }
          return const Center(
            child: Icon(Icons.broken_image, color: Colors.white, size: 64),
          );
        },
      ),
    );
  }
}
