# CLAUDE.md

## Project Overview

Flutter Android SSH终端客户端，支持交互式shell（htop/vim等）、实时输出流、多会话管理。

## Common Commands

```bash
# 开发运行（需指定设备，不支持web）
flutter run -d <device_id>

# 代码生成（修改 models/ 后必须执行）
flutter packages pub run build_runner build --delete-conflicting-outputs

# 构建发布APK
flutter build apk --release

# 查看可用设备
flutter devices
```

## Architecture

```
lib/
├── main.dart                       # 入口：Hive初始化 → HomeScreen
├── models/
│   ├── ssh_connection.dart         # Hive TypeId:0 - SSH连接配置
│   ├── command_record.dart         # Hive TypeId:1 - 命令历史记录
│   └── *.g.dart                    # build_runner自动生成的Hive适配器
├── services/
│   ├── ssh_service.dart            # SSH核心：连接、shell会话、流式输出
│   └── storage_service.dart        # Hive CRUD：connections + command_history boxes
├── screens/
│   ├── home_screen.dart            # 连接列表（ValueListenableBuilder响应式）
│   ├── connection_form_screen.dart # 创建/编辑连接表单
│   └── terminal_screen.dart        # 交互式终端界面
└── widgets/
    └── connection_card.dart        # 连接信息卡片
```

## Key Technical Details

### SSH交互式终端（核心）

使用 `dartssh2` 的 `client.shell()` 而非 `client.execute()`，创建持久化PTY会话：

```dart
// 创建交互式shell（支持htop等全屏命令）
final shell = await client.shell(pty: SSHPtyConfig(width: 80, height: 24));

// 实时监听输出（Stream-based）
shell.stdout.listen((data) {
  final text = utf8.decode(data);  // 注意：不能用transform(Utf8Decoder())，类型不匹配
  outputController.add(text);
});

// 发送命令到stdin
shell.stdin.add(utf8.encode('$command\n'));

// 发送Ctrl+C中断
shell.stdin.add(utf8.encode('\x03'));
```

**关键点**：
- `utf8.decode(data)` 直接在listener中解码，不能用 `stream.transform(Utf8Decoder())`（会报 StreamTransformer 类型错误）
- `TerminalSession` 持有 `StreamController<String>.broadcast()` 向UI推送输出
- `terminal_screen.dart` 用 `StringBuffer` 累积输出，`setState` 触发渲染
- 连接超时30秒，支持 `SocketException`/`TimeoutException`/`SSHAuthFailError`/`SSHAuthAbortError` 分类处理

### Hive数据持久化

两个Box：
- `connections` (Box\<SshConnection\>) — SSH连接配置
- `command_history` (Box\<CommandRecord\>) — 命令记录

**添加模型字段流程**：
1. 在模型类添加 `@HiveField(N)` 新字段
2. 运行 `flutter packages pub run build_runner build --delete-conflicting-outputs`
3. 新字段需设默认值（旧数据无此字段）

### 状态管理

- `HomeScreen`：`ValueListenableBuilder` 监听 Hive box 变化
- `TerminalScreen`：`StreamSubscription` 监听 SSH 输出流 + `setState`
- 无Provider/Riverpod依赖

### Android权限

`AndroidManifest.xml` 已配置：
- `INTERNET` — SSH网络连接
- `ACCESS_NETWORK_STATE` — 网络状态检测

## xterm + tmux 鼠标选区问题与解决方案

### 问题背景

tmux 终端中鼠标拖选文字时，执行几次 `ls` 等命令后选区失效（无法选中或选中立刻消失）。

### 根因分析

两个独立问题叠加：

1. **InfiniteScrollView 手势竞争**：xterm 在 alternate screen buffer（tmux）模式下包裹 `InfiniteScrollView`（`Scrollable`），其 `DragGestureRecognizer` 与文字选区的 `PanGestureRecognizer` 竞争同一个拖拽手势。内容多时 Scrollable 赢，拖拽被当作滚动而非选区。

2. **tmux mouse tracking 回传干扰**：tmux `mouse on` 通过 escape sequence 开启终端 mouse tracking，xterm 的原始 drag handler 只做本地 `selectCharacters()`，不转发 drag 事件给 tmux。同时 tap 事件发给 tmux 后，tmux 回传屏幕刷新，导致 `CellAnchor` detach、选区失效。

### 解决方案

#### Patch 1: `scroll_handler.dart` — 跳过 InfiniteScrollView

文件：`~/.pub-cache/hosted/pub.dev/xterm-4.0.0/lib/src/ui/scroll_handler.dart`

当 `simulateScroll == false` 时直接返回 child，不创建 `InfiniteScrollView`，消除手势竞争。app 中 TerminalView 设置 `simulateScroll: false`。

#### Patch 2: `gesture_handler.dart` — drag 转发给 tmux

文件：`~/.pub-cache/hosted/pub.dev/xterm-4.0.0/lib/src/ui/gesture/gesture_handler.dart`

当 terminal mouseMode 为 `upDownScrollDrag` 或 `upDownScrollMove`（tmux mouse on 会设置）时，`onDragStart`/`onDragUpdate`/`onDragEnd` 转发为 `mouseEvent`（mouse-down → mouse-move → mouse-up），让 tmux 原生处理选区（与 iTerm2 行为一致）。无 mouse tracking 时保持原始本地选区行为。

需同步修改 `gesture_detector.dart` 添加 `onDragEnd` 回调。

#### tmux 配置

远端配置文件：`/tmp/.ssh_tool_tmux.conf`（app 自动上传）

```
set -g mouse on
set -g set-clipboard on    # OSC 52 剪贴板同步
set -s set-clipboard on
```

### 注意事项

- xterm patch 在 `~/.pub-cache` 中，**`flutter pub get` 或升级 xterm 版本会覆盖**，需重新 patch
- 远端旧配置需删除后重连才会更新：`rm /tmp/.ssh_tool_tmux.conf`
- `_tmuxConfigUploaded` 标记在 app 生命周期内只检查一次，修改配置后需重启 app

## Important Constraints

- **不支持Web平台**：dartssh2 使用原生Socket，`flutter run` 不能选 Chrome
- **密码明文存储**：Hive中未加密，勿在不安全设备使用
- **SSH密钥认证**：UI已有开关，但后端未实现（`ssh_service.dart` TODO注释处）
- **终端固定80x24**：未做屏幕尺寸自适应
- **无ANSI颜色解析**：彩色输出显示为转义序列原文

## Troubleshooting

| 问题 | 解决 |
|------|------|
| `Utf8Decoder` 类型错误 | 用 `utf8.decode(data)` 而非 `stream.transform()` |
| 多设备时flutter run失败 | 加 `-d <device_id>` 指定设备 |
| 连接闪退/卡死 | 确认用的是 `shell()` 而非 `execute()`（execute会阻塞） |
| 代码生成失败 | `flutter clean && flutter pub get` 后重试 |
| Hive数据损坏 | `StorageService.clearAll()` 或清除应用数据 |

## Dependencies

| 包 | 版本 | 用途 |
|----|------|------|
| dartssh2 | ^2.13.0 | 纯Dart SSH客户端（shell/SFTP/端口转发） |
| hive / hive_flutter | ^2.2.3 | 本地NoSQL存储 |
| uuid | ^4.0.0 | 唯一ID生成 |
| intl | ^0.19.0 | 日期格式化 |
| build_runner + hive_generator | dev | Hive TypeAdapter代码生成 |
