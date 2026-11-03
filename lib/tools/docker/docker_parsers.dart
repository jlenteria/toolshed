import 'dart:convert';

import 'docker_models.dart';

/// Splits a `--format '{{json .}}'` stream — one JSON object per line — into
/// records, tolerating the two things a real CLI emits that a table does not:
/// blank lines, and a final partial line when the output was cut off mid-read.
///
/// A line that is not valid JSON is skipped rather than thrown, and reported
/// through [partial] so the backend can say a scan may be incomplete instead of
/// quietly showing one fewer row. This mirrors how `listener_parsers` reads
/// `lsof`/`ss` line by line instead of assuming the whole buffer is well-formed.
({List<Map<String, dynamic>> rows, String? partial}) parseJsonLines(
  String raw,
) {
  final rows = <Map<String, dynamic>>[];
  String? partial;
  final lines = const LineSplitter().convert(raw);
  for (final line in lines) {
    final text = line.trim();
    if (text.isEmpty) continue;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        rows.add(decoded);
      } else {
        partial = 'ignored a line of output that was not an object';
      }
    } on FormatException {
      partial = 'stopped on a truncated line; some entries may be missing';
    }
  }
  return (rows: rows, partial: partial);
}

String _s(Map<String, dynamic> row, String key) {
  final value = row[key];
  if (value == null) return '';
  return '$value';
}

List<String> _commaList(String value) => value
    .split(',')
    .map((part) => part.trim())
    .where((part) => part.isNotEmpty)
    .toList();

Map<String, String> _labels(String value) {
  final map = <String, String>{};
  for (final pair in _commaList(value)) {
    final at = pair.indexOf('=');
    if (at < 0) continue;
    map[pair.substring(0, at).trim()] = pair.substring(at + 1).trim();
  }
  return map;
}

/// Splits `containerPort/proto`, defaulting to tcp when a CLI omits the scheme.
(String port, String proto) _splitProto(String value) {
  final slash = value.lastIndexOf('/');
  if (slash < 0) return (value, 'tcp');
  return (value.substring(0, slash), value.substring(slash + 1));
}

/// Normalises the host address half of a published port. Docker prints the
/// bind-any case as `0.0.0.0`, `[::]` or the odd `:::`; all mean "every
/// interface", which `localhost` reaches, and are collapsed to `*`.
String _hostIp(String raw) {
  var ip = raw;
  if (ip.startsWith('[') && ip.endsWith(']')) {
    ip = ip.substring(1, ip.length - 1);
  }
  // Bind-any in all the spellings docker prints: 0.0.0.0, ::, ::: and empty.
  if (ip.isEmpty ||
      ip == '*' ||
      ip == '0.0.0.0' ||
      ip.replaceAll(':', '') == '') {
    return '*';
  }
  return ip;
}

/// Parses `docker ps`' `Ports` string into per-mapping rows. Two shapes appear:
/// a published `0.0.0.0:24400->80/tcp` (or `[::]:24400->80/tcp`) and an
/// exposed-only `8080/tcp` with no host port. The second is kept so the row can
/// say the container listens there, but it is not browsable.
List<DockerPortMapping> parsePorts(String raw) {
  if (raw.trim().isEmpty) return const <DockerPortMapping>[];
  final mappings = <DockerPortMapping>[];
  final seen = <String>{};
  for (final piece in raw.split(',')) {
    final entry = piece.trim();
    if (entry.isEmpty) continue;
    final arrow = entry.indexOf('->');
    final DockerPortMapping mapping;
    if (arrow < 0) {
      final (port, proto) = _splitProto(entry);
      mapping = DockerPortMapping(containerPort: port, proto: proto);
    } else {
      final host = entry.substring(0, arrow).trim();
      final (containerPort, proto) = _splitProto(
        entry.substring(arrow + 2).trim(),
      );
      final colon = host.lastIndexOf(':');
      final hostIp = colon < 0 ? host : host.substring(0, colon);
      final hostPort = colon < 0 ? '' : host.substring(colon + 1);
      mapping = DockerPortMapping(
        containerPort: containerPort,
        proto: proto,
        hostIp: _hostIp(hostIp),
        hostPort: hostPort,
      );
    }
    // A dual-stack bind prints `0.0.0.0:24400->80/tcp` and `[::]:24400->80/tcp`
    // for one port; the host port is what the developer dials, so key on it and
    // drop the second line rather than showing two identical links.
    final key = mapping.isPublished
        ? '${mapping.hostPort}|${mapping.containerPort}/${mapping.proto}'
        : 'x-${mapping.containerPort}/${mapping.proto}';
    if (seen.add(key)) mappings.add(mapping);
  }
  return mappings;
}

/// Maps `docker ps -a --format '{{json .}}'` rows, sorted running-first. A key a
/// given CLI version does not print simply yields an empty field rather than a
/// crash, so a newer or older engine still renders a readable list.
({List<DockerContainer> containers, String? partial}) parseContainers(
  String raw,
) {
  final parsed = parseJsonLines(raw);
  final containers = [
    for (final row in parsed.rows)
      DockerContainer(
        id: _s(row, 'ID'),
        names: _commaList(_s(row, 'Names')),
        image: _s(row, 'Image'),
        imageId: _s(row, 'ImageID'),
        command: _s(row, 'Command'),
        state: _s(row, 'State'),
        status: _s(row, 'Status'),
        ports: _s(row, 'Ports'),
        portMappings: parsePorts(_s(row, 'Ports')),
        size: _s(row, 'Size'),
        runningFor: _s(row, 'RunningFor'),
        createdAt: _s(row, 'CreatedAt'),
        labels: _labels(_s(row, 'Labels')),
      ),
  ]..sort(compareContainers);
  return (containers: containers, partial: parsed.partial);
}

/// Maps `docker images --format '{{json .}}'` rows, tagged-first then by age.
({List<DockerImage> images, String? partial}) parseImages(String raw) {
  final parsed = parseJsonLines(raw);
  final images = [
    for (final row in parsed.rows)
      DockerImage(
        id: _s(row, 'ID'),
        repository: _s(row, 'Repository'),
        tag: _s(row, 'Tag'),
        createdSince: _s(row, 'CreatedSince'),
        createdAt: _s(row, 'CreatedAt'),
        size: _s(row, 'Size'),
      ),
  ]..sort(compareImages);
  return (images: images, partial: parsed.partial);
}

/// Maps `docker system df --format '{{json .}}'` rows: Images, Containers,
/// Local Volumes and Build Cache, each with how much is reclaimable.
({List<DockerDiskLine> disk, String? partial}) parseSystemDf(String raw) {
  final parsed = parseJsonLines(raw);
  return (
    disk: [
      for (final row in parsed.rows)
        DockerDiskLine(
          type: _s(row, 'Type'),
          total: _s(row, 'Total'),
          active: _s(row, 'Active'),
          size: _s(row, 'Size'),
          reclaimable: _s(row, 'Reclaimable'),
        ),
    ],
    partial: parsed.partial,
  );
}
