import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/agent_status.dart';
import '../models/tool_config.dart';
import '../models/tool_descriptor.dart';
import '../models/tool_exception.dart';
import 'app_lock/app_lock_backend.dart';
import 'app_lock/lock_agent.dart';
import 'dev_sweeper/dev_sweeper_backend.dart';
import 'dev_sweeper/sweep_target.dart';
import 'docker/docker_backend.dart';
import 'docker/docker_engine.dart';
import 'docker/docker_models.dart';
import 'fan_ctl/fan_backend.dart';
import 'fan_ctl/fan_daemon.dart';
import 'fan_ctl/fan_policy.dart';
import 'fan_ctl/fan_telemetry.dart';
import 'mem_reaper/android_backend.dart';
import 'mem_reaper/macos_backend.dart';
import 'mem_reaper/managed_app.dart';
import 'mem_reaper/stop_outcome.dart';
import 'port_warden/port_backend.dart';
import 'port_warden/port_listener.dart';
import 'tool_backend.dart';
import 'unsupported_backend.dart';

/// One tool plus the state the console shows for it.
class ToolEntry {
  ToolEntry({required this.backend, this.busy = false});

  ToolBackend backend;
  AgentStatus? status;

  /// Whatever shape this tool's settings have. The list screen shows
  /// [ToolConfig.blurb] without knowing which tool it is describing.
  ToolConfig? config;

  /// Serialises actions per tool so two taps cannot queue two bootstraps.
  bool busy;

  /// The message from the last failure, kept so the detail screen can show it
  /// next to the button that caused it rather than in a vanishing snackbar.
  String? error;

  Capabilities get capabilities => backend.capabilities;
  ToolDescriptor get descriptor => backend.descriptor;
}

/// Resolves each tool's backend for the running OS and holds the console state.
class ToolRegistry extends ChangeNotifier {
  ToolRegistry._(this._entries);

  static ToolRegistry? _instance;

  static ToolRegistry get instance => _instance ??= _build();

  /// Test hook: a registry over backends you supply.
  static ToolRegistry forBackends(List<ToolBackend> backends) =>
      ToolRegistry._([for (final b in backends) ToolEntry(backend: b)]);

  final List<ToolEntry> _entries;

  List<ToolEntry> get tools => List<ToolEntry>.unmodifiable(_entries);

  ToolEntry? byId(String id) {
    for (final entry in _entries) {
      if (entry.descriptor.id == id) return entry;
    }
    return null;
  }

  static ToolRegistry _build() => ToolRegistry._([
    ToolEntry(backend: _memReaperBackend()),
    ToolEntry(backend: _portWardenBackend()),
    ToolEntry(backend: _devSweeperBackend()),
    ToolEntry(backend: _dockerBackend()),
    ToolEntry(backend: _fanBackend()),
    ToolEntry(backend: _appLockBackend()),
  ]);

  /// Which backend a tool gets is decided once, here. Windows and Linux get an
  /// object that throws on every method, so no screen can render a working
  /// button for an OS where the tool cannot run.
  static ToolBackend _memReaperBackend() {
    if (Platform.isMacOS) return MacOSMemReaperBackend();
    if (Platform.isAndroid) return const AndroidMemReaperBackend();
    if (Platform.isWindows) {
      return UnsupportedToolBackend(
        descriptor: const ToolDescriptor(
          id: 'mem_reaper',
          name: 'Memory Reaper',
          summary:
              'Force-stops over-limit processes after you confirm each '
              'one.',
          implPath: 'mem_reaper.py',
        ),
        reason:
            'mem_reaper.py is macOS-only: it reads memory with `top`, '
            'confirms with an AppleScript dialog and installs itself with '
            'launchctl. A Windows equivalent needs a native service and has not '
            'been written.',
      );
    }
    return UnsupportedToolBackend(
      descriptor: const ToolDescriptor(
        id: 'mem_reaper',
        name: 'Memory Reaper',
        summary: 'Force-stops over-limit processes after you confirm each one.',
        implPath: 'mem_reaper.py',
      ),
      reason:
          'mem_reaper.py is macOS-only: it reads memory with `top` and '
          'installs itself with launchctl. On Linux it has never been run, so '
          'the app reports it unavailable instead of guessing at a port.',
    );
  }

