import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  Future<void> pumpTerminal(
    WidgetTester tester, {
    required Terminal terminal,
    required TerminalController controller,
    bool preferLocalSelectionWhenMouseTracking = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 640,
            height: 320,
            child: TerminalView(
              terminal,
              controller: controller,
              simulateScroll: false,
              preferLocalSelectionWhenMouseTracking:
                  preferLocalSelectionWhenMouseTracking,
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
  }

  testWidgets(
    'mouse drag keeps a local selection when mouse tracking is enabled',
    (tester) async {
      final output = StringBuffer();
      final terminal = Terminal(onOutput: output.write);
      final controller = TerminalController();

      terminal.write('first line\r\nsecond line\r\nthird line\r\n');
      terminal.write('\x1b[?1000h\x1b[?1006h');

      await pumpTerminal(
        tester,
        terminal: terminal,
        controller: controller,
      );

      final rect = tester.getRect(find.byType(TerminalView));
      final start = rect.topLeft + const Offset(24, 24);
      final end = rect.topLeft + const Offset(200, 72);

      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await gesture.addPointer(location: start);
      await tester.pump();
      await gesture.down(start);
      await tester.pump();
      await gesture.moveTo(end);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(controller.selection, isNotNull);
      expect(
        RegExp(r'\x1b\[<(\d+);(\d+);(\d+)([Mm])').hasMatch(output.toString()),
        isFalse,
      );
    },
  );

  testWidgets(
    'mouse click still forwards to the terminal when local selection is preferred',
    (tester) async {
      final output = StringBuffer();
      final terminal = Terminal(onOutput: output.write);
      final controller = TerminalController();

      terminal.write('click target\r\n');
      terminal.write('\x1b[?1000h\x1b[?1006h');

      await pumpTerminal(
        tester,
        terminal: terminal,
        controller: controller,
      );

      final rect = tester.getRect(find.byType(TerminalView));
      final point = rect.topLeft + const Offset(40, 24);

      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await gesture.addPointer(location: point);
      await tester.pump();
      await gesture.down(point);
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 350));

      final matches = RegExp(r'\x1b\[<(\d+);(\d+);(\d+)([Mm])')
          .allMatches(output.toString())
          .toList();

      expect(matches.length, 2);
      expect(matches.first.group(4), 'M');
      expect(matches.last.group(4), 'm');
    },
  );
}
