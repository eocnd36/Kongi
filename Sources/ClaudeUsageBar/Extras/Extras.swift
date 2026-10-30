import AppKit
import ClaudeUsageCore
import Combine
import Darwin
import EventKit
import Foundation
import SwiftUI

// 아일랜드를 개발자의 하루에 맞게 넓히는 기능들.
// 모두 이 Mac 안에서만 동작하고, 권한이나 다른 도구가 필요한 것은 설정에서 켜야 동작합니다.

extension AppSettings {
    static let githubEnabled = "githubEnabled"
    static let watchedPorts = "watchedPorts"
    static let meetingsEnabled = "meetingsEnabled"
    static let clipboardEnabled = "clipboardEnabled"
    static let focusMinutes = "focusMinutes"
    static let breakMinutes = "breakMinutes"
    static let shellMinimumSeconds = "shellMinimumSeconds"

    static func registerExtrasDefaults() {
        UserDefaults.standard.register(defaults: [
            githubEnabled: false,
            watchedPorts: "",
            meetingsEnabled: false,
            clipboardEnabled: false,
            focusMinutes: 25,
            breakMinutes: 5,
            shellMinimumSeconds: 10,
        ])
    }
}

@MainActor
private func post(_ notice: DeviceEventsMonitor.Notice, for seconds: Double = 5) {
    AppServices.shared.devices.post(notice, for: seconds)
}

// MARK: - 사용량 속도 경고

/// 지금 속도라면 한도에 언제 닿는지 미리 알려 줍니다 (한 창에 한 번).
@MainActor
final class UsagePaceWatcher {
    private var warned: Set<String> = []
    private var cancellable: AnyCancellable?

    func start(usage: UsageStore) {
        cancellable = usage.$snapshot.compactMap { $0 }.sink { [weak self] snapshot in
            Task { @MainActor in self?.check(snapshot) }
        }
    }

    private func check(_ snapshot: UsageSnapshot) {
        guard UserDefaults.standard.bool(forKey: AppSettings.islandShowsPace) else { return }
        let now = Date()
        for item in snapshot.limits where item.kind == .session || item.kind == .weekly {
            guard item.percent >= 50, let resetsAt = item.resetsAt, let hit = item.projectedLimitDate(now: now),
                  hit < resetsAt else { continue }
            let minutes = Int(hit.timeIntervalSince(now) / 60)
            let key = "\(item.kind.rawValue)-\(Int(resetsAt.timeIntervalSince1970))"
            guard minutes > 0, minutes <= (item.kind == .session ? 45 : 24 * 60), !warned.contains(key) else { continue }
            warned.insert(key)
            let hours = minutes / 60
            let left = minutes < 120 ? String(localized: "\(minutes) min") : String(localized: "\(hours) h")
            post(.init(
                key: "pace-\(key)",
                symbol: "gauge.with.dots.needle.67percent",
                tint: KongiTheme.orange,
                title: String(localized: "\(item.kind.title) runs out in about \(left)"),
                detail: String(localized: "at this pace"),
                trailing: MenuBarFormatter.percentText(item.percent),
                action: .openWindow
            ), for: 7)
        }
    }
}

// MARK: - 집중 타이머

/// 섬이 곧 타이머: 집중 → 쉬기를 번갈아. 접힌 섬에 남은 시간이 보입니다.
@MainActor
final class FocusTimer: ObservableObject {
    enum Phase: Equatable { case focus, rest }

    @Published private(set) var phase: Phase?
    @Published private(set) var endsAt: Date?
    @Published private(set) var startedAt: Date?
    private var task: Task<Void, Never>?

    var isRunning: Bool { phase != nil }

    func remaining(at date: Date = Date()) -> TimeInterval { max((endsAt ?? date).timeIntervalSince(date), 0) }

    func progress(at date: Date = Date()) -> Double {
        guard let startedAt, let endsAt, endsAt > startedAt else { return 0 }
        return min(max(date.timeIntervalSince(startedAt) / endsAt.timeIntervalSince(startedAt), 0), 1)
    }

