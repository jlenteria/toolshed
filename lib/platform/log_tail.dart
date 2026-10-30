import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The lines [path] gains after the stream starts, one per event.
///
/// Size-polling rather than a spawned `tail -f`: the caller owns the offset, a
/// truncated or rotated log is handled instead of silently going backwards, and
/// there is no child process to kill when the panel closes.
Stream<String> tailAppendedLines(
  String path, {
  Duration every = const Duration(seconds: 1),
}) async* {
  final file = File(path);
  var offset = file.lengthSync();
  var partial = '';
  while (true) {
    await Future<void>.delayed(every);
    final size = file.statSync().size;
    if (size < offset) {
      offset = 0;
      partial = '';
    }
    if (size == offset) continue;
    final raf = await file.open();
    try {
      await raf.setPosition(offset);
      final chunk = await raf.read(size - offset);
      offset = size;
      partial += utf8.decode(chunk, allowMalformed: true);
      final lines = partial.split('\n');
      // The last element is either an unfinished line or the empty string after
      // a real newline; hold it either way and emit the complete rest.
      partial = lines.removeLast();
      for (final line in lines) {
        yield line;
      }
    } finally {
      await raf.close();
    }
  }
}
