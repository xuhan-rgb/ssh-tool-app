# SSH Tool App

一个使用 Flutter 编写的 SSH 客户端，面向 Android、Linux 和 macOS。它把远程终端、tmux 工作区和 Codex 对话放在同一个界面中。

## 功能

- 保存 SSH 连接，并通过终端和 tmux 会话操作远程主机。
- 浏览和继续远程 Codex 对话，也可以新建文字对话；主页面固定使用文字聊天，保留对话中的“只看对话 / 终端视图 / 完整日志”选项；首页会预加载常用对话，列表自动刷新。
- 首页可切换 Codex / Claude，默认 Codex。Claude 与 Codex 共用对话列表和查看组件，支持目录/时间筛选、收藏、新建、继续、模型/思考强度设置及三档日志；受管理的对话复用同一个 tmux 中的 Claude 实例，手机与电脑可连接同一终端。
- Claude 消息和回执保存在远端 `~/.ssh_tool/claude_runtime/`，忙时排队，收到提交 hook 后才标记接收；不使用中断键。权限/信任确认需打开终端处理，未确认的提交不会自动重发。已有外部 Claude 实例不会被自动恢复为第二个副本。
- Codex 列表提供“远程打开 / 新回复 / 历史”和收藏入口；远程打开包含非收藏目录，收藏目录排在前面，新回复也包含非收藏目录的回复。系统通知和应用内完成记录都支持未读状态。
- 对话支持 Markdown、代码和表格显示；宽表格可以横向滚动。
- 查看远程对话支持“只看对话 / 终端视图 / 完整日志”，默认终端视图显示执行摘要、文件差异与日志中的进度标题，并保留模型和思考强度。所选档位会保存在本机；对话记录在当前应用进程内缓存，重新打开时继续刷新远程记录。
- 查看外部对话时，发送会先重新查询远端运行状态：运行中使用 `turn/steer` 补充当前任务；空闲或已完成使用 `codex queue --thread --message` 排队。无需手动选择路线，不发送中断指令。手机创建的文字会话由常驻 app-server 承接后续消息，使用 `turn/start` 启动新一轮。
- Steer 需要目标终端由共享 app-server 承载，通过 `$CODEX_HOME/app-server-control/app-server-control.sock` 访问当前会话（`CODEX_HOME` 默认 `~/.codex`）。旧独立终端运行中无法直接接入时会提示原因并保留草稿，不中断任务、不自动降级为 Queue；任务结束后再次发送会重新查询状态。
- 点击发送后立即显示消息正文及发送状态。退出再打开对话会恢复当前应用进程内的待处理消息；远程日志确认收到后合并为正式消息，避免重复显示。
- Codex 聊天页和远程记录页的“更多”菜单支持“清空上下文”和“更改模型”。清空后在同目录开始新对话，保留旧历史；模型和思考强度从下一轮手机发送的消息生效，正在执行的任务不受影响。远程记录页选择模型后需等当前任务结束再发送；设置保存在本机，选择本身不会修改全局 Codex 配置。
- 在对话中只读显示远程 Codex Goal 状态；应用不提供设置或暂停 Goal 的功能。

## Codex 对话列表与刷新

- 默认显示“远程打开”，不按最近 24 小时的完成时间筛选，也不显示“加载更早会话”和底部“继续对话”入口。历史时间筛选保留“今天”和“近 7 天”。
- 长按对话可收藏或取消收藏；对话操作菜单提供 Fork 等操作。关闭状态的对话和状态文字显示为灰色，可通过重新激活入口继续。关闭操作的可用性取决于会话类型和运行状态。
- 新建对话使用独立的目录选择页，默认定位当前工作目录，支持展开多个目录层级和手动输入路径。隐藏目录默认不显示；右上角“目录显示选项”可开启“显示隐藏目录”或“只显示收藏目录”。收藏目录支持添加、编辑和取消收藏，与对话筛选独立；选择工作目录不会自动收藏该目录。文字聊天先建立草稿，发送首条消息后才启动远程会话；手机创建的文字会话回答完成后仍保持打开，离开页面不会关闭它。
- 列表位于前台时，“远程打开”每 5 秒查询一次；有正在执行的对话时，列表状态也每 5 秒刷新，空闲时完整列表约每 60 秒刷新。正在查看的 Codex 对话执行中每秒刷新，打开但空闲时每 5 秒刷新。应用进入后台或列表被其他页面遮挡时暂停列表轮询。
- “其他端执行中”状态文字下方显示小进度条，用于提示活动，不代表任务完成百分比。
- 共享 app-server 中日志仍显示执行中的对话，会额外查询原生当前状态和最新一轮结果；原生确认完成或中断后，列表不再沿用旧的执行状态。原生接口不可用时保留日志判断。

