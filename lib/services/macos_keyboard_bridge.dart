import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class MacosShortcutEvent {
  final String action;
  final int sequence;
  final String phase;
  final int keyCode;
  final bool alt;
  final bool meta;
  final bool control;
  final bool shift;
  final String? characters;
  final String? charactersIgnoringModifiers;
  final DateTime timestamp;

  const MacosShortcutEvent({
    required this.action,
    required this.sequence,
    required this.phase,
    required this.keyCode,
    required this.alt,
    required this.meta,
    required this.control,
    required this.shift,
    required this.timestamp,
    this.characters,
    this.charactersIgnoringModifiers,
  });

  factory MacosShortcutEvent.fromMap(Map<Object?, Object?> map) {
    return MacosShortcutEvent(
      action: (map['action'] as String? ?? '').trim(),
      sequence: (map['sequence'] as num? ?? 0).toInt(),
      phase: (map['phase'] as String? ?? 'unknown').trim(),
      keyCode: (map['keyCode'] as num? ?? -1).toInt(),
      alt: map['alt'] == true,
      meta: map['meta'] == true,
      control: map['control'] == true,
      shift: map['shift'] == true,
      characters: map['characters'] as String?,
      charactersIgnoringModifiers:
          map['charactersIgnoringModifiers'] as String?,
      timestamp: DateTime.tryParse(map['timestamp'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'action': action,
      'sequence': sequence,
      'phase': phase,
      'keyCode': keyCode,
      'alt': alt,
      'meta': meta,
      'control': control,
      'shift': shift,
      'characters': characters,
      'charactersIgnoringModifiers': charactersIgnoringModifiers,
      'timestamp': timestamp.toIso8601String(),
    };
  }
}

class MacosKeyboardBridge {
  static const MethodChannel _channel =
      MethodChannel('ssh_tool_app/macos_keyboard');
  static final StreamController<MacosShortcutEvent> _eventController =
      StreamController<MacosShortcutEvent>.broadcast();

  static bool _initialized = false;
  static Future<void> _writeQueue = Future<void>.value();
  static String? _logFilePath;

  static Stream<MacosShortcutEvent> get events => _eventController.stream;

  static Future<void> ensureInitialized() async {
    if (_initialized || !Platform.isMacOS) {
      return;
    }
    _initialized = true;
    _channel.setMethodCallHandler(_handleMethodCall);
    await log(
      'bridge',
      'initialized',
      const <String, Object?>{'platform': 'macOS'},
    );
  }

  static Future<void> setTmuxShortcutCaptureEnabled(
    bool enabled, {
    String reason = '',
  }) async {
    if (!Platform.isMacOS) {
      return;
    }
    await ensureInitialized();
    await _channel.invokeMethod<void>(
      'setTmuxShortcutCaptureEnabled',
      <String, Object?>{
        'enabled': enabled,
        'reason': reason,
      },
    );
    await log(
      'bridge',
      'set capture',
      <String, Object?>{
        'enabled': enabled,
        'reason': reason,
      },
    );
  }

  static Future<void> log(
    String scope,
    String message, [
    Map<String, Object?> data = const <String, Object?>{},
  ]) async {
    if (!Platform.isMacOS) {
      return;
    }
    final entry = <String, Object?>{
      'timestamp': DateTime.now().toIso8601String(),
      'scope': scope,
      'message': message,
      'data': data,
    };
    final encoded = jsonEncode(entry);
    debugPrint('[keyboard_flutter] $encoded');

    _writeQueue = _writeQueue.then((_) async {
      final file = File(await logFilePath());
      await file.writeAsString('$encoded\n',
          mode: FileMode.append, flush: true);
    }).catchError((Object error, StackTrace stackTrace) {
      debugPrint('[keyboard_flutter] write failed: $error');
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'macos_keyboard_bridge',
          context: ErrorDescription('writing keyboard log'),
        ),
      );
    });

    await _writeQueue;
  }

  static Future<String> logFilePath() async {
    if (_logFilePath != null) {
      return _logFilePath!;
    }
    final appSupportDir = await getApplicationSupportDirectory();
    final logDir = Directory(
      '${appSupportDir.path}${Platform.pathSeparator}ssh_tool_app${Platform.pathSeparator}logs',
    );
    if (!await logDir.exists()) {
      await logDir.create(recursive: true);
    }
    _logFilePath =
        '${logDir.path}${Platform.pathSeparator}keyboard_flutter.log';
    return _logFilePath!;
  }

  static Future<void> clearLog() async {
    if (!Platform.isMacOS) {
      return;
    }
    await ensureInitialized();
    final file = File(await logFilePath());
    if (await file.exists()) {
      await file.writeAsString('', flush: true);
    }
    try {
      await _channel.invokeMethod<void>('clearNativeKeyboardLog');
    } catch (error, stackTrace) {
      debugPrint('[keyboard_flutter] clear native log failed: $error');
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'macos_keyboard_bridge',
          context: ErrorDescription('clearing native keyboard log'),
        ),
      );
    }
  }

  static Future<void> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'nativeShortcut':
        final raw = call.arguments;
        if (raw is! Map<Object?, Object?>) {
          await log(
            'bridge',
            'ignored malformed native shortcut payload',
            <String, Object?>{'payloadType': raw.runtimeType.toString()},
          );
          return;
        }
        final event = MacosShortcutEvent.fromMap(raw);
        _eventController.add(event);
        await log('bridge', 'received native shortcut', event.toMap());
        return;
      default:
        await log(
          'bridge',
          'unhandled method call',
          <String, Object?>{'method': call.method},
        );
    }
  }
}
