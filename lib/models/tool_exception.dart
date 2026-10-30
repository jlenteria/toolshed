/// A failure the UI is expected to show rather than swallow.
///
/// [message] is launchctl/plutil/Android's own stderr when there is one, so the
/// user sees the real reason instead of "something went wrong".
class ToolException implements Exception {
  const ToolException(this.code, this.message, {this.detail});

  final String code;
  final String message;

  /// Optional extra context — a plist path, a launchctl exit code, a note about
  /// a second agent declaring the same label.
  final String? detail;

  @override
  String toString() =>
      detail == null ? '[$code] $message' : '[$code] $message\n$detail';
}
