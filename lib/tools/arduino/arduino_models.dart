/// One board definition as `arduino-cli board listall` reports it.
///
/// [fqbn] is the identifier every compile and upload is sent with; [name] is
/// only what the console shows. A board can appear in both the connected list
/// and the installed-platform list, so equality is keyed on the FQBN.
class ArduinoBoard {
  const ArduinoBoard({required this.name, required this.fqbn});

  final String name;
  final String fqbn;

  String get label => name.isEmpty ? fqbn : '$name — $fqbn';

  bool matches(String query) {
    final q = query.toLowerCase();
    return name.toLowerCase().contains(q) || fqbn.toLowerCase().contains(q);
  }

  @override
  bool operator ==(Object other) =>
      other is ArduinoBoard && other.fqbn == fqbn && other.name == name;

  @override
  int get hashCode => Object.hash(name, fqbn);

  @override
  String toString() => 'ArduinoBoard($fqbn)';
}

/// One port `arduino-cli board list` found, with whatever boards the CLI could
/// match against it.
///
/// A port with no matching board is still useful — it is a port to upload to or
/// to open the monitor on — so the console keeps it and shows the address alone.
class ArduinoPort {
  const ArduinoPort({
    required this.address,
    this.label = '',
    this.protocol = '',
    this.protocolLabel = '',
    this.boards = const <ArduinoBoard>[],
  });

  final String address;

  /// The name the CLI suggests for a GUI, often the same as [address].
  final String label;
  final String protocol;
  final String protocolLabel;
  final List<ArduinoBoard> boards;

  ArduinoBoard? get board => boards.isEmpty ? null : boards.first;

  /// The row headline: a matched board name when there is one, then the address
  /// or the CLI's own label.
  String get title {
    final shown = label.isEmpty ? address : label;
    final name = board?.name ?? '';
    return name.isEmpty ? shown : '$name · $shown';
  }

  String get subtitle => [
    if (protocolLabel.isNotEmpty) protocolLabel,
    if (protocolLabel.isEmpty && protocol.isNotEmpty) protocol,
    if (boards.length > 1) '${boards.length} matching boards',
  ].join(' · ');

  bool matches(String query) {
    final q = query.toLowerCase();
    return address.toLowerCase().contains(q) ||
        label.toLowerCase().contains(q) ||
        protocol.toLowerCase().contains(q) ||
        boards.any((b) => b.matches(q));
  }

  @override
  bool operator ==(Object other) =>
      other is ArduinoPort && other.address == address;

  @override
  int get hashCode => address.hashCode;

  @override
  String toString() => 'ArduinoPort($address)';
}

/// One installed platform, from `arduino-cli core list`.
///
/// [installed] is empty for a core that is only known, not installed; the
/// console uses that to explain why no boards are available.
class ArduinoCore {
  const ArduinoCore({
    required this.id,
    this.name = '',
    this.installed = '',
    this.latest = '',
  });

  final String id;
  final String name;
  final String installed;
  final String latest;

  bool get isInstalled => installed.isNotEmpty;

  String get label =>
      '${name.isEmpty ? id : name}${installed.isEmpty ? '' : ' $installed'}';

  String get subtitle => [
    id,
    if (latest.isNotEmpty && latest != installed) 'latest $latest',
  ].join(' · ');

  bool matches(String query) {
    final q = query.toLowerCase();
    return id.toLowerCase().contains(q) || name.toLowerCase().contains(q);
  }
}

/// One sketch folder in the Arduino sketchbook.
///
/// [directory] is what `arduino-cli compile` and `upload` are handed; [inoPath]
/// is the primary `.ino` file the editor opens. The two are kept apart because
/// the CLI takes the folder and the editor needs the file.
class ArduinoSketch {
  const ArduinoSketch({
    required this.name,
    required this.directory,
    required this.inoPath,
  });

  final String name;
  final String directory;
  final String inoPath;

  String get fileName {
    final normalized = inoPath.replaceAll('\\', '/');
    final at = normalized.lastIndexOf('/');
    return at < 0 ? normalized : normalized.substring(at + 1);
  }

  String get subtitle => inoPath;

  bool matches(String query) {
    final q = query.toLowerCase();
    return name.toLowerCase().contains(q) ||
        directory.toLowerCase().contains(q) ||
        fileName.toLowerCase().contains(q);
  }

  @override
  bool operator ==(Object other) =>
      other is ArduinoSketch && other.directory == directory;

  @override
  int get hashCode => directory.hashCode;

  @override
  String toString() => 'ArduinoSketch($name)';
}

/// The contents of one sketch file, as the editor reads them.
class ArduinoSketchFile {
  const ArduinoSketchFile({required this.path, required this.contents});

  final String path;
  final String contents;

  String get fileName {
    final normalized = path.replaceAll('\\', '/');
    final at = normalized.lastIndexOf('/');
    return at < 0 ? normalized : normalized.substring(at + 1);
  }
}

/// Everything the Arduino screen shows, loaded in one pass.
///
/// [notes] carries the reads that failed without taking the whole console down
/// — a missing sketchbook, an unreadable core list — so a page that still works
/// says what it could not see.
class ArduinoInventory {
  const ArduinoInventory({
    this.version = '',
    this.ports = const <ArduinoPort>[],
    this.boards = const <ArduinoBoard>[],
    this.cores = const <ArduinoCore>[],
    this.sketches = const <ArduinoSketch>[],
    this.sketchbookPath = '',
    this.notes = const <String>[],
  });

  final String version;
  final List<ArduinoPort> ports;
  final List<ArduinoBoard> boards;
  final List<ArduinoCore> cores;
  final List<ArduinoSketch> sketches;
  final String sketchbookPath;
  final List<String> notes;

  int get installedCoreCount => cores.where((c) => c.isInstalled).length;

  /// Boards the CLI matched to a connected port, de-duplicated by FQBN. These
  /// are the ones worth putting first: they are physically attached.
  List<ArduinoBoard> get detectedBoards {
    final seen = <String>{};
    return [
      for (final port in ports)
        for (final board in port.boards)
          if (board.fqbn.isNotEmpty && seen.add(board.fqbn)) board,
    ];
  }

  ArduinoPort? get firstPort => ports.isEmpty ? null : ports.first;

  ArduinoBoard? get firstDetectedBoard {
    final detected = detectedBoards;
    return detected.isEmpty ? null : detected.first;
  }

  bool get hasBoards => boards.isNotEmpty || detectedBoards.isNotEmpty;
}
