import 'dart:io';

import '../../models/tool_exception.dart';
import '../../platform/runner.dart';

/// Where the fan daemon lives once installed.
///
/// Root-owned paths throughout: a daemon that runs as root must not be
/// startable from a binary the user can rewrite, which is why the installer
/// checks ownership after copying rather than trusting `install` to have done
/// the right thing.
class FanDaemonPaths {
  FanDaemonPaths._();

  static const String label = 'com.bling.toolshed.fand';
  static const String binary = '/usr/local/bin/toolshed-fand';
  static const String plist = '/Library/LaunchDaemons/$label.plist';
  static const String socket = '/var/run/toolshed-fand.sock';
  static const String log = '/Library/Logs/toolshed-fand.log';

  /// launchd's own capture of stdout/stderr. The daemon writes its log itself,
  /// so this file exists for the one thing the daemon cannot log: a failure that
  /// happens before the log is open, such as a socket that cannot be bound.
  static const String launchdLog = '/Library/Logs/toolshed-fand.launchd.log';

  static const String backupDir = '/var/tmp';

  static bool get isInstalled =>
      File(plist).existsSync() && File(binary).existsSync();
}

/// Installs, starts, stops and removes the root LaunchDaemon.
///
/// Every method here is one `do shell script … with administrator privileges`
/// call: one password prompt per action rather than one per command, and the
/// whole action either happens or does not. Nothing in this file writes to the
/// SMC — it moves files and talks to launchd, which is all the privilege is for.
class FanDaemonInstaller {
  FanDaemonInstaller({ProcessRunner? runner})
    : _runner = runner ?? const ProcessRunner();

  final ProcessRunner _runner;

  /// A prompt the user can read as an answer to what they just clicked.
  static const String _prompt =
      'toolshed needs root to install the fan daemon: reading temperatures '
      'works without privilege, but writing a fan speed returns '
      'kIOReturnNotPrivileged for any other uid.';

  bool get isInstalled => FanDaemonPaths.isInstalled;

  bool get plistPresent => File(FanDaemonPaths.plist).existsSync();

  bool get binaryPresent => File(FanDaemonPaths.binary).existsSync();

  /// Copies the helper, writes the LaunchDaemon and loads it.
  ///
  /// [sourceBinary] is verified before it is handed to root: the app will not
  /// make a LaunchDaemon out of a file that does not answer `selfcheck`, because
  /// that is the one mistake a privileged installer cannot take back.
  Future<void> install({required String sourceBinary}) async {
    if (!File(sourceBinary).existsSync()) {
      throw ToolException(
        'NO_HELPER',
        'There is no helper at $sourceBinary to install.',
        detail: 'Build it with `make fanctl` (swiftc macos/fanctl/main.swift).',
      );
    }
    final verified = await _runner.run(sourceBinary, ['selfcheck', '--json']);
    if (!verified.ok || !verified.stdout.contains('"failures":[]')) {
      throw ToolException(
        'HELPER_UNSOUND',
        'Refused to install a helper that did not pass its own policy '
            'selfcheck.',
        detail:
            'binary: $sourceBinary\nexit: ${verified.exitCode}\n'
            '${verified.blurb}',
      );
    }

    await _privileged(
      [
        'mkdir -p /usr/local/bin /Library/Logs',
        // install, not cp: it sets owner and mode in the same step, so there is
        // no window where a root-owned binary is world-writable. Skipped when the
        // source already *is* the destination, because `install` refuses to copy
        // a file onto itself and a reinstall with nothing new to install is that
        // case, not an error.
        '[ ${_q(sourceBinary)} -ef ${_q(FanDaemonPaths.binary)} ] || '
            'install -o root -g wheel -m 0755 ${_q(sourceBinary)} '
            '${_q(FanDaemonPaths.binary)}',
        // Checked before launchd is asked to run the file, so a binary that came
        // out owned by anyone but root is never started.
        '[ "\$(stat -f %Su ${_q(FanDaemonPaths.binary)})" = root ]',
        'printf %s ${_q(plistTemplate())} > ${_q(FanDaemonPaths.plist)}',
        'chown root:wheel ${_q(FanDaemonPaths.plist)}',
        'chmod 0644 ${_q(FanDaemonPaths.plist)}',
        'plutil -lint ${_q(FanDaemonPaths.plist)} > /dev/null',
        bootstrapScript,
      ].join(' && '),
    );
  }

  Future<void> start() => _privileged(
    'test -f ${_q(FanDaemonPaths.plist)} && $bootstrapScript',
    hint:
        'The daemon is not installed, so there is nothing to start. '
        'Install it first.',
  );

  /// bootout, not kill: with KeepAlive the pid would simply be respawned, and a
  /// button that appeared to do nothing is worse than one that is honest.
  ///
  /// The daemon's SIGTERM handler returns the fan to Apple before it exits, so
  /// stopping the daemon never leaves the fan forced.
  Future<void> stop() => _privileged(bootoutScript);

  /// Unload, then keep the plist rather than deleting it outright — it is the
  /// only record of what was installed, and a delete cannot be undone. The copy
  /// lands in /var/tmp, which root owns: a backup in the user's home would be a
  /// file another process could quietly remove later.
  Future<void> uninstall() => _privileged(
    '$bootoutScript; '
    'mv ${_q(FanDaemonPaths.plist)} ${_q(_backupPath(_stamp))} 2>/dev/null '
    '|| cp ${_q(FanDaemonPaths.plist)} ${_q(FanDaemonPaths.backupDir)}; '
    'rm -f ${_q(FanDaemonPaths.plist)} ${_q(FanDaemonPaths.binary)}',
    hint: 'Nothing was loaded, so uninstall only had to remove the files.',
  );

