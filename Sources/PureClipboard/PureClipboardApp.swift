import AppKit
import PureClipboardCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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
    @State private var model = AppModel(store: ConfigFileStore(url: ConfigFileStore.defaultURL()))

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