### 终端退出后的状态延迟

当前通过原生 writer 锁和共享 app-server 的 `thread/loaded/list` 查询远程打开状态，保留用户现有的终端启动命令，也不增加终端连接标记。

在已有的共享服务终端测试中，按 Ctrl+C 断开终端后，共享 app-server 仍将对话保留在已加载列表约 60 秒。因此手机可能暂时继续显示“远程打开”，增加手机轮询频率不能消除这段后台保留时间。对话从远端已加载列表移除后，手机下一次成功刷新才会更新；历史记录不会因此删除。

约 60 秒是测试观察值，并非固定时限保证。2026-09-30 的隔离实机测试中，任务完成后手机约 5 秒更新为“等待消息”；终端退出后远端约 61 秒判为关闭，随后确认手机“远程打开”列表已移除该条目。收藏页也已验证执行、完成、关闭状态的切换，关闭后保留历史记录。此次未验证断开时任务仍在执行的情况。目前不保证终端打开、关闭状态即时同步。

## 依赖与项目结构

本项目使用 Flutter 3.38.6 和其捆绑的 Dart。Android 构建验证环境为 JDK 17、Android Gradle Plugin 8.9.1 和 Gradle 8.12。Android 的 `compileSdk` 与 NDK 版本沿用 Flutter 默认值；首次构建会由 Flutter/Gradle 下载所需组件。首次构建前需安装 Android SDK Command-line Tools 并接受 Android SDK 许可证。

连接目标主机需要可用的 SSH 服务。tmux 工作区需要远端安装 `tmux`；Codex 对话功能需要远端安装 Python 3，以及已完成认证的 Codex CLI，SSH 登录账号还需要有权读取对应的 Codex 会话数据。排队发送和 Goal 读取取决于远端 CLI 版本及其功能，并非所有 Codex 安装都支持。Claude 功能需要远端 Python 3、tmux 和已配置认证的 Claude CLI；运行控制依赖 `--settings` hooks 和 `claude agents --json`，已在 Claude Code 2.1.274 验证。Claude 当前在整轮回复结束后派发下一条排队消息，不提供 Codex 的 `turn/steer` 协议。

主要目录：

| 路径 | 内容 |
| --- | --- |
| `lib/` | Flutter 界面、数据模型与 SSH/Codex 服务 |
| `assets/` | 远端执行的 Python 辅助脚本 |
| `third_party/xterm/` | 项目使用的 xterm 修改版源码及其许可证；不要用 pub 上的原版替换 |
| `android/`、`linux/`、`macos/` | 平台工程 |
| `scripts/` | Android、Linux 和 macOS 构建或启动脚本 |
| `docker/flutter-dev/` | Android 容器构建环境 |
| `test/` | Flutter/Dart 测试及 Python 辅助脚本测试 |

## 获取源码

```bash
git clone https://github.com/xuhan-rgb/ssh-tool-app.git
cd ssh-tool-app
```

安装对应平台的 Flutter SDK 后，在项目根目录执行：

```bash
flutter --version
flutter pub get
```

`pubspec.yaml` 使用仓库内的 `third_party/xterm` 修改版。依赖解析应保持此本地路径，不要将它改回 pub 上游包。

## Linux 远端一键环境准备

连接 Codex 时，应用检测官方 Codex 路径、共享服务接口能力、登录状态、Python 3.9+ 和 tmux。未就绪时打开环境准备页面。可从每个 Codex 连接的“更多操作 → Codex 环境配置”进入准备页面；检测失败时也可点击“检查环境”。电脑端进入项目目录后直接运行 `codex`。

