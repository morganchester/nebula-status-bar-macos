import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited)
    }
}

@main
struct NebulaTrayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = NebulaModel()

    var body: some Scene {
        MenuBarExtra("Nebula", systemImage: "network") {
            MenuContentView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
