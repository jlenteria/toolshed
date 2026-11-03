/// What a tool can actually do on the current platform.
enum Support {
  /// The tool runs here and the app can really control it.
  full,

  /// The tool exists here but the OS caps what it can do.
  cappedByOs,

  /// The tool exists for this platform, but the native helper it drives is not
  /// present. Different from [notOnThisOs]: this one is fixable by building or
  /// installing something, and the user should be told which.
  helperMissing,

  /// The tool cannot run here at all (Windows, Linux).
  notOnThisOs,
}

/// Every distinct thing a detail screen might offer a button for.
enum ToolAction {
  start,
  stop,
  install,

  /// Replace the installed helper with the copy this app carries and restart
  /// the agent on it. Offered only while installed: an agent runs the binary it
  /// bootstrapped with, so an app update needs this to reach it.
  update,
  uninstall,
  configure,
  tailLogs,
  reapNow,

  /// Stop one process from the memory list, after confirming in the console.
  forceStop,
  showRanking,

  /// List the listening sockets and, where the platform allows, free a port.
  showPorts,

  /// Show the build caches and package stores that can be reclaimed.
  showCaches,

  /// Move the chosen caches to the Trash. Never a delete.
  trashCaches,

  /// Take the fan out of Apple's control now, with the settings on screen.
  engage,

  /// Hand the fan back to Apple now, without waiting for a lease to expire.
  releaseControl,

  /// Live sensor and rpm readout. Reads need no privilege, so this is offered
  /// even where control is not.
  showSensors,

  /// Choose or change the passphrase a locked app is opened with.
  setPassphrase,

  /// Open one locked app for a while, or drop an allowance that is running.
  unlockApp,

  /// Ask one app to quit now, without waiting for the watcher to notice.
  closeApp,

  /// Open the Docker console: containers, images and disk usage read from the
  /// `docker` CLI on demand.
  showDocker,

  /// Per-container lifecycle, each confirmed in the console before it is sent.
  dockerStart,
  dockerStop,
  dockerRestart,

  /// `docker rm -f`: the only container action that discards the writable
  /// layer, so it always confirms with that said out loud.
  dockerRemove,

  /// `docker image prune`: dangling images only, never a tagged one.
  dockerPrune,

  /// Open a container's published port in the system browser. A read-shaped
  /// side effect — it sends nothing to the engine — advertised whenever a CLI
  /// was found to read the ports through, since only a published port offers it.
  dockerOpenPort,

  /// Start the engine itself through whichever manager owns it — `colima
  /// start`, `orbctl start` or opening Docker Desktop — so a stopped daemon
  /// can be brought back from the console instead of a terminal. Advertised
  /// only when such a manager is actually installed.
  dockerStartEngine,

  /// Stop the engine manager. Off by the same rule as starting it: only when a
  /// manager was found, and the console says plainly that it takes every
  /// running container down with it.
  dockerStopEngine,
}

class Capabilities {
  const Capabilities({
    required this.support,
    required this.actions,
    required this.reason,
  });

  final Support support;
  final Set<ToolAction> actions;

  /// Shown to the user verbatim whenever an action is unavailable. Never leave
  /// this empty: a missing button with no explanation reads as a bug.
  final String reason;

  bool can(ToolAction action) => actions.contains(action);
}

class ToolDescriptor {
  const ToolDescriptor({
    required this.id,
    required this.name,
    required this.summary,
    required this.implPath,
  });

  final String id;
  final String name;
  final String summary;

  /// Path of the implementation the app drives, shown in the UI so it is clear
  /// the app is a remote control and not the thing doing the work.
  final String implPath;
}
