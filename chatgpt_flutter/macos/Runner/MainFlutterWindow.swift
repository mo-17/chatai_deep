import Cocoa
import FlutterMacOS
import Carbon
import ScreenCaptureKit

class MainFlutterWindow: NSWindow {
  private var desktopAssistant: DesktopAssistantBridge?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController.init()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.title = "艾普"
    self.contentMinSize = NSSize(width: 800, height: 600)
    self.setContentSize(NSSize(width: 1280, height: 800))
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)
    desktopAssistant = DesktopAssistantBridge(window: self, messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

private func desktopHotKey(_ next: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
  guard let data = data, let event = event else { return OSStatus(eventNotHandledErr) }
  var key = EventHotKeyID()
  let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
      MemoryLayout<EventHotKeyID>.size, nil, &key)
  if status == noErr {
    let bridge = Unmanaged<DesktopAssistantBridge>.fromOpaque(data).takeUnretainedValue()
    DispatchQueue.main.async { if key.id == 1 { bridge.toggleWindow() } else if key.id == 2 { bridge.capture() } }
  }
  return status
}

class DesktopAssistantBridge: NSObject {
  static weak var current: DesktopAssistantBridge?
  private let window: NSWindow
  private let channel: FlutterMethodChannel
  private var hotkeys: [EventHotKeyRef] = []
  private var handler: EventHandlerRef?
  private var statusItem: NSStatusItem?
  private var panel: NSPanel?
  private var capturing = false
  private(set) var enabled = false
  init(window: NSWindow, messenger: FlutterBinaryMessenger) {
    self.window = window
    channel = FlutterMethodChannel(name: "aipu/desktop-assistant", binaryMessenger: messenger)
    super.init()
    Self.current = self
    window.isReleasedWhenClosed = false
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      if call.method == "configure" {
        let value = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
        if self.configure(value) { result(value) }
        else { result(FlutterError(code: "hotkey_unavailable", message: "快捷键被占用，请关闭冲突软件后重试", details: nil)) }
      } else if call.method == "capture" { self.capture(); result(nil) }
      else { result(FlutterMethodNotImplemented) }
    }
  }
  private func configure(_ value: Bool) -> Bool {
    for key in hotkeys { UnregisterEventHotKey(key) }
    hotkeys.removeAll()
    if let handler = handler { RemoveEventHandler(handler); self.handler = nil }
    if let item = statusItem { NSStatusBar.system.removeStatusItem(item); statusItem = nil }
    enabled = false
    if !value { return true }
    var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    guard InstallEventHandler(GetApplicationEventTarget(), desktopHotKey, 1, &event,
        Unmanaged.passUnretained(self).toOpaque(), &handler) == noErr else { return false }
    for (code, identifier) in [(UInt32(kVK_Space), UInt32(1)), (UInt32(kVK_ANSI_O), UInt32(2))] {
      var reference: EventHotKeyRef?
      let id = EventHotKeyID(signature: OSType(0x41495055), id: identifier)
      if RegisterEventHotKey(code, UInt32(controlKey | shiftKey), id, GetApplicationEventTarget(), 0, &reference) != noErr {
        _ = configure(false); return false
      }
      if let reference = reference { hotkeys.append(reference) }
    }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "艾普快捷助手")
    let menu = NSMenu()
    for (title, action) in [("打开艾普", #selector(openWindow)), ("截图 OCR", #selector(screenshot)),
                            ("OCR 任务中心", #selector(openTasks)), ("退出艾普", #selector(quit))] {
      let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
      entry.target = self; menu.addItem(entry)
    }
    item.menu = menu; statusItem = item; enabled = true
    return true
  }
  @objc private func openWindow() { showWindow() }
  @objc private func screenshot() { capture() }
  @objc private func openTasks() { showWindow(); channel.invokeMethod("tasks", arguments: nil) }
  @objc private func quit() { NSApplication.shared.terminate(nil) }
  func showWindow() { window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true) }
  func toggleWindow() { if window.isVisible && NSApplication.shared.isActive { window.orderOut(nil) } else { showWindow() } }
  func capture() {
    if capturing { return }
    capturing = true
    channel.invokeMethod("beginCapture", arguments: nil) { [weak self] response in
      guard let self = self else { return }
      guard let token = response as? String else { self.capturing = false; self.showWindow(); return }
      self.selectRegion(token)
    }
  }
  private func selectRegion(_ token: String) {
    let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
    guard let screen = screen, let displayId = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
      finish(token, bytes: nil, failed: true); return
    }
    let visible = window.isVisible
    window.orderOut(nil)
    let selection = RegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
    let overlay = SelectionPanel(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
    overlay.isOpaque = false; overlay.backgroundColor = NSColor.black.withAlphaComponent(0.18)
    overlay.level = .screenSaver; overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    overlay.contentView = selection
    selection.completed = { [weak self] rect in
      overlay.orderOut(nil)
      self?.panel = nil
      guard let self = self else { return }
      guard let rect = rect, rect.width >= 4, rect.height >= 4 else {
        self.finish(token, bytes: nil, failed: false)
        if visible { self.showWindow() }
        return
      }
      Task { @MainActor in
        do {
          let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
          guard let display = content.displays.first(where: { $0.displayID == displayId.uint32Value }) else {
            self.finish(token, bytes: nil, failed: true); self.showWindow(); return
          }
          let filter = SCContentFilter(display: display, excludingWindows: [])
          let config = SCStreamConfiguration()
          config.sourceRect = CGRect(x: rect.minX, y: screen.frame.height - rect.maxY, width: rect.width, height: rect.height)
          let scale = min(screen.backingScaleFactor, 1200 / max(rect.width, rect.height))
          config.width = max(2, Int(rect.width * scale)); config.height = max(2, Int(rect.height * scale))
          config.showsCursor = false
          let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
          self.finish(token, bytes: data, failed: data == nil)
        } catch { self.finish(token, bytes: nil, failed: true) }
        self.showWindow()
      }
    }
    panel = overlay
    NSApplication.shared.activate(ignoringOtherApps: true)
    overlay.makeKeyAndOrderFront(nil); overlay.makeFirstResponder(selection)
  }
  private func finish(_ token: String, bytes: Data?, failed: Bool) {
    capturing = false
    if let bytes = bytes, !bytes.isEmpty, bytes.count <= 8 * 1024 * 1024 {
      channel.invokeMethod("captured", arguments: ["token": token, "bytes": FlutterStandardTypedData(bytes: bytes)])
    } else {
      channel.invokeMethod(failed ? "captureFailed" : "captureCancelled", arguments: ["token": token])
    }
  }
}
private class SelectionPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override func resignKey() {
    super.resignKey()
    (contentView as? RegionSelectionView)?.cancelOperation(nil)
  }
}
private class RegionSelectionView: NSView {
  var completed: ((NSRect?) -> Void)?
  private var start: NSPoint?
  private var selection = NSRect.zero
  override var acceptsFirstResponder: Bool { true }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 { cancelOperation(nil) } else { super.keyDown(with: event) }
  }
  override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil) }
  override func mouseDragged(with event: NSEvent) {
    guard let start = start else { return }
    let end = convert(event.locationInWindow, from: nil)
    selection = NSRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y)).intersection(bounds)
    needsDisplay = true
  }
  override func mouseUp(with event: NSEvent) { mouseDragged(with: event); let done = completed; completed = nil; done?(selection) }
  override func cancelOperation(_ sender: Any?) { let done = completed; completed = nil; done?(nil) }
  override func draw(_ dirtyRect: NSRect) { NSColor.white.setStroke(); let path = NSBezierPath(rect: selection); path.lineWidth = 2; path.stroke() }
}
