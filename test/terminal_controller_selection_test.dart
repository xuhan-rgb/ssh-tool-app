import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('fixed selection offsets stay available until cleared', () {
    final controller = TerminalController();

    controller.setSelectionOffsets(
      const CellOffset(2, 3),
      const CellOffset(5, 4),
    );

    expect(
      controller.selection,
      BufferRangeLine(const CellOffset(2, 3), const CellOffset(5, 4)),
    );

    controller.clearSelection();

    expect(controller.selection, isNull);
  });

  test('fixed selection offsets survive later terminal output', () {
    final terminal = Terminal();
    final controller = TerminalController();

    terminal.write('alpha\r\nbeta\r\n');
    controller.setSelectionOffsets(
      const CellOffset(0, 0),
      const CellOffset(5, 0),
    );

    terminal.write('gamma\r\ndelta\r\n');

    expect(
      controller.selection,
      BufferRangeLine(const CellOffset(0, 0), const CellOffset(5, 0)),
    );
    expect(terminal.buffer.getText(controller.selection!), 'alpha');
  });
}
