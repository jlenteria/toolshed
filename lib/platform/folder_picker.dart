import 'package:flutter/services.dart';

/// The desktop's own folder chooser, without a plugin package.
///
/// Every runner registers `toolshed/folder_picker`: `NSOpenPanel` on macOS, a
/// `GtkFileChooserDialog` on Linux and `IFileOpenDialog` on Windows. Keeping the
/// Dart side behind this tiny interface means a screen can be tested with a fake
/// picker, and a machine without a native handler gets an error it can show
/// instead of a frozen dialog.
abstract class FolderPicker {
  const FolderPicker();

  /// Opens a folder dialog and returns the chosen directory, or `null` when the
  /// user cancels.
  Future<String?> pickFolder({
    required String title,
    String? initialDirectory,
  });
}

class NativeFolderPicker implements FolderPicker {
  const NativeFolderPicker();

  static const MethodChannel _channel = MethodChannel('toolshed/folder_picker');

  @override
  Future<String?> pickFolder({
    required String title,
    String? initialDirectory,
  }) async {
    final picked = await _channel.invokeMethod<String>(
      'pickFolder',
      <String, String?>{
        'title': title,
        'initialDirectory': initialDirectory,
      },
    );
    if (picked == null || picked.trim().isEmpty) return null;
    return picked;
  }
}