  /// Port listing needs only a command that prints the socket table, so every
  /// desktop gets a real backend. Android gets none: its socket table has no
  /// owner an unrooted app can read, and it cannot stop another app anyway.
  static ToolBackend _portWardenBackend() {
    if (Platform.isMacOS) return MacOSPortWardenBackend();
    if (Platform.isLinux) return LinuxPortWardenBackend();
    if (Platform.isWindows) return WindowsPortWardenBackend();
    return UnsupportedToolBackend(
      descriptor: const ToolDescriptor(
        id: kPortWardenId,
        name: 'Port Warden',
        summary: 'Shows which process is listening on each port.',
        implPath: 'lsof',
      ),
      reason:
          'Android gives an app no readable socket-to-process table: '
          '/proc/net/tcp lists sockets without the pids that own them, and '
          'mapping them needs root. It also cannot stop another app. This tool '
          'is for the desktop.',
    );
  }

  /// Dev Sweeper needs only the file system and the platform Trash, so every
  /// desktop gets a real backend. Android gets none: an unrooted app can see
  /// its own cache and no one else's, which is not the developer caches this
  /// tool is for.
  static ToolBackend _devSweeperBackend() {
    if (Platform.isMacOS) return MacDevSweeperBackend();
    if (Platform.isLinux) return LinuxDevSweeperBackend();
    if (Platform.isWindows) return WindowsDevSweeperBackend();
    return UnsupportedToolBackend(
      descriptor: const ToolDescriptor(
        id: kDevSweeperId,
        name: 'Dev Sweeper',
        summary:
            'Finds build caches and node_modules, and moves the ones you pick '
            'to the Trash.',
        implPath: 'du · find · Trash',
      ),
      reason:
          'Android gives an app no view of other apps\' caches: an unrooted '
          'phone exposes only this app\'s own storage. The developer caches '
          'this tool is for are out of reach, so it is listed rather than '
          'offering a button that cannot work.',
    );
  }

