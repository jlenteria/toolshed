/// A container action the console can send. Every one maps to a plain `docker`
/// subcommand; the engine decides whether it succeeds.
enum DockerOp {
  start,
  stop,
  restart,
  remove;

  String get label => switch (this) {
    DockerOp.start => 'Start',
    DockerOp.stop => 'Stop',
    DockerOp.restart => 'Restart',
    DockerOp.remove => 'Remove',
  };

  bool get isDestructive => this == DockerOp.remove;
}

/// One port line from `docker ps`' `Ports` field, split into the parts that
/// decide whether the port can be reached from the host.
///
/// A published mapping (`0.0.0.0:24400->80/tcp`) names a host port the machine
/// can dial; an exposed-but-unpublished one (`8080/tcp`) lives only inside the
/// container's network, so nothing here can open it. Only the first is browsable.
class DockerPortMapping {
  const DockerPortMapping({
    required this.containerPort,
    required this.proto,
    this.hostIp = '',
    this.hostPort = '',
  });

  final String containerPort;
  final String proto;

  /// The address the engine bound on the host; `*` for the dual-stack `0.0.0.0`
  /// / `::` case, which `localhost` reaches either way.
  final String hostIp;
  final String hostPort;

  /// Published only when a real host port sits in front of it — the `->` half of
  /// the line. Digits-only is the guard: a malformed host port is treated as
  /// unpublished rather than handed to a browser.
  bool get isPublished => RegExp(r'^\d+$').hasMatch(hostPort);

  /// The address to open. `localhost` is used because a port bound to `*`
  /// answers there, and a `127.0.0.1` binding is reachable by that name too.
  String? get url => isPublished ? 'http://localhost:$hostPort' : null;

  /// The human row: `24400 → 80/tcp` for a published port, `8080/tcp` otherwise.
  String get label => isPublished
      ? '$hostPort → $containerPort/$proto'
      : '$containerPort/$proto';
}

/// One container as `docker ps -a` reported it, running or not.
class DockerContainer {
  const DockerContainer({
    required this.id,
    this.names = const <String>[],
    this.image = '',
    this.imageId = '',
    this.command = '',
    this.state = '',
    this.status = '',
    this.ports = '',
    this.portMappings = const <DockerPortMapping>[],
    this.size = '',
    this.runningFor = '',
    this.createdAt = '',
    this.labels = const <String, String>{},
  });

  final String id;
  final List<String> names;
  final String image;
  final String imageId;
  final String command;
  final String state;
  final String status;
  final String ports;
  final List<DockerPortMapping> portMappings;
  final String size;
  final String runningFor;
  final String createdAt;
  final Map<String, String> labels;

  bool get isRunning =>
      state.toLowerCase() == 'running' || status.startsWith('Up');

  String get idShort => id.length <= 12 ? id : id.substring(0, 12);

  String get primaryName => names.isEmpty ? idShort : names.first;

  /// The row's headline: the name a developer gave, not a hex id.
  String get name => names.isEmpty ? idShort : names.join(', ');

  /// The second line: what image it came from and how long it has been in the
  /// state it is in, in the words `docker` used.
  String get subtitle {
    final since = runningFor.isEmpty ? status : runningFor;
    return [
      if (image.isNotEmpty) image,
      if (since.isNotEmpty) since,
    ].join(' · ');
  }

  String get stateLabel {
    if (state.isNotEmpty) return _capitalise(state);
    return isRunning ? 'Running' : 'Stopped';
  }

  bool matches(String query) {
    final q = query.toLowerCase();
    return id.contains(q) ||
        name.toLowerCase().contains(q) ||
        image.toLowerCase().contains(q) ||
        command.toLowerCase().contains(q) ||
        ports.toLowerCase().contains(q) ||
        status.toLowerCase().contains(q);
  }

  static String _capitalise(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

/// Orders running containers first, then most-recently-created, so the active
/// work sits at the top rather than in whatever order the engine walked.
int compareContainers(DockerContainer a, DockerContainer b) {
  if (a.isRunning != b.isRunning) return a.isRunning ? -1 : 1;
  final byCreated = b.createdAt.compareTo(a.createdAt);
  if (byCreated != 0) return byCreated;
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}

/// One image as `docker images` reported it. Sizes are kept as the strings the
/// CLI printed, so nothing here re-derives a number the engine already chose.
class DockerImage {
  const DockerImage({
    required this.id,
    this.repository = '',
    this.tag = '',
    this.createdSince = '',
    this.createdAt = '',
    this.size = '',
  });

  final String id;
  final String repository;
  final String tag;
  final String createdSince;
  final String createdAt;
  final String size;

  String get idShort => id.startsWith('sha256:')
      ? id.substring(7, 19)
      : (id.length <= 12 ? id : id.substring(0, 12));

  bool get isDangling =>
      (repository.isEmpty || repository == '<none>') &&
      (tag.isEmpty || tag == '<none>');

  /// `repo:tag`, or the shortened id for a dangling image with no tags.
  String get ref {
    if (isDangling) return '$idShort (dangling)';
    final repo = repository.isEmpty ? '<none>' : repository;
    final t = tag.isEmpty ? '<none>' : tag;
    return '$repo:$t';
  }

  String get subtitle => [
    if (createdSince.isNotEmpty) createdSince,
    if (size.isNotEmpty) size,
  ].join(' · ');

  bool matches(String query) {
    final q = query.toLowerCase();
    return id.contains(q) ||
        ref.toLowerCase().contains(q) ||
        repository.toLowerCase().contains(q);
  }
}

/// Orders tagged images by recency and pushes dangling ones to the bottom, so
/// the prune candidate pile is visually separate from what you are using.
int compareImages(DockerImage a, DockerImage b) {
  if (a.isDangling != b.isDangling) return a.isDangling ? 1 : -1;
  final byCreated = b.createdAt.compareTo(a.createdAt);
  if (byCreated != 0) return byCreated;
  return a.ref.toLowerCase().compareTo(b.ref.toLowerCase());
}

/// One line of `docker system df`: a resource type and how much of it can be
/// reclaimed. Values are the strings the CLI printed.
class DockerDiskLine {
  const DockerDiskLine({
    required this.type,
    this.total = '',
    this.active = '',
    this.size = '',
    this.reclaimable = '',
  });

  final String type;
  final String total;
  final String active;
  final String size;
  final String reclaimable;
}

/// Everything the console shows for one engine, loaded in one pass.
class DockerInventory {
  const DockerInventory({
    required this.containers,
    required this.images,
    required this.disk,
    this.notes = const <String>[],
  });

  final List<DockerContainer> containers;
  final List<DockerImage> images;
  final List<DockerDiskLine> disk;
  final List<String> notes;

  int get runningCount => containers.where((c) => c.isRunning).length;

  int get danglingCount => images.where((i) => i.isDangling).length;
}

/// The CLI's own answer to a container action, shown verbatim in a toast so the
/// engine — not the app — is what the user hears back.
class DockerActionResult {
  const DockerActionResult({required this.message, this.reclaimed = ''});

  final String message;

  /// For prune, the space the CLI says it reclaimed; empty for other actions.
  final String reclaimed;

  String describe(String target) {
    final first = message.trim();
    final summary = reclaimed.isNotEmpty
        ? '$first · reclaimed $reclaimed'
        : first;
    return summary.isEmpty ? target : summary;
  }
}
