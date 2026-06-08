import AppKit
import SwiftUI
import iUX_MacOS
import SageCore

@main
struct SageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window(SageModule.displayName, id: SageModule.windowID) {
            appDelegate.module.windowView()
        }
        .defaultSize(width: 740, height: 600)
        .windowToolbarStyle(.unified)

        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let module = SageModule()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            others.forEach { $0.activate(options: .activateIgnoringOtherApps) }
            NSApp.terminate(nil)
            return
        }

        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--icon"), idx + 1 < args.count {
            AppIconRenderer.run(directory: args[idx + 1])
            NSApp.terminate(nil)
            return
        }

        module.start()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
