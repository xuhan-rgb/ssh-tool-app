import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import 'macos_keyboard_bridge.dart';

class TerminalClipboardService {
  static void bind(Terminal terminal) {
    terminal.onPrivateOSC = (code, args) {
      if (code != '52') return;

      final text = decodeOsc52Payload(args);
      if (text == null || text.isEmpty) return;

      unawaited(
        MacosKeyboardBridge.log(
          'clipboard',
          'received OSC 52 payload',
          <String, Object?>{
            'textLength': text.length,
            'argCount': args.length,
          },
        ),
      );
      unawaited(Clipboard.setData(ClipboardData(text: text)));
    };
  }

  static String? decodeOsc52Payload(List<String> args) {
    if (args.length < 2) return null;

    final payload = args.last.trim();
    if (payload.isEmpty || payload == '?') return null;

    try {
      final bytes = base64.decode(payload);
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }
}
