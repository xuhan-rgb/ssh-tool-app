# tmux 终端鼠标拖选失效问题分析

## 现象

在 ssh_tool_app 中通过 tmux 连接远程服务器时，鼠标拖选文字存在以下问题：

| 场景 | 能否拖选 |
|------|---------|
| 刚打开软件，连接服务器 | ✅ 正常 |
| 执行命令，屏幕**未**打满文字 | ✅ 正常 |
| 屏幕打满文字（如 Claude CLI 全屏输出） | ❌ 无法拖选 |
| 退到主界面，重新打开 shell 标签 | ✅ 恢复正常 |
| 退到主界面，重新打开 claude 标签 | ❌ 仍然无法拖选 |

**核心表现**：拖动鼠标时看不到任何选区高亮，松手后无文字被选中。

## 问题本质：两层鼠标事件争夺

普通终端（iTerm2、Terminal.app）不存在这个问题，因为它们实现了**修饰键旁路**（Shift/Option 绕过 tmux 鼠标捕获）。问题出在 tmux 的 `set -g mouse on` 与 xterm 终端组件的本地选区机制之间的冲突。

```
┌─────────────────────────────────────────┐
│  用户拖拽鼠标                            │
│       ↓                                 │
│  ┌─────────────┐   ┌─────────────────┐  │
│  │ 本地选区     │ vs │ tmux 鼠标追踪   │  │
│  │ (Flutter)   │   │ (escape seq)    │  │
│  └─────────────┘   └─────────────────┘  │
│       ↓                    ↓            │
│  selectCharacters()  mouseEvent() →     │
│  绘制选区高亮         发送到远端 tmux     │
└─────────────────────────────────────────┘
```

tmux 开启 `mouse on` 后，通过 escape 序列（`\e[?1002h` / `\e[?1003h`）启用终端鼠标追踪模式。此时 xterm 组件会将**所有**鼠标事件转发给远端 tmux，而不是在本地做文字选区。

## 已有的修复措施及其局限

### 修复 1：跳过 InfiniteScrollView（已完成）

**文件**：`third_party/xterm/lib/src/ui/scroll_handler.dart`

tmux 使用 alternate screen buffer，xterm 原本会用 `InfiniteScrollView`（`Scrollable`）包裹终端内容。`Scrollable` 内部的 `DragGestureRecognizer` 会与选区的 `PanGestureRecognizer` 竞争拖拽手势。屏幕内容多时 Scrollable 胜出，拖拽被当作滚动而非选区。

**修复**：`simulateScroll: false` 时直接返回 child，不创建 InfiniteScrollView。

### 修复 2：本地选区优先（已完成）

**文件**：`third_party/xterm/lib/src/ui/gesture/gesture_handler.dart`

设置 `preferLocalSelectionWhenMouseTracking: true`，使拖拽事件走本地 `selectCharacters()` 路径，而不是转发给 tmux。

### 修复 3：暂停输出防止选区被覆盖（已完成）

**文件**：`lib/screens/tmux_workspace_screen.dart`

拖选期间暂停终端输出（`pauseOutput`），防止 tmux 刷新屏幕导致选区消失。松手后延迟 3 秒恢复输出，给用户时间 Cmd+C 复制。

### 修复 4：防止 setState 破坏手势状态（已完成）

**文件**：`lib/screens/tmux_workspace_screen.dart`

`_detectClaudeState()` 在每次 SSH 数据到达时调用 `setState()`，导致 Widget 重建，手势识别器状态被销毁。已修复为在 `outputPaused` 时跳过检测。

### 修复 5：HitTestBehavior.opaque（已完成）

**文件**：`third_party/xterm/lib/src/ui/gesture/gesture_detector.dart`

`RawGestureDetector` 默认使用 `HitTestBehavior.deferToChild`，有时无法接收到事件。改为 `HitTestBehavior.opaque` 确保手势事件始终被接收。

## 当前状态：手势到达但选区不可见

经过上述修复，debug 日志（`~/gesture_debug.log`）确认手势事件**已正确触发**：

```
02:36:17.387822 [DOWN] idx=1 kind=mouse btn=1 altBuf=true type=claude
02:36:17.442424 [DRAG] onDragStart enableDrag=true shouldForward=false preferLocal=true
02:36:17.840102 [UP] idx=1 dragActive=true
```

但选区仍然不可见。问题转移到了选区渲染层。

## 根因定位：CellAnchor 脱钩

选区创建的调用链：

