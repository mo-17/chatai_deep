import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'app_io.dart';

/// Image.file 不支持 Web；虚拟文件字节使用同一图片解码管线渲染。
Widget appFileImage(File file,
    {Key? key,
    double? width,
    double? height,
    BoxFit? fit,
    AlignmentGeometry alignment = Alignment.center,
    ImageErrorWidgetBuilder? errorBuilder,
    int? cacheWidth,
    int? cacheHeight,
    FilterQuality filterQuality = FilterQuality.medium,
    bool gaplessPlayback = false}) {
  if (kIsWeb) {
    Uint8List bytes;
    try {
      bytes = file.readAsBytesSync();
    } catch (_) {
      bytes = Uint8List(0);
    }
    return Image.memory(bytes,
        key: key,
        width: width,
        height: height,
        fit: fit,
        alignment: alignment,
        errorBuilder: errorBuilder,
        cacheWidth: cacheWidth,
        cacheHeight: cacheHeight,
        filterQuality: filterQuality,
        gaplessPlayback: gaplessPlayback);
  }
  return Image.file(file,
      key: key,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      errorBuilder: errorBuilder,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
      filterQuality: filterQuality,
      gaplessPlayback: gaplessPlayback);
}
