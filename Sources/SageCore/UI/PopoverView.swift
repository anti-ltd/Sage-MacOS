import SwiftUI
import iUX_MacOS

public struct PopoverView: View {
    @Bindable var model: SageModel
    @State private var tab: SageTab = .chat

    public init(model: SageModel) { self.model = model }

    public var body: some View {
        SettingsPopover(selection: $tab) {
            PopOutButton(windowID: SageModule.windowID)
        } content: { tab in
            content(for: tab)
        }
    }

    @ViewBuilder
    private func content(for tab: SageTab) -> some View {
        switch tab {
        case .chat:     ChatView(model: model, compact: true)
        case .settings: SageSettingsContent(model: model)
        case .about:    SageAboutContent()
        }
    }
}

// MARK: - Tab definition

enum SageTab: String, CaseIterable, Identifiable, SettingsTab {
    case chat, settings, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat:     return "Chat"
        case .settings: return "Settings"
        case .about:    return "About"
        }
    }

    var icon: String {
        switch self {
        case .chat:     return "bubble.left.and.bubble.right"
        case .settings: return "slider.horizontal.3"
        case .about:    return "info.circle"
        }
    }
}

// MARK: - Full window (sidebar layout)

public struct ChatWindowView: View {
    @Bindable var model: SageModel
    @State private var selection: SageTab? = .chat

    public init(model: SageModel) { self.model = model }

    public var body: some View {
        SettingsWindow(title: SageModule.displayName, selection: $selection) { tab in
            switch tab {
            case .chat:     ChatView(model: model)
            case .settings: SageSettingsContent(model: model)
            case .about:    SageAboutContent()
            }
        }
        .background(SageWindowOpenerBridge())
        .toolbar {
            if selection == .chat {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.newConversation()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .help("New Conversation")
                }
            }
        }
    }
}

@MainActor
public enum SageWindowOpener {
    public static var action: OpenWindowAction?

    public static func open() {
        guard let action else { NSSound.beep(); return }
        action(id: SageModule.windowID)
        NSApp.activate(ignoringOtherApps: true)
        let id = SageModule.windowID
        DispatchQueue.main.async {
            for window in NSApp.windows {
                guard let raw = window.identifier?.rawValue, raw.contains(id) else { continue }
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
    }
}

import AppKit

private struct SageWindowOpenerBridge: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear { SageWindowOpener.action = openWindow }
    }
}
