import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/services/terminal_clipboard_service.dart';

void main() {
  group('TerminalClipboardService.decodeOsc52Payload', () {
    test('decodes valid OSC 52 payload', () {
      final text = TerminalClipboardService.decodeOsc52Payload(
        const ['c', '5L2g5aW977yM5LiW55WM'],
      );

      expect(text, '你好，世界');
    });

    test('returns null for missing payload', () {
      final text = TerminalClipboardService.decodeOsc52Payload(
        const ['c'],
      );

      expect(text, isNull);
    });

    test('returns null for invalid payload', () {
      final text = TerminalClipboardService.decodeOsc52Payload(
        const ['c', '%%%'],
      );

      expect(text, isNull);
    });
  });
}
