import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/src/core/mouse/button.dart';
import 'package:xterm/src/core/mouse/button_state.dart';
import 'package:xterm/src/core/mouse/mode.dart';
import 'package:xterm/src/terminal_view.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/gesture/gesture_detector.dart';
import 'package:xterm/src/ui/pointer_input.dart';
import 'package:xterm/src/ui/render.dart';

class TerminalGestureHandler extends StatefulWidget {
  const TerminalGestureHandler({
    super.key,
    required this.terminalView,
    required this.terminalController,
    this.child,
    this.onTapUp,
    this.onSingleTapUp,
    this.onTapDown,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.onTertiaryTapDown,
    this.onTertiaryTapUp,
    this.enableInternalDragSelection = true,
    this.readOnly = false,
  });

  final TerminalViewState terminalView;

  final TerminalController terminalController;

  final Widget? child;

  final GestureTapUpCallback? onTapUp;

  final GestureTapUpCallback? onSingleTapUp;

  final GestureTapDownCallback? onTapDown;

  final GestureTapDownCallback? onSecondaryTapDown;

  final GestureTapUpCallback? onSecondaryTapUp;

  final GestureTapDownCallback? onTertiaryTapDown;

  final GestureTapUpCallback? onTertiaryTapUp;

  final bool enableInternalDragSelection;

  final bool readOnly;

  @override
  State<TerminalGestureHandler> createState() => _TerminalGestureHandlerState();
}

class _TerminalGestureHandlerState extends State<TerminalGestureHandler> {
  TerminalViewState get terminalView => widget.terminalView;

  RenderTerminal get renderTerminal => terminalView.renderTerminal;

  DragStartDetails? _lastDragStartDetails;
  Offset? _lastDragPosition;

  LongPressStartDetails? _lastLongPressStartDetails;

  /// Whether the terminal has mouse tracking enabled (tmux mouse on, etc.)
  bool get _isMouseTracking {
    final mode = terminalView.widget.terminal.mouseMode;
    return mode != MouseMode.none;
  }

  /// Whether drag events should be forwarded to the terminal as mouse events
  /// (like iTerm2 does when tmux mouse is on).
  bool get _shouldForwardDrag =>
      !terminalView.widget.preferLocalSelectionWhenMouseTracking &&
      _isMouseTracking &&
      (terminalView.widget.terminal.mouseMode == MouseMode.upDownScrollDrag ||
          terminalView.widget.terminal.mouseMode == MouseMode.upDownScrollMove);

  @override
  Widget build(BuildContext context) {
    return TerminalGestureDetector(
      child: widget.child,
      onTapUp: widget.onTapUp,
      onSingleTapUp: onSingleTapUp,
      onTapDown: onTapDown,
      onSecondaryTapDown: onSecondaryTapDown,
      onSecondaryTapUp: onSecondaryTapUp,
      onTertiaryTapDown: onSecondaryTapDown,
      onTertiaryTapUp: onSecondaryTapUp,
      onLongPressStart: onLongPressStart,
      onLongPressMoveUpdate: onLongPressMoveUpdate,
      // onLongPressUp: onLongPressUp,
      onDragStart: onDragStart,
      onDragUpdate: onDragUpdate,
      onDragEnd: onDragEnd,
      onDoubleTapDown: onDoubleTapDown,
    );
  }

  bool get _shouldSendTapEvent =>
      !widget.readOnly &&
      widget.terminalController.shouldSendPointerInput(PointerInput.tap);

  bool get _shouldDeferPrimaryTapUntilTapUp =>
      terminalView.widget.preferLocalSelectionWhenMouseTracking &&
      _isMouseTracking;

  void _tapDown(
    GestureTapDownCallback? callback,
    TapDownDetails details,
    TerminalMouseButton button, {
    bool forceCallback = false,
  }) {
    // Check if the terminal should and can handle the tap down event.
    var handled = false;
    final shouldDeferTap =
        button == TerminalMouseButton.left && _shouldDeferPrimaryTapUntilTapUp;

    if (_shouldSendTapEvent && !shouldDeferTap) {
      handled = renderTerminal.mouseEvent(
        button,
        TerminalMouseButtonState.down,
        details.localPosition,
      );
    }
    // If the event was not handled by the terminal, use the supplied callback.
    if (!handled || forceCallback) {
      callback?.call(details);
    }
  }

