import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';
import '../models/ssh_connection.dart';
import '../services/ssh_service.dart';
import '../services/storage_service.dart';
import '../services/terminal_clipboard_service.dart';
import '../theme/app_theme.dart';

class TerminalScreen extends StatefulWidget {
  final SshConnection connection;
  final String? tmuxSessionName;
  final String? tmuxWorkDir;
  final String? initialCommand;
  final String? terminalSessionId;

  const TerminalScreen({
    super.key,
    required this.connection,
    this.tmuxSessionName,
    this.tmuxWorkDir,
    this.initialCommand,
    this.terminalSessionId,
  });

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  late Terminal _terminal;
  late TerminalController _terminalController;

  bool _isConnecting = false;
  bool _isConnected = false;
  String? _errorMessage;
  StreamSubscription? _outputSubscription;

  double _fontSize = StorageService.getTerminalFontSize();
  static const double _minFontSize = 6.0;
  static const double _maxFontSize = 24.0;

  Timer? _resizeTimer;
  final ScrollController _scrollController = ScrollController();

  String get _sessionId => widget.terminalSessionId ?? (widget.tmuxSessionName != null
      ? '${widget.connection.id}:${widget.tmuxSessionName}'
      : widget.connection.id);

  @override
  void initState() {
    super.initState();
    _initTerminal();
    _connectToServer();
  }

