import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';

/// 悬浮历史浏览面板 — 不阻塞终端交互，可拖拽移动
class HistoryPanel extends StatefulWidget {
  final ValueNotifier<String> contentNotifier;
  final ValueNotifier<String> titleNotifier;
  final double fontSize;
  final VoidCallback onClose;

  const HistoryPanel({
    super.key,
    required this.contentNotifier,
    required this.titleNotifier,
    required this.fontSize,
    required this.onClose,
  });

  @override
  State<HistoryPanel> createState() => _HistoryPanelState();
}

class _HistoryPanelState extends State<HistoryPanel> {
  Offset _position = Offset.zero;
  bool _positioned = false;
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();
  String _lastContent = '';

  @override
  void initState() {
    super.initState();
    widget.contentNotifier.addListener(_onContentChanged);
  }

  @override
  void dispose() {
    widget.contentNotifier.removeListener(_onContentChanged);
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onContentChanged() {
    // 内容变化后自动滚到底部
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  void _initPosition(BoxConstraints constraints) {
    if (!_positioned) {
      _positioned = true;
      // 初始位置：右侧，垂直居中
      final panelWidth = constraints.maxWidth * 0.42;
      _position = Offset(
        constraints.maxWidth - panelWidth - 16,
        constraints.maxHeight * 0.05,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _initPosition(constraints);
        final panelWidth = constraints.maxWidth * 0.42;
        final panelHeight = constraints.maxHeight * 0.9;

        return Stack(
          children: [
            Positioned(
              left: _position.dx,
              top: _position.dy,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  width: panelWidth.clamp(300.0, constraints.maxWidth - 32),
                  height: panelHeight.clamp(200.0, constraints.maxHeight - 32),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A2E),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.borderAccent),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.5),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Column(
                      children: [
                        _buildTitleBar(),
                        Expanded(child: _buildContent()),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTitleBar() {
    return GestureDetector(
      onPanUpdate: (details) {
        setState(() {
          _position += details.delta;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: const BoxDecoration(
          color: Color(0xFF252545),
        ),
        child: Row(
          children: [
            const Icon(Icons.history, size: 16, color: Colors.white70),
            const SizedBox(width: 8),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: widget.titleNotifier,
                builder: (_, title, __) => Text(
                  'Pane 历史 — $title',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const Text(
              '选中 → Cmd+C 复制',
              style: TextStyle(color: Colors.white30, fontSize: 11),
            ),
            const SizedBox(width: 8),
            InkWell(
              onTap: widget.onClose,
              borderRadius: BorderRadius.circular(4),
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(Icons.close, size: 16, color: Colors.white38),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    return KeyboardListener(
      focusNode: _focusNode,
      onKeyEvent: (event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          widget.onClose();
        }
      },
      child: GestureDetector(
        onTap: () => _focusNode.requestFocus(),
        child: ValueListenableBuilder<String>(
          valueListenable: widget.contentNotifier,
          builder: (_, content, __) {
            if (content != _lastContent) {
              _lastContent = content;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_scrollController.hasClients) {
                  _scrollController
                      .jumpTo(_scrollController.position.maxScrollExtent);
                }
              });
            }
            return Scrollbar(
              controller: _scrollController,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  content,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: widget.fontSize,
                    color: Colors.white,
                    height: 1.4,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
