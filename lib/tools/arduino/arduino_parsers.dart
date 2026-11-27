import 'dart:convert';
import 'dart:io';

import 'arduino_models.dart';

/// The parsers behind the Arduino console.
///
/// Every shape here comes from `arduino-cli` itself. The board-list grammar is
/// deliberately tolerant of both the pre-0.19 shape (`address`/`boards`) and the
/// current one (`port`/`matching_boards`), plus the `detected_ports` wrapper a
/// few releases used, because the console should not stop working when the CLI
/// on the machine is one version older than the one in a doc.
///
/// A malformed answer is never read as "no boards": the parser reports a
/// [partial] note instead, and the backend puts it on screen beside the result.

String _s(Map<String, dynamic> row, String key) {
  final value = row[key];
  return value == null ? '' : '$value';
}

Map<String, dynamic>? _asMap(Object? value) =>
    value is Map<String, dynamic> ? value : null;

/// Decodes the whole answer, then — when a warning line was printed before the
/// JSON — the part from the first `[` or `{`. Returns a note on failure so the
/// caller can distinguish an unreadable answer from an empty one.
(Object?, String?) _decode(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return (null, null);
  try {
    return (jsonDecode(text), null);
  } on FormatException {
    final at = text.indexOf(RegExp(r'[\[{]'));
    if (at > 0) {
      try {
        return (jsonDecode(text.substring(at)), null);
      } on FormatException {
        // Fall through to the note below.
      }
    }
    return (
      null,
      'the CLI did not return valid JSON; some entries may be missing',
    );
  }
}

List<Object?> _rows(Object? decoded, {String? key}) {
  if (decoded is List) return decoded;
  if (decoded is Map<String, dynamic>) {
    for (final candidate in [
      key,
      'detected_ports',
      'ports',
      'cores',
      'boards',
    ]) {
      if (candidate != null && decoded[candidate] is List) {
        return decoded[candidate] as List;
      }
    }
  }
  return const [];
}

/// `arduino-cli board list --json`, in either the current or the older shape.
({List<ArduinoPort> ports, String? partial}) parseBoardList(String raw) {
  final (decoded, decodeNote) = _decode(raw);
  if (decodeNote != null) {
    return (ports: const <ArduinoPort>[], partial: decodeNote);
  }

  final rows = _rows(decoded, key: 'detected_ports');
  String? partial;
  final ports = <ArduinoPort>[];
  for (final rawEntry in rows) {
    final entry = _asMap(rawEntry);
    if (entry == null) {
      partial ??= 'ignored a port entry that was not an object';
      continue;
    }

    // Current shape: {port: {...}, matching_boards: [...]}. Older shape:
    // {address: ..., protocol: ..., boards: [...]}.
    final portMap = _asMap(entry['port']) ?? entry;
    final address = _s(portMap, 'address');
    if (address.isEmpty) {
      partial ??= 'ignored a port entry with no address';
      continue;
    }

    final boardsRaw =
        entry['matching_boards'] ??
        entry['boards'] ??
        portMap['matching_boards'] ??
        portMap['boards'];
    final boards = <ArduinoBoard>[];
    if (boardsRaw is List) {
      for (final rawBoard in boardsRaw) {
        final board = _asMap(rawBoard);
        if (board == null) continue;
        final fqbn = _s(board, 'fqbn');
        if (fqbn.isEmpty) continue;
        boards.add(ArduinoBoard(name: _s(board, 'name'), fqbn: fqbn));
      }
    }

    ports.add(
      ArduinoPort(
        address: address,
        label: _s(portMap, 'label'),
        protocol: _s(portMap, 'protocol'),
        protocolLabel: _s(portMap, 'protocol_label'),
        boards: boards,
      ),
    );
  }
  ports.sort(
    (a, b) => a.address.toLowerCase().compareTo(b.address.toLowerCase()),
  );
  return (ports: ports, partial: partial);
}

/// `arduino-cli board listall --json`: every board whose platform is installed.
({List<ArduinoBoard> boards, String? partial}) parseAllBoards(String raw) {
  final (decoded, decodeNote) = _decode(raw);
  if (decodeNote != null) {
    return (boards: const <ArduinoBoard>[], partial: decodeNote);
  }

  final rows = _rows(decoded, key: 'boards');
  String? partial;
  final boards = <ArduinoBoard>[];
  final seen = <String>{};
  for (final rawBoard in rows) {
    final board = _asMap(rawBoard);
    if (board == null) {
      partial ??= 'ignored a board entry that was not an object';
      continue;
    }
    final fqbn = _s(board, 'fqbn');
    if (fqbn.isEmpty) {
      partial ??= 'ignored a board entry with no FQBN';
      continue;
    }
    if (!seen.add(fqbn)) continue;
    boards.add(ArduinoBoard(name: _s(board, 'name'), fqbn: fqbn));
  }
  boards.sort((a, b) {
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return byName != 0 ? byName : a.fqbn.compareTo(b.fqbn);
  });
  return (boards: boards, partial: partial);
}

