import AppKit
import ClaudeUsageCore
import SwiftUI
import UniformTypeIdentifiers

/// 확장의 일 목록 (일이 둘 이상일 때)
struct ExtensionActionList: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var store = AppServices.shared.extensions

    var body: some View {
        let language = ExtensionStore.language
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IslandIconButton(symbol: "chevron.left", help: String(localized: "Back")) { model.navigate(to: .sessions) }
                Text("Extensions").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            ForEach(store.actions) { ref in
                HStack(spacing: 10) {
                    Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(KongiTheme.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: ref.action.title.text(language)).font(.system(size: 12, weight: .semibold))
                        Text(verbatim: ref.item.manifest.name).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .islandHoverRow()
                .contentShape(Rectangle())
                .onTapGesture { model.navigate(to: .action(ref.id)) }
            }
        }
    }
}

/// 확장의 일 하나: 입력 칸 + 선택지 (+ 프로젝트·첨부) → 실행 → 질문이 오면 답하고 다시 → 결과 (복사, 대화에 넣기)
struct ExtensionActionPanel: View {
    @ObservedObject var model: IslandModel
    let ref: ExtensionStore.ActionRef
    @EnvironmentObject private var agents: AgentStore
    @State private var input = ""
    @State private var choice = ""
    @State private var running = false
    @State private var result: (text: String, failed: Bool)?
    @State private var note: String?
    /// 확장이 결과와 함께 보낸 메모 (예: 실제로 쓴 모델)
    @State private var resultNote: String?
    /// 고른 대화 (프로젝트 맥락). nil이면 프로젝트 없이
    @State private var sessionId: String?
    /// 첨부: 섬 전체의 끌어 놓기가 여기에 넣습니다 (IslandDropModifier)
    private var files: [URL] {
        get { model.actionFiles[ref.id] ?? [] }
        nonmutating set { model.actionFiles[ref.id] = newValue }
    }
    /// 확장이 물은 질문과 지금 쓰는 답, 이미 답한 것들
    @State private var questions: [ActionOutput.Question] = []
    @State private var drafts: [String] = []
    @State private var answered: [ActionContext.Answer] = []
    @FocusState private var focused: Bool
    @Namespace private var segments

    private var language: String { ExtensionStore.language }
    private var choiceKey: String { "extensionChoice." + ref.id }

    /// 프로젝트로 고를 수 있는 대화: 진행 중인 것, 그다음 최근 것 (폴더마다 하나)
    private var projects: [AgentSession] {
        var seen = Set<String>()
        return (agents.activeSessions + agents.pastSessions.prefix(20)).filter { !$0.cwd.isEmpty && seen.insert($0.cwd).inserted }
    }

