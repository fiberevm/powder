import AppKit
import SwiftUI

/// Which locally installed agent CLI answers ⌘K. Each uses the login already on this Mac.
enum AIProvider: String, CaseIterable {
    case claude, codex

    var title: String { self == .claude ? "CLAUDE" : "CODEX" }

    /// Looked up where the installers put them; a GUI app does not inherit the shell's PATH.
    var executable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.claude/local", "\(home)/bin", "/usr/bin"]
        return folders.map { URL(fileURLWithPath: $0).appendingPathComponent(rawValue) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

struct AIEntry: Identifiable, Equatable {
    enum Kind { case user, assistant, tool, error }

    let id = UUID()
    let kind: Kind
    var text: String
}

/// The ⌘K assistant: runs the chosen CLI once per prompt with Powder's tool server attached,
/// and shows what it says and does. Follow-ups continue the same CLI session.
@MainActor
final class AIAssistant: ObservableObject {
    @Published var prompt = ""
    @Published private(set) var entries: [AIEntry] = []
    @Published private(set) var isRunning = false
    @Published var provider: AIProvider {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "ai.provider") }
    }

    let server = PowderMCPServer()
    private var sessions: [AIProvider: String] = [:]
    private var process: Process?
    private var run: Task<Void, Never>?

    private static let brief = """
    You are the assistant built into Powder, a macOS trading terminal for Hyperliquid perpetuals. \
    Use the powder tools to arrange the window (panes, tabs, charts, theme) and to read live market and account data. \
    You cannot place, cancel or close orders, and must say so if asked. Act first, then reply in one or two short plain sentences. No markdown.
    """

    init() {
        provider = UserDefaults.standard.string(forKey: "ai.provider").flatMap(AIProvider.init) ?? .claude
    }

    func start(router: AppRouter) {
        server.tools = PowderTools(router: router)
        server.start()
    }

    func toggleProvider() {
        guard !isRunning else { return }
        provider = provider == .claude ? .codex : .claude
    }

    func clear() {
        cancel()
        entries = []
        sessions = [:]
    }

    func cancel() {
        guard isRunning else { return }
        run?.cancel()
        process?.terminate()
        entries.append(AIEntry(kind: .error, text: "Stopped."))
        isRunning = false
    }

    func submit() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        prompt = ""
        entries.append(AIEntry(kind: .user, text: text))