  void _initTerminal() {
    _terminal = Terminal(maxLines: 10000);
    _terminalController = TerminalController();
    TerminalClipboardService.bind(_terminal);

    _terminal.onOutput = (data) {
      if (_isConnected) {
        SshService.sendInput(_sessionId, data);
      }
    };

    _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      if (_isConnected) {
        // 防抖：窗口拖拽/字体变化时避免高频 resize 导致 tmux 乱码
        _resizeTimer?.cancel();
        _resizeTimer = Timer(const Duration(milliseconds: 300), () {
          SshService.resizePty(_sessionId, width, height);
        });
      }
    };
  }

  @override
  void dispose() {
    _resizeTimer?.cancel();
    _outputSubscription?.cancel();
    _terminalController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _connectToServer() async {
    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });

    try {
      final session =
          await SshService.connect(widget.connection, sessionId: _sessionId);
      if (widget.tmuxSessionName != null) {
        session.tmuxName = widget.tmuxSessionName;
        session.workDir = widget.tmuxWorkDir ?? '~';
      }
      final isReattach = session.outputBuffer.isNotEmpty;

      _outputSubscription = session.rawOutputStream.listen(
        (data) {
          _terminal.write(utf8.decode(data, allowMalformed: true));
        },
        onError: (error) {
          _terminal.write('\r\n[错误]: $error\r\n');
        },
      );

      setState(() {
        _isConnected = true;
        _isConnecting = false;
      });

      if (isReattach) {
        // tmux 重连：不回放旧 buffer，强制 resize 抖动让 tmux 重绘
        WidgetsBinding.instance.addPostFrameCallback((_) {
          Future.delayed(const Duration(milliseconds: 300), () {
            if (!mounted || !_isConnected) return;
            final cols = _terminal.viewWidth;
            final rows = _terminal.viewHeight;
            if (cols > 0 && rows > 0) {
              SshService.forceRedraw(_sessionId, cols, rows);
            }
          });
        });
      }

      if (!isReattach && widget.tmuxSessionName != null) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (_isConnected) {
          final name = widget.tmuxSessionName!;
          final dir = widget.tmuxWorkDir?.isNotEmpty == true
              ? widget.tmuxWorkDir!
              : '~';
          SshService.sendInput(
            _sessionId,
            "tmux new-session -A -s '$name' -c '$dir'\n",
          );
          StorageService.saveTmuxSession(widget.connection.id, name, dir);
        }
      }
      if (!isReattach && widget.tmuxSessionName == null &&
          widget.initialCommand != null) {
        await Future.delayed(const Duration(milliseconds: 350));
        if (mounted && _isConnected) {
          SshService.sendInput(_sessionId, '${widget.initialCommand!.trimRight()}\n');
        }
      }
    } catch (e) {
      setState(() {
        _isConnecting = false;
        _errorMessage = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.tmuxSessionName != null
            ? '${widget.connection.name} · ${widget.tmuxSessionName}'
            : widget.connection.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.text_decrease, size: 20),
            onPressed: _fontSize > _minFontSize
                ? () {
                    setState(() => _fontSize =
                        (_fontSize - 1).clamp(_minFontSize, _maxFontSize));
                    StorageService.setTerminalFontSize(_fontSize);
                  }
                : null,
            tooltip: '缩小字体',
          ),
          IconButton(
            icon: const Icon(Icons.text_increase, size: 20),
            onPressed: _fontSize < _maxFontSize
                ? () {
                    setState(() => _fontSize =
                        (_fontSize + 1).clamp(_minFontSize, _maxFontSize));
                    StorageService.setTerminalFontSize(_fontSize);
                  }
                : null,
            tooltip: '放大字体',
          ),
          if (!Platform.isMacOS)
            PopupMenuButton<String>(
              icon: const Icon(Icons.content_copy, size: 20),
              tooltip: '复制/粘贴',
              onSelected: (value) {
                if (value == 'copy') _copySelection();
                if (value == 'paste') _pasteToTerminal();
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                    value: 'copy',
                    child: Row(
                      children: [
                        Icon(Icons.copy, size: 18),
                        SizedBox(width: 8),
                        Text('复制选中')
                      ],
                    )),
                const PopupMenuItem(
                    value: 'paste',
                    child: Row(
                      children: [
                        Icon(Icons.paste, size: 18),
                        SizedBox(width: 8),
                        Text('粘贴')
                      ],
                    )),
              ],
            ),
          if (_isConnected)
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: _confirmDisconnect,
              tooltip: '断开连接',
            ),
        ],
      ),
      body: Column(
        children: [
          _buildStatusBar(),
          Expanded(child: _buildTerminalView()),
          if (_isConnected && !Platform.isMacOS) _buildQuickKeysBar(),
        ],
      ),
    );
  }

  Widget _buildStatusBar() {
    Color statusColor;
    String statusText;
    IconData statusIcon;

    if (_isConnecting) {
      statusColor = AppTheme.orange;
      statusText = '连接中...';
      statusIcon = Icons.sync;
    } else if (_isConnected) {
      statusColor = AppTheme.green;
      statusText = '已连接 ${widget.connection.connectionString}';
      statusIcon = Icons.check_circle;
    } else if (_errorMessage != null) {
      statusColor = AppTheme.red;
      statusText = '连接失败';
      statusIcon = Icons.error;
    } else {
      statusColor = AppTheme.textMuted;
      statusText = '未连接';
      statusIcon = Icons.cloud_off;
    }

    return Container(
      color: statusColor.withValues(alpha: 0.08),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Icon(statusIcon, size: 14, color: statusColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              statusText,
              style: TextStyle(
                  color: statusColor,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                  fontFamily: 'monospace'),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (!_isConnected && _errorMessage != null)
            TextButton(
              onPressed: _connectToServer,
              child: const Text('重试'),
            ),
        ],
      ),
    );
  }

  Widget _buildTerminalView() {
    if (!_isConnected && !_isConnecting && _errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 48, color: AppTheme.red),
            const SizedBox(height: 16),
            Text('连接失败', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _errorMessage!,
                style: TextStyle(color: AppTheme.textMuted),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _connectToServer,
              icon: const Icon(Icons.refresh),
              label: const Text('重新连接'),
            ),
          ],
        ),
      );
    }

    return TerminalView(
      _terminal,
      controller: _terminalController,
      scrollController: _scrollController,
      autofocus: true,
      theme: AppTheme.terminalTheme,
      textStyle: TerminalStyle(fontSize: _fontSize),
      simulateScroll: false,
      deleteDetection: true,
      onKeyEvent: _handleTerminalKeyEvent,
      onSecondaryTapUp: _onSecondaryTapUp,
    );
  }

  /// 快捷键工具栏
  Widget _buildQuickKeysBar() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.bgSurface,
        border: Border(top: BorderSide(color: AppTheme.borderSubtle, width: 1)),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildKeyButton(Icons.keyboard_arrow_up, () => _sendEsc('[A')),
                _buildKeyButton(
                    Icons.keyboard_arrow_down, () => _sendEsc('[B')),
                _buildKeyButton(
                    Icons.keyboard_arrow_left, () => _sendEsc('[D')),
                _buildKeyButton(
                    Icons.keyboard_arrow_right, () => _sendEsc('[C')),
                _buildSlashCommandMenu(),
                _divider(),
                _buildTextKey('Tab', () => _sendRaw('\t')),
                _buildTextKey('Esc', () => _sendRaw('\x1b')),
                _divider(),
                _buildTextKey('Ctrl+C', () => _sendRaw('\x03'), accent: 'red'),
                _buildTextKey('Ctrl+L', () => _sendRaw('\x0c')),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _divider() => Container(
        width: 1,
        height: 22,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        color: AppTheme.borderSubtle,
      );

  Widget _buildKeyButton(IconData icon, VoidCallback onPressed) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: 38,
            height: 34,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppTheme.borderSubtle),
            ),
            child: Icon(icon, size: 18, color: AppTheme.textSecondary),
          ),
        ),
      ),
    );
  }

  Widget _buildTextKey(String label, VoidCallback onPressed, {String? accent}) {
    Color textColor = AppTheme.textSecondary;
    Color bgColor = AppTheme.bgCard;
    Color borderColor = AppTheme.borderSubtle;

    if (accent == 'red') {
      textColor = AppTheme.red;
      bgColor = AppTheme.redDim;
      borderColor = AppTheme.red.withValues(alpha: 0.2);
    } else if (accent == 'purple') {
      textColor = AppTheme.purple;
      bgColor = AppTheme.purpleDim;
      borderColor = AppTheme.purple.withValues(alpha: 0.2);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: bgColor,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: borderColor),
            ),
            alignment: Alignment.center,
            child: Text(label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace',
                  color: textColor,
                )),
          ),
        ),
      ),
    );
  }

  Widget _buildSlashCommandMenu() {
    const commands = [
      ('/', '帮助'),
      ('/model', '切换模型'),
      ('/resume', '继续对话'),
      ('/clear', '清除上下文'),
      ('/usage', '查看消耗'),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: PopupMenuButton<String>(
        onSelected: (cmd) => _sendRaw(cmd),
        tooltip: '斜杠命令',
        offset: const Offset(0, -200),
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: AppTheme.purpleDim,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppTheme.purple.withValues(alpha: 0.2)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('/',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                      color: AppTheme.purple)),
              Icon(Icons.arrow_drop_down, size: 16, color: AppTheme.purple),
            ],
          ),
        ),
        itemBuilder: (_) => commands
            .map((c) => PopupMenuItem(
                  value: c.$1,
                  child: Row(
                    children: [
                      Text(c.$1,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontFamily: 'monospace')),
                      const SizedBox(width: 12),
                      Text(c.$2,
                          style: TextStyle(
                              fontSize: 12, color: AppTheme.textMuted)),
                    ],
                  ),
                ))
            .toList(),
      ),
    );
  }

  void _sendRaw(String data) => SshService.sendInput(_sessionId, data);
  void _sendEsc(String seq) => SshService.sendInput(_sessionId, '\x1b$seq');

  KeyEventResult _handleTerminalKeyEvent(FocusNode _, KeyEvent event) {
    if (!Platform.isMacOS) return KeyEventResult.ignored;

    final key = event.logicalKey;
    final isMetaPressed = HardwareKeyboard.instance.isMetaPressed;
    final isAltPressed = HardwareKeyboard.instance.isAltPressed;
    final isControlPressed = HardwareKeyboard.instance.isControlPressed;
    bool matches({
      required LogicalKeyboardKey logicalKey,
      bool meta = false,
      bool alt = false,
      bool control = false,
    }) {
      return key == logicalKey &&
          isMetaPressed == meta &&
          isAltPressed == alt &&
          isControlPressed == control;
    }

    if (matches(logicalKey: LogicalKeyboardKey.keyC, meta: true)) {
      if (event is! KeyUpEvent) {
        _copySelection();
      }
      return KeyEventResult.handled;
    }

    if (matches(logicalKey: LogicalKeyboardKey.keyV, meta: true)) {
      if (event is! KeyUpEvent) {
        unawaited(_pasteToTerminal());
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  Future<void> _pasteToTerminal() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      SshService.sendInput(_sessionId, data.text!);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已粘贴'), duration: Duration(seconds: 1)),
        );
      }
    }
  }

  void _copySelection() {
    final selection = _terminalController.selection;
    if (selection != null) {
      final text = _terminal.buffer.getText(selection);
      Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('已复制到剪贴板'), duration: Duration(seconds: 1)),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('请先在终端中选中文本'), duration: Duration(seconds: 1)),
        );
      }
    }
  }

  void _onSecondaryTapUp(TapUpDetails details, CellOffset cellOffset) {
    final hasSelection = _terminalController.selection != null;
    final renderBox = context.findRenderObject() as RenderBox;
    final position = renderBox.localToGlobal(details.localPosition);

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        PopupMenuItem<String>(
          value: 'copy',
          enabled: hasSelection,
          child: const Row(
            children: [
              Icon(Icons.copy, size: 18),
              SizedBox(width: 8),
              Text('复制'),
              Spacer(),
              Text('⌘C', style: TextStyle(color: Colors.grey, fontSize: 12)),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'paste',
          child: const Row(
            children: [
              Icon(Icons.paste, size: 18),
              SizedBox(width: 8),
              Text('粘贴'),
              Spacer(),
              Text('⌘V', style: TextStyle(color: Colors.grey, fontSize: 12)),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'selectAll',
          child: const Row(
            children: [
              Icon(Icons.select_all, size: 18),
              SizedBox(width: 8),
              Text('全选'),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == 'copy') {
        _copySelection();
      } else if (value == 'paste') {
        _pasteToTerminal();
      } else if (value == 'selectAll') {
        _terminalController.setSelectionOffsets(
          const CellOffset(0, 0),
          CellOffset(
            _terminal.viewWidth - 1,
            _terminal.buffer.lines.length - 1,
          ),
        );
      }
    });
  }

  Future<void> _confirmDisconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认断开连接'),
        content: const Text('确定要断开SSH连接吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.red),
            child: const Text('断开'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await SshService.disconnect(_sessionId);
      if (mounted) {
        Navigator.pop(context);
      }
    }
  }
}
