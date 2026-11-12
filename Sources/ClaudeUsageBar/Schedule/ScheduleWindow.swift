import AppKit
import ClaudeUsageCore
import SwiftUI

/// 새 예약을 만들 때 미리 채워 둘 값
struct ScheduleDraft: Equatable {
    var sessionId: String?
    var projectPath: String = ""
    var prompt: String = ""
    var trigger: ScheduleTriggerKind = .sessionReset
}

enum ScheduleTriggerKind: String, CaseIterable, Identifiable {
    case sessionReset, weeklyReset, time

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessionReset: return String(localized: "Right after the session limit resets")
        case .weeklyReset: return String(localized: "Right after the weekly limit resets")
        case .time: return String(localized: "At a specific time")
        }
    }
}

extension ScheduledPrompt.Permission {
    var title: String {
        switch self {
        case .standard: return String(localized: "Skip anything that needs approval")
        case .acceptEdits: return String(localized: "Allow file edits")
        case .bypassPermissions: return String(localized: "Allow everything (careful)")
        }
    }
}

extension ScheduledPrompt {
    var triggerDescription: String {
        switch trigger {
        case .sessionReset:
            return repeats ? String(localized: "After every session reset") : String(localized: "After the next session reset")
        case .weeklyReset:
            return repeats ? String(localized: "After every weekly reset") : String(localized: "After the next weekly reset")
        case let .at(date):
            let locale = Formatters.appLocale
            if repeats {
                let time = date.formatted(.dateTime.locale(locale).hour().minute())
                return String(localized: "Every day at \(time)")
            }
            return date.formatted(.dateTime.locale(locale).month().day().weekday(.abbreviated).hour().minute())
        }
    }
}

// MARK: - List

struct ScheduleListView: View {
    @EnvironmentObject private var scheduler: PromptScheduler
    @State private var editing: ScheduledPrompt?
    @State private var creating = false
    @State private var now = Date()

    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Scheduled prompts").font(.title2.weight(.semibold))
                    Text("Send a prompt to Claude Code in a project when your usage limit resets, or at a time you choose.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    creating = true
                } label: {
                    Label("New schedule", systemImage: "plus")
                }
                .controlSize(.large)
                .keyboardShortcut("n")
            }
            .padding(20)

            Divider()

            if scheduler.prompts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "calendar.badge.clock").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("No scheduled prompts yet").font(.headline)
                    Text("Tip: when you hit the session limit, the island offers to continue automatically after the reset.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(scheduler.prompts) { prompt in
                        ScheduleRow(prompt: prompt, now: now) { editing = prompt }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 480, minHeight: 380)
        .onReceive(clock) { now = $0 }
        .sheet(isPresented: $creating) {
            ScheduleEditor(existing: nil, draft: AppServices.shared.scheduleDraft) { creating = false }
        }
        .sheet(item: $editing) { prompt in
            ScheduleEditor(existing: prompt, draft: nil) { editing = nil }
        }
        .onReceive(AppServices.shared.$scheduleDraft) { draft in
            if draft != nil { creating = true }
        }
    }
}