- 缺失 Python 或 tmux 时，点击“安装缺失依赖”，查看安装命令后在交互终端执行。管理员授权在终端完成，应用不记录 sudo 密码。支持 apt-get、dnf、yum、pacman、zypper、apk；软件不会自动安装或更新 Codex。
- 未登录时，点击“登录 Codex”，应用在远端执行 device-auth 登录，并在当前页面显示授权网址、验证码和进度，无需切换终端。授权完成后自动重新检测；网络失败可查看错误并重试。已有 codex-auth 时兼容其账户环境；普通官方安装不需要该脚本。更新入口使用 npm；无 npm 的独立二进制安装需要按其原安装方式更新。
- 代理由远端电脑现有的 shell 配置管理。环境检测、准备和登录通过交互式 Bash 执行，会读取该 SSH 用户已有的配置；应用不单独保存代理，也不修改 `.bashrc`。
- 依赖就绪后点击“一键准备”，应用将辅助脚本原子部署到 `~/.ssh_tool/`，优先启动或复用原生 Codex daemon；无 daemon 管理命令时，在专用 tmux 会话启动官方 Unix socket app-server，记录实际 socket 地址并验证协议连接。环境准备不修改 `.bashrc`，也不要求电脑端快捷命令。不会创建额外权限 profile 或复制本机认证文件。
- 默认文字聊天通过应用桥接器连接共享 daemon，保留后台 tmux、多轮、消息去重和断线跟随。准备后的聊天沿用远端权限设置，命令执行与文件修改审批可在手机确认；Codex 的方案选择问题（包括电脑端 Plan 模式发起的问题）会显示触屏选项，全部答完后点击“提交”。支持“其他”文字回答；电脑端先回答或取消后，手机同步收起问题。其他未支持的交互需通过终端继续处理。关闭自有空闲聊天取消其订阅，不停止共享服务。
- 电脑端进入项目目录后运行 `codex`；继续已有对话时运行 `codex resume <对话 ID>`，手机选择同一个对话。启用 `daemon_auto_start` 的 Codex 会自动启动或连接共享后台服务，手机“一键准备”会启动或复用服务并保存连接地址。手机也可以点击“新建对话”，选择工作目录后发送首条消息。环境页面不再提供额外启动命令的配置入口；旧版快捷命令兼容代码仍保留。

首次准备成功后，应用把未自定义的终端命令设为上述共享启动入口；显式填写的自定义命令保留。已有运行中的旧 worker 不强制重启。当前自动准备只支持 Linux，远端 Codex 必须具备共享 Unix socket 服务和 --remote 能力；使用能力检测，不仅按版本号判断。真实模型回复和具体发行版的依赖安装需在相应远端环境验证。

## Codex 终端启动命令

终端代码与配置保留用于兼容；当前主页面固定使用文字聊天，终端模式不能点击。对话记录中的三种日志显示方式保持可用。

在“新建连接”或“编辑连接”中填写“Codex 终端启动命令”，例如 `codex` 或带参数的可执行文件路径。配置按 SSH 连接保存在本机，新建 Codex 终端使用该命令；恢复和 Fork 对话时自动追加 `resume <对话 ID>` 或 `fork <对话 ID>`。自定义脚本需要转发这些参数，例如在脚本中使用 `"$@"`。

留空使用官方 `codex` 命令。远端交互 shell 需要能找到所填命令；包含空格的路径应使用 shell 引号。此项只影响 Codex 终端，不改变文字聊天的 app-server 启动方式，也不会修改远端 Codex 配置。

## Android 本机编译

安装 Flutter 3.38.6、JDK 17 和 Android SDK（可通过 Android Studio 的 SDK Manager 安装 Android SDK Command-line Tools）。设置好 `ANDROID_HOME` 或 `ANDROID_SDK_ROOT` 后检查工具链并接受 SDK 许可证：

```bash
flutter doctor --android-licenses
flutter pub get
flutter doctor -v
```

首次构建会自动下载 Flutter 配置的 Android SDK Platform 与 NDK。构建并安装 Debug APK：

```bash
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

也可以连接已启用 USB 调试的 Android 设备后直接运行：

```bash
adb devices
flutter run
```

`adb install -r` 会尝试保留设备上的应用数据；更新安装要求新 APK 与设备上应用使用相同签名。Release 构建命令和产物路径为：

```bash
flutter build apk --release
# build/app/outputs/flutter-apk/app-release.apk
```

当前 Android Release 配置仍使用 Debug 签名，适用于本地构建和测试，不是应用商店发布签名。

### Docker Android 构建

仓库内的 Dockerfile 提供基于 Ubuntu 22.04、JDK 17 和 Flutter 3.38.6 的 Android 构建环境。该镜像使用 Linux x86_64 Flutter SDK 与 `JAVA_HOME` amd64 路径，应在 Linux x86_64 Docker 环境中构建运行。需先安装 Docker。从项目根目录构建镜像（首次会下载基础镜像、Flutter、Android SDK 和其他工具，需联网）：

```bash
docker build -t flutter-dev:latest docker/flutter-dev
```

若主机没有 Flutter 或 JDK，可用容器里的 `keytool` 创建标准 Android Debug keystore；已有文件时不要覆盖，否则后续 APK 签名会改变：

```bash
mkdir -p ~/.android
if [ ! -f ~/.android/debug.keystore ]; then
  docker run --rm \
    -v "$HOME/.android":/root/.android \
    --entrypoint keytool flutter-dev:latest \
    -genkeypair -v \
    -keystore /root/.android/debug.keystore \
    -storepass android -alias androiddebugkey -keypass android \
    -dname "CN=Android Debug,O=Android,C=US" \
    -keyalg RSA -keysize 2048 -validity 10000
