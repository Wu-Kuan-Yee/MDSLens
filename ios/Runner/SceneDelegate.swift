import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(
      scene,
      willConnectTo: session,
      options: connectionOptions
    )
    guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else {
      return
    }
    appDelegate.installPencilInteraction(
      on: window?.rootViewController?.view
    )
    connectionOptions.urlContexts.forEach {
      appDelegate.queueOpenURL($0.url)
    }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else {
      return
    }
    URLContexts.forEach { appDelegate.queueOpenURL($0.url) }
  }
}
