import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    let folderPicker = FlutterMethodChannel(
      name: "toolshed/folder_picker",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    folderPicker.setMethodCallHandler { call, result in
      guard call.method == "pickFolder" else {
        result(FlutterMethodNotImplemented)
        return
      }

      let arguments = call.arguments as? [String: Any]
      let panel = NSOpenPanel()
      panel.title = arguments?["title"] as? String ?? "Choose a folder"
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.allowsMultipleSelection = false

      if let initialDirectory = arguments?["initialDirectory"] as? String,
         !initialDirectory.isEmpty {
        panel.directoryURL = URL(fileURLWithPath: initialDirectory,
                                 isDirectory: true)
      }

      result(panel.runModal() == .OK ? panel.url?.path : nil)
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
