import 'package:flutter/services.dart';

import '../models/tool_exception.dart';

/// Dart side of the Android bridge. Keep in sync with
/// `android/app/src/main/kotlin/com/bling/toolshed/MemReaperChannel.kt`.
class MemReaperChannel {
  const MemReaperChannel();

  static const MethodChannel _channel = MethodChannel(
    'com.bling.toolshed/memreaper',
  );

  Future<Map<String, Object?>> status() =>
      _map('status', const <String, Object?>{});

  Future<List<Map<String, Object?>>> rankedApps({
    required int windowDays,
    required int limit,
  }) async {
    final raw = await _call('rankedApps', {
      'windowDays': windowDays,
      'limit': limit,
    });
    if (raw is! List) return const [];
    return raw.whereType<Map<Object?, Object?>>().map(_stringKey).toList();
  }

  Future<List<int>?> appIcon(String packageName, int sizePx) async {
    final raw = await _call('appIcon', {
      'packageName': packageName,
      'sizePx': sizePx,
    });
    return raw is Uint8List ? raw.toList() : null;
  }

  /// Returns null on success, otherwise the reason the system page could not be
  /// opened (some OEM ROMs remove the usage-access screen entirely).
  Future<String?> openAppDetails(String packageName) =>
      _nullableText('openAppDetails', {'packageName': packageName});

  Future<String?> openUsageAccess() =>
      _nullableText('openUsageAccess', const {});

  Future<Object?> _call(String method, Map<String, Object?> args) async {
    try {
      return await _channel.invokeMethod<Object?>(method, args);
    } on PlatformException catch (e) {
      throw ToolException(
        'ANDROID_${e.code}',
        e.message ?? 'The Android side failed while calling $method.',
        detail: e.stacktrace,
      );
    } on MissingPluginException {
      throw const ToolException(
        'CHANNEL_MISSING',
        'The Android bridge is not attached to this engine, so per-app memory '
            'cannot be read.',
      );
    }
  }

  Future<Map<String, Object?>> _map(
    String method,
    Map<String, Object?> args,
  ) async {
    final raw = await _call(method, args);
    if (raw is! Map) {
      throw ToolException(
        'BAD_RESPONSE',
        '$method returned ${raw.runtimeType} instead of a map.',
      );
    }
    return _stringKey(raw);
  }

  Future<String?> _nullableText(
    String method,
    Map<String, Object?> args,
  ) async {
    final raw = await _call(method, args);
    if (raw == null) return null;
    final text = '$raw'.trim();
    return text.isEmpty ? null : text;
  }

  static Map<String, Object?> _stringKey(Map<Object?, Object?> map) =>
      map.map((key, value) => MapEntry('$key', value));
}