    func start(_ phase: Phase = .focus) {
        let minutes = UserDefaults.standard.integer(forKey: phase == .focus ? AppSettings.focusMinutes : AppSettings.breakMinutes)
        self.phase = phase
        startedAt = Date()
        endsAt = Date().addingTimeInterval(TimeInterval(max(minutes, 1) * 60))
        task?.cancel()
        task = Task { [weak self] in
            while let self, !Task.isCancelled, self.remaining() > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    func stop() {
        task?.cancel()
        phase = nil
        endsAt = nil
        startedAt = nil
    }

    private func finish() {
        let ended = phase
        NSSound(named: "Glass")?.play()
        if ended == .focus {
            post(.init(key: "focus-end", symbol: "cup.and.saucer.fill", tint: KongiTheme.accent,
                       title: String(localized: "Focus done"), detail: String(localized: "Take a short break")), for: 8)
            Notifier.post(title: String(localized: "Focus done"), body: String(localized: "Take a short break"))
            start(.rest)
        } else {
            post(.init(key: "rest-end", symbol: "timer", tint: KongiTheme.accent,
                       title: String(localized: "Break is over"), detail: String(localized: "Ready for the next one?")), for: 8)
            stop()
        }
    }
}

// MARK: - 셸 명령 완료 (오래 걸린 빌드·테스트)

/// ~/.zshrc에 작은 코드를 넣어, 오래 걸린 명령이 끝나면 도우미가 Kongi에 알립니다.
/// 사용자가 설정에서 누를 때만 설치하고, 고치기 전에 백업합니다.
enum ShellIntegration {
    static let begin = "# >>> Kongi shell integration >>>"
    static let end = "# <<< Kongi shell integration <<<"

    static var zshrc: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc") }

    static var snippet: String {
        """
        \(begin)
        # 오래 걸린 명령이 끝나면 Kongi 아일랜드에 알려 줍니다. 지우려면 이 블록을 지우세요.
        if [[ -o interactive ]]; then
          zmodload zsh/datetime 2>/dev/null
          autoload -Uz add-zsh-hook
          _kongi_preexec() { _kongi_cmd="$1"; _kongi_start=$EPOCHREALTIME }
          _kongi_precmd() {
            local exit_status=$?
            [[ -n "$_kongi_start" ]] || return
            local elapsed=$(( ${EPOCHREALTIME%.*} - ${_kongi_start%.*} ))
            unset _kongi_start
            local helper="$HOME/Library/Application Support/ClaudeUsageBar/bin/claude-usage-hook"
            (( elapsed >= 5 )) && [[ -x "$helper" ]] && "$helper" --shell "$exit_status" "$elapsed" "$PWD" "$_kongi_cmd" &!
          }
          add-zsh-hook preexec _kongi_preexec
          add-zsh-hook precmd _kongi_precmd
        fi
        \(end)
        """
    }

    static var isInstalled: Bool {
        ((try? String(contentsOf: zshrc, encoding: .utf8)) ?? "").contains(begin)
    }

    static func install() throws {
        let existing = (try? String(contentsOf: zshrc, encoding: .utf8)) ?? ""
        guard !existing.contains(begin) else { return }
        if !existing.isEmpty {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try existing.write(to: zshrc.deletingLastPathComponent().appendingPathComponent(".zshrc.kongi-backup-\(stamp)"), atomically: true, encoding: .utf8)
        }
        let updated = existing + (existing.hasSuffix("\n") || existing.isEmpty ? "" : "\n") + "\n" + snippet + "\n"
        try updated.write(to: zshrc, atomically: true, encoding: .utf8)
    }

    static func uninstall() throws {
        guard let existing = try? String(contentsOf: zshrc, encoding: .utf8),
              let start = existing.range(of: begin), let stop = existing.range(of: end, range: start.upperBound..<existing.endIndex) else { return }
        var updated = existing
        updated.removeSubrange(start.lowerBound..<stop.upperBound)
        try updated.replacingOccurrences(of: "\n\n\n", with: "\n\n").write(to: zshrc, atomically: true, encoding: .utf8)
    }

    /// 도우미가 보낸 "명령 끝" 소식
    @MainActor
    static func handle(_ event: JSONValue) {
        let seconds = Int(event["seconds"]?.numberValue ?? 0)
        guard seconds >= UserDefaults.standard.integer(forKey: AppSettings.shellMinimumSeconds) else { return }
        let status = Int(event["status"]?.numberValue ?? 0)
        let command = (event["command"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = ((event["cwd"]?.stringValue ?? "") as NSString).lastPathComponent
        let short = command.count > 48 ? String(command.prefix(47)) + "…" : command
        let success = status == 0
        let minutes = seconds / 60
        let duration = seconds < 120 ? String(localized: "\(seconds)s") : String(localized: "\(minutes) min")
        post(.init(
            key: "shell-\(command)",
            symbol: success ? "checkmark.circle.fill" : "xmark.octagon.fill",
            tint: success ? KongiTheme.green : KongiTheme.red,
            title: short.isEmpty ? String(localized: "Command finished") : short,
            detail: folder.isEmpty ? nil : folder,
            trailing: success ? duration : String(localized: "exit \(status) · \(duration)")
        ), for: success ? 5 : 8)
        // 1분 넘게 걸린 것은 다른 일을 하고 있었을 테니 알림도
        if seconds >= 60 {
            Notifier.post(
                title: success ? String(localized: "Finished: \(short)") : String(localized: "Failed: \(short)"),
                body: "\(folder) · \(duration)"
            )
        }
    }
}

// MARK: - GitHub (gh)

/// `gh`로 로그인돼 있으면 알림(리뷰 요청, CI, 멘션)을 아일랜드에. 토큰은 gh가 관리하고 Kongi는 보지 않습니다.
@MainActor
final class GitHubWatcher: ObservableObject {
    struct Item: Identifiable, Equatable {
        var id: String
        var title: String
        var repo: String
        var reason: String
        var url: URL?
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var available = GitHubWatcher.ghPath != nil
    private var seen: Set<String> = []
    private var first = true
    private var task: Task<Void, Never>?

    static var ghPath: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func apply() {
        let enabled = UserDefaults.standard.bool(forKey: AppSettings.githubEnabled) && Self.ghPath != nil
        if enabled, task == nil {
            task = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    try? await Task.sleep(nanoseconds: 120 * NSEC_PER_SEC)
                }
            }
        } else if !enabled {
            task?.cancel()
            task = nil
            items = []
        }
    }

    private func refresh() async {
        guard let gh = Self.ghPath else { return }
        let output = await Task.detached(priority: .utility) { () -> Data? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: gh)
            process.arguments = ["api", "notifications", "--jq", "[.[] | {id, reason, title: .subject.title, url: .subject.url, type: .subject.type, repo: .repository.full_name}]"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        }.value
        guard let output, let list = try? JSONSerialization.jsonObject(with: output) as? [[String: Any]] else { return }
        let parsed: [Item] = list.compactMap { entry in
            guard let id = entry["id"] as? String, let title = entry["title"] as? String else { return nil }
            return Item(id: id, title: title, repo: entry["repo"] as? String ?? "", reason: entry["reason"] as? String ?? "",
                        url: Self.webURL(api: entry["url"] as? String, repo: entry["repo"] as? String))
        }
        items = parsed
        // 처음 켰을 때 이미 있던 것은 띄우지 않습니다.
        defer { first = false; seen.formUnion(parsed.map(\.id)) }
        guard !first, let new = parsed.first(where: { !seen.contains($0.id) }) else { return }
        post(.init(
            key: "github-\(new.id)",
            symbol: new.reason == "ci_activity" ? "hammer.circle.fill" : "arrow.triangle.pull",
            tint: Color(red: 0.6, green: 0.55, blue: 1.0),
            title: new.title,
            detail: Self.reasonLabel(new.reason),
            trailing: new.repo.split(separator: "/").last.map(String.init),
            action: new.url.map { .openURL($0) }
        ), for: 7)
    }

    static func reasonLabel(_ reason: String) -> String {
        switch reason {
        case "review_requested": return String(localized: "Review requested")
        case "ci_activity": return String(localized: "CI")
        case "mention", "team_mention": return String(localized: "Mentioned you")
        case "assign": return String(localized: "Assigned to you")
        case "comment": return String(localized: "New comment")
        default: return "GitHub"
        }
    }

    /// api.github.com/repos/o/r/pulls/12 → github.com/o/r/pull/12
    static func webURL(api: String?, repo: String?) -> URL? {
        guard let api else { return repo.flatMap { URL(string: "https://github.com/\($0)") } }
        let web = api.replacingOccurrences(of: "https://api.github.com/repos/", with: "https://github.com/")
            .replacingOccurrences(of: "/pulls/", with: "/pull/")
            .replacingOccurrences(of: "/commits/", with: "/commit/")
        guard let url = URL(string: web), url.host == "github.com" else { return nil }
        return url
    }
}

// MARK: - 개발 서버 포트

/// 지정한 localhost 포트가 열리거나 닫히면 알려 줍니다 (서버가 죽었을 때 바로 알게).
@MainActor
final class PortWatcher: ObservableObject {
    @Published private(set) var states: [Int: Bool] = [:]
    private var task: Task<Void, Never>?

    static func ports() -> [Int] {
        (UserDefaults.standard.string(forKey: AppSettings.watchedPorts) ?? "")
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .compactMap { Int($0) }
            .filter { (1...65535).contains($0) }
    }

    func apply() {
        let ports = Self.ports()
        task?.cancel()
        task = nil
        states = states.filter { ports.contains($0.key) }
        guard !ports.isEmpty else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                let results = await Task.detached(priority: .utility) { ports.map { ($0, Self.isOpen(port: $0)) } }.value
                guard let self, !Task.isCancelled else { return }
                for (port, open) in results {
                    let before = self.states[port]
                    self.states[port] = open
                    guard let before, before != open else { continue }
                    post(.init(
                        key: "port-\(port)",
                        symbol: open ? "server.rack" : "exclamationmark.triangle.fill",
                        tint: open ? KongiTheme.green : KongiTheme.red,
                        title: "localhost:\(port)",
                        detail: open ? String(localized: "Server is up") : String(localized: "Server stopped"),
                        action: open ? URL(string: "http://localhost:\(port)").map { .openURL($0) } : nil
                    ), for: open ? 4 : 8)
                }
                try? await Task.sleep(nanoseconds: 4 * NSEC_PER_SEC)
            }
        }
    }

    /// 127.0.0.1에 바로 연결해 봅니다 (로컬이라 즉시 답이 옴).
    nonisolated static func isOpen(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

// MARK: - 다음 회의

/// 캘린더의 다음 일정: 10분 전과 1분 전에 섬에 띄우고, 화상회의 링크가 있으면 눌러서 바로 참여.
@MainActor
final class MeetingWatcher: ObservableObject {
    struct Meeting: Equatable {
        var id: String
        var title: String
        var start: Date
        var url: URL?
    }

    @Published private(set) var next: Meeting?
    @Published private(set) var denied = false
    private let store = EKEventStore()
    private var task: Task<Void, Never>?
    private var announced: Set<String> = []

    func apply() {
        let enabled = UserDefaults.standard.bool(forKey: AppSettings.meetingsEnabled)
        task?.cancel()
        task = nil
        guard enabled else {
            next = nil
            return
        }
        task = Task { [weak self] in
            guard let self, await self.requestAccess() else { return }
            while !Task.isCancelled {
                self.refresh()
                try? await Task.sleep(nanoseconds: 30 * NSEC_PER_SEC)
            }
        }
    }

    private func requestAccess() async -> Bool {
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = (try? await store.requestFullAccessToEvents()) ?? false
        } else {
            granted = await withCheckedContinuation { continuation in
                store.requestAccess(to: .event) { ok, _ in continuation.resume(returning: ok) }
            }
        }
        denied = !granted
        return granted
    }

    private func refresh() {
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-60), end: now.addingTimeInterval(3 * 3600), calendars: nil)
        let upcoming = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate > now.addingTimeInterval(-60) }
            .sorted { $0.startDate < $1.startDate }
            .first
        guard let event = upcoming else {
            next = nil
            return
        }
        let meeting = Meeting(
            id: event.eventIdentifier ?? event.title,
            title: event.title ?? String(localized: "Meeting"),
            start: event.startDate,
            url: Self.joinURL(in: [event.url?.absoluteString, event.location, event.notes].compactMap { $0 })
        )
        next = meeting
        let minutes = Int(ceil(meeting.start.timeIntervalSince(now) / 60))
        for mark in [10, 1] where minutes <= mark && minutes >= 0 {
            let key = "\(meeting.id)-\(mark)"
            guard !announced.contains(key) else { continue }
            announced.insert(key)
            post(.init(
                key: "meeting-\(meeting.id)",
                symbol: "video.fill",
                tint: Color(red: 0.4, green: 0.7, blue: 1.0),
                title: meeting.title,
                detail: minutes <= 1 ? String(localized: "Starting now") : String(localized: "In \(minutes) min"),
                trailing: meeting.url != nil ? String(localized: "Join") : nil,
                action: meeting.url.map { .openURL($0) }
            ), for: mark == 1 ? 12 : 8)
        }
    }

    /// Zoom, Meet, Teams, Webex 링크
    static func joinURL(in texts: [String]) -> URL? {
        let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com", "around.co"]
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for text in texts {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector?.matches(in: text, range: range) ?? [] {
                guard let url = match.url, url.scheme == "https", let host = url.host?.lowercased(),
                      hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { continue }
                return url
            }
        }
        return nil
    }
}

