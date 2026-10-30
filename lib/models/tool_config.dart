/// The settings a tool exposes, whatever the tool is.
///
/// The console reads and writes these generically — the front page shows a
/// [blurb], the detail screen refuses to save when [isValid] is false, and each
/// backend knows how to put its own concrete config on disk. Two tools, two
/// shapes of settings, one code path in the registry.
abstract class ToolConfig {
  /// Every reason this config must not be written, in the order the user should
  /// read them.
  List<String> get problems;

  bool get isValid => problems.isEmpty;

  /// One line for the tool list, so a card can describe the active settings
  /// without knowing what kind of tool it is describing.
  String get blurb;
}
