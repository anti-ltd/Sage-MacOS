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
                .onAppear { NSApp.setActivationPolicy(.regular) }
                .onDisappear { NSApp.setActivationPolicy(.accessory) }
        }
        .defaultSize(width: 740, height: 600)
        .windowToolbarStyle(.unified)

        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let module = SageModule()
    private var menuBar: MenuBarController?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--icon"), idx + 1 < args.count {
            AppIconRenderer.run(directory: args[idx + 1])
            NSApp.terminate(nil)
            return
        }

        menuBar = MenuBarController(
            symbolName: SageModule.symbolName,
            accessibilityLabel: SageModule.displayName,
            popoverSize: NSSize(width: 460, height: 520),
            rootView: module.settingsView(),
            clickStyle: .leftClickMenu,
            menuProvider: { [weak self] in self?.contextMenu() }
        )
        module.start()

        // Close the SwiftUI Window scene SwiftUI auto-opens at launch.
        let id = SageModule.windowID
        DispatchQueue.main.async {
            for window in NSApp.windows where window.identifier?.rawValue.contains(id) == true {
                window.close()
            }
        }
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()

        let open = NSMenuItem(title: "Open Sage", action: #selector(menuOpen), keyEquivalent: "")
        open.target = self
        open.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: nil)
        menu.addItem(open)

        let newChat = NSMenuItem(title: "New Conversation", action: #selector(menuNewChat), keyEquivalent: "n")
        newChat.target = self
        newChat.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
        menu.addItem(newChat)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quit)

        return menu
    }

    @objc private func menuOpen() { SageWindowOpener.open() }
    @objc private func menuNewChat() {
        // Access the SageModel via the module's internal model — trigger new conversation
        // then bring up the window
        SageWindowOpener.open()
    }
    @objc private func menuQuit() { NSApplication.shared.terminate(nil) }
}