        let provider = provider
        guard let executable = provider.executable else {
            entries.append(AIEntry(kind: .error, text: "The \(provider.rawValue) command is not installed (looked in ~/.local/bin, /opt/homebrew/bin and /usr/local/bin)."))
            return
        }
        guard let url = server.url else {
            entries.append(AIEntry(kind: .error, text: "Powder's tool server has not started."))
            return
        }
        isRunning = true
        run = Task { [weak self] in
            await self?.execute(text, provider: provider, executable: executable, url: url)
        }
    }

    private func arguments(for provider: AIProvider, url: String) -> [String] {
        switch provider {
        case .claude:
            let config = #"{"mcpServers":{"powder":{"type":"http","url":"\#(url)"}}}"#
            var arguments = [
                "-p", "--output-format", "stream-json", "--verbose",
                "--mcp-config", config, "--strict-mcp-config",
                // Only Powder's tools: no shell, no file access.
                "--tools", "", "--allowedTools", "mcp__powder",
                "--append-system-prompt", Self.brief,
            ]
            if let session = sessions[.claude] { arguments += ["--resume", session] }
            return arguments
        case .codex:
            // The user's Codex config is skipped: its other servers and hooks only slow a one-line request down.
            let options = [
                "--json", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
                "-c", "mcp_servers.powder.url=\"\(url)\"",
                // Non-interactive runs refuse tools that need approval, so Powder's are approved up front.
                "-c", "mcp_servers.powder.default_tools_approval_mode=\"approve\"",
            ]
            if let session = sessions[.codex] { return ["exec", "resume", session] + options + ["-"] }
            return ["exec", "--sandbox", "read-only"] + options + ["-"]
        }
    }

    private func execute(_ text: String, provider: AIProvider, executable: URL, url: String) async {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(for: provider, url: url)
        // An empty folder of its own: the agent has no project to look at.
        if let folder = PowderMCPServer.supportFolder?.appendingPathComponent("agent", isDirectory: true) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            process.currentDirectoryURL = folder
        }
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment

        let input = Pipe(), output = Pipe()
        let errorFile = FileManager.default.temporaryDirectory.appendingPathComponent("powder-agent-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errorFile.path, contents: nil)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = try? FileHandle(forWritingTo: errorFile)
        defer { try? FileManager.default.removeItem(at: errorFile) }

        do {
            try process.run()
        } catch {
            finish(error: "Could not start \(provider.rawValue): \(error.localizedDescription)")
            return
        }
        self.process = process

        // Codex has no system-prompt flag, so a new conversation opens with the brief.
        let first = provider == .codex && sessions[.codex] == nil
        input.fileHandleForWriting.write(Data((first ? Self.brief + "\n\n" + text : text).utf8))
        try? input.fileHandleForWriting.close()

        var said = false
        do {
            for try await line in output.fileHandleForReading.bytes.lines {
                guard let data = line.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if Task.isCancelled { return }
                said = read(event, from: provider) || said
            }
        } catch {}
        process.waitUntilExit()
        guard !Task.isCancelled, isRunning else { return }

        if process.terminationStatus != 0, !entries.contains(where: { $0.kind == .error }) || !said {
            let detail = (try? String(contentsOf: errorFile, encoding: .utf8))?
                .split(separator: "\n").suffix(3).joined(separator: " ") ?? ""
            if !said || !detail.isEmpty, entries.last?.kind != .error {
                entries.append(AIEntry(kind: .error, text: detail.isEmpty ? "\(provider.rawValue) exited with status \(process.terminationStatus)." : detail))
            }
        }
        isRunning = false
        self.process = nil
    }

    private func finish(error: String) {
        entries.append(AIEntry(kind: .error, text: error))
        isRunning = false
    }

    /// Turns one line of the CLI's JSON event stream into transcript entries. Returns true when the model spoke.
    private func read(_ event: [String: Any], from provider: AIProvider) -> Bool {
        let type = event["type"] as? String ?? ""
        switch provider {
        case .claude:
            if let session = event["session_id"] as? String { sessions[.claude] = session }
            if type == "assistant", let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] {
                var spoke = false
                for block in content {
                    if block["type"] as? String == "text", let text = block["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        entries.append(AIEntry(kind: .assistant, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
                        spoke = true
                    } else if block["type"] as? String == "tool_use", let name = block["name"] as? String {
                        entries.append(AIEntry(kind: .tool, text: Self.describe(tool: name, arguments: block["input"])))
                    }
                }
                return spoke
            }
            if type == "result", event["is_error"] as? Bool == true {
                entries.append(AIEntry(kind: .error, text: event["result"] as? String ?? "Claude reported an error."))
            }
        case .codex:
            if type == "thread.started", let session = event["thread_id"] as? String { sessions[.codex] = session }
            if let item = event["item"] as? [String: Any] {
                let kind = item["type"] as? String ?? ""
                if type == "item.started", kind == "mcp_tool_call", let name = item["tool"] as? String {
                    entries.append(AIEntry(kind: .tool, text: Self.describe(tool: name, arguments: item["arguments"])))
                } else if type == "item.completed", kind == "agent_message", let text = item["text"] as? String {
                    entries.append(AIEntry(kind: .assistant, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
                    return true
                } else if type == "item.completed", kind == "error", let message = item["message"] as? String, !message.contains("deprecated") {
                    entries.append(AIEntry(kind: .error, text: message))
                }
            }
            if type == "error", let message = event["message"] as? String {
                entries.append(AIEntry(kind: .error, text: message))
            }
            if type == "turn.failed", let message = (event["error"] as? [String: Any])?["message"] as? String, entries.last?.text != message {
                entries.append(AIEntry(kind: .error, text: message))
            }
        }
        return false
    }

    /// `open_market coin=BTC placement=split_right`
    private static func describe(tool: String, arguments: Any?) -> String {
        let name = tool.replacingOccurrences(of: "mcp__powder__", with: "")
        var fields = arguments as? [String: Any]
        if fields == nil, let text = arguments as? String, let data = text.data(using: .utf8) {
            fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        let detail = (fields ?? [:]).sorted { $0.key < $1.key }.map { key, value in
            if let list = value as? [Any] { return "\(key)=\(list.map { "\($0)" }.joined(separator: ","))" }
            return "\(key)=\(value)"
        }
        return ([name] + detail).joined(separator: " ")
    }
}

// MARK: - View

/// The ⌘K panel: a prompt, the agent switch, and the running transcript, in the palette's place and style.
struct AIView: View {
    @ObservedObject var assistant: AIAssistant
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("ASK")
                    .font(Term.font(10.5, .bold))
                    .foregroundStyle(Term.accent)
                TextField("Arrange the layout, or ask about markets and positions", text: $assistant.prompt)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .autocorrectionDisabled()
                    .focused($isFocused)
                ForEach(AIProvider.allCases, id: \.self) { provider in
                    Button {
                        if !assistant.isRunning { assistant.provider = provider }
                    } label: {
                        InverseLabel(text: provider.title, isActive: assistant.provider == provider)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Answer with the \(provider.rawValue) command and its login on this Mac (tab switches)")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Term.background)
            .overlay(Rectangle().stroke(Term.accent, lineWidth: 1))
            .padding(6)

            if !assistant.entries.isEmpty || assistant.isRunning {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(assistant.entries) { entry in
                                line(entry).id(entry.id)
                            }
                            if assistant.isRunning {
                                TimelineView(.periodic(from: .now, by: 0.4)) { timeline in
                                    let dots = Int(timeline.date.timeIntervalSinceReferenceDate / 0.4) % 3 + 1
                                    Text("working" + String(repeating: ".", count: dots))
                                        .font(Term.font(11.5))
                                        .foregroundStyle(.secondary)
                                }
                                .id("working")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: assistant.entries.count) {
                        if let last = assistant.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                TermRule()
            }

            HStack(spacing: 14) {
                hint("⏎", "send")
                hint("tab", "switch agent")
                hint("esc", assistant.isRunning ? "stop" : "close")
                Spacer(minLength: 0)
                if !assistant.entries.isEmpty {
                    Button {
                        assistant.clear()
                    } label: {
                        Text("NEW CHAT").font(Term.font(10.5, .semibold)).foregroundStyle(.secondary).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Text("layout and data only · cannot trade")
                    .foregroundStyle(.secondary)
            }
            .font(Term.font(10.5))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 24)
        }
        .frame(width: 620)
        .background(Term.chrome)
        .overlay(Rectangle().stroke(Term.rule, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .foregroundStyle(Term.foreground)
        .onAppear { isFocused = true }
    }

    @ViewBuilder
    private func line(_ entry: AIEntry) -> some View {
        switch entry.kind {
        case .user:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("›").foregroundStyle(Term.accent)
                Text(entry.text).fontWeight(.semibold)
            }
            .font(.system(size: 13))
            .padding(.top, 2)
        case .assistant:
            Text(entry.text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .tool:
            Text("→ " + entry.text)
                .font(Term.font(11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case .error:
            Text(entry.text)
                .font(Term.font(11.5))
                .foregroundStyle(PowderPalette.riskCoral)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func hint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 5) {
            Text(key).foregroundStyle(Term.accent)
            Text(action).foregroundStyle(.secondary)
        }
        .fixedSize()
    }
}