private struct ScheduleRow: View {
    let prompt: ScheduledPrompt
    let now: Date
    let edit: () -> Void
    @EnvironmentObject private var scheduler: PromptScheduler

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(prompt.enabled && !prompt.finished ? Color.accentColor : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: prompt.projectName).font(.headline)
                    if prompt.sessionId != nil {
                        Text("This conversation")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    } else if prompt.continueConversation {
                        Text("Continues chat")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                Text(verbatim: prompt.prompt)
                    .font(.callout)
                    .lineLimit(2)
                Text(verbatim: "\(prompt.triggerDescription) · \(prompt.permission.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(status)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Toggle("", isOn: Binding(
                    get: { prompt.enabled && !prompt.finished },
                    set: { scheduler.setEnabled($0, for: prompt.id) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                HStack(spacing: 4) {
                    if scheduler.running.contains(prompt.id) {
                        Button("Stop") { scheduler.stop(prompt.id) }
                    } else {
                        Button("Run now") { scheduler.runNow(prompt.id) }
                    }
                    if let log = scheduler.logURL(for: prompt.id) {
                        Button {
                            NSWorkspace.shared.open(log)
                        } label: {
                            Image(systemName: "doc.text")
                        }
                        .help(Text("Show output"))
                    }
                    Button(action: edit) { Image(systemName: "pencil") }
                        .help(Text("Edit"))
                    Button(role: .destructive) {
                        scheduler.delete(prompt.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help(Text("Delete"))
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
    }

    private var icon: String {
        switch prompt.trigger {
        case .sessionReset, .weeklyReset: return prompt.repeats ? "arrow.clockwise.circle" : "clock.arrow.circlepath"
        case .at: return prompt.repeats ? "repeat.circle" : "calendar.circle"
        }
    }

    private var status: String {
        if scheduler.running.contains(prompt.id) { return String(localized: "Running…") }
        if let next = scheduler.nextRun(prompt) {
            return String(localized: "Next run: \(Formatters.scheduleTime(next, now: now))")
        }
        if let outcome = prompt.lastOutcome, prompt.finished || !prompt.enabled || prompt.repeats {
            switch outcome {
            case let .succeeded(summary): return summary.isEmpty ? String(localized: "Finished") : String(localized: "Finished: \(summary)")
            case let .failed(message): return String(localized: "Failed: \(message)")
            case .missed: return String(localized: "Missed (the Mac was asleep or offline)")
            }
        }
        if !prompt.enabled { return String(localized: "Paused") }
        switch prompt.trigger {
        case .sessionReset, .weeklyReset:
            return String(localized: "Waiting for a reset time (use Claude first, or check that the app is connected)")
        case .at:
            return ""
        }
    }

    private var statusColor: Color {
        if scheduler.running.contains(prompt.id) { return .orange }
        if case .failed = prompt.lastOutcome, prompt.finished || prompt.repeats { return .red }
        return .secondary
    }
}

// MARK: - Editor

private struct ScheduleEditor: View {
    let existing: ScheduledPrompt?
    let close: () -> Void

    @EnvironmentObject private var scheduler: PromptScheduler
    @EnvironmentObject private var agents: AgentStore
    @EnvironmentObject private var usage: UsageStore

    @State private var projectPath: String
    @State private var prompt: String
    @State private var triggerKind: ScheduleTriggerKind
    @State private var date: Date
    @State private var repeats: Bool
    @State private var continueConversation: Bool
    @State private var permission: ScheduledPrompt.Permission
    /// 빈 문자열 = Claude Code 기본값
    @State private var model: String
    @State private var effort: String
    /// 비어 있으면 폴더에서 새로 실행, 아니면 그 Claude Code 대화에 이어서 보냄
    @State private var targetSessionId: String

    init(existing: ScheduledPrompt?, draft: ScheduleDraft?, close: @escaping () -> Void) {
        self.existing = existing
        self.close = close
        _projectPath = State(initialValue: existing?.projectPath ?? draft?.projectPath ?? "")
        _prompt = State(initialValue: existing?.prompt ?? draft?.prompt ?? "")
        _repeats = State(initialValue: existing?.repeats ?? false)
        _continueConversation = State(initialValue: existing?.continueConversation ?? false)
        _permission = State(initialValue: existing?.permission ?? .acceptEdits)
        _model = State(initialValue: existing?.model ?? "")
        _effort = State(initialValue: existing?.effort ?? "")
        _targetSessionId = State(initialValue: existing?.sessionId ?? draft?.sessionId ?? "")
        switch existing?.trigger {
        case .weeklyReset:
            _triggerKind = State(initialValue: .weeklyReset)
            _date = State(initialValue: Date().addingTimeInterval(3600))
        case let .at(date):
            _triggerKind = State(initialValue: .time)
            _date = State(initialValue: date)
        case .sessionReset:
            _triggerKind = State(initialValue: .sessionReset)
            _date = State(initialValue: Date().addingTimeInterval(3600))
        case nil:
            _triggerKind = State(initialValue: draft?.trigger ?? .sessionReset)
            _date = State(initialValue: Date().addingTimeInterval(3600))
        }
    }

    private var recentProjects: [String] {
        var seen = Set<String>()
        let paths = agents.sessions.map(\.cwd) + scheduler.prompts.map(\.projectPath) + [projectPath]
        return paths.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 이어서 보낼 수 있는 대화: 진행 중인 세션 (편집 중인 예약의 세션은 끝났어도 포함)
    private var targetSessions: [AgentSession] {
        agents.sessions.filter { $0.state != .ended || $0.id == existing?.sessionId || $0.id == targetSessionId }
    }

    private var canSave: Bool {
        let hasTarget = !targetSessionId.isEmpty || !projectPath.isEmpty
        return hasTarget && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? String(localized: "New schedule") : String(localized: "Edit schedule"))
                .font(.title3.weight(.semibold))

            Form {
                Picker("Send to", selection: $targetSessionId) {
                    Text("A new run in a folder").tag("")
                    ForEach(targetSessions) { session in
                        Text(String(localized: "Conversation in \(session.projectName)")).tag(session.id)
                    }
                }
                if !targetSessionId.isEmpty {
                    Text("The prompt is typed into that conversation's terminal (Terminal, iTerm). If the terminal is closed, the same conversation is resumed with claude --resume.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if targetSessionId.isEmpty {
                Picker("Project", selection: $projectPath) {
                    if projectPath.isEmpty { Text("Choose a folder").tag("") }
                    ForEach(recentProjects, id: \.self) { path in
                        Text(verbatim: (path as NSString).abbreviatingWithTildeInPath).tag(path)
                    }
                }
                HStack {
                    Spacer()
                    Button("Choose folder…", action: chooseFolder)
                }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Prompt")
                    TextEditor(text: $prompt)
                        .font(.body)
                        .frame(height: 80)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                }

                Picker("When", selection: $triggerKind) {
                    ForEach(ScheduleTriggerKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                if triggerKind == .time {
                    DatePicker("Time", selection: $date)
                }
                Toggle(triggerKind == .time ? String(localized: "Repeat every day") : String(localized: "Repeat after every reset"), isOn: $repeats)
                if triggerKind != .time {
                    Text(resetHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if targetSessionId.isEmpty {
                    Toggle("Continue the last conversation in this folder", isOn: $continueConversation)
                }
                Picker("Permissions", selection: $permission) {
                    ForEach(ScheduledPrompt.Permission.allCases, id: \.self) { permission in
                        Text(permission.title).tag(permission)
                    }
                }
                Text("Nobody is there to approve requests during a scheduled run, so choose what Claude may do on its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Model", selection: $model) {
                    Text("Claude Code default").tag("")
                    ForEach(["fable", "opus", "sonnet", "haiku"], id: \.self) { Text(verbatim: $0.capitalized).tag($0) }
                }
                Picker("Effort", selection: $effort) {
                    Text("Claude Code default").tag("")
                    ForEach(ScheduledPrompt.effortLevels, id: \.self) { Text(verbatim: $0).tag($0) }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    AppServices.shared.scheduleDraft = nil
                    close()
                }
                .keyboardShortcut(.cancelAction)
                Button(existing == nil ? String(localized: "Schedule") : String(localized: "Save")) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var resetHint: String {
        let kind: LimitKind = triggerKind == .weeklyReset ? .weekly : .session
        guard let resetsAt = usage.snapshot?.limit(kind)?.resetsAt else {
            return String(localized: "The reset time isn't known yet. It appears once you've used Claude in this window.")
        }
        let time = Formatters.scheduleTime(resetsAt, now: Date())
        return String(localized: "Next reset: \(time)")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url {
            projectPath = url.path
        }
    }

    /// "모든 작업 허용"은 지켜보는 사람 없이 Claude가 어떤 명령이든 실행할 수 있으므로 한 번 더 확인합니다.
    private func confirmBypass() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Allow everything without asking?")
        alert.informativeText = String(localized: "During this scheduled run, Claude can run any command and change or delete any file in this folder without asking. Only use this for projects you trust and have backed up.")
        alert.addButton(withTitle: String(localized: "Allow everything"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func save() {
        if permission == .bypassPermissions, existing?.permission != .bypassPermissions, !confirmBypass() { return }
        let trigger: ScheduledPrompt.Trigger
        switch triggerKind {
        case .sessionReset: trigger = .sessionReset
        case .weeklyReset: trigger = .weeklyReset
        case .time: trigger = .at(date)
        }
        var prompt = existing ?? ScheduledPrompt(projectPath: projectPath, prompt: "", trigger: trigger)
        if let session = agents.session(targetSessionId) {
            prompt.sessionId = session.id
            prompt.sessionContext = session.context
            prompt.projectPath = session.cwd
            prompt.continueConversation = true
        } else {
            prompt.sessionId = nil
            prompt.sessionContext = nil
            prompt.projectPath = projectPath
        }
        prompt.prompt = self.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        prompt.trigger = trigger
        prompt.repeats = repeats
        if prompt.sessionId == nil { prompt.continueConversation = continueConversation }
        prompt.permission = permission
        prompt.model = model.isEmpty ? nil : model
        prompt.effort = effort.isEmpty ? nil : effort
        prompt.enabled = true
        prompt.finished = false
        scheduler.save(prompt)
        AppServices.shared.scheduleDraft = nil
        close()
    }
}