  /// Docker is driven through the `docker` CLI, so every desktop gets a real
  /// backend — and on every desktop the backend itself reports `helperMissing`
  /// when no CLI is found, so the tool is listed with a reason rather than dead
  /// buttons. Android is excluded: an unrooted app has no docker CLI, no daemon
  /// and no engine context to reach, so there is nothing for the console to
  /// drive.
  static ToolBackend _dockerBackend() {
    if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
      return DockerBackend();
    }
    return UnsupportedToolBackend(
      descriptor: const ToolDescriptor(
        id: kDockerId,
        name: 'Docker',
        summary:
            'Lists containers and images and lets you start, stop, restart or '
            'remove a container and prune dangling images, through the docker '
            'CLI.',
        implPath: 'docker',
      ),
      reason:
          'Docker runs on the machine that owns the engine. An Android app has '
          'no docker CLI, no daemon and no context to talk to, so this tool '
          'is for the desktop.',
    );
  }

  /// Fan control exists only on macOS: the SMC is an Apple device service, and
  /// `IOConnectCallStructMethod` on `AppleSMC` has no Windows or Linux
  /// equivalent that a portable app could reach. Elsewhere the tool is listed
  /// with a reason rather than a half-ported button.
  static ToolBackend _fanBackend() {
    if (Platform.isMacOS) return MacOSFanBackend();
    const descriptor = ToolDescriptor(
      id: 'fan_ctl',
      name: 'Fan Control',
      summary:
          'Holds the fan up once a temperature sensor crosses your threshold, '
          'then hands it back to the firmware when it cools off.',
      implPath: 'macos/fanctl/main.swift',
    );
    return UnsupportedToolBackend(
      descriptor: descriptor,
      reason: Platform.isAndroid
          ? 'Android gives an app no way to touch the thermal controller. '
                'Fan speed on a phone is the kernel thermal daemon\'s decision '
                'alone, and an unrooted app cannot reach it.'
          : 'Fan control drives the Apple System Management Controller through '
                'IOKit, which exists only on macOS. A Windows or Linux '
                'equivalent would be a different tool with different hardware, '
                'not a port of this one.',
    );
  }

  /// App lock is a macOS tool because the whole mechanism is macOS: an
  /// `NSWorkspace` launch notification, `terminate()` on a running application,
  /// and a per-user LaunchAgent. Android has no way for one app to close another
  /// (that is the device-admin/API-consent path, and it does not offer a
  /// per-app gate either), and Windows would be a different tool against
  /// different APIs, so both are listed with a reason rather than a button.
  static ToolBackend _appLockBackend() {
    if (Platform.isMacOS) return MacAppLockBackend();
    const descriptor = ToolDescriptor(
      id: 'app_lock',
      name: 'App Lock',
      summary:
          'Watches the apps on your lock list and closes them when they are '
          'launched, until you type the passphrase.',
      implPath: 'macos/lockd/main.swift',
    );
    return UnsupportedToolBackend(
      descriptor: descriptor,
      reason: Platform.isAndroid
          ? 'Android does not let one app close another. A device-admin app can '
                'lock the *screen*, but a per-app gate is the system\'s own '
                'Digital Wellbeing feature and no third-party app can install '
                'one.'
          : 'App lock closes another process by asking it to quit, which on '
                'macOS is an NSWorkspace application handle plus `terminate()`. '
                'Windows and Linux would need a different mechanism entirely, '
                'and none has been written.',
    );
  }

  /// Re-reads each tool's state. The entry is busy for the length of the read:
  /// that is what draws the progress bar in the body of the detail screen and
  /// the spinner on the tool card, and it also keeps a button press from
  /// landing halfway through a state the user is watching being replaced.
  Future<void> refresh({String? id}) async {
    for (final entry in _entries) {
      if (id != null && entry.descriptor.id != id) continue;
      if (entry.busy) continue;
      entry.busy = true;
      notifyListeners();
      await _run(entry, 'status', (b) async {
        entry.status = await b.status();
        if (entry.capabilities.can(ToolAction.configure)) {
          try {
            entry.config = await b.readConfig();
          } on ToolException {
            // A status line that still rendered is more useful than an error
            // screen, and the config sheet will surface the same failure.
            entry.config = null;
          }
        }
      });
      entry.busy = false;
      notifyListeners();
    }
  }

  /// Runs one backend action, then refreshes that tool so the UI cannot show a
  /// state the OS has already moved past.
  Future<bool> act(
    String id,
    ToolAction action,
    Future<void> Function(ToolBackend backend) body,
  ) async {
    final entry = byId(id);
    if (entry == null || entry.busy) return false;
    if (!entry.capabilities.can(action)) {
      entry.error = entry.capabilities.reason;
      notifyListeners();
      return false;
    }
    entry.busy = true;
    entry.error = null;
    notifyListeners();
    final ok = await _run(entry, action.name, body);
    entry.busy = false;
    if (ok) await _refreshOne(entry);
    notifyListeners();
    return ok;
  }

  Future<void> _refreshOne(ToolEntry entry) async {
    await _run(entry, 'read status', (b) async {
      entry.status = await b.status();
      if (entry.capabilities.can(ToolAction.configure)) {
        entry.config = await b.readConfig();
      }
    });
  }

  Future<bool> _run(
    ToolEntry entry,
    String what,
    Future<void> Function(ToolBackend) body,
  ) async {
    try {
      await body(entry.backend);
      return true;
    } on ToolException catch (e) {
      entry.error = '$what: $e';
      return false;
    } catch (e) {
      entry.error = '$what: unexpected failure — $e';
      return false;
    } finally {
      notifyListeners();
    }
  }

  // Convenience wrappers the detail screen calls, so the action list lives in
  // one place and every path goes through the busy guard.

  Future<bool> start(String id) => act(id, ToolAction.start, (b) => b.start());

  Future<bool> stop(String id) => act(id, ToolAction.stop, (b) => b.stop());

  Future<bool> install(String id) =>
      act(id, ToolAction.install, (b) => b.install());

  /// Replaces the installed helper with the one this app carries. The lock has
  /// no separate update verb: installing is the update, and the installer boots
  /// the old watcher out before it copies, so the new binary is what runs.
  Future<bool> updateAgent(String id) =>
      act(id, ToolAction.update, (b) => b.install());

  Future<bool> uninstall(String id) =>
      act(id, ToolAction.uninstall, (b) => b.uninstall());

  Future<bool> reapNow(String id) => act(id, ToolAction.reapNow, (b) {
    if (b case final ProcessReaper reaper) return reaper.reapNow();
    throw ToolException('NO_REAPER', byId(id)?.capabilities.reason ?? '');
  });

  /// Null when the request could not be made at all ([ToolEntry.error] says
  /// why); otherwise mem_reaper's own verdict, which may still be a refusal.
  Future<StopOutcome?> stopProcess(
    String id,
    ManagedApp app, {
    bool immediate = false,
  }) => _ask<StopOutcome>(id, ToolAction.forceStop, (b) {
    if (b case final ProcessStopper stopper) {
      return stopper.stopProcess(app, immediate: immediate);
    }
    throw ToolException('NO_STOPPER', byId(id)?.capabilities.reason ?? '');
  });

  /// The listening sockets as the OS reports them. A read, not an action:
  /// nothing is changed, so it does not take the busy guard.
  Future<List<PortListener>> listening(String id) => _portsAt(id).listening();

  PortInspector _portsAt(String id) {
    final entry = byId(id);
    if (entry == null) {
      throw ToolException('NO_TOOL', 'There is no tool called "$id".');
    }
    if (!entry.capabilities.can(ToolAction.showPorts)) {
      throw ToolException('UNAVAILABLE', entry.capabilities.reason);
    }
    if (entry.backend case final PortInspector inspector) return inspector;
    throw ToolException('NO_PORTS', entry.capabilities.reason);
  }

  /// The containers, images and disk usage as the engine reported them. A read,
  /// so like [listening] it skips the busy guard.
  Future<DockerInventory> dockerInventory(String id) =>
      _dockerAt(id).inventory();

  /// Sends one lifecycle command. Null when it could not be sent at all
  /// ([ToolEntry.error] says why); otherwise the docker CLI's own verdict. The
  /// capability checked is the one matching [op], so the console can only ask
  /// for what the current platform advertised.
  Future<DockerActionResult?> dockerAction(
    String id,
    DockerContainer container,
    DockerOp op,
  ) => _ask<DockerActionResult>(id, _dockerActionFor(op), (b) async {
    if (b case final DockerManager docker) {
      return docker.containerAction(container, op);
    }
    throw ToolException('NO_DOCKER', byId(id)?.capabilities.reason ?? '');
  });

  Future<DockerActionResult?> dockerPrune(String id) =>
      _ask<DockerActionResult>(id, ToolAction.dockerPrune, (b) async {
        if (b case final DockerManager docker) {
          return docker.pruneImages();
        }
        throw ToolException('NO_DOCKER', byId(id)?.capabilities.reason ?? '');
      });

  /// Opens a published port in the browser. Goes through the busy guard like any
  /// action, and is checked against the same capability the console drew the
  /// clickable link under, so a link can never be tapped when the platform has
  /// no browser handler advertised.
  Future<DockerActionResult?> dockerOpenPort(
    String id,
    DockerPortMapping port,
  ) => _ask<DockerActionResult>(id, ToolAction.dockerOpenPort, (b) async {
    if (b case final DockerManager docker) {
      return docker.openPort(port);
    }
    throw ToolException('NO_DOCKER', byId(id)?.capabilities.reason ?? '');
  });

  /// The engine manager that can be started/stopped here, for labelling the
  /// button. A read with no side effect, and it does not go through the busy
  /// guard: knowing what owns the engine is not an action on it. Null when
  /// nothing is installed that the console can start.
  DockerEngineManager? dockerEngine(String id) {
    if (byId(id)?.backend case final DockerManager docker) {
      return docker.engineManager;
    }
    return null;
  }

  /// Brings the engine up through its own manager. Available whenever a manager
  /// was found — including with no CLI and no daemon yet, which is the whole
  /// point of starting one from here.
  Future<DockerActionResult?> dockerStartEngine(String id) =>
      _ask<DockerActionResult>(id, ToolAction.dockerStartEngine, (b) async {
        if (b case final DockerManager docker) {
          return docker.startEngine();
        }
        throw ToolException('NO_DOCKER', byId(id)?.capabilities.reason ?? '');
      });

  /// Takes the engine down. Confirmed in the console first, because it stops
  /// every running container with it.
  Future<DockerActionResult?> dockerStopEngine(String id) =>
      _ask<DockerActionResult>(id, ToolAction.dockerStopEngine, (b) async {
        if (b case final DockerManager docker) {
          return docker.stopEngine();
        }
        throw ToolException('NO_DOCKER', byId(id)?.capabilities.reason ?? '');
      });

  static ToolAction _dockerActionFor(DockerOp op) => switch (op) {
    DockerOp.start => ToolAction.dockerStart,
    DockerOp.stop => ToolAction.dockerStop,
    DockerOp.restart => ToolAction.dockerRestart,
    DockerOp.remove => ToolAction.dockerRemove,
  };

  DockerManager _dockerAt(String id) {
    final entry = byId(id);
    if (entry == null) {
      throw ToolException('NO_TOOL', 'There is no tool called "$id".');
    }
    if (!entry.capabilities.can(ToolAction.showDocker)) {
      throw ToolException('UNAVAILABLE', entry.capabilities.reason);
    }
    if (entry.backend case final DockerManager docker) return docker;
    throw ToolException('NO_DOCKER', entry.capabilities.reason);
  }

  /// The caches and node_modules as they were measured at scan time. A read, so
  /// it skips the busy guard; the move goes through it.
  Future<SweepReport> sweepTargets(String id) => _sweeperAt(id).scanCaches();

  /// Null when the request could not be made at all ([ToolEntry.error] says
  /// why); otherwise the Trash's own tally, which may contain failures.
  Future<SweepOutcome?> trashCaches(String id, List<SweepTarget> targets) =>
      _ask<SweepOutcome>(
        id,
        ToolAction.trashCaches,
        (b) => _sweeper(b, id).trashCaches(targets),
      );

  CacheSweeper _sweeperAt(String id) {
    final entry = byId(id);
    if (entry == null) {
      throw ToolException('NO_TOOL', 'There is no tool called "$id".');
    }
    if (!entry.capabilities.can(ToolAction.showCaches)) {
      throw ToolException('UNAVAILABLE', entry.capabilities.reason);
    }
    return _sweeper(entry.backend, id);
  }

  CacheSweeper _sweeper(ToolBackend backend, String id) {
    if (backend case final CacheSweeper sweeper) return sweeper;
    throw ToolException(
      'NO_SWEEPER',
      byId(id)?.capabilities.reason ??
          'This tool does not reclaim disk space, so nothing was moved.',
    );
  }

  Future<bool> saveConfig(String id, ToolConfig config) =>
      act(id, ToolAction.configure, (b) => b.writeConfig(config));

  Future<bool> engageFan(String id, FanPolicy policy) =>
      act(id, ToolAction.engage, (b) => _fan(b, id).engage(policy));

  Future<bool> releaseFan(String id) =>
      act(id, ToolAction.releaseControl, (b) => _fan(b, id).releaseControl());

  // App lock. The reads go straight to the helper; the writes go through the
  // busy guard, because a second tap while a passphrase is being hashed would
  // only queue a second dialog behind the first.

  Future<List<LockableApp>> lockableApps(String id) =>
      _lockAt(id).installedApps();

  Future<LockAgentInfo> lockInfo(String id) => _lockAt(id).lockStatus();

  Future<bool> setPassphrase(String id, String passphrase) => act(
    id,
    ToolAction.setPassphrase,
    (b) => _lock(b, id).setPassphrase(passphrase),
  );

  /// Three answers, not two: null means the check could not be made (and
  /// [ToolEntry.error] says why), while false is the helper's own "no".
  Future<bool?> verifyPassphrase(String id, String passphrase) => _ask<bool>(
    id,
    ToolAction.unlockApp,
    (b) => _lock(b, id).verifyPassphrase(passphrase),
  );

  Future<bool?> unlockApp(String id, String bundleId, String passphrase) =>
      _ask<bool>(
        id,
        ToolAction.unlockApp,
        (b) async => (await _lock(b, id).unlock(bundleId, passphrase)) != null,
      );

  Future<bool> revokeUnlock(String id, String bundleId) =>
      act(id, ToolAction.unlockApp, (b) => _lock(b, id).revokeUnlock(bundleId));

  Future<bool?> closeApp(String id, String bundleId, {bool force = false}) =>
      _ask<bool>(
        id,
        ToolAction.closeApp,
        (b) => _lock(b, id).closeApp(bundleId, force: force),
      );

  Future<bool?> testLockPrompt(
    String id,
    String bundleId, {
    String? name,
    int? timeoutSeconds,
  }) => _ask<bool>(
    id,
    ToolAction.unlockApp,
    (b) => _lock(
      b,
      id,
    ).testPrompt(bundleId, name: name, timeoutSeconds: timeoutSeconds),
  );

  /// [act] with a return value. The state machine is the same one [act] drives —
  /// busy guard, capability check, error recorded on the entry — but a passphrase
  /// check has an answer the screen has to show, not just a success to report.
  Future<T?> _ask<T>(
    String id,
    ToolAction action,
    Future<T> Function(ToolBackend backend) body,
  ) async {
    final entry = byId(id);
    if (entry == null || entry.busy) return null;
    if (!entry.capabilities.can(action)) {
      entry.error = entry.capabilities.reason;
      notifyListeners();
      return null;
    }
    entry.busy = true;
    entry.error = null;
    notifyListeners();
    T? value;
    try {
      value = await body(entry.backend);
    } on ToolException catch (e) {
      entry.error = '${action.name}: $e';
    } catch (e) {
      entry.error = '${action.name}: unexpected failure — $e';
    }
    entry.busy = false;
    notifyListeners();
    return value;
  }

  AppLockGuard _lockAt(String id) {
    final entry = byId(id);
    if (entry == null) {
      throw ToolException('NO_TOOL', 'There is no tool called "$id".');
    }
    if (entry.backend case final AppLockGuard guard) return guard;
    throw ToolException('NO_APP_LOCK', entry.capabilities.reason);
  }

  AppLockGuard _lock(ToolBackend backend, String id) {
    if (backend case final AppLockGuard guard) return guard;
    throw ToolException(
      'NO_APP_LOCK',
      byId(id)?.capabilities.reason ??
          'This tool does not gate apps, so nothing was checked.',
    );
  }

  Stream<String> tailLog(String id) {
    final entry = byId(id);
    if (entry == null) {
      throw ToolException('NO_TOOL', 'There is no tool called "$id".');
    }
    if (!entry.capabilities.can(ToolAction.tailLogs)) {
      throw ToolException('UNAVAILABLE', entry.capabilities.reason);
    }
    return entry.backend.tailLog();
  }

  PhoneMemorySource? phoneSource(String id) {
    final entry = byId(id);
    if (entry?.backend case final PhoneMemorySource source) return source;
    return null;
  }

  Future<List<ManagedApp>> ranked(ToolEntry entry, {int windowDays = 7}) async {
    if (entry.backend case final MemoryRanking ranking) {
      return ranking.ranked(windowDays: windowDays);
    }
    throw ToolException('NO_RANKING', entry.capabilities.reason);
  }

  // Fan reads. These skip [act] on purpose: a read has no state to serialise,
  // and the panel that watches a fan come up must keep working while a hold is
  // in force. What they cannot do is write — that goes through engageFan and
  // releaseFan, which do respect the busy guard.

  Future<FanTelemetry> fanTelemetry(String id) =>
      _fanEntry(id, ToolAction.showSensors).telemetry();

  Future<FanPrivilegeReport> fanPrivileges(String id) =>
      _fanEntry(id, ToolAction.showSensors).privileges();

  Future<FanDaemonStatus?> fanDaemonStatus(String id) async =>
      _fanSource(id).daemonStatus();

  /// Asks the daemon — the only process on this Mac that can answer the write
  /// half of the question honestly.
  Future<FanPrivilegeReport?> fanDaemonPrivileges(String id) async =>
      _fanSource(id).daemonPrivileges();

  FanControl _fanSource(String id) {
    final entry = byId(id);
    if (entry == null) {
      throw ToolException('NO_TOOL', 'There is no tool called "$id".');
    }
    if (entry.backend case final FanControl fan) return fan;
    throw ToolException('NO_FAN_CONTROL', entry.capabilities.reason);
  }

  FanControl _fan(ToolBackend backend, String id) {
    if (backend case final FanControl fan) return fan;
    throw ToolException(
      'NO_FAN_CONTROL',
      byId(id)?.capabilities.reason ??
          'This tool does not control a fan, so nothing was sent.',
    );
  }

  FanControl _fanEntry(String id, ToolAction action) {
    final entry = byId(id);
    if (entry == null) {
      throw ToolException('NO_TOOL', 'There is no tool called "$id".');
    }
    if (!entry.capabilities.can(action)) {
      throw ToolException('UNAVAILABLE', entry.capabilities.reason);
    }
    return _fanSource(id);
  }
}