```
onDragStart / onDragUpdate
  → renderTerminal.selectCharacters(from, to)
    → getCellOffset(from/to)           // 像素 → 单元格坐标
    → buffer.createAnchorFromOffset()  // 创建 CellAnchor
    → controller.setSelection(base, extent)  // 锚点式选区
      → notifyListeners()              // 触发 RenderTerminal 重绘
```

渲染时检查选区：

```dart
// render.dart paint()
if (_controller.selection != null) {    // ← 这里可能为 null
    _paintSelection(canvas, selection, firstLine, lastLine);
}
```

`selection` getter 的关键逻辑：

```dart
BufferRange? get selection {
    if (_fixedSelection != null) return _fixedSelection;  // 优先返回固定选区

    if (base == null || extent == null) return null;
    if (!base.attached || !extent.attached) return null;  // ← 锚点脱钩 → 返回 null
    return _createRange(base.offset, extent.offset);
}
```

**CellAnchor 通过引用 BufferLine 来追踪位置。当 tmux 刷新屏幕（即使数据被缓冲），alternate buffer 中的 BufferLine 可能被重建，导致锚点的 `attached` 变为 false，`selection` 返回 null，选区不被绘制。**

### 为什么屏幕未满时能工作

屏幕未满时，tmux 不处于 alternate buffer 模式（`altBuf=false`），鼠标追踪未激活（`mouseMode=none`），选区走的是纯本地路径，没有 tmux 干扰。

### 为什么 Claude 标签退出再进入仍不能工作

Claude CLI 始终运行在 alternate buffer 中，鼠标追踪持续激活（`mouseMode=upDownScrollDrag`）。即使退到主界面再打开，tmux 仍然在发送鼠标追踪 escape 序列，问题条件持续存在。Shell 标签则在执行普通命令时退出 alternate buffer，所以重新打开后恢复正常。

## 解决方案

### 方案 A：使用固定坐标选区（推荐，最小改动）

将 `selectCharacters()` 和 `selectWord()` 从锚点式选区改为固定坐标选区：

```dart
// render.dart — 修改前
void selectCharacters(Offset from, [Offset? to]) {
    _controller.setSelection(
        buffer.createAnchorFromOffset(fromPos),  // CellAnchor 可能脱钩
        buffer.createAnchorFromOffset(toPos),
    );
}

// render.dart — 修改后
void selectCharacters(Offset from, [Offset? to]) {
    _controller.setSelectionOffsets(fromPos, toPos);  // 固定坐标，不依赖锚点
}
```

`setSelectionOffsets` 已存在于 `TerminalController` 中，它创建 `_fixedSelection`（纯坐标范围），不依赖 BufferLine 引用，不会因缓冲区变更而失效。

**优点**：改动仅 2 个方法（~10 行），不影响其他功能
**缺点**：如果缓冲区在选区存活期间滚动，固定坐标可能指向错误行（但因 `pauseOutput` 机制，拖选期间无输出，此问题不会发生）

### 方案 B：修饰键旁路（行业标准做法，可与 A 并行）

所有主流终端的解决方案：

| 终端 | 旁路键 | 效果 |
|------|--------|------|
| iTerm2 | Option | 按住 Option 拖选 → 本地选区 |
| xterm | Shift | 按住 Shift 拖选 → 本地选区 |
| Ghostty | Shift | 按住 Shift → 绕过鼠标追踪 |
| Alacritty | Shift | 同上 |
| xterm.js | macOS: Option / 其他: Shift | 同上 |

实现方式：在 `gesture_handler.dart` 中检测修饰键状态：

```dart
bool get _isForceLocalSelection {
    return HardwareKeyboard.instance.logicalKeysPressed
        .contains(LogicalKeyboardKey.shift);
}

void onDragStart(DragStartDetails details) {
    if (_isForceLocalSelection || !_isMouseTracking) {
        // 本地选区
        renderTerminal.selectCharacters(details.localPosition);
    } else {
        // 转发给 tmux
        renderTerminal.mouseEvent(...);
    }
}
```

这样可以将 `preferLocalSelectionWhenMouseTracking` 改回 `false`（默认转发给 tmux），仅在按住 Shift 时做本地选区，与 iTerm2 等行为一致。

### 方案 C：双模切换（UI 按钮）

在工具栏添加"鼠标模式"切换按钮：
- **tmux 模式**：鼠标事件转发给 tmux（切换 pane、tmux 原生滚动）
- **选区模式**：鼠标事件在本地处理（文字选区 + 复制）