    private var selected: AgentSession? { sessionId.flatMap { agents.session($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                IslandIconButton(symbol: "chevron.left", help: String(localized: "Back")) {
                    model.navigate(to: AppServices.shared.extensions.actions.count > 1 ? .actions : .sessions)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: ref.action.title.text(language)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(verbatim: ref.item.manifest.name).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
            }

            if let choices = ref.action.choices, !choices.isEmpty {
                HStack(spacing: 4) {
                    if let title = ref.action.choiceTitle {
                        Text(verbatim: title.text(language)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    }
                    ForEach(choices, id: \.id) { item in
                        IslandSegment(title: item.title.text(language), selected: choice == item.id, namespace: segments) {
                            choice = item.id
                            UserDefaults.standard.set(item.id, forKey: choiceKey)
                            // 입력이 필요 없는 일은 고르면 바로 실행 (예: 저장공간 → 정리하기)
                            if !ref.action.takesInput, !running { start() }
                        }
                    }
                }
            }

            if ref.action.wantsProject || ref.action.wantsFiles { contextRow }

            if ref.action.takesInput {
            TextField(ref.action.placeholder?.text(language) ?? "", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(3...8)
                .focused($focused)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(focused ? 0.12 : 0.08)))
                // 입력하는 동안 섬이 접히지 않게
                .onChange(of: focused) { isFocused in if isFocused { model.holdOpen() } }
            }

            if !files.isEmpty { attachments }

            if !questions.isEmpty {
                questionList
            } else {
                HStack(spacing: 8) {
                    if running {
                        ProgressView().controlSize(.small)
                        Text("Working…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    } else {
                        IslandPillButton(title: ref.action.takesInput ? String(localized: "Run") : String(localized: "Refresh"), style: .primary) { start() }
                            .disabled(ref.action.takesInput && input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty)
                    }
                    Spacer()
                }
            }

            if let result, questions.isEmpty { resultView(result) }
        }
        .onAppear {
            // Finder에서 파일을 끌어오느라 마우스가 섬 밖으로 나가도 접히지 않게 고정합니다 (닫기 버튼으로 닫음).
            model.holdOpen()
            let saved = UserDefaults.standard.string(forKey: choiceKey)
            let choices = ref.action.choices ?? []
            choice = choices.contains { $0.id == saved } ? saved ?? "" : choices.first?.id ?? ""
            // 입력이 필요 없는 일(상태 보기)은 열자마자 실행
            if !ref.action.takesInput, result == nil, !running { start() }
            // 프로젝트는 지금 일하는(또는 고정한) 대화부터
            if ref.action.wantsProject, sessionId == nil {
                sessionId = (agents.activeSessions.first { $0.state.isBusy } ?? agents.activeSessions.first)?.id
            }
        }
    }

    // MARK: 맥락

    private var contextRow: some View {
        HStack(spacing: 8) {
            if ref.action.wantsProject {
                Menu {
                    Button(String(localized: "No project")) { sessionId = nil }
                    if !projects.isEmpty { Divider() }
                    ForEach(projects) { session in
                        Button(session.title) { sessionId = session.id }
                    }
                } label: {
                    Label(selected?.title ?? String(localized: "No project"), systemImage: "folder")
                        .font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(Text("Pick a project so the result fits what you're working on"))
            }
            if ref.action.wantsFiles {
                IslandTextButton(title: String(localized: "Attach"), symbol: "paperclip") { pickFiles() }
                if files.isEmpty {
                    Text("or drop files here").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                }
            }
            Spacer()
        }
    }

    private var attachments: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(files, id: \.self) { url in
                HStack(spacing: 6) {
                    Image(systemName: "doc").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    Text(verbatim: url.lastPathComponent).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    IslandIconButton(symbol: "xmark", help: String(localized: "Remove")) { files.removeAll { $0 == url } }
                }
            }
        }
    }

    private func pickFiles() {
        // 섬은 다른 앱의 포커스를 뺏지 않는 창이라, 파일 고르는 창을 띄우기 전에 앱을 앞으로 가져옵니다.
        model.holdOpen()
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            for url in panel.urls where !files.contains(url) { files.append(url) }
        }
    }

    // MARK: 질문

