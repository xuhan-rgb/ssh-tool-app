import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('tmux mouse-up uses the last drag position', (tester) async {
    final output = StringBuffer();
    final terminal = Terminal(onOutput: output.write);

    // Enable drag reporting and SGR mouse coordinates so the test can
    // inspect the reported release position directly.
    terminal.write('\x1b[?1002h\x1b[?1006h');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 640,
            height: 320,
            child: TerminalView(
              terminal,
              simulateScroll: false,
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final rect = tester.getRect(find.byType(TerminalView));
    final start = rect.topLeft + const Offset(24, 24);
    final end = rect.topLeft + const Offset(240, 120);

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

    final matches = RegExp(r'\x1b\[<(\d+);(\d+);(\d+)([Mm])')
        .allMatches(output.toString())
        .toList();

    expect(matches.length, greaterThanOrEqualTo(3));

    final first = matches.first;
    final last = matches.last;
    final releaseMatchesPress =
        first.group(2) == last.group(2) && first.group(3) == last.group(3);

    expect(last.group(4), 'm');
    expect(releaseMatchesPress, isFalse);
  });
}
