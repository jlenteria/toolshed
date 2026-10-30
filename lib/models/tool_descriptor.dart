/// What a tool can actually do on the current platform.
enum Support {
  /// The tool runs here and the app can really control it.
  full,

  /// The tool exists here but the OS caps what it can do (Android).
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
  openAppInfo,
  requestUsageAccess,

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