// MARK: - 클립보드 기록

/// 최근에 복사한 글 몇 개를 기억해 섬에서 다시 복사합니다. 메모리에만 두고, 비밀번호 관리자가 표시한 항목은 건너뜁니다.
@MainActor
final class ClipboardHistory: ObservableObject {
    @Published private(set) var items: [String] = []
    private var lastChange = NSPasteboard.general.changeCount
    private var task: Task<Void, Never>?
    private var ignoreNext = false

    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    func apply() {
        let enabled = UserDefaults.standard.bool(forKey: AppSettings.clipboardEnabled)
        if enabled, task == nil {
            lastChange = NSPasteboard.general.changeCount
            task = Task { [weak self] in
                while !Task.isCancelled {
                    self?.poll()
                    try? await Task.sleep(nanoseconds: 800_000_000)
                }
            }
        } else if !enabled {
            task?.cancel()
            task = nil
            items = []
        }
    }

    private func poll() {
        let board = NSPasteboard.general
        guard board.changeCount != lastChange else { return }
        lastChange = board.changeCount
        if ignoreNext {
            ignoreNext = false
            return
        }
        let types = board.types ?? []
        guard !types.contains(Self.concealed), !types.contains(Self.transient),
              let text = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count < 20_000 else { return }
        items.removeAll { $0 == text }
        items.insert(text, at: 0)
        if items.count > 8 { items.removeLast(items.count - 8) }
    }

