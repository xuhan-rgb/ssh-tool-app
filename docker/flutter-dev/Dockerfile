# Flutter Android 开发环境 Docker 镜像
# 基于 Ubuntu 22.04 + Flutter + Android SDK

FROM ubuntu:22.04

# 避免交互式提示
ENV DEBIAN_FRONTEND=noninteractive

# ============ 版本配置 ============
ENV FLUTTER_VERSION=3.38.6
ENV ANDROID_SDK_VERSION=11076708

# ============ 路径配置 ============
ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=${ANDROID_HOME}
ENV FLUTTER_HOME=/opt/flutter
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64

# ============ 环境变量 ============
ENV PATH=${PATH}:${FLUTTER_HOME}/bin:${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/emulator:${JAVA_HOME}/bin
ENV TZ=Asia/Shanghai
ENV LANG=zh_CN.UTF-8
ENV PUB_HOSTED_URL=https://pub.flutter-io.cn
ENV FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn

# ============ 配置国内镜像源 ============
RUN sed -i 's@//.*archive.ubuntu.com@//mirrors.aliyun.com@g' /etc/apt/sources.list && \
    sed -i 's@//.*security.ubuntu.com@//mirrors.aliyun.com@g' /etc/apt/sources.list

# ============ 安装系统依赖 ============
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    unzip \
    git \
    vim \
    xz-utils \
    zip \
    openjdk-17-jdk \
    build-essential \
    lib32stdc++6 \
    lib32z1 \
    libc6-i386 \
    libglu1-mesa \
    locales \
    clang \
    cmake \
    ninja-build \
    pkg-config \
    libgtk-3-dev \
    # Chrome 依赖（用于 Flutter Web 调试）
    libnss3 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcups2 \
    libdrm2 \
    libxkbcommon0 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxrandr2 \
    libgbm1 \
    libasound2 \
    # 模拟器依赖
    libpulse0 \
    libgl1 \
    libegl1 \
    libx11-6 \
    libxcb1 \
    qemu-kvm \
    && locale-gen zh_CN.UTF-8 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ============ 安装 Android SDK ============
RUN mkdir -p ${ANDROID_HOME}/cmdline-tools && \
    cd /tmp && \
    wget -q https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_SDK_VERSION}_latest.zip && \
    unzip -q commandlinetools-linux-${ANDROID_SDK_VERSION}_latest.zip && \
    mv cmdline-tools ${ANDROID_HOME}/cmdline-tools/latest && \
    rm commandlinetools-linux-${ANDROID_SDK_VERSION}_latest.zip

# 接受许可证并安装 SDK 组件（含模拟器）
RUN yes | sdkmanager --licenses && \
    sdkmanager --update && \
    sdkmanager \
    "platform-tools" \
    "build-tools;34.0.0" \
    "build-tools;33.0.2" \
    "platforms;android-34" \
    "platforms;android-33" \
    "cmake;3.22.1" \
    "emulator" \
    "system-images;android-33;google_apis;x86_64"

# 创建默认 AVD（Android Virtual Device）
RUN echo "no" | avdmanager create avd \
    --name "pixel_6" \
    --package "system-images;android-33;google_apis;x86_64" \
    --device "pixel_6" \
    --force

# ============ 安装 Flutter SDK ============
RUN cd /opt && \
    wget -q https://storage.flutter-io.cn/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz && \
    tar xf flutter_linux_${FLUTTER_VERSION}-stable.tar.xz && \
    rm flutter_linux_${FLUTTER_VERSION}-stable.tar.xz && \
    # 设置 Flutter 为安全目录
    git config --system --add safe.directory /opt/flutter

# ============ 配置 Flutter ============
RUN flutter config --no-analytics && \
    flutter config --android-sdk ${ANDROID_HOME} && \
    flutter precache --android && \
    # 接受 Android 许可证
    yes | flutter doctor --android-licenses || true

# ============ 配置 Gradle 镜像加速 ============
RUN mkdir -p /root/.gradle && \
    echo 'org.gradle.jvmargs=-Xmx2048m -XX:MaxMetaspaceSize=512m\n\
org.gradle.parallel=true\n\
org.gradle.daemon=true\n\
android.useAndroidX=true' > /root/.gradle/gradle.properties

# ============ 创建工作目录 ============
WORKDIR /workspace

# ============ 验证安装 ============
RUN echo "===== 环境验证 =====" && \
    java -version && \
    echo "" && \
    flutter --version && \
    echo "" && \
    adb version && \
    echo "===== 安装完成 ====="

CMD ["/bin/bash"]
