import 'dart:io';

/// The freedesktop.org Trash, implemented directly so Linux needs no
/// third-party package.
///
/// The spec is two directories: `files/` holds the moved entry, and
/// `info/<name>.trashinfo` records where it came from and when, which is what
/// lets a file manager offer "Restore". A rename is used, never a copy followed
/// by a delete, so a cross-device target fails loudly instead of losing data.
class FreedesktopTrash {
  FreedesktopTrash({required this.dataHome});

  final String dataHome;

  String get _root => '$dataHome/Trash';
  String get filesDir => '$_root/files';
  String get infoDir => '$_root/info';

  Future<void> move(String path) async {
    await Directory(filesDir).create(recursive: true);
    await Directory(infoDir).create(recursive: true);

    final name = _uniqueName(_basename(path));
    final info = File('$infoDir/$name.trashinfo');
    await info.writeAsString(_trashInfo(path), flush: true);

    try {
      await Directory(path).rename('$filesDir/$name');
    } on FileSystemException {
      // A move that did not happen must not leave an info file claiming it did.
      try {
        await info.delete();
      } on FileSystemException {
        // Nothing more to do; the move's own error is the one to report.
      }
      rethrow;
    }
  }

  String _trashInfo(String path) {
    final now = DateTime.now();
    return '[Trash Info]\n'
        'Path=${encodeTrashPath(path)}\n'
        'DeletionDate=${_date(now)}\n';
  }

  String _uniqueName(String base) {
    var candidate = base;
    var n = 1;
    while (FileSystemEntity.typeSync(
              '$filesDir/$candidate',
              followLinks: false,
            ) !=
            FileSystemEntityType.notFound ||
        File('$infoDir/$candidate.trashinfo').existsSync()) {
      candidate = '$base.$n';
      n++;
    }
    return candidate;
  }

  static String _basename(String path) {
    final trimmed = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    return trimmed.split('/').last;
  }

  static String _date(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)}'
        'T${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }
}

/// Percent-encodes each path segment, keeping the separators readable.
String encodeTrashPath(String path) => path
    .split('/')
    .map((segment) => segment.isEmpty ? segment : Uri.encodeComponent(segment))
    .join('/');
