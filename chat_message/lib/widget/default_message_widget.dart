import 'dart:convert';
import 'dart:io';

import 'package:bubble/bubble.dart';
import 'package:chat_message/util/wechat_date_format.dart';
import 'package:flutter/material.dart';

import '../models/message_model.dart';

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

  /// the text-color of the [content].
  final Color? textColor;

  /// Background color of the message
  final Color? backgroundColor;
  final MessageWidgetBuilder? messageWidget;

  /// 只替换气泡内部内容（块化渲染）；返回 null 时回退默认渲染。
  final MessageContentBuilder? contentBuilder;
  final OnBubbleClick? onBubbleTap;
  final OnBubbleClick? onBubbleLongPress;

  const DefaultMessageWidget(
      {required GlobalKey key,
      required this.message,
      this.fontFamily,
      this.fontSize = 16.0,
      this.textColor,
      this.backgroundColor,
      this.avatarSize = 40,
      this.messageWidget,
      this.contentBuilder,
      this.onBubbleTap,
      this.onBubbleLongPress})
      : super(key: key);

  double get contentMargin => avatarSize + 10;

  String get senderInitials {
    if (message.ownerName == null) return "";
    List<String> chars = message.ownerName!.split(" ");
    if (chars.length > 1) {
      return chars[0];
    } else {
      return message.ownerName![0];
    }
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
      ? const Color(0xFF2E7D32) // AI 绿色
      : const Color(0xFF0F3460); // 用户蓝色

  Widget get _initialsAvatar => CircleAvatar(
      radius: avatarSize / 2,
      backgroundColor: _avatarBgColor,
      child: Text(
        senderInitials,
        style: const TextStyle(fontSize: 16, color: Colors.white),
      ));

  Widget get _buildCircleAvatar {
    if (!_isValidNetworkUrl(message.avatar)) return _initialsAvatar;
    return ClipOval(
      child: Image.network(
        message.avatar!.trim(),
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

  @override
  Widget build(BuildContext context) {
    if (messageWidget != null) return messageWidget!(message);
    Widget content = message.ownerType == OwnerType.receiver
        ? _buildReceiver(context)
        : _buildSender(context);
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

  Widget _buildReceiver(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.start,
      children: <Widget>[
        _buildCircleAvatar,
        Flexible(
          child: Bubble(
              margin: BubbleEdges.fromLTRB(10, 0, contentMargin, 0),
              stick: true,
              nip: BubbleNip.leftTop,
              color: backgroundColor ?? const Color.fromRGBO(233, 232, 252, 10),
              alignment: Alignment.topLeft,
              child: _bubbleChild(TextAlign.left, context)),
        ),
      ],
    );
  }

  Widget _buildSender(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Flexible(
          child: Bubble(
              margin: BubbleEdges.fromLTRB(contentMargin, 0, 10, 0),
              stick: true,
              nip: BubbleNip.rightTop,
              color: backgroundColor ?? Colors.white,
              alignment: Alignment.topRight,
              child: _bubbleChild(TextAlign.left, context)),
        ),
        _buildCircleAvatar
      ],
    );
  }

  /// 气泡内部内容：优先用 [contentBuilder]（块化渲染），回退默认文本/图片。
  /// 自定义内容外包一层手势，保留气泡级 点击/长按 菜单。
  Widget _bubbleChild(TextAlign align, BuildContext context) {
    final custom = contentBuilder?.call(context, message);
    if (custom == null) return _buildContentText(align, context);
    return InkWell(
      onTap: () => onBubbleTap != null ? onBubbleTap!(message, context) : null,
      onLongPress: () =>
          onBubbleLongPress != null ? onBubbleLongPress!(message, context) : null,
      child: custom,
    );
  }

  Widget _buildContentText(TextAlign align, BuildContext context) {
    final hasImages =
        message.imageUrlsOrB64 != null && message.imageUrlsOrB64!.isNotEmpty;
    final hasText = message.content.isNotEmpty;

    if (!hasImages) {
      return InkWell(
        onTap: () => onBubbleTap != null ? onBubbleTap!(message, context) : null,
        onLongPress: () => onBubbleLongPress != null
            ? onBubbleLongPress!(message, context)
            : null,
        child: Text(
          message.content,
          textAlign: align,
          style: TextStyle(
              fontSize: fontSize,
              color: textColor ?? Colors.black,
              fontFamily: fontFamily),
        ),
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
                color: textColor ?? Colors.black,
                fontFamily: fontFamily),
          ),
        ],
      ],
    );
  }

  Widget _buildImageGrid(BuildContext context) {
    final images = message.imageUrlsOrB64!;
    final count = images.length;
    final crossAxisCount = count == 1 ? 1 : 2;
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
      final file = File(img);
      if (file.existsSync()) {
        return Image.file(
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
                  errorBuilder: (_, __, ___) =>
                      const Icon(Icons.broken_image, color: Colors.white, size: 64),
                ),
              );
            }
          } else if (img.startsWith('http://') || img.startsWith('https://')) {
            return Center(
              child: Image.network(
                img,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) =>
                    const Icon(Icons.broken_image, color: Colors.white, size: 64),
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
