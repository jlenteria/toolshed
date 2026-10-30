import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/tools/mem_reaper/launchctl_parse.dart';

/// The fixture is real `launchctl print gui/501/com.bling.memreaper` output
/// from this machine. It matters because the same keys reappear at two tabs
/// inside the coalition blocks: `state = running` once, `state = active` twice.
void main() {
  late String output;

  setUpAll(() {
    output = File('test/fixtures/launchctl_print.txt').readAsStringSync();
  });

  test('reads the top-level fields, not the nested coalition ones', () {
    final info = LaunchctlInfo.parse(output);
    expect(info.state, 'running');
    expect(info.state, isNot('active'));
    expect(info.pid, isNotNull);
    expect(info.runs, 1);
    // A freshly bootstrapped service has never exited, and launchd says so in
    // words rather than a number.
    expect(info.lastExitCode, isNull);
    expect(info.isRunning, isTrue);
    expect(info.stdoutPath, '/Users/jlenteria/Library/Logs/mem_reaper.log');
    expect(
      info.path,
      '/Users/jlenteria/Library/LaunchAgents/com.bling.memreaper.plist',
    );
    expect(info.program, '/usr/bin/python3');
  });

  test('the coalition state lines are the trap this parser exists for', () {
    // A loose match picks them up as well, so it reports "active" for an agent
    // that is not running at all.
    final loose = RegExp(
      'state = (\\w+)',
    ).allMatches(output).map((m) => m.group(1)).toList();
    expect(loose, ['running', 'active', 'active']);

    const stopped =
        'gui/501/com.bling.memreaper = {\n'
        '\tstate = spawn queued\n'
        '\tresource coalition = {\n'
        '\t\tstate = active\n'
        '\t}\n'
        '}';
    expect(LaunchctlInfo.parse(stopped).state, 'spawn queued');
    expect(LaunchctlInfo.parse(stopped).isRunning, isFalse);
  });

  test('the two-tab state lines are still present in the fixture', () {
    expect('\t\tstate = active'.allMatches(output).length, 2);
  });

  test('missing service is recognised from exit code 113 and its text', () {
    final missing = File(
      'test/fixtures/launchctl_missing.txt',
    ).readAsStringSync();
    expect(LaunchctlInfo.notLoaded(113, missing), isTrue);
    expect(LaunchctlInfo.notLoaded(1, missing), isTrue);
    expect(LaunchctlInfo.notLoaded(0, output), isFalse);
  });

  test('bootout of an unloaded agent counts as success', () {
    expect(
      LaunchctlInfo.alreadyGone(3, 'Boot-out failed: 3: No such process'),
      isTrue,
    );
    expect(LaunchctlInfo.alreadyGone(0, ''), isFalse);
  });

  test('absent fields stay null instead of throwing', () {
    final info = LaunchctlInfo.parse('gui/501/com.example.thing = {\n}\n');
    expect(info.state, isNull);
    expect(info.pid, isNull);
    expect(info.runs, isNull);
    expect(info.lastExitCode, isNull);
    expect(info.isRunning, isFalse);
  });

  test('an unparseable pid is ignored rather than crashing the panel', () {
    expect(LaunchctlInfo.parse('\tpid = (nothing)').pid, isNull);
  });

  test('a numeric last exit code is still read', () {
    // The live fixture only appears here freshly bootstrapped, where launchd
    // writes "(never exited)"; an agent that has died once writes a number.
    expect(LaunchctlInfo.parse('\tlast exit code = 1\n').lastExitCode, 1);
  });

  test('jetsam memory limits marked (unlimited) are not read as paths', () {
    // `\tjetsam memory limit (active) = (unlimited)` and friends exist in the
    // output; nothing may mistake them for a value.
    final info = LaunchctlInfo.parse(output);
    expect(info.stdoutPath, isNot(contains('unlimited')));
  });
}
