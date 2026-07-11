import 'dart:async';
import 'dart:isolate';

import 'package:chatgpt_app_core/model/story_regex_script.dart';

enum StoryRegexRuleStatus { applied, skipped, failed, timedOut }

class StoryRegexRuleResult {
  final String key;
  final StoryRegexRuleStatus status;
  final Duration elapsed;
  final String? error;

  const StoryRegexRuleResult({
    required this.key,
    required this.status,
    required this.elapsed,
    this.error,
  });
}

class StoryRegexExecutionResult {
  final String output;
  final List<StoryRegexRuleResult> rules;
  final bool timedOut;
  final bool inputTruncated;
  final bool outputTruncated;

  const StoryRegexExecutionResult({
    required this.output,
    required this.rules,
    required this.timedOut,
    required this.inputTruncated,
    required this.outputTruncated,
  });
}

/// Runs one rule per isolate so a pathological Dart [RegExp] can be killed.
/// This layer accepts declarative strings only; it never evaluates JS or shell
/// commands. The timeout covers the complete stage rather than each rule.
class StoryRegexExecutor {
  const StoryRegexExecutor._();

  static const defaultStageTimeout = Duration(milliseconds: 800);

  static Future<StoryRegexExecutionResult> execute({
    required StoryRegexScripts scripts,
    required StoryRegexStage stage,
    required String input,
    Duration stageTimeout = defaultStageTimeout,
  }) async {
    final inputTruncated = input.length > StoryRegexScriptLimits.maxTextLength;
    var output = inputTruncated
        ? input.substring(0, StoryRegexScriptLimits.maxTextLength)
        : input;
    var outputTruncated = false;
    var timedOut = false;
    final results = <StoryRegexRuleResult>[];
    final total = Stopwatch()..start();
    final ordered = scripts.orderedRules;

    for (var index = 0; index < ordered.length; index++) {
      final rule = ordered[index];
      if (!rule.enabled) {
        results.add(_skipped(rule.key, 'disabled'));
        continue;
      }
      if (rule.stage != stage) {
        results.add(_skipped(rule.key, 'stage mismatch'));
        continue;
      }
      final remaining = stageTimeout - total.elapsed;
      if (remaining <= Duration.zero) {
        timedOut = true;
        results.add(_timeout(rule.key, Duration.zero));
        for (final later in ordered.skip(index + 1)) {
          results.add(_skipped(later.key, 'stage timeout'));
        }
        break;
      }

      final ruleClock = Stopwatch()..start();
      final run = await _runInKillableIsolate(
        input: output,
        find: rule.find,
        replace: rule.replace,
        trimStrings: rule.trimStrings,
        caseSensitive: rule.caseSensitive,
        multiLine: rule.multiLine,
        dotAll: rule.dotAll,
        timeout: remaining,
      );
      ruleClock.stop();
      if (run.timedOut) {
        timedOut = true;
        results.add(_timeout(rule.key, ruleClock.elapsed));
        for (final later in ordered.skip(index + 1)) {
          results.add(_skipped(later.key, 'stage timeout'));
        }
        break;
      }
      if (run.error != null) {
        results.add(StoryRegexRuleResult(
          key: rule.key,
          status: StoryRegexRuleStatus.failed,
          elapsed: ruleClock.elapsed,
          error: run.error,
        ));
        continue;
      }
      output = run.output!;
      if (output.length > StoryRegexScriptLimits.maxTextLength) {
        output = output.substring(0, StoryRegexScriptLimits.maxTextLength);
        outputTruncated = true;
      }
      results.add(StoryRegexRuleResult(
        key: rule.key,
        status: StoryRegexRuleStatus.applied,
        elapsed: ruleClock.elapsed,
      ));
    }
    return StoryRegexExecutionResult(
      output: output,
      rules: List.unmodifiable(results),
      timedOut: timedOut,
      inputTruncated: inputTruncated,
      outputTruncated: outputTruncated,
    );
  }

  static StoryRegexRuleResult _skipped(String key, String error) =>
      StoryRegexRuleResult(
        key: key,
        status: StoryRegexRuleStatus.skipped,
        elapsed: Duration.zero,
        error: error,
      );

  static StoryRegexRuleResult _timeout(String key, Duration elapsed) =>
      StoryRegexRuleResult(
        key: key,
        status: StoryRegexRuleStatus.timedOut,
        elapsed: elapsed,
        error: 'stage timeout',
      );
}

