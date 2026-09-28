# SSH Tool App

一个使用 Flutter 编写的 SSH 客户端，面向 Android、Linux 和 macOS。它把远程终端、tmux 工作区和 Codex 对话放在同一个界面中。

## 功能

- 保存 SSH 连接，并通过终端和 tmux 会话操作远程主机。
- 浏览和继续远程 Codex 对话，也可以新建对话、切换文字聊天与终端模式；首页会预加载常用对话，列表可刷新。
- 展示 Codex 运行任务，以及最近 24 小时内完成的任务；系统通知和应用内完成记录都支持未读状态。
- 对话支持 Markdown、代码和表格显示；宽表格可以横向滚动。
- 对话发送会先重新查询远端运行状态：运行中使用 `turn/steer` 补充当前任务；空闲或已完成使用 `codex queue --thread --message` 排队。无需手动选择路线，不调用 `turn/start`，不发送中断指令。
- Steer 需要目标终端由共享 app-server 承载，通过 `$CODEX_HOME/app-server-control/app-server-control.sock` 访问当前会话（`CODEX_HOME` 默认 `~/.codex`）。旧独立终端运行中无法直接接入时会提示原因并保留草稿，不中断任务、不自动降级为 Queue；任务结束后再次发送会重新查询状态。
- 点击发送后立即显示消息正文及发送状态。退出再打开对话会恢复当前应用进程内的待处理消息；远程日志确认收到后合并为正式消息，避免重复显示。
- 在对话中只读显示远程 Codex Goal 状态；应用不提供设置或暂停 Goal 的功能。

## 依赖与项目结构

本项目使用 Flutter 3.38.6 和其捆绑的 Dart。Android 构建验证环境为 JDK 17、Android Gradle Plugin 8.9.1 和 Gradle 8.12。Android 的 `compileSdk` 与 NDK 版本沿用 Flutter 默认值；首次构建会由 Flutter/Gradle 下载所需组件。首次构建前需安装 Android SDK Command-line Tools 并接受 Android SDK 许可证。

连接目标主机需要可用的 SSH 服务。tmux 工作区需要远端安装 `tmux`；Codex 对话功能需要远端安装 Python 3，以及已完成认证的 Codex CLI，SSH 登录账号还需要有权读取对应的 Codex 会话数据。排队发送和 Goal 读取取决于远端 CLI 版本及其功能，并非所有 Codex 安装都支持。

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

`test/` 中的两个 Python 测试文件使用 pytest 风格函数，可用 pytest 运行：

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
