/// Parses the stdout of `du -sk <paths...>`.
///
/// `du` prints `<KiB>\t<path>` per path. It exits non-zero when one path
/// vanished mid-walk but still prints the others, so the caller parses stdout
/// regardless of the exit code and asks again about anything missing.
Map<String, int> parseDuSizes(String output) {
  final sizes = <String, int>{};
  for (final line in output.split('\n')) {
    final tab = line.indexOf('\t');
    if (tab <= 0) continue;
    final kib = int.tryParse(line.substring(0, tab).trim());
    if (kib == null) continue;
    sizes[line.substring(tab + 1).trimRight()] = kib * 1024;
  }
  return sizes;
}

/// Parses the `<path>\t<bytes>` lines the PowerShell fallback writes.
Map<String, int> parsePathSizes(String output) {
  final sizes = <String, int>{};
  for (final line in output.split('\n')) {
    final tab = line.lastIndexOf('\t');
    if (tab <= 0) continue;
    final bytes = int.tryParse(line.substring(tab + 1).trim());
    if (bytes == null) continue;
    sizes[line.substring(0, tab)] = bytes;
  }
  return sizes;
}

/// One path per line, as `find -print` and PowerShell's `FullName` write it.
List<String> parseFoundPaths(String output) => [
  for (final line in output.split('\n'))
    if (line.trim().isNotEmpty) line.trimRight(),
];
