import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:toolshed/tools/dev_sweeper/trash_linux.dart';

void main() {
  late Directory scratch;
  late FreedesktopTrash trash;

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('toolshed-trash-');
    trash = FreedesktopTrash(dataHome: '${scratch.path}/data');
    addTearDown(() async {
      if (scratch.existsSync()) await scratch.delete(recursive: true);
    });
  });

  Directory cache(String parent, {String name = 'caches'}) =>
      Directory('${scratch.path}/$parent/$name');

  test(
    'moves a directory into files/ and records where it came from',
    () async {
      final gradle = cache('home/.gradle');
      await gradle.create(recursive: true);
      await File('${gradle.path}/blob.bin').writeAsBytes([1, 2, 3]);

      await trash.move(gradle.path);

      final moved = Directory('${trash.filesDir}/caches');
      expect(moved.existsSync(), isTrue);
      expect(File('${moved.path}/blob.bin').readAsBytesSync(), [1, 2, 3]);
      expect(Directory(gradle.path).existsSync(), isFalse);

      final info = File('${trash.infoDir}/caches.trashinfo').readAsStringSync();
      expect(info, startsWith('[Trash Info]\n'));
      expect(info, contains('Path=${encodeTrashPath(gradle.path)}\n'));
      expect(
        info,
        matches(RegExp(r'DeletionDate=\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\n')),
      );
    },
  );

  test('a second cache with the same name gets a suffix', () async {
    final first = cache('a');
    final second = cache('b');
    await first.create(recursive: true);
    await second.create(recursive: true);

    await trash.move(first.path);
    await trash.move(second.path);

    expect(Directory('${trash.filesDir}/caches').existsSync(), isTrue);
    expect(Directory('${trash.filesDir}/caches.1').existsSync(), isTrue);
    expect(File('${trash.infoDir}/caches.trashinfo').existsSync(), isTrue);
    final info = File('${trash.infoDir}/caches.1.trashinfo').readAsStringSync();
    expect(info, contains('Path=${encodeTrashPath(second.path)}\n'));
  });

  test('a failed rename leaves no info file claiming a move', () async {
    await expectLater(
      trash.move('${scratch.path}/missing'),
      throwsA(isA<FileSystemException>()),
    );

    expect(Directory(trash.infoDir).existsSync(), isTrue);
    expect(Directory(trash.infoDir).listSync(), isEmpty);
  });

  test('encodes each path segment and keeps the slashes readable', () {
    expect(
      encodeTrashPath('/Users/me/My Files/a b'),
      '/Users/me/My%20Files/a%20b',
    );
    expect(encodeTrashPath('/Users/me/a+b'), '/Users/me/a%2Bb');
    expect(encodeTrashPath('/Users/me/café'), '/Users/me/caf%C3%A9');
  });
}
