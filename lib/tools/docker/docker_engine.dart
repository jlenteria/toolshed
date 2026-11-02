import 'dart:io';

import '../../platform/paths.dart';

/// Which program actually starts and stops the engine behind the `docker` CLI.
enum DockerEngineKind { colima, orbstack, desktop }

/// A discovered engine manager: the thing to run to bring the daemon up or take
/// it down when the daemon is not answering.
///
/// The app holds no idea how an engine is started; it keeps only the command the
/// manager itself advertises — `colima start`, `orbctl start`, or opening
/// Docker Desktop — and runs it. [start] and [stop] are full argv lists whose
/// first element is the executable, so the caller never has to know whether a
/// given engine has a CLI at all.
class DockerEngineManager {
  const DockerEngineManager({
    required this.kind,
    required this.label,
    required this.start,
    required this.stop,
  });

  final DockerEngineKind kind;

  /// Human name used on the button, so "Start Colima" says what will run.
  final String label;

  /// argv that starts the engine.
  final List<String> start;

  /// argv that stops it.
  final List<String> stop;

  String get startExecutable => start.first;
}

/// The engine manager installed here, or `null` when nothing can be started.
///
/// Detection is synchronous and purely about what exists on disk, so a capability
/// can be drawn from it before any process runs. It prefers a manager with a real
/// command-line entry point (Colima, then OrbStack's `orbctl`) and falls back to
/// Docker Desktop, which is opened rather than commanded. A machine running a
/// plain `dockerd` with no manager is honestly reported as having nothing to
/// start from the console.
///
/// A dangling symlink from a half-removed engine does not count as installed:
/// [which] follows the link and an uninstalled OrbStack leaves `orbctl` pointing
/// at a deleted bundle, so it is skipped and the next candidate wins — which is
/// exactly the OrbStack-to-Colima switch this console is built to survive.
DockerEngineManager? discoverEngineManager({
  String? Function(String name)? which,
  bool? desktopInstalled,
}) {
  final resolve = which ?? Paths.which;

  final colima = resolve('colima');
  if (colima != null) {
    return DockerEngineManager(
      kind: DockerEngineKind.colima,
      label: 'Colima',
      start: [colima, 'start'],
      stop: [colima, 'stop'],
    );
  }

  final orbctl = resolve('orbctl');
  if (orbctl != null) {
    return DockerEngineManager(
      kind: DockerEngineKind.orbstack,
      label: 'OrbStack',
      start: [orbctl, 'start'],
      stop: [orbctl, 'stop'],
    );
  }

  final hasDesktop =
      desktopInstalled ?? Directory('/Applications/Docker.app').existsSync();
  if (hasDesktop) {
    return const DockerEngineManager(
      kind: DockerEngineKind.desktop,
      label: 'Docker Desktop',
      start: ['open', '-a', 'Docker'],
      stop: ['osascript', '-e', 'quit app "Docker"'],
    );
  }

  return null;
}