/// `arduino-cli core list --json`: installed platforms.
({List<ArduinoCore> cores, String? partial}) parseCores(String raw) {
  final (decoded, decodeNote) = _decode(raw);
  if (decodeNote != null) {
    return (cores: const <ArduinoCore>[], partial: decodeNote);
  }

  final rows = _rows(decoded, key: 'cores');
  String? partial;
  final cores = <ArduinoCore>[];
  final seen = <String>{};
  for (final rawCore in rows) {
    final core = _asMap(rawCore);
    if (core == null) {
      partial ??= 'ignored a core entry that was not an object';
      continue;
    }
    // The JSON keys were lowercased in 0.20; accepting both means an older CLI
    // still fills the table rather than showing a list of blank rows.
    final id = _s(core, 'id').isEmpty ? _s(core, 'ID') : _s(core, 'id');
    if (id.isEmpty) {
      partial ??= 'ignored a core entry with no id';
      continue;
    }
    if (!seen.add(id)) continue;
    cores.add(
      ArduinoCore(
        id: id,
        name: _s(core, 'name').isEmpty ? _s(core, 'Name') : _s(core, 'name'),
        installed: _s(core, 'installed').isEmpty
            ? _s(core, 'Installed')
            : _s(core, 'installed'),
        latest: _s(core, 'latest').isEmpty
            ? _s(core, 'Latest')
            : _s(core, 'latest'),
      ),
    );
  }
  cores.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
  return (cores: cores, partial: partial);
}

/// The version line `arduino-cli version` prints, without the commit and date.
String parseVersion(String raw) {
  final match = RegExp(r'Version:\s*(\S+)').firstMatch(raw);
  if (match != null) return match.group(1)!;
  final first = raw.trim().split('\n').first.trim();
  if (first.isEmpty) return '';
  final parts = first.split(RegExp(r'\s+'));
  return parts.length > 1 ? parts[1] : first;
}

/// `arduino-cli config get directories.user`, which prints either the bare path
/// or `directories.user: <path>` depending on the release.
String parseSketchbookPath(String raw) {
  for (final line in raw.split('\n')) {
    final text = line.trim();
    if (text.isEmpty) continue;
    if (text.toLowerCase().startsWith('error')) continue;
    const key = 'directories.user:';
    if (text.toLowerCase().startsWith(key)) {
      return text.substring(key.length).trim();
    }
    return text;
  }
  return '';
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final trimmed = normalized.endsWith('/')
      ? normalized.substring(0, normalized.length - 1)
      : normalized;
  final at = trimmed.lastIndexOf('/');
  return at < 0 ? trimmed : trimmed.substring(at + 1);
}

/// Every sketch folder under [dir], each with the `.ino` the editor should open.
///
/// The Arduino convention is that a sketch folder contains a file of the same
/// name; when that file is missing the first `.ino` in the folder is used, which
/// is what the IDE itself does. Unreadable folders are skipped rather than
/// taking the whole sketchbook down.
List<ArduinoSketch> scanSketchbook(Directory dir) {
  if (!dir.existsSync()) return const <ArduinoSketch>[];
  final sketches = <ArduinoSketch>[];
  late final List<FileSystemEntity> entries;
  try {
    entries = dir.listSync(followLinks: false);
  } on FileSystemException {
    // An unreadable sketchbook leaves a note in the inventory instead of taking
    // the ports and boards down with it.
    return sketches;
  }
  for (final entity in entries) {
    if (entity is! Directory) continue;
    final name = _basename(entity.path);
    if (name.isEmpty || name.startsWith('.')) continue;

    final preferred = File('${entity.path}${Platform.pathSeparator}$name.ino');
    String? inoPath;
    if (preferred.existsSync()) {
      inoPath = preferred.path;
    } else {
      try {
        for (final child in entity.listSync(followLinks: false)) {
          if (child is File && child.path.toLowerCase().endsWith('.ino')) {
            inoPath = child.path;
            break;
          }
        }
      } on FileSystemException {
        continue;
      }
    }
    if (inoPath == null) continue;
    sketches.add(
      ArduinoSketch(name: name, directory: entity.path, inoPath: inoPath),
    );
  }
  sketches.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return sketches;
}

/// Resolves a configured sketch path — a folder or an `.ino` file — to the pair
/// the CLI and the editor each need. Null when neither names a real sketch.
ArduinoSketch? resolveSketch(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return null;

  if (trimmed.toLowerCase().endsWith('.ino')) {
    final file = File(trimmed);
    if (!file.existsSync()) return null;
    final dir = file.parent.path;
    return ArduinoSketch(
      name: _basename(dir),
      directory: dir,
      inoPath: file.path,
    );
  }

  final dir = Directory(trimmed);
  if (!dir.existsSync()) return null;
  final name = _basename(dir.path);
  final preferred = File('${dir.path}${Platform.pathSeparator}$name.ino');
  if (preferred.existsSync()) {
    return ArduinoSketch(
      name: name,
      directory: dir.path,
      inoPath: preferred.path,
    );
  }
  try {
    for (final child in dir.listSync(followLinks: false)) {
      if (child is File && child.path.toLowerCase().endsWith('.ino')) {
        return ArduinoSketch(
          name: name,
          directory: dir.path,
          inoPath: child.path,
        );
      }
    }
  } on FileSystemException {
    return null;
  }
  return null;
}
