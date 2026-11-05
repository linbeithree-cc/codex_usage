import AppKit
import SwiftUI

@main
struct CodexUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var usageStore = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: usageStore)
        } label: {
            MenuBarLabel(store: usageStore)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(store: UsageStore) {
        let hostingView = NSHostingView(rootView: SettingsView(store: store))
        if let window {
            window.contentView = hostingView
        } else {
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 430),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            newWindow.title = "Codex Usage 设置"
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            newWindow.contentView = hostingView
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