    func copy(_ text: String) {
        ignoreNext = true
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        items.removeAll { $0 == text }
        items.insert(text, at: 0)
        post(.init(key: "copied", symbol: "doc.on.clipboard.fill", tint: KongiTheme.accent,
                   title: String(localized: "Copied"), detail: String(text.prefix(40))), for: 1.8)
    }

    func clear() { items = [] }
}

// MARK: - 이번 주 리포트

/// 남아 있는 세션 기록으로 만든 이번 주 요약
struct WeeklyStats: Equatable {
    var sessions: Int
    var files: Int
    var added: Int
    var removed: Int
    var hours: Double
    var topProject: String?

    @MainActor
    static func make(from sessions: [AgentSession], now: Date = Date()) -> WeeklyStats {
        let start = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        let recent = sessions.filter { $0.updatedAt >= start }
        let hours = recent.reduce(0.0) { $0 + min($1.updatedAt.timeIntervalSince(max($1.startedAt, start)), 12 * 3600) } / 3600
        var byProject: [String: Int] = [:]
        for session in recent { byProject[session.projectName, default: 0] += session.activities.count }
        return WeeklyStats(
            sessions: recent.count,
            files: recent.reduce(0) { $0 + $1.changes.count },
            added: recent.reduce(0) { $0 + $1.added },
            removed: recent.reduce(0) { $0 + $1.removed },
            hours: max(hours, 0),
            topProject: byProject.max { $0.value < $1.value }?.key
        )
    }
}