  void _tapUp(
    GestureTapUpCallback? callback,
    TapUpDetails details,
    TerminalMouseButton button, {
    bool forceCallback = false,
  }) {
    // Check if the terminal should and can handle the tap up event.
    var handled = false;
    if (_shouldSendTapEvent) {
      final shouldDeferTap = button == TerminalMouseButton.left &&
          _shouldDeferPrimaryTapUntilTapUp;
      if (shouldDeferTap) {
        renderTerminal.mouseEvent(
          button,
          TerminalMouseButtonState.down,
          details.localPosition,
        );
      }
      handled = renderTerminal.mouseEvent(
        button,
        TerminalMouseButtonState.up,
        details.localPosition,
      );
    }
    // If the event was not handled by the terminal, use the supplied callback.
    if (!handled || forceCallback) {
      callback?.call(details);
    }
  }

  void onTapDown(TapDownDetails details) {
    // onTapDown is special, as it will always call the supplied callback.
    // The TerminalView depends on it to bring the terminal into focus.
    _tapDown(
      widget.onTapDown,
      details,
      TerminalMouseButton.left,
      forceCallback: true,
    );
  }

  void onSingleTapUp(TapUpDetails details) {
    _tapUp(widget.onSingleTapUp, details, TerminalMouseButton.left);
  }

  void onSecondaryTapDown(TapDownDetails details) {
    _tapDown(widget.onSecondaryTapDown, details, TerminalMouseButton.right);
  }

  void onSecondaryTapUp(TapUpDetails details) {
    _tapUp(widget.onSecondaryTapUp, details, TerminalMouseButton.right);
  }

  void onTertiaryTapDown(TapDownDetails details) {
    _tapDown(widget.onTertiaryTapDown, details, TerminalMouseButton.middle);
  }

  void onTertiaryTapUp(TapUpDetails details) {
    _tapUp(widget.onTertiaryTapUp, details, TerminalMouseButton.right);
  }

  void onDoubleTapDown(TapDownDetails details) {
    if (!widget.enableInternalDragSelection) {
      return;
    }
    renderTerminal.selectWord(details.localPosition);
  }

  void onLongPressStart(LongPressStartDetails details) {
    if (!widget.enableInternalDragSelection) {
      return;
    }
    _lastLongPressStartDetails = details;
    renderTerminal.selectWord(details.localPosition);
  }

  void onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    if (!widget.enableInternalDragSelection) {
      return;
    }
    renderTerminal.selectWord(
      _lastLongPressStartDetails!.localPosition,
      details.localPosition,
    );
  }

  // void onLongPressUp() {}

  void onDragStart(DragStartDetails details) {
    if (!widget.enableInternalDragSelection) {
      return;
    }
    _lastDragStartDetails = details;
    _lastDragPosition = details.localPosition;

    if (_shouldForwardDrag) {
      // Mouse tracking active (tmux mouse on): forward drag as mouse-down
      // to the terminal so tmux handles selection natively (like iTerm2).
      renderTerminal.mouseEvent(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        details.localPosition,
      );
    } else {
      // No mouse tracking: do local text selection
      details.kind == PointerDeviceKind.mouse
          ? renderTerminal.selectCharacters(details.localPosition)
          : renderTerminal.selectWord(details.localPosition);
    }
  }

  void onDragUpdate(DragUpdateDetails details) {
    if (!widget.enableInternalDragSelection) {
      return;
    }
    _lastDragPosition = details.localPosition;
    if (_shouldForwardDrag) {
      // Forward drag movement as mouse-move to tmux
      renderTerminal.mouseEvent(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        details.localPosition,
      );
    } else {
      renderTerminal.selectCharacters(
        _lastDragStartDetails!.localPosition,
        details.localPosition,
      );
    }
  }

  void onDragEnd(DragEndDetails details) {
    if (!widget.enableInternalDragSelection) {
      return;
    }
    if (_shouldForwardDrag) {
      // Send mouse-up so tmux finalizes the selection
      final lastPos = _lastDragPosition ??
          _lastDragStartDetails?.localPosition ??
          Offset.zero;
      renderTerminal.mouseEvent(
        TerminalMouseButton.left,
        TerminalMouseButtonState.up,
        lastPos,
      );
    }
    _lastDragPosition = null;
  }
}
