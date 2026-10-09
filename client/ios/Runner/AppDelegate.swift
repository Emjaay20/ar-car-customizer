import UIKit
import Flutter
import UnityFramework

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    
    // Unity + flutter_unity_widget integration hook
    // After exporting from Unity, link UnityFramework here if needed.
    
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}