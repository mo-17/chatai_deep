import 'dart:io';

/// 用同一 Flutter SDK 解析依赖、生成 SQLite worker/wasm、构建可静态托管的 Web 包。
/// 调用：dart tool/build_web.dart [flutter build web 的额外参数]
Future<void> main(List<String> arguments) async {
  final shell = File.fromUri(Platform.script).parent.parent;
  final dartBin = File(Platform.resolvedExecutable).parent;
  final bundledFlutter = File(
      '${dartBin.parent.parent.parent.path}${Platform.pathSeparator}flutter${Platform.isWindows ? '.bat' : ''}');
  final flutter = Platform.environment['FLUTTER_BIN'] ??
      (bundledFlutter.existsSync() ? bundledFlutter.path : 'flutter');
  final environment = Map<String, String>.of(Platform.environment);
  final pathKey = environment.keys
      .firstWhere((key) => key.toUpperCase() == 'PATH', orElse: () => 'PATH');
  environment[pathKey] =
      '${dartBin.path}${Platform.isWindows ? ';' : ':'}${environment[pathKey] ?? ''}';

  Future<void> run(String executable, List<String> args) async {
    final process = await Process.start(executable, args,
        workingDirectory: shell.path,
        environment: environment,
        mode: ProcessStartMode.inheritStdio,
        runInShell: Platform.isWindows);
    final code = await process.exitCode;
    if (code != 0) exit(code);
  }

  await run(flutter, ['pub', 'get', '--enforce-lockfile', '--no-example']);
  await run(
      Platform.resolvedExecutable, ['run', 'sqflite_common_ffi_web:setup']);
  for (final asset in ['sqlite3.wasm', 'sqflite_sw.js']) {
    if (!File('${shell.path}/web/$asset').existsSync()) {
      stderr.writeln('Missing SQLite Web runtime: $asset');
      exit(1);
    }
  }
  await run(flutter, [
    'build',
    'web',
    '--release',
    '--no-pub',
    '--no-web-resources-cdn',
    '--pwa-strategy=none',
    ...arguments
  ]);
  for (final asset in [
    'index.html',
    'flutter_bootstrap.js',
    'main.dart.js',
    'sqlite3.wasm',
    'sqflite_sw.js'
  ]) {
    if (!File('${shell.path}/build/web/$asset').existsSync()) {
      stderr.writeln('Missing Web build artifact: $asset');
      exit(1);
    }
  }
}
