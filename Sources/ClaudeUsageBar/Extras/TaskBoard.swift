import AppKit
import ClaudeUsageCore
import SwiftUI

/// `kongi` 명령으로 오는 것: 빌드·테스트(스코어보드, `run`·`task`), 알림(`notify`), 위젯(`widget`), 상태 묻기(`status`).
@MainActor
final class TaskBoard: ObservableObject {
    struct Task: Identifiable, Equatable {
        enum State: String { case running, succeeded, failed }
        let id: String
        var name: String
        var folder: String
        var state: State
        var fraction: Double?
        var passed: Int
        var failed: Int
        var seconds: Double
        var updatedAt: Date
    }

    /// 확장·앱이 메뉴 막대 창에 올린 작은 위젯 (`kongi widget`)
    struct Widget: Identifiable, Equatable {
        let id: String
        var owner: String
        var title: String
        var value: String
        var detail: String?
        var symbol: String
        var progress: Double?
        var url: URL?
    }

    /// 최근 것이 앞
    @Published private(set) var tasks: [Task] = []
    @Published private(set) var widgets: [Widget] = []
    private var lastNotice = Date.distantPast

    var running: [Task] { tasks.filter { $0.state == .running } }

    /// AgentStore가 훅 소켓에서 받은 Kongi… 이벤트를 넘깁니다. 돌려준 값은 `kongi status`의 답.
    func handle(_ event: JSONValue) -> JSONValue? {
        guard UserDefaults.standard.bool(forKey: AppSettings.appNotices) else { return nil }
        switch event["hook_event_name"]?.stringValue {
        case "KongiNotify": notify(event)
        case "KongiTask": update(event)
        case "KongiWidget": widget(event)
        case "KongiStatus": return Self.status()
        default: break
        }
        return nil
    }

    private static func symbol(_ name: String?, fallback: String) -> String {
        name.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil ? nil : $0 } ?? fallback
    }

    private func widget(_ event: JSONValue) {
        guard let id = event["id"]?.stringValue.map({ String($0.prefix(60)) }), !id.isEmpty else { return }
        let owner = event["owner"]?.stringValue ?? ""
        if event["remove"]?.boolValue == true {
            widgets.removeAll { $0.id == id }
            return
        }
        let item = Widget(
            id: id, owner: owner,
            title: String((event["title"]?.stringValue ?? id).prefix(40)),
            value: String((event["value"]?.stringValue ?? "").prefix(40)),
            detail: event["detail"]?.stringValue.map { String($0.prefix(120)) },
            symbol: Self.symbol(event["symbol"]?.stringValue, fallback: "puzzlepiece.extension"),
            progress: event["progress"]?.numberValue.map { min(max($0, 0), 1) },
            url: event["url"]?.stringValue.flatMap(URL.init(string:))
        )
        if let index = widgets.firstIndex(where: { $0.id == id }) {
            if widgets[index] != item { widgets[index] = item }
        } else if widgets.count < 12 {
            widgets.append(item)
        }
    }

    /// 확장을 끄거나 지우면 그 확장의 위젯도 치웁니다.
    func removeWidgets(owner: String) { widgets.removeAll { $0.owner == owner } }

    /// "running", "waitingForApproval" … (도구 이름 같은 값은 빼고)
    private static func stateName(_ state: AgentState) -> String {
        String(String(describing: state).prefix { $0 != "(" })
    }

    /// `kongi status`: 사용량, 진행 중인 대화, 빌드
    private static func status() -> JSONValue {
        let services = AppServices.shared
        func window(_ kind: LimitKind) -> JSONValue {
            guard let item = services.usage.snapshot?.limit(kind) else { return .null }
            var fields: [String: JSONValue] = ["percent": .number(item.percent)]
            if let reset = item.resetsAt { fields["resets_at"] = .string(ISO8601DateFormatter().string(from: reset)) }
            return .object(fields)
        }
        let sessions: [JSONValue] = services.agents.activeSessions.map { session in
            .object([
                "id": .string(session.id), "agent": .string(session.agent ?? "claude"),
                "project": .string(session.projectName), "cwd": .string(session.cwd),
                "state": .string(Self.stateName(session.state)),
                "updated_at": .string(ISO8601DateFormatter().string(from: session.updatedAt)),
            ])
        }
        let tasks: [JSONValue] = services.tasks.tasks.map { task in
            .object(["id": .string(task.id), "name": .string(task.name), "state": .string(task.state.rawValue),
                     "progress": task.fraction.map(JSONValue.number) ?? .null,
                     "passed": .number(Double(task.passed)), "failed": .number(Double(task.failed))])
        }
        return .object([
            "usage": .object([
                "session": window(.session),
                "weekly": window(.weekly),
            ]),
            "sessions": .array(sessions),
            "tasks": .array(tasks),
        ])
    }

    private func notify(_ event: JSONValue) {
        // 같은 Mac의 앱만 보낼 수 있지만, 너무 자주 오면 흘려보냅니다.
        guard Date().timeIntervalSince(lastNotice) > 1,
              let title = event["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return }
        lastNotice = Date()
        let symbol = Self.symbol(event["symbol"]?.stringValue, fallback: "bell.badge.fill")
        let seconds = min(max(event["seconds"]?.numberValue ?? 5, 2), 15)
        // --id가 같으면 앞의 알림을 바꿉니다. --url은 누르면 열립니다.
        let key = event["id"]?.stringValue.map { "app-\($0.prefix(60))" } ?? "app-\(UUID().uuidString)"
        AppServices.shared.devices.post(.init(
            key: key, symbol: symbol, tint: KongiTheme.accent,
            title: String(title.prefix(60)), detail: event["detail"]?.stringValue.map { String($0.prefix(100)) },
            trailing: event["source"]?.stringValue.map { String($0.prefix(16)) },
            action: event["url"]?.stringValue.flatMap(URL.init(string:)).map { .openURL($0) }
        ), for: seconds)
    }

    private func update(_ event: JSONValue) {
        guard let id = event["id"]?.stringValue, let raw = event["state"]?.stringValue,
              let state = Task.State(rawValue: raw) else { return }
        // `kongi task`는 시간을 모르므로 처음 받은 때부터 잽니다.
        let previous = tasks.first { $0.id == id }
        let task = Task(
            id: id,
            name: String((event["name"]?.stringValue ?? previous?.name ?? "").prefix(80)),
            folder: ((event["cwd"]?.stringValue ?? "") as NSString).lastPathComponent,
            state: state,
            fraction: event["fraction"]?.numberValue,
            passed: Int(event["passed"]?.numberValue ?? 0),
            failed: Int(event["failed"]?.numberValue ?? 0),
            seconds: event["seconds"]?.numberValue ?? previous.map { $0.seconds + Date().timeIntervalSince($0.updatedAt) } ?? 0,
            updatedAt: Date()
        )
        let wasRunning = previous?.state == .running
        tasks.removeAll { $0.id == id || Date().timeIntervalSince($0.updatedAt) > 86400 }
        tasks.insert(task, at: 0)
        tasks = Array(tasks.prefix(8))
        if state != .running, wasRunning || task.seconds > 0 { announce(task) }
    }

    /// 끝나면 아일랜드에 결과를 알립니다.
    private func announce(_ task: Task) {
        let ok = task.state == .succeeded
        var detail = TaskBoard.duration(task.seconds)
        if task.passed + task.failed > 0 { detail += " · ✓\(task.passed)" + (task.failed > 0 ? " ✗\(task.failed)" : "") }
        AppServices.shared.devices.post(.init(
            key: "task-\(task.id)", symbol: ok ? "checkmark.circle.fill" : "xmark.octagon.fill",
            tint: ok ? KongiTheme.green : KongiTheme.red,
            title: task.name, detail: detail, trailing: task.folder
        ), for: 6)
        AppServices.shared.extensions.emit(ok ? "task.done" : "task.failed", [
            "id": .string(task.id), "name": .string(task.name), "cwd": .string(task.folder),
            "seconds": .number(task.seconds), "passed": .number(Double(task.passed)), "failed": .number(Double(task.failed)),
        ])
        if !ok || task.seconds > 60 {
            Notifier.post(title: ok ? String(localized: "Done: \(task.name)") : String(localized: "Failed: \(task.name)"), body: detail, phone: true)
        }
    }

    func clearFinished() { tasks.removeAll { $0.state != .running } }

    /// "42초", "3분 5초" (시스템 언어로)
    static func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        return formatter.string(from: max(seconds.rounded(), 1)) ?? ""
    }
}

