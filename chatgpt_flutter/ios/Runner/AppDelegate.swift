import Flutter
import UIKit
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var agentBackgroundBridge: AgentBackgroundBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    WorkmanagerPlugin.registerBGProcessingTask(
      withIdentifier: "com.example.chatgpt_flutter.story-template-translation"
    )
    if let registrar = registrar(forPlugin: "AgentBackgroundBridge") {
      agentBackgroundBridge = AgentBackgroundBridge(messenger: registrar.messenger())
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
