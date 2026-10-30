import '../mem_reaper/managed_app.dart';

/// Which transport a socket is bound on.
enum PortProtocol { tcp, udp }

/// One listening socket as the OS reports it, grouped by the process that owns
/// it.
///
/// A server bound on `127.0.0.1`, `::1` and the wildcard address is one row,
/// not three: the question this tool answers is "what is holding port 3000",
/// and the answer is one process. Two processes on the same port therefore
/// stay two rows, which is exactly the conflict the user is looking for.
class PortListener {
  const PortListener({
    required this.port,
    required this.protocol,
    required this.addresses,
    this.pid,
    this.processName,
    this.user,
    this.command,
  });

  final int port;
  final PortProtocol protocol;

  /// Every local address the process bound this port on, as the OS printed it
  /// (`*`, `0.0.0.0`, `::`, `127.0.0.1`).
  final List<String> addresses;

  /// Null when the OS hides the owner from this user. A non-root `ss` on Linux
  /// prints the socket and no process for another user, and pretending the pid
  /// is 0 would offer a stop button that cannot work.
  final int? pid;

  final String? processName;

  /// The owner as `lsof` reports it. Null where the scanner has no user column.
  final String? user;

  /// Full executable path, used as the pid-reuse guard when a stop is sent to
  /// mem_reaper. Null when `ps` could not be read.
  final String? command;

  bool get hasOwner => pid != null;

  String get protocolLabel => switch (protocol) {
    PortProtocol.tcp => 'TCP',
    PortProtocol.udp => 'UDP',
  };

  String get processLabel =>
      processName ?? (pid == null ? 'owner not visible' : 'pid $pid');

  static const Set<String> _wildcards = {'*', '0.0.0.0', '::', '[::]'};

  /// The bound addresses in one phrase, so a wildcard binding reads as what it
  /// means instead of as a row of zeroes.
  String get addressLabel {
    if (addresses.isEmpty) return 'unknown address';
    final specific = <String>{};
    var wildcard = false;
    for (final address in addresses) {
      if (_wildcards.contains(address)) {
        wildcard = true;
      } else {
        specific.add(address);
      }
    }
    if (wildcard && specific.isEmpty) return 'all interfaces';
    if (wildcard) return 'all interfaces, ${specific.join(', ')}';
    return specific.join(', ');
  }

  /// The row's second line: every fact the scanner gave us, in one place.
  String get subtitle {
    final parts = [protocolLabel, addressLabel];
    if (pid != null) {
      parts.add('pid $pid');
      if (user != null) parts.add(user!);
    }
    return parts.join(' · ');
  }

  /// What a stop request needs. Null when there is no pid to stop, so the
  /// screen cannot offer a button for a socket whose owner it cannot see.
  ManagedApp? get process {
    final pid = this.pid;
    if (pid == null) return null;
    return ManagedApp(
      id: '$pid',
      name: processLabel,
      detail: command,
      killMode: KillMode.viaReaper,
    );
  }

  PortListener copyWith({String? processName, String? user, String? command}) =>
      PortListener(
        port: port,
        protocol: protocol,
        addresses: addresses,
        pid: pid,
        processName: processName ?? this.processName,
        user: user ?? this.user,
        command: command ?? this.command,
      );
}

/// Ports first, then TCP before UDP, then by process: the list reads like the
/// answer to "what is on 3000" rather than in the order lsof happened to walk
/// its file descriptors.
int comparePorts(PortListener a, PortListener b) {
  final byPort = a.port.compareTo(b.port);
  if (byPort != 0) return byPort;
  final byProtocol = a.protocol.index.compareTo(b.protocol.index);
  if (byProtocol != 0) return byProtocol;
  return a.processLabel.toLowerCase().compareTo(b.processLabel.toLowerCase());
}