fi
```

生成 Debug APK：

```bash
bash scripts/build_android.sh
```

第一次运行脚本时不要传 `--no-pub`；脚本默认执行 `flutter build apk --debug`。脚本将项目目录挂载为工作区，并复用 Docker volume `ssh_tool_app_android_sdk`（Android SDK）和 `flutter-dev_flutter-pub-cache`（Pub 缓存），同时挂载主机的 `~/.android` 与 `~/.gradle`。APK 输出到 `build/app/outputs/flutter-apk/app-debug.apk`。如需禁用依赖解析，可在依赖已准备好后执行 `bash scripts/build_android.sh --no-pub`。

## Linux 桌面版

Ubuntu/Debian 可安装 Flutter Linux 桌面构建依赖：

```bash
sudo apt update
sudo apt install -y clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev
```

安装并配置 Flutter SDK 后，启用 Linux 目标并获取依赖：

```bash
flutter config --enable-linux-desktop
flutter pub get
flutter build linux
```

运行仓库脚本：

```bash
bash scripts/run_linux.sh
```

脚本会优先使用主机上的 Flutter；主机没有 Flutter 时，会尝试使用 `flutter-dev:latest` Docker 镜像，并要求在有图形桌面和 `DISPLAY` 的终端中运行。Docker 运行方式需先按上文构建镜像。Linux 构建和运行尚未在所有发行版上验证。

## macOS 桌面版

macOS 构建只能在 Mac 上完成。准备完整 Xcode 并运行首次组件安装，安装 Flutter 和 Homebrew，并确保 `pod --version` 可用（例如 `brew install cocoapods`）；若没有可用的系统 CocoaPods，构建脚本会尝试使用 Homebrew 自带的 portable Ruby 安装到用户目录：

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
flutter config --enable-macos-desktop
flutter pub get
```

启动桌面版：

```bash
flutter run -d macos
```

构建 Release `.app` 并打开（脚本会执行 `flutter pub get`）：

```bash
bash scripts/build_macos_app.sh --open
```

脚本默认清理后构建，支持 `--skip-clean`、`--open` 和 `--derived-data <dir>`。默认 `.app` 位于 `build/macos_xcode/Build/Products/Release/`。也可用 `bash scripts/open_macos_app.sh --print-path` 查看已构建应用路径。

Apple Silicon Mac 可用以下脚本制作 DMG，输出默认在 `dist/`：

```bash
bash scripts/build_dmg_macos.sh
```

脚本支持 `--version <版本>`、`--name <名称>`、`--output <目录>`、`--skip-clean`、`--skip-build` 和 `--open`。App Store `.pkg` 脚本 `scripts/build_app_store_pkg_macos.sh` 需要 Apple Developer 签名身份及相应配置；默认输出目录为 `dist/app_store/`。macOS 构建、DMG 和 App Store 打包流程均需在 Mac 上运行。

## 测试

当前验证范围：已从不含 `.dart_tool/`、`build/` 和 `android/local.properties` 的干净源码副本成功构建 Android Debug APK。验证使用已有 Docker 镜像及 SDK、依赖下载缓存，未重新构建镜像；本次没有构建 Linux 或 macOS 版本。

运行 Flutter/Dart 测试：

```bash
flutter test
```

`test/` 中的 Python 测试可用 pytest 运行：

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install pytest
python3 -m pytest test -q
```

Windows、iOS 和 Web 目录目前不能代表已支持或已验收的平台目标。尤其 Web 端依赖的 `dartssh2` 使用原生 socket，不能在浏览器中运行；本项目 Web 模板不支持 SSH 连接。

## 使用说明与数据安全

首次启动后添加 SSH 连接，再选择已有 Codex 对话或新建对话。macOS tmux 工作区支持使用 `Option` / `Command+Option` 加方向键切换会话或 pane，`Command+C` / `Command+V` 复制和粘贴。左键拖选终端文本后可用 `Command+C` 复制；tmux 分割菜单支持水平和垂直分屏。

SSH 连接配置（包括密码）保存在本机 Hive 数据库中。当前实现没有对这些 Hive 数据进行加密；请妥善保护设备账户和本地数据文件。macOS 数据目录位于应用容器的 `Library/Application Support/ssh_tool_app/hive` 下；旧版位于 `~/Documents/*.hive` 的数据会在启动时迁移。若提示数据被占用，请关闭其他正在运行的 `ssh_tool_app` 实例后再启动。
