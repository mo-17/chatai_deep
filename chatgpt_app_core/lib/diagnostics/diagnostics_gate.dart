final class DiagnosticsGate {
  const DiagnosticsGate._();

  static bool enabled({
    required bool buildConfigured,
    required bool userConsented,
    required bool remoteDisabled,
  }) =>
      buildConfigured && userConsented && !remoteDisabled;
}
