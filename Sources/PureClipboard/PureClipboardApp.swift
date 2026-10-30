import AppKit
import PureClipboardCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let directory = ScreenshotMode.outputDirectory() {
            NSApp.setActivationPolicy(.accessory)
            ScreenshotMode.run(into: directory)
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct PureClipboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = ScreenshotMode.outputDirectory() == nil
        ? AppModel(store: ConfigFileStore(url: ConfigFileStore.defaultURL()))
        : AppModel(store: ConfigFileStore(url: ScreenshotMode.unusedConfigURL), monitoring: false)

    var body: some Scene {
        Window("Pure Clipboard", id: "main") {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 680, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 760, height: 860)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Znovu načíst konfiguraci") { model.reload() }
                    .keyboardShortcut("r")
            }
        }
    }
}