class _RuleRunResult {
  final String? output;
  final String? error;
  final bool timedOut;

  const _RuleRunResult({this.output, this.error, this.timedOut = false});
}

Future<_RuleRunResult> _runInKillableIsolate({
  required String input,
  required String find,
  required String replace,
  required List<String> trimStrings,
  required bool caseSensitive,
  required bool multiLine,
  required bool dotAll,
  required Duration timeout,
}) async {
  final port = ReceivePort();
  Isolate? isolate;
  try {
    isolate = await Isolate.spawn<_RegexIsolateRequest>(
      _executeRegexInIsolate,
      _RegexIsolateRequest(
        sendPort: port.sendPort,
        input: input,
        find: find,
        replace: replace,
        trimStrings: trimStrings,
        caseSensitive: caseSensitive,
        multiLine: multiLine,
        dotAll: dotAll,
      ),
      errorsAreFatal: true,
    );
    final raw = await port.first.timeout(timeout);
    if (raw is Map && raw['ok'] == true && raw['output'] is String) {
      return _RuleRunResult(output: raw['output'] as String);
    }
    return _RuleRunResult(error: _isolateError(raw));
  } on TimeoutException {
    return const _RuleRunResult(timedOut: true);
  } catch (error) {
    return _RuleRunResult(error: '$error');
  } finally {
    isolate?.kill(priority: Isolate.immediate);
    port.close();
  }
}

String _isolateError(Object? raw) {
  if (raw is Map && raw['error'] is String) return raw['error'] as String;
  return raw == null ? 'regex isolate ended without a result' : '$raw';
}

class _RegexIsolateRequest {
  final SendPort sendPort;
  final String input;
  final String find;
  final String replace;
  final List<String> trimStrings;
  final bool caseSensitive;
  final bool multiLine;
  final bool dotAll;

  const _RegexIsolateRequest({
    required this.sendPort,
    required this.input,
    required this.find,
    required this.replace,
    required this.trimStrings,
    required this.caseSensitive,
    required this.multiLine,
    required this.dotAll,
  });
}

void _executeRegexInIsolate(_RegexIsolateRequest request) {
  try {
    final expression = RegExp(
      request.find,
      caseSensitive: request.caseSensitive,
      multiLine: request.multiLine,
      dotAll: request.dotAll,
    );
    var output = request.input.replaceAllMapped(
      expression,
      (match) => _expandReplacement(request.replace, match),
    );
    var changed = true;
    while (changed) {
      changed = false;
      for (final value in request.trimStrings) {
        final trimmed = _trimString(output, value);
        if (trimmed == output) continue;
        output = trimmed;
        changed = true;
      }
    }
    request.sendPort.send({'ok': true, 'output': output});
  } catch (error) {
    request.sendPort.send({'ok': false, 'error': '$error'});
  }
}

String _expandReplacement(String replacement, Match match) {
  final output = StringBuffer();
  for (var index = 0; index < replacement.length; index++) {
    final char = replacement[index];
    if (char != r'$' || index + 1 >= replacement.length) {
      output.write(char);
      continue;
    }
    final next = replacement[index + 1];
    if (next == r'$') {
      output.write(r'$');
      index++;
      continue;
    }
    if (next == '&') {
      output.write(match.group(0) ?? '');
      index++;
      continue;
    }
    var cursor = index + 1;
    var braced = false;
    if (replacement[cursor] == '{') {
      braced = true;
      cursor++;
    }
    final start = cursor;
    while (cursor < replacement.length &&
        cursor - start < 2 &&
        _isAsciiDigit(replacement.codeUnitAt(cursor))) {
      cursor++;
    }
    if (cursor == start ||
        (braced &&
            (cursor >= replacement.length || replacement[cursor] != '}'))) {
      output.write(char);
      continue;
    }
    final group = int.tryParse(replacement.substring(start, cursor));
    if (group == null || group > match.groupCount) {
      output.write(replacement.substring(index, braced ? cursor + 1 : cursor));
    } else {
      output.write(match.group(group) ?? '');
    }
    index = braced ? cursor : cursor - 1;
  }
  return output.toString();
}

bool _isAsciiDigit(int codeUnit) => codeUnit >= 48 && codeUnit <= 57;

String _trimString(String value, String trim) {
  var result = value;
  while (result.startsWith(trim)) {
    result = result.substring(trim.length);
  }
  while (result.endsWith(trim)) {
    result = result.substring(0, result.length - trim.length);
  }
  return result;
}