  static String _backupPath(String stamp) =>
      '${FanDaemonPaths.backupDir}/${FanDaemonPaths.label}'
      '.plist.uninstalled-$stamp';

  /// Where the most recent uninstalled plist was kept, for the UI to name.
  String? get lastBackup {
    final dir = Directory(FanDaemonPaths.backupDir);
    if (!dir.existsSync()) return null;
    final candidates =
        dir
            .listSync(followLinks: false)
            .whereType<File>()
            .where(
              (f) =>
                  f.path.contains('${FanDaemonPaths.label}.plist.uninstalled-'),
            )
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    return candidates.isEmpty ? null : candidates.last.path;
  }

  // ------------------------------------------------------------------- launchd

  /// `bootstrap` exits non-zero when the job is already loaded, which is success
  /// as far as the user is concerned; `kickstart -k` then makes sure the running
  /// process is the binary that was just replaced rather than one that predates
  /// the install.
  static String get bootstrapScript =>
      'launchctl enable system/${FanDaemonPaths.label}; '
      'launchctl bootstrap system ${_q(FanDaemonPaths.plist)} || true; '
      'launchctl kickstart -k system/${FanDaemonPaths.label}';

  /// `disable` is what makes Stop survive a reboot: bootout only unloads the job
  /// from the running launchd, and the next boot would read the plist again.
  /// Start reverses it with `enable`.
  ///
  /// A bootout of a job that is not loaded exits 3, which is the state the button
  /// asked for, so it is tolerated rather than reported as a failure.
  static String get bootoutScript =>
      'launchctl bootout system/${FanDaemonPaths.label} || true; '
      'launchctl disable system/${FanDaemonPaths.label} || true';

  static String get _stamp =>
      DateTime.now().toIso8601String().replaceAll(':', '-');

  // --------------------------------------------------------------- privileges

  /// Runs [script] as root through one authorization prompt.
  Future<void> _privileged(String script, {String? hint}) async {
    final result = await _runner.run('osascript', [
      '-e',
      appleScript(script),
    ], timeout: const Duration(minutes: 3));
    if (result.ok) return;

    final blurb = result.blurb;
    final canceled = blurb.contains('-128') || blurb.contains('User canceled');
    throw ToolException(
      canceled ? 'AUTH_CANCELED' : 'PRIVILEGED_FAILED',
      canceled
          ? 'The administrator prompt was dismissed, so nothing was changed.'
          : 'The privileged step failed: $blurb',
      detail: [
        'command: $script',
        ?hint,
        if (canceled)
          'The fan daemon is not running. Temperature readings still work '
              'without root.',
      ].join('\n'),
    );
  }

  /// The exact AppleScript handed to `osascript`.
  ///
  /// Public and free of side effects so a test can run it through a real
  /// `do shell script` as the current user — [privileged] off — and check that a
  /// plist full of quotes, tabs and newlines arrives at `/bin/sh` unchanged. That
  /// is the only way to know the two layers of escaping agree, and getting it
  /// wrong here means a root shell command that is not the one that was asked
  /// for.
  static String appleScript(String script, {bool privileged = true}) =>
      'do shell script "${_appleScriptEscape(script)}"'
      '${privileged ? ' with administrator privileges with prompt '
                '"${_appleScriptEscape(_prompt)}"' : ''}';

  /// Single quotes for `/bin/sh`. Everything the installer runs is built from
  /// these, so a path containing a space or a quote cannot become a command.
  static String _q(String value) => "'${value.replaceAll("'", r"'\''")}'";

  /// `do shell script` takes an AppleScript string literal, so the shell command
  /// is escaped once more on the way in. Newlines survive rather than being
  /// collapsed, because the plist is a document a person may read afterwards.
  static String _appleScriptEscape(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r')
      .replaceAll('\t', r'\t');

  /// The LaunchDaemon itself.
  ///
  /// `KeepAlive` is a dictionary, not `true`: a crash must respawn (the fresh
  /// daemon hands any forced fan back to Apple as it comes up), but a clean exit
  /// — which is what our own SIGTERM handler produces — must stay stopped, or
  /// pressing Stop would be undone a second later by a daemon that had just
  /// released the fan.
  static String plistTemplate() => [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    '<plist version="1.0">',
    '<dict>',
    '\t<key>Label</key><string>${FanDaemonPaths.label}</string>',
    '\t<key>ProgramArguments</key>',
    '\t<array>',
    '\t\t<string>${FanDaemonPaths.binary}</string>',
    '\t\t<string>serve</string>',
    '\t</array>',
    // The daemon owns its log; launchd's capture is for the failure that
    // happens before a log can be opened.
    '\t<key>RunAtLoad</key><true/>',
    '\t<key>KeepAlive</key>',
    '\t<dict>',
    '\t\t<key>Crashed</key><true/>',
    '\t\t<key>SuccessfulExit</key><false/>',
    '\t</dict>',
    '\t<key>ThrottleInterval</key><integer>10</integer>',
    '\t<key>StandardOutPath</key><string>${FanDaemonPaths.launchdLog}</string>',
    '\t<key>StandardErrorPath</key><string>${FanDaemonPaths.launchdLog}</string>',
    '</dict>',
    '</plist>',
  ].join('\n');
}
