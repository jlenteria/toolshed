import 'dart:convert';

import 'port_listener.dart';

/// Parsers for the four command outputs the desktop scanners read.
///
/// Kept as pure functions over stdout so every format a machine might print —
/// IPv4 and IPv6, a command name with spaces, a socket whose owner is hidden —
/// is testable without running the command.

/// `lsof -nP -iTCP -sTCP:LISTEN` and `lsof -nP -iUDP`.
///
/// Columns are COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME, where the
/// protocol is part of NAME. The fixed columns are found by locating the
/// `IPv4`/`IPv6` token instead of splitting from the left, because COMMAND can
/// itself contain spaces.
List<PortListener> parseLsof(String text) {
  final rows = <PortListener>[];
  for (final line in const LineSplitter().convert(text)) {
    final tokens = line.trim().split(RegExp(r'\s+'));
    if (tokens.length < 9) continue;
    final ipv4 = tokens.indexOf('IPv4');
    final ipv6 = tokens.indexOf('IPv6');
    final type = ipv4 >= 0 ? ipv4 : ipv6;
    if (type < 4 || type + 4 >= tokens.length) continue;

    final pid = int.tryParse(tokens[type - 3]);
    final protocol = switch (tokens[type + 3].toUpperCase()) {
      'TCP' => PortProtocol.tcp,
      'UDP' => PortProtocol.udp,
      _ => null,
    };
    if (pid == null || protocol == null) continue;

    var endpoint = tokens.sublist(type + 4).join(' ');
    final state = endpoint.indexOf(' (');
    if (state > 0) endpoint = endpoint.substring(0, state);
    // A connected UDP socket has a peer after `->`; it is not listening on
    // anything, and listing it would answer a question nobody asked.
    if (endpoint.contains('->')) continue;
    final port = _portOf(endpoint);
    if (port == null) continue;

    rows.add(
      PortListener(
        port: port,
        protocol: protocol,
        addresses: [_hostOf(endpoint)],
        pid: pid,
        processName: tokens.sublist(0, type - 3).join(' '),
        user: tokens[type - 2],
      ),
    );
  }
  return mergeListeners(rows);
}

/// `ss -ltnp` and `ss -lunp` on Linux.
///
/// `ss -p` shows the users of a socket only when the calling user may see
/// them, so a socket with no `users:(...)` group is kept as a row with an
/// unknown owner rather than dropped — the port is still taken.
List<PortListener> parseSs(String text) {
  final rows = <PortListener>[];
  final scope = RegExp(r'%[A-Za-z0-9_.-]+$');
  final owner = RegExp(r'\("([^"]*)",pid=(\d+)');

  for (final line in const LineSplitter().convert(text)) {
    final tokens = line.trim().split(RegExp(r'\s+'));
    if (tokens.length < 5) continue;
    final protocol = switch (tokens[0]) {
      'LISTEN' => PortProtocol.tcp,
      'UNCONN' => PortProtocol.udp,
      _ => null,
    };
    if (protocol == null) continue;

    final endpoint = tokens[3];
    final port = _portOf(endpoint);
    if (port == null) continue;
    final address = _hostOf(endpoint).replaceAll(scope, '');
    final rest = tokens.length <= 5 ? '' : tokens.sublist(5).join(' ');
    final owners = owner.allMatches(rest).toList(growable: false);
    if (owners.isEmpty) {
      rows.add(
        PortListener(port: port, protocol: protocol, addresses: [address]),
      );
      continue;
    }
    for (final match in owners) {
      final pid = int.tryParse(match.group(2)!);
      if (pid == null) continue;
      rows.add(
        PortListener(
          port: port,
          protocol: protocol,
          addresses: [address],
          pid: pid,
          processName: match.group(1)!,
        ),
      );
    }
  }
  return mergeListeners(rows);
}

/// `netstat -ano` on Windows. TCP rows are kept only in the LISTENING state;
/// UDP rows are bound sockets and have no state column at all.
List<PortListener> parseNetstat(String text) {
  final rows = <PortListener>[];
  for (final line in const LineSplitter().convert(text)) {
    final tokens = line.trim().split(RegExp(r'\s+'));
    if (tokens.length < 4) continue;
    final protocol = switch (tokens[0].toUpperCase()) {
      'TCP' => PortProtocol.tcp,
      'UDP' => PortProtocol.udp,
      _ => null,
    };
    if (protocol == null) continue;
    if (protocol == PortProtocol.tcp &&
        (tokens.length < 5 || tokens[3].toUpperCase() != 'LISTENING')) {
      continue;
    }

    final endpoint = tokens[1];
    final port = _portOf(endpoint);
    final pid = int.tryParse(tokens.last);
    if (port == null || pid == null) continue;

    rows.add(
      PortListener(
        port: port,
        protocol: protocol,
        addresses: [_hostOf(endpoint)],
        pid: pid,
      ),
    );
  }
  return mergeListeners(rows);
}

/// `tasklist /FO CSV /NH`: `"node.exe","1234","Console","1","45,678 K"`.
/// Only the image name is needed; netstat supplies the pid.
Map<int, String> parseTasklist(String text) {
  final names = <int, String>{};
  final row = RegExp(r'^"((?:[^"]|"")*)","(\d+)"');
  for (final line in const LineSplitter().convert(text)) {
    final match = row.firstMatch(line.trim());
    if (match == null) continue;
    final pid = int.tryParse(match.group(2)!);
    if (pid == null) continue;
    names[pid] = match.group(1)!.replaceAll('""', '"');
  }
  return names;
}

/// Names a scan's owners from a pid table (tasklist on Windows), leaving rows
/// whose pid is unknown or absent untouched.
List<PortListener> attachProcessNames(
  Iterable<PortListener> rows,
  Map<int, String> names,
) => [
  for (final row in rows)
    switch (row.pid) {
      final int pid when names[pid] != null => row.copyWith(
        processName: names[pid],
      ),
      _ => row,
    },
];

/// Collapses the addresses a single process bound into one row per protocol
/// and port. Order is the list's order once sorted by [comparePorts].
List<PortListener> mergeListeners(Iterable<PortListener> rows) {
  final groups = <(PortProtocol, int, int?), _Group>{};
  for (final row in rows) {
    final group = groups.putIfAbsent((
      row.protocol,
      row.port,
      row.pid,
    ), () => _Group(row));
    group.add(row);
  }
  return [for (final group in groups.values) group.build()]..sort(comparePorts);
}

class _Group {
  _Group(PortListener first) : _first = first {
    _addresses.addAll(first.addresses);
  }

  PortListener _first;
  final Set<String> _addresses = {};

  void add(PortListener row) {
    _addresses.addAll(row.addresses);
    if (_first.user == null && row.user != null) {
      _first = _first.copyWith(user: row.user);
    }
    if (_first.command == null && row.command != null) {
      _first = _first.copyWith(command: row.command);
    }
  }

  PortListener build() => PortListener(
    port: _first.port,
    protocol: _first.protocol,
    addresses: _addresses.toList(growable: false),
    pid: _first.pid,
    processName: _first.processName,
    user: _first.user,
    command: _first.command,
  );
}

String _hostOf(String endpoint) {
  final colon = endpoint.lastIndexOf(':');
  var host = colon <= 0 ? endpoint : endpoint.substring(0, colon);
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
  }
  return host;
}

int? _portOf(String endpoint) {
  final colon = endpoint.lastIndexOf(':');
  if (colon < 0) return null;
  final port = int.tryParse(endpoint.substring(colon + 1));
  return port == null || port <= 0 ? null : port;
}