适合触屏设备（无修饰键）。

## 涉及的关键文件

| 文件 | 角色 |
|------|------|
| `third_party/xterm/lib/src/ui/render.dart` | `selectCharacters()` / `selectWord()` — 选区创建 |
| `third_party/xterm/lib/src/ui/controller.dart` | `setSelection()` vs `setSelectionOffsets()` — 锚点 vs 固定坐标 |
| `third_party/xterm/lib/src/core/buffer/line.dart` | `CellAnchor` 类 — `attached` 属性决定选区是否有效 |
| `third_party/xterm/lib/src/ui/gesture/gesture_handler.dart` | 拖拽手势路由 — 本地选区 vs 转发给 tmux |
| `third_party/xterm/lib/src/ui/gesture/gesture_detector.dart` | `PanGestureRecognizer` + `TapGestureRecognizer` 手势竞争 |
| `third_party/xterm/lib/src/ui/scroll_handler.dart` | `InfiniteScrollView` 手势竞争（已修复） |
| `lib/screens/tmux_workspace_screen.dart` | `pauseOutput` / `_freezeTerminalSelection` / `_detectClaudeState` |

## 最终落地结果（已完成）

这次最终采用的是 **方案 A + 现有本地选区优先链路**，没有实现 Shift 旁路和 UI 双模切换。

### 实际怎么修的

1. **把选区创建改成固定坐标**

   `third_party/xterm/lib/src/ui/render.dart` 中的 `selectCharacters()` 和 `selectWord()` 已从：

   - `buffer.createAnchorFromOffset(...)`
   - `controller.setSelection(...)`

   改成直接调用：

   - `controller.setSelectionOffsets(...)`

   这样选区不再依赖 `CellAnchor` 持有的 `BufferLine` 引用，tmux/Claude 在 alternate buffer 中重绘时也不会因为 anchor detach 而丢失选区。

2. **继续让拖拽优先走本地选区**

   `third_party/xterm/lib/src/ui/gesture/gesture_handler.dart` 继续保留：

   - `preferLocalSelectionWhenMouseTracking: true` 时，左键拖拽优先走本地选区
   - 普通点击仍会在 `tapUp` 阶段转发给远端 tmux / 应用

   这样不会破坏 tmux 内部点击行为，同时解决“全屏输出时拖不出本地选区”的问题。

3. **拖选期间冻结输出，松手后固定当前选区**

   `lib/screens/tmux_workspace_screen.dart` 中保留并收口了这条链路：

   - `pointer down` 时 `pauseOutput()`
   - 识别为 drag 后，维持本地选区
   - `pointer up` 时调用 `_freezeTerminalSelection()`
   - 将当前 `selection.begin/end` 再次写回 `setSelectionOffsets(...)`
   - 缓存选中文本，延迟恢复输出，给 `Command+C` 复制留时间

   这样即使松手后 tmux 继续刷新，复制仍然能拿到刚刚看到的那段文本。

4. **清理调试代码**

   之前用于定位问题的 `gesture_debug.log` 写入和相关 debug hook 已删除，只保留正式修复逻辑，避免运行时持续写日志。

### 为什么这样能解决

根因不是“手势没到”，而是**手势到了以后，选区对象依赖的 anchor 在 buffer 重绘时失效**。  
改成固定坐标后，渲染层读取的是纯 `CellOffset` 范围，不再依赖 anchor 是否 attached，所以选区可以稳定显示。

### 这次没有做的方案

- **方案 B：Shift / Option 旁路**
  没实现。当前“本地选区优先”已经满足这个 app 的核心诉求：tmux / Claude 全屏输出时也能稳定拖选并复制。

- **方案 C：UI 鼠标模式切换**
  没实现。现阶段会增加交互复杂度，但对这次 bug 修复不是必需。

### 验证结果

- `flutter test`：全部通过
- `dart analyze lib test third_party/xterm/lib/src/ui`：通过修复相关检查，剩余 6 个 info 级提示，位于未改动的其他文件（非本次 bug 引入）

### 相关文件

- `third_party/xterm/lib/src/ui/render.dart`
- `third_party/xterm/lib/src/ui/gesture/gesture_handler.dart`
- `lib/screens/tmux_workspace_screen.dart`
- `test/terminal_controller_selection_test.dart`
- `test/terminal_local_selection_test.dart`
- `test/terminal_drag_forwarding_test.dart`
