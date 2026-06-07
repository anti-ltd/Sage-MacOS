import SwiftUI
import iUX_MacOS

// MARK: - Chat scroll + input

public struct ChatView: View {
    @Bindable var model: SageModel
    var compact: Bool = false

    public init(model: SageModel, compact: Bool = false) {
        self.model = model
        self.compact = compact
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !model.isAvailable {
                unavailableView
            } else {
                messagesView
                Divider()
                inputBar
            }
        }
    }

    // MARK: - Unavailable

    private var unavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(model.unavailabilityReason ?? "On-device AI unavailable.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Messages

    private var messagesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if model.messages.isEmpty {
                        emptyState
                    }
                    ForEach(model.messages) { msg in
                        MessageBubble(message: msg)
                            .id(msg.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: model.messages.count) {
                if let last = model.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: model.messages.last?.content) {
                if let last = model.messages.last, last.isStreaming {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("Ask Sage anything")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $model.inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(compact ? 3 : 6)
                .font(.body)
                .onSubmit { sendIfReady() }
                .submitLabel(.send)
                .onKeyPress(.return) {
                    // Shift+Return inserts newline; plain Return sends
                    sendIfReady()
                    return .handled
                }
                .padding(.vertical, 6)

            Button(action: sendIfReady) {
                Image(systemName: model.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(model.inputText.isEmpty && !model.isStreaming ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.isStreaming)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func sendIfReady() {
        Task { await model.send() }
    }
}

// MARK: - Message bubble

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 2) {
                Text(message.content.isEmpty && message.isStreaming ? "…" : message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(message.role == .user
                                  ? Color.accentColor
                                  : Color(nsColor: .controlBackgroundColor))
                    )
                    .foregroundStyle(message.role == .user ? .white : .primary)

                if message.isStreaming {
                    Text("Thinking…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
}

// MARK: - Settings tab in window

struct SageSettingsContent: View {
    @Bindable var model: SageModel
    @State private var draft: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                iUX_MacOS.CardSection("System Prompt") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $draft)
                            .font(.callout)
                            .frame(minHeight: 80)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(nsColor: .textBackgroundColor))
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                            )
                        Button("Apply") {
                            model.systemPrompt = draft
                            model.applySystemPrompt()
                        }
                        .controlSize(.small)
                    }
                }

                iUX_MacOS.CardSection("Conversation") {
                    Button("New Conversation", role: .destructive) {
                        model.newConversation()
                    }
                }
            }
            .padding()
        }
        .onAppear { draft = model.systemPrompt }
    }
}

// MARK: - About tab

struct SageAboutContent: View {
    @State private var status: String?
    @State private var checking = false

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var body: some View {
        ScrollView {
            iUX_MacOS.CardSection("About") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sage").font(.headline)
                    Text("Version \(version)").foregroundStyle(.secondary)
                    Text("On-device AI chatbot. No data leaves your Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
#if !SAGE_MAS
                    Button(checking ? "Checking…" : "Check for updates") {
                        Task { await checkForUpdates() }
                    }
                    .disabled(checking)
                    if let status {
                        Text(status).font(.callout).foregroundStyle(.secondary)
                    }
#endif
                }
            }
            .padding()
        }
    }

#if !SAGE_MAS
    private func checkForUpdates() async {
        checking = true
        defer { checking = false }
        do {
            let info = try await UpdateChecker.fetch(appID: "sage")
            status = UpdateChecker.isNewer(info.version, than: version)
                ? "Update available: \(info.version)"
                : "You're up to date."
        } catch {
            status = "Couldn't check: \(error.localizedDescription)"
        }
    }
#endif
}