// MARK: - 화면

/// 진행률 링: 도는 중이면 퍼센트(모르면 빙글), 끝나면 초록 체크 / 빨간 X
struct TaskRing: View {
    let task: TaskBoard.Task
    var size: CGFloat = 26

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: size * 0.12)
            switch task.state {
            case .running:
                if let fraction = task.fraction {
                    Circle().trim(from: 0, to: fraction)
                        .stroke(KongiTheme.orange, style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.3), value: fraction)
                    Text(verbatim: "\(Int(fraction * 100))")
                        .font(.system(size: size * 0.32, weight: .bold, design: .rounded)).monospacedDigit()
                } else {
                    Spinner(size: size * 0.7, color: KongiTheme.orange)
                }
            case .succeeded:
                Circle().stroke(KongiTheme.green, lineWidth: size * 0.12)
                Image(systemName: "checkmark").font(.system(size: size * 0.38, weight: .bold)).foregroundStyle(KongiTheme.green)
            case .failed:
                Circle().stroke(KongiTheme.red, lineWidth: size * 0.12)
                Image(systemName: "xmark").font(.system(size: size * 0.38, weight: .bold)).foregroundStyle(KongiTheme.red)
            }
        }
        .frame(width: size, height: size)
    }
}

/// 스코어보드 한 줄
struct TaskRow: View {
    let task: TaskBoard.Task

    var body: some View {
        HStack(spacing: 10) {
            TaskRing(task: task)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: task.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(verbatim: summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var summary: String {
        var parts = [task.folder]
        if task.passed + task.failed > 0 { parts.append("✓\(task.passed)" + (task.failed > 0 ? " ✗\(task.failed)" : "")) }
        if task.state != .running { parts.append(TaskBoard.duration(task.seconds)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// 확장 위젯 한 줄: 아이콘 · 제목/설명 · 값 (진행 막대). 주소가 있으면 누르면 열립니다.
struct WidgetRow: View {
    let widget: TaskBoard.Widget

    var body: some View {
        if let url = widget.url {
            Button { NSWorkspace.shared.open(url) } label: { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: widget.symbol).font(.system(size: 14)).foregroundStyle(KongiTheme.accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: widget.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if let detail = widget.detail, !detail.isEmpty {
                        Text(verbatim: detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 6)
                Text(verbatim: widget.value).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            if let progress = widget.progress {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.1))
                        Capsule().fill(progress > 0.85 ? KongiTheme.red : KongiTheme.accent)
                            .frame(width: max(proxy.size.width * progress, progress > 0 ? 6 : 0))
                    }
                }
                .frame(height: 6)
            }
        }
    }
}