    private var questionList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(String(localized: "A few questions to make it better"), systemImage: "questionmark.bubble")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(KongiTheme.green)
            ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: question.question).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    if question.multiSelect == true, let options = question.options {
                        // 여러 개 고르기: 고른 보기를 줄바꿈으로 이어 답으로 보냄
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(options, id: \.self) { option in
                                let picked = drafts[index].split(separator: "\n").map(String.init).contains(option)
                                Button {
                                    var set = drafts[index].split(separator: "\n").map(String.init)
                                    if picked { set.removeAll { $0 == option } } else { set.append(option) }
                                    drafts[index] = set.joined(separator: "\n")
                                } label: {
                                    Label(option, systemImage: picked ? "checkmark.square.fill" : "square")
                                        .font(.system(size: 12))
                                        .foregroundStyle(picked ? KongiTheme.green : .white.opacity(0.85))
                                }
                                .buttonStyle(KHoverStyle())
                            }
                        }
                    } else {
                        if let options = question.options, !options.isEmpty {
                            FlowRow(options: options, selected: drafts[index]) { drafts[index] = $0 }
                        }
                        TextField(String(localized: "Your answer"), text: $drafts[index], axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .lineLimit(1...3)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.08)))
                    }
                }
            }
            HStack(spacing: 8) {
                if running {
                    ProgressView().controlSize(.small)
                    Text("Working…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                } else {
                    let confirm = questions.first?.confirm
                    IslandPillButton(title: confirm ?? String(localized: "Continue"), style: confirm == nil ? .primary : .destructive) { answerAndContinue() }
                    IslandPillButton(title: confirm == nil ? String(localized: "Skip") : String(localized: "Cancel"), style: .secondary) {
                        // 확인형 질문(삭제 등)의 취소는 아무것도 하지 않고 닫습니다.
                        if confirm == nil { execute(skip: true) } else { questions = []; result = nil }
                    }
                }
                Spacer()
            }
        }
    }

    // MARK: 결과

    @ViewBuilder
    private func resultView(_ result: (text: String, failed: Bool)) -> some View {
        ScrollView {
            Text(verbatim: result.text)
                .font(ref.action.monospaced ? .system(size: 11, design: .monospaced) : .system(size: 12))
                .foregroundStyle(result.failed ? KongiTheme.orange : .white)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: 260)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
        if let resultNote {
            Text(verbatim: resultNote).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
        }
        if !result.failed {
            HStack(spacing: 8) {
                IslandTextButton(title: String(localized: "Copy"), symbol: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.text, forType: .string)
                    note = String(localized: "Copied")
                }
                let sessions = agents.activeSessions
                if !sessions.isEmpty {
                    Menu {
                        // 고른 프로젝트의 대화를 맨 위에
                        ForEach(sessions.filter { $0.id == sessionId } + sessions.filter { $0.id != sessionId }) { session in
                            Button(session.title) { send(result.text, to: session) }
                        }
                    } label: {
                        Label(String(localized: "Send to a conversation"), systemImage: "arrow.up.message")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Spacer()
                if let note { Text(verbatim: note).font(.system(size: 11)).foregroundStyle(KongiTheme.green) }
            }
        }
    }

    // MARK: 실행

    /// 새로 실행: 앞서 받은 답은 비웁니다.
    private func start() {
        answered = []
        execute(skip: false)
    }

    private func answerAndContinue() {
        for (question, answer) in zip(questions, drafts) {
            let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { answered.append(.init(question: question.question, answer: text)) }
        }
        execute(skip: false)
    }

    private func execute(skip: Bool) {
        let text = input
        let context = makeContext(skip: skip)
        running = true
        note = nil
        Task {
            let output = await AppServices.shared.extensions.perform(ref, input: text, choice: choice.isEmpty ? nil : choice, context: context)
            running = false
            resultNote = nil
            switch output.failed ? .text(output.text) : ActionOutput.parse(output.text) {
            case let .questions(list) where !skip:
                questions = list
                drafts = Array(repeating: "", count: list.count)
                result = nil
            case let .result(text, note):
                questions = []
                result = (text, false)
                resultNote = note
            default:
                questions = []
                result = output
            }
        }
    }

    private func makeContext(skip: Bool) -> ActionContext {
        ExtensionStore.context(session: selected, files: files.map(\.path), answers: answered, skip: skip)
    }

    private func send(_ text: String, to session: AgentSession) {
        switch agents.send(text, to: session.id, from: ref.item.manifest.name) {
        case .sent: note = String(localized: "Sent")
        case .queued: note = String(localized: "Sends when Claude pauses")
        case .resumed: note = String(localized: "Continuing in the background")
        case .needsUpdate, .failed: note = String(localized: "Couldn't send")
        }
    }
}

/// 질문의 보기들 (누르면 답 칸에 들어감)
private struct FlowRow: View {
    let options: [String]
    let selected: String
    let pick: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { option in
                    Text(verbatim: option)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(selected == option ? KongiTheme.green.opacity(0.35) : Color.white.opacity(0.1)))
                        .contentShape(Capsule())
                        .onTapGesture { pick(option) }
                }
            }
        }
    }
}
