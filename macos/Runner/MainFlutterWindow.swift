import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private let keyboardLogger = KeyboardDebugLogger()
  private var keyboardChannel: FlutterMethodChannel?
  private var shouldCaptureTmuxShortcuts = false
  private var shortcutSequence = 0

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    // 保持窗口可手动缩放，同时限制最小尺寸，避免布局挤压。
    self.minSize = NSSize(width: 1100, height: 700)

    let registrar = flutterViewController.registrar(forPlugin: "MacosKeyboardBridge")
    let keyboardChannel = FlutterMethodChannel(
      name: "ssh_tool_app/macos_keyboard",
      binaryMessenger: registrar.messenger)
    self.keyboardChannel = keyboardChannel
    keyboardChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      switch call.method {
      case "setTmuxShortcutCaptureEnabled":
        let arguments = call.arguments as? [String: Any]
        self.shouldCaptureTmuxShortcuts = arguments?["enabled"] as? Bool ?? false
        self.keyboardLogger.log([
          "source": "native-control",
          "timestamp": Self.timestamp(),
          "message": "set capture state",
          "enabled": self.shouldCaptureTmuxShortcuts,
          "reason": arguments?["reason"] as? String ?? "",
        ])
        result(nil)
      case "clearNativeKeyboardLog":
        self.keyboardLogger.clear()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    RegisterGeneratedPlugins(registry: flutterViewController)
    keyboardLogger.log([
      "source": "native-window",
      "timestamp": Self.timestamp(),
      "message": "window initialized",
    ])

    super.awakeFromNib()
  }

  override func keyDown(with event: NSEvent) {
    if let action = shortcutAction(for: event) {
      let payload = shortcutPayload(for: event, action: action, phase: "keyDown")
      keyboardLogger.log(payload.merging([
        "source": "native-key",
        "captureEnabled": shouldCaptureTmuxShortcuts,
      ]) { _, new in new })
      if shouldCaptureTmuxShortcuts {
        keyboardChannel?.invokeMethod("nativeShortcut", arguments: payload)
        return
      }
    } else if shouldLogEvent(event) {
      keyboardLogger.log([
        "source": "native-key",
        "timestamp": Self.timestamp(),
        "phase": "keyDown",
        "captureEnabled": shouldCaptureTmuxShortcuts,
        "keyCode": event.keyCode,
        "characters": event.characters ?? "",
        "charactersIgnoringModifiers": event.charactersIgnoringModifiers ?? "",
        "alt": event.modifierFlags.contains(.option),
        "meta": event.modifierFlags.contains(.command),
        "control": event.modifierFlags.contains(.control),
        "shift": event.modifierFlags.contains(.shift),
      ])
    }
    super.keyDown(with: event)
  }

  override func flagsChanged(with event: NSEvent) {
    if shouldLogFlags(event) {
      keyboardLogger.log([
        "source": "native-flags",
        "timestamp": Self.timestamp(),
        "phase": "flagsChanged",
        "captureEnabled": shouldCaptureTmuxShortcuts,
        "keyCode": event.keyCode,
        "alt": event.modifierFlags.contains(.option),
        "meta": event.modifierFlags.contains(.command),
        "control": event.modifierFlags.contains(.control),
        "shift": event.modifierFlags.contains(.shift),
      ])
    }
    super.flagsChanged(with: event)
  }

  private func shortcutAction(for event: NSEvent) -> String? {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let hasOption = flags.contains(.option)
    let hasCommand = flags.contains(.command)
    let hasControl = flags.contains(.control)
    let hasShift = flags.contains(.shift)

    if !hasOption || hasShift {
      return nil
    }

    switch event.keyCode {
    case 123:
      return hasControl ? "pane-left" : "tab-left"
    case 124:
      return hasControl ? "pane-right" : "tab-right"
    case 125:
      return hasCommand && !hasControl ? nil : "pane-down"
    case 126:
      return hasCommand && !hasControl ? nil : "pane-up"
    default:
      return nil
    }
  }

  private func shortcutPayload(for event: NSEvent, action: String, phase: String) -> [String: Any] {
    shortcutSequence += 1
    return [
      "sequence": shortcutSequence,
      "timestamp": Self.timestamp(),
      "phase": phase,
      "action": action,
      "keyCode": event.keyCode,
      "characters": event.characters ?? "",
      "charactersIgnoringModifiers": event.charactersIgnoringModifiers ?? "",
      "alt": event.modifierFlags.contains(.option),
      "meta": event.modifierFlags.contains(.command),
      "control": event.modifierFlags.contains(.control),
      "shift": event.modifierFlags.contains(.shift),
    ]
  }

  private func shouldLogEvent(_ event: NSEvent) -> Bool {
    switch event.keyCode {
    case 123, 124, 125, 126:
      return true
    default:
      return event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command)
    }
  }

  private func shouldLogFlags(_ event: NSEvent) -> Bool {
    event.keyCode == 58 || event.keyCode == 61 || event.keyCode == 55 || event.keyCode == 54
  }

  private static func timestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
  }
}

private final class KeyboardDebugLogger {
  private let queue = DispatchQueue(label: "ssh_tool_app.keyboard.log")
  private lazy var logFileURL: URL = {
    let fileManager = FileManager.default
    let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let bundleDirectory = Bundle.main.bundleIdentifier ?? "com.example.sshToolApp"
    let logDir = baseURL
      .appendingPathComponent(bundleDirectory, isDirectory: true)
      .appendingPathComponent("ssh_tool_app", isDirectory: true)
      .appendingPathComponent("logs", isDirectory: true)
    try? fileManager.createDirectory(
      at: logDir,
      withIntermediateDirectories: true,
      attributes: nil)
    return logDir.appendingPathComponent("keyboard_native.log")
  }()

  func log(_ payload: [String: Any]) {
    queue.async {
      guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
        var line = String(data: data, encoding: .utf8)
      else {
        return
      }
      line.append("\n")
      if let fileHandle = try? FileHandle(forWritingTo: self.logFileURL) {
        fileHandle.seekToEndOfFile()
        if let lineData = line.data(using: .utf8) {
          fileHandle.write(lineData)
        }
        fileHandle.closeFile()
      } else {
        try? line.write(to: self.logFileURL, atomically: true, encoding: .utf8)
      }
    }
  }

  func clear() {
    queue.async {
      try? "".write(to: self.logFileURL, atomically: true, encoding: .utf8)
    }
  }
}
