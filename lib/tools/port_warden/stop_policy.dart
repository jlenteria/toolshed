import 'dart:io' as io;

import 'port_listener.dart';

/// The subset of mem_reaper's stop rules a scan can judge before a request is
/// sent, so the list only offers sockets that pressing "free" can act on.
///
/// The script remains the authority — it re-checks ownership, the ancestor
/// walk and the executable at the pid. These two tables mirror
/// `PROTECTED_NAMES` and `PROTECTED_PATH_PREFIXES` in scripts/mem_reaper.py;
/// when a name is added there, add it here too or the list will offer a stop
/// that comes back refused.
const Set<String> protectedProcessNames = {
  'launchd',
  'loginwindow',
  'WindowServer',
  'Dock',
  'Finder',
  'SystemUIServer',
  'ControlCenter',
  'NotificationCenter',
  'Spotlight',
  'WallpaperAgent',
  'cfprefsd',
  'distnoted',
  'usernoted',
  'tccd',
  'trustd',
  'securityd',
  'keychainaccessd',
  'kcd',
  'kdc',
  'launchservicesd',
  'coreservicesd',
  'lsd',
  'containermanagerd',
  'runningboardd',
  'UserEventAgent',
  'universalaccessd',
  'accessibilityd',
  'pboard',
  'pasteboardd',
  'mDNSResponder',
  'opendirectoryd',
  'syspolicyd',
  'taskgated',
  'amfid',
  'kernelmanagerd',
  'installd',
  'softwareupdated',
  'perfd',
  'ReportCrash',
  'mem_reaper.py',
};

const List<String> protectedPathPrefixes = [
  '/System/',
  '/usr/libexec/',
  '/usr/sbin/',
  '/sbin/',
  '/private/var/db/',
  '/Library/Apple/',
];

/// Whether this socket's owner is one mem_reaper would agree to stop.
///
/// A socket with no visible pid has nothing to signal; pid 1 and 2 are the
/// kernel and launchd; root-owned, protected-named or system-path processes are
/// refused by the script; and the console's own pid is always its own ancestor.
bool canFreePort(PortListener listener) {
  final pid = listener.pid;
  if (pid == null || pid <= 2 || pid == io.pid) return false;
  if (listener.user == 'root') return false;

  final path = listener.command;
  if (path != null) {
    if (protectedPathPrefixes.any(path.startsWith)) return false;
    if (protectedProcessNames.contains(path.split('/').last)) return false;
  }

  final name = listener.processName;
  return name == null || !protectedProcessNames.contains(name);
}
