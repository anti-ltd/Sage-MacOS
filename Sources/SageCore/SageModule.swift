import SwiftUI
import iUX_MacOS

@MainActor
public final class SageModule: AppModule {

    public static let moduleID    = "ltd.anti.sage"
    public static let displayName = "Sage"
    public static let symbolName  = "bubble.left.and.bubble.right.fill"
    public static let windowID    = "sage-chat"

    private let model: SageModel

    public required init() {
        model = SageModel()
    }

    public func start() {
        model.start()
    }

    public var isMuted: Bool { false }

    public func settingsView() -> AnyView {
        AnyView(SageSettingsContent(model: model))
    }

    public func windowView() -> AnyView {
        AnyView(ChatWindowView(model: model))
    }
}
