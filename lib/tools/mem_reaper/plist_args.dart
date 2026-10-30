import '../../models/tool_exception.dart';

/// Reads and rewrites a LaunchAgent's `ProgramArguments` array.
///
/// Positions are never hardcoded: the live plist and one edited by hand
/// differ in the flags they carry, so a flag's value is looked up at
/// indexOf(flag) + 1. When that lookup fails the edit is refused rather than
/// written into a guessed slot.
class PlistArgs {
  const PlistArgs(this.argv);

  final List<String> argv;

  /// The interpreter. Kept exactly as found: `/usr/bin/python3` is the 3.9
  /// Command Line Tools build, and mem_reaper only runs there because of its
  /// `from __future__ import annotations`. Rewriting it to a Homebrew python
  /// would break the agent the moment that upgrade is removed.
  String get interpreter => argv[0];

  String? get script => argv.length > 1 ? argv[1] : null;

  /// Index of the value that follows [flag].
  ///
  /// Throws when the flag is absent (the array was restructured) or is the last
  /// element (a truncated array), because either way we would be writing into
  /// a slot whose meaning we do not know.
  int valueIndex(String flag) {
    final i = argv.indexOf(flag);
    if (i < 0) {
      throw ToolException(
        'FLAG_MISSING',
        'The agent command line no longer has a $flag option, so the app '
            'refuses to guess where its value goes.',
        detail: 'argv = ${argv.join(' ')}',
      );
    }
    if (i + 1 >= argv.length) {
      throw ToolException(
        'FLAG_VALUE_MISSING',
        '$flag is the last entry in the agent command line — it has no value. '
            'Fix the plist before changing settings from the app.',
        detail: 'argv = ${argv.join(' ')}',
      );
    }
    return i + 1;
  }

  String raw(String flag) => argv[valueIndex(flag)];

  int intArg(String flag) {
    final value = raw(flag);
    final parsed = int.tryParse(value);
    if (parsed == null) {
      throw ToolException(
        'BAD_INT_ARG',
        '$flag is "$value" in the plist, which is not a number. '
            'Edit the plist by hand, or uninstall and reinstall the agent.',
      );
    }
    return parsed;
  }

  /// Null when the flag is absent, meaning the agent runs on mem_reaper's own
  /// default. A flag that is present but not a number still throws — that is a
  /// broken plist, not an unset option.
  int? optionalInt(String flag) => argv.contains(flag) ? intArg(flag) : null;

  /// A copy with each flag's value set, appending `flag value` for a flag the
  /// agent does not have yet (a plist written by hand may omit
  /// `--dialog-timeout` entirely).
  ///
  /// Safe against shifting: nothing is ever inserted before an existing
  /// element, so every earlier index still means the same thing, and each flag
  /// is looked up against the array as it stands.
  List<String> withValues(Map<String, Object> byFlag) {
    final updated = List<String>.of(argv);
    for (final entry in byFlag.entries) {
      final i = updated.indexOf(entry.key);
      if (i < 0) {
        updated
          ..add(entry.key)
          ..add('${entry.value}');
      } else {
        // If the flag was appended on an earlier iteration, its value is
        // already the element after it.
        if (i + 1 >= updated.length) {
          throw ToolException(
            'FLAG_VALUE_MISSING',
            '${entry.key} is the last entry in the agent command line, so it '
                'has no value slot to write into.',
            detail: 'argv = ${updated.join(' ')}',
          );
        }
        updated[i + 1] = '${entry.value}';
      }
    }
    return updated;
  }

  factory PlistArgs.fromProgramArguments(Object? value) {
    if (value is! List) {
      throw const ToolException(
        'NO_PROGRAM_ARGUMENTS',
        'The plist has no ProgramArguments array, so there is nothing to read '
            'the settings from.',
      );
    }
    final argv = value.map((e) => '$e').toList(growable: false);
    if (argv.isEmpty) {
      throw const ToolException(
        'EMPTY_PROGRAM_ARGUMENTS',
        'ProgramArguments is empty — the agent cannot run as written.',
      );
    }
    return PlistArgs(argv);
  }
}
