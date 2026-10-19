import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

class JsEvalResult {
  final String stringResult;
  final bool isError;
  const JsEvalResult(this.stringResult, {this.isError = false});
}

abstract class JavascriptRuntime {
  JsEvalResult evaluate(String code, {String? sourceUrl});
  void dispose();
}

typedef _EvalNative =
    Pointer<Utf8> Function(
      Pointer<Utf8>,
      UintPtr,
      Int32,
      UintPtr,
      Pointer<Int32>,
    );
typedef _Eval =
    Pointer<Utf8> Function(Pointer<Utf8>, int, int, int, Pointer<Int32>);
typedef _LengthNative = UintPtr Function(Pointer<Utf8>);
typedef _Length = int Function(Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _Free = void Function(Pointer<Void>);

/// 仅提供共享核心使用的同步纯计算接口；每次 evaluate 创建并销毁独立原生 runtime。
class QuickJsRuntime2 implements JavascriptRuntime {
  static final DynamicLibrary _library = DynamicLibrary.open(
    Platform.operatingSystem == 'ohos'
        ? 'libchatai_js.so'
        : Platform.environment['CHATAI_JS_TEST_LIBRARY'] ??
              (throw UnsupportedError('该适配器仅用于鸿蒙；宿主测试需显式指定测试库')),
  );
  static final _Eval _evaluate = _library.lookupFunction<_EvalNative, _Eval>(
    'chatai_js_eval',
  );
  static final _Length _length = _library
      .lookupFunction<_LengthNative, _Length>('chatai_js_length');
  static final _Free _free = _library.lookupFunction<_FreeNative, _Free>(
    'chatai_js_free',
  );
  final int timeout;
  final int memoryLimit;
  bool _disposed = false;
  QuickJsRuntime2({int? timeout, int? memoryLimit})
    : timeout = timeout ?? 2000,
      memoryLimit = memoryLimit ?? 32 * 1024 * 1024;

  @override
  JsEvalResult evaluate(String code, {String? sourceUrl}) {
    if (_disposed) throw StateError('JS runtime 已释放');
    final bytes = utf8.encode(code);
    if (bytes.length > 4 * 1024 * 1024)
      return const JsEvalResult('脚本过大', isError: true);
    final source = calloc<Uint8>(bytes.length + 1);
    final status = calloc<Int32>();
    Pointer<Utf8> result = nullptr;
    try {
      source.asTypedList(bytes.length).setAll(0, bytes);
      result = _evaluate(
        source.cast(),
        bytes.length,
        timeout,
        memoryLimit,
        status,
      );
      if (result == nullptr)
        return const JsEvalResult('JS 原生内存分配失败', isError: true);
      return JsEvalResult(
        result.toDartString(length: _length(result)),
        isError: status.value != 0,
      );
    } finally {
      if (result != nullptr) _free(result.cast());
      calloc.free(source);
      calloc.free(status);
    }
  }

  @override
  void dispose() {
    _disposed = true;
  }
}
