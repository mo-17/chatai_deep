import Flutter
import UIKit
import workmanager_apple
import PDFKit
import AVFAudio

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var agentBackgroundBridge: AgentBackgroundBridge?
  private var knowledgePdfChannel: FlutterMethodChannel?
  private var voiceAudioChannel: FlutterMethodChannel?
  private var previousAudio: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = registrar(forPlugin: "VoiceAudioBridge") {
      let channel = FlutterMethodChannel(name: "aipu/voice-audio", binaryMessenger: registrar.messenger())
      voiceAudioChannel = channel
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self = self else { result(false); return }
        let session = AVAudioSession.sharedInstance()
        func connected() -> Bool {
          session.currentRoute.outputs.contains { [.headphones, .bluetoothHFP, .bluetoothLE].contains($0.portType) }
        }
        do {
          switch call.method {
          case "prepareHeadset":
            guard connected() else { result(["safeDuplex": false]); return }
            if self.previousAudio == nil { self.previousAudio = (session.category, session.mode, session.categoryOptions) }
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
            try session.setActive(true)
            result(["safeDuplex": connected()])
          case "headsetConnected": result(connected())
          case "release":
            if let previous = self.previousAudio {
              self.previousAudio = nil
              try session.setActive(false, options: .notifyOthersOnDeactivation)
              try session.setCategory(previous.0, mode: previous.1, options: previous.2)
            }
            result(nil)
          default: result(FlutterMethodNotImplemented)
          }
        } catch { result(FlutterError(code: "voice_audio_unavailable", message: "音频路由暂不可用", details: nil)) }
      }
    }
    if let registrar = registrar(forPlugin: "KnowledgePdfBridge") {
      let channel = FlutterMethodChannel(name: "aipu/knowledge-pdf", binaryMessenger: registrar.messenger())
      knowledgePdfChannel = channel
      channel.setMethodCallHandler { call, result in
        guard call.method == "render", let args = call.arguments as? [String: Any],
          let path = args["path"] as? String, let page = args["page"] as? Int, page >= 0 else {
          result(FlutterMethodNotImplemented); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
          let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .resolvingSymlinksInPath().path + "/accounts/"
          guard url.path.hasPrefix(root), url.lastPathComponent.range(of: "^[a-f0-9]{64}\\.pdf$", options: .regularExpression) != nil,
            let pdf = PDFDocument(url: url), let original = pdf.page(at: page) else {
            DispatchQueue.main.async { result(FlutterError(code: "pdf_unavailable", message: "PDF原件不可用", details: nil)) }; return
          }
          let bounds = original.bounds(for: .mediaBox)
          guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else {
            DispatchQueue.main.async { result(FlutterError(code: "pdf_unavailable", message: "PDF页面尺寸无效", details: nil)) }; return
          }
          let scale = min(1200 / bounds.width, 2000 / bounds.height)
          let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
          let format = UIGraphicsImageRendererFormat(); format.scale = 1
          let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: size.width / bounds.width, y: -size.height / bounds.height)
            original.draw(with: .mediaBox, to: ctx.cgContext)
          }
          DispatchQueue.main.async {
            if let data = image.pngData() { result(FlutterStandardTypedData(bytes: data)) }
            else { result(FlutterError(code: "pdf_unavailable", message: "PDF页面未能渲染", details: nil)) }
          }
        }
      }
    }
    WorkmanagerPlugin.registerBGProcessingTask(
      withIdentifier: "com.example.chatgpt_flutter.story-template-translation"
    )
    if let registrar = registrar(forPlugin: "AgentBackgroundBridge") {
      agentBackgroundBridge = AgentBackgroundBridge(messenger: registrar.messenger())
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
