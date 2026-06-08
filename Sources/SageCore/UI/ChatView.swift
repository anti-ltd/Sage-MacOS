import SwiftUI
import iUX_MacOS
import AppKit

// MARK: - Main chat view

public struct ChatView: View {
    @Bindable var model: SageModel
    var compact: Bool = false

    public init(model: SageModel, compact: Bool = false) {
        self.model = model
        self.compact = compact
    }

    @State private var showModelPicker = false
    @State private var showSettings = false

    public var body: some View {
        VStack(spacing: 0) {
            if !model.isAvailable {
                unavailableView
            } else {
                messagesView
                    .layoutPriority(1)
                Divider()
                inputBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            if let cwd = model.workingDirectory {
                ToolbarItem(placement: .navigation) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                        Text(cwd.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .help(cwd.path)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 4) {
                    Button {
                        showSettings.toggle()
                    } label: {
                        Image(systemName: "gear")
                    }
                    .help("Settings")
                    .popover(isPresented: $showSettings, arrowEdge: .top) {
                        SageSettingsContent(model: model)
                            .frame(width: 360, height: 480)
                    }

                    Button { model.newConversation() } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .help("New Conversation")
                    .opacity(model.messages.isEmpty ? 0.35 : 1)
                }
            }
        }
    }

    private var llamaStatusPill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor(model.llama.serverStatus))
                .frame(width: 6, height: 6)
            Text(llamaStatusLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var llamaStatusLabel: String {
        switch model.llama.serverStatus {
        case .idle:          return model.llama.modelName ?? "No model"
        case .starting:      return "Loading…"
        case .ready:         return model.llama.modelName ?? "Ready"
        case .error:         return "Error"
        }
    }

    private func statusColor(_ status: LlamaCppBackend.ServerStatus) -> Color {
        switch status {
        case .idle:     return .secondary
        case .starting: return .yellow
        case .ready:    return .green
        case .error:    return .red
        }
    }

    // MARK: - Unavailable

    private var unavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(model.unavailabilityReason ?? "AI unavailable.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.callout)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Messages (only this scrolls)

    private var messagesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if model.messages.isEmpty { emptyState }
                    ForEach(model.messages) { msg in
                        MessageBubble(message: msg, backend: model.selectedBackend)
                            .id(msg.id)
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: model.messages.count) {
                if let last = model.messages.last {
                    withAnimation(.easeOut(duration: 0.15)) {
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

    // MARK: - Input bar (fixed at bottom)

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            modelPickerButton

            TextField("Message", text: $model.inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(compact ? 4 : 8)
                .font(.body)
                .onSubmit { sendIfReady() }
                .submitLabel(.send)
                .onKeyPress(.return) {
                    sendIfReady()
                    return .handled
                }
                .padding(.vertical, 6)

            Button(action: sendIfReady) {
                Image(systemName: model.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(
                        model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && !model.isStreaming
                            ? Color.secondary
                            : Color.accentColor
                    )
            }
            .buttonStyle(.plain)
            .disabled(
                model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !model.isStreaming
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var modelPickerButton: some View {
        Button {
            showModelPicker.toggle()
        } label: {
            Image(systemName: model.selectedBackend.icon)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help("Choose model")
        .popover(isPresented: $showModelPicker, arrowEdge: .bottom) {
            modelPickerPopover
        }
    }

    private var modelPickerPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(BackendType.allCases, id: \.self) { (backend: BackendType) in
                Button {
                    model.selectedBackend = backend
                    showModelPicker = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: backend.icon)
                            .frame(width: 18)
                        Text(backend.shortLabel)
                            .font(.body)
                        Spacer()
                        if model.selectedBackend == backend {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if backend == .apple && BackendType.allCases.last != backend {
                    Divider()
                }
            }

            if model.selectedBackend == .llamaCpp {
                Divider()
                llamaStatusPill
                    .font(.caption)
            }
        }
        .padding(14)
        .frame(minWidth: 180)
    }

    private func sendIfReady() {
        Task { await model.send() }
    }
}

// MARK: - Message bubble

struct MessageBubble: View {
    let message: ChatMessage
    let backend: BackendType

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 2) {
                Text(message.content.isEmpty && message.isStreaming ? " " : message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(message.role == .user
                                  ? Color.accentColor
                                  : Color(nsColor: .controlBackgroundColor))
                    )
                    .foregroundStyle(message.role == .user ? Color.white : Color.primary)

                if message.isStreaming {
                    HStack(spacing: 4) {
                        Image(systemName: backend.icon)
                            .imageScale(.small)
                        Text("Thinking…")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }

            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
}

// MARK: - Full window

public struct ChatWindowView: View {
    @Bindable var model: SageModel

    public init(model: SageModel) { self.model = model }

    public var body: some View {
        ChatView(model: model)
    }
}

// MARK: - Settings tab

public struct SageSettingsContent: View {
    @Bindable var model: SageModel
    @State private var draft: String = ""

    public init(model: SageModel) { self.model = model }

    public var body: some View {
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

                iUX_MacOS.CardSection("Project") {
                    WorkingDirectoryPicker(url: $model.workingDirectory)
                }

                iUX_MacOS.CardSection("llama.cpp") {
                    LlamaCppSettingsContent(backend: model.llama)
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

// MARK: - llama.cpp settings panel

struct LlamaCppSettingsContent: View {
    @Bindable var backend: LlamaCppBackend

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Model file row
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(backend.modelName ?? "No model selected")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("GGUF format · downloaded from HuggingFace or llm.gguf.ai")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Choose…") {
                    Task { try? await backend.loadModelFromPanel() }
                }
                .controlSize(.small)
            }

            // Status row
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if case .ready = backend.serverStatus {
                    Button("Restart") {
                        Task { try? await backend.startServer() }
                    }
                    .controlSize(.small)
                } else if case .idle = backend.serverStatus, backend.modelURL != nil {
                    Button("Load") {
                        Task { try? await backend.startServer() }
                    }
                    .controlSize(.small)
                }
            }

            if case .error(let msg) = backend.serverStatus {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Requires `brew install llama.cpp` — runs fully offline on your Mac.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dotColor: Color {
        switch backend.serverStatus {
        case .idle:     return .secondary
        case .starting: return .yellow
        case .ready:    return .green
        case .error:    return .red
        }
    }

    private var statusText: String {
        switch backend.serverStatus {
        case .idle:      return "Not loaded"
        case .starting:  return backend.loadingProgress.isEmpty ? "Starting…" : backend.loadingProgress
        case .ready:     return "Ready"
        case .error:     return "Error — see below"
        }
    }
}

// MARK: - Working directory picker

struct WorkingDirectoryPicker: View {
    @Binding var url: URL?
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)

                if let url {
                    Text(url.lastPathComponent)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(url.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No project set")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Button("Choose…") { chooseDirectory() }
                    .controlSize(.small)

                if url != nil {
                    Button("Clear", role: .destructive) { url = nil }
                        .controlSize(.small)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isTargeted
                          ? Color.accentColor.opacity(0.12)
                          : Color(nsColor: .controlBackgroundColor))
                    .stroke(isTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: isTargeted ? 1.5 : 0.5)
            )
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { dropped, _ in
                    guard let dropped, dropped.hasDirectoryPath else { return }
                    DispatchQueue.main.async { url = dropped }
                }
                return true
            }

            Text("Drag a folder here or choose one. The path is added to every conversation so the model knows your project context.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose project directory"
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        url = picked
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
