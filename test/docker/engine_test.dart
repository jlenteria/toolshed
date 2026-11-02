import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/tools/docker/docker_engine.dart';

void main() {
  DockerEngineManager? discover(
    Map<String, String> bins, {
    required bool desktop,
  }) => discoverEngineManager(
    which: (name) => bins[name],
    desktopInstalled: desktop,
  );

  test('Colima wins when its binary is present', () {
    final m = discover({'colima': '/opt/homebrew/bin/colima'}, desktop: false);
    expect(m?.kind, DockerEngineKind.colima);
    expect(m?.label, 'Colima');
    expect(m?.start, ['/opt/homebrew/bin/colima', 'start']);
    expect(m?.stop, ['/opt/homebrew/bin/colima', 'stop']);
  });

  test('OrbStack is used when only orbctl exists', () {
    final m = discover({'orbctl': '/usr/local/bin/orbctl'}, desktop: false);
    expect(m?.kind, DockerEngineKind.orbstack);
    expect(m?.start, ['/usr/local/bin/orbctl', 'start']);
    expect(m?.stop, ['/usr/local/bin/orbctl', 'stop']);
  });

  test('Colima is preferred when both managers are installed', () {
    final m = discover({
      'colima': '/b/colima',
      'orbctl': '/b/orbctl',
    }, desktop: false);
    expect(m?.kind, DockerEngineKind.colima);
  });

  test('Docker Desktop is the last resort, and is opened not commanded', () {
    final m = discover({}, desktop: true);
    expect(m?.kind, DockerEngineKind.desktop);
    expect(m?.start, ['open', '-a', 'Docker']);
    expect(m?.stop, ['osascript', '-e', 'quit app "Docker"']);
  });

  test('a plain dockerd with no manager has nothing to start', () {
    expect(discover({}, desktop: false), isNull);
  });
}
