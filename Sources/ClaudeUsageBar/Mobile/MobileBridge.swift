import AppKit
import Combine
import ClaudeUsageCore
import Darwin
import Foundation
import os

/// 안드로이드 앱과 Mac을 같은 Wi-Fi 안에서 잇습니다: 상태 보기, 승인·질문 응답, 프롬프트 보내기, 알림.
///
/// 모든 요청은 `POST /rpc`, 실시간 업데이트는 `POST /events` 하나로 오갑니다. 본문은 QR 코드로 나눈 키로 봉인되어 있고
/// (PhoneCipher), 열리지 않거나 오래됐거나 다시 보낸 요청은 거절합니다.
@MainActor
final class MobileBridge: ObservableObject {
    typealias Reply = (status: Int, body: [String: Any])

    struct Config: Codable {
        /// 휴대폰과 나눈 키 (32바이트, base64)
        var key: String
        /// Bonjour 서비스 이름. 휴대폰이 바뀐 IP로 다시 찾을 때 씁니다.
        var id: String
    }

    /// 서버가 포트를 실제로 잡고 듣는 중인지 (.ready)
    @Published private(set) var running = false
    /// 지금 연결된 휴대폰 수 (실시간 업데이트를 받는 중)
    @Published private(set) var connectedPhones = 0
    /// QR 코드에 넣을 이 Mac의 사설망 주소
    @Published private(set) var addresses: [String] = []
    /// 켜기를 요청했는지 (포트를 잡기 전에도 true)
    private var active = false

    private let agents: AgentStore
    private let usage: UsageStore
    private let scheduler: PromptScheduler
    private let server = MobileServer()
    private var config: Config
    private var cipher: PhoneCipher
    private var replay = ReplayGuard()
    private var streams: [ObjectIdentifier: (connection: MobileConnection, nonce: Data)] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var pingTask: Task<Void, Never>?
    private let log = Logger(subsystem: "io.github.claudeusagebar", category: "mobile")

    private static var configURL: URL { HookPaths.supportDirectory.appendingPathComponent("phone.json") }

    init(agents: AgentStore, usage: UsageStore, scheduler: PromptScheduler) {
        self.agents = agents
        self.usage = usage
        self.scheduler = scheduler
        Self.removeTailscaleSetup()
        if let data = try? Data(contentsOf: Self.configURL), let saved = try? JSONDecoder().decode(Config.self, from: data),
           let cipher = Data(base64Encoded: saved.key).flatMap(PhoneCipher.init(keyData:)) {
            config = saved
            self.cipher = cipher
        } else {
            let key = PhoneCipher.newKeyData()
            config = Config(key: key.base64EncodedString(), id: "kongi-" + UUID().uuidString.prefix(8).lowercased())
            cipher = PhoneCipher(keyData: key)!
        }
    }

    var enabled: Bool { UserDefaults.standard.bool(forKey: AppSettings.mobileEnabled) }

    // MARK: Lifecycle

    func applySettings() {
        if enabled { start() } else { stop() }
    }

    private func start() {
        guard !active else { return }
        active = true
        server.onRequest = { [weak self] request, connection in self?.handle(request, connection) }
        server.onReadyChange = { [weak self] ready in
            guard let self else { return }
            self.running = self.active && ready
            if !ready, self.active { self.log.error("Phone server isn't listening on its port") }
        }
        do {
            try server.start(serviceName: config.id)
            saveConfig()
        } catch {
            log.error("Phone server failed: \(error.localizedDescription, privacy: .public)")
            running = false
            return
        }
        agents.objectWillChange.merge(with: usage.objectWillChange, scheduler.objectWillChange)
            // Claude가 쉬지 않고 일해도 밀리지 않게, 모아서 0.5초마다 한 번씩 보냅니다.
            .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in Task { @MainActor in self?.broadcast() } }
            .store(in: &cancellables)
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25 * NSEC_PER_SEC)
                self?.streams.values.forEach { $0.connection.ping() }
            }
        }
        refreshAddresses()
    }

    private func stop() {
        active = false
        server.stop()
        running = false
        cancellables.removeAll()
        pingTask?.cancel()
        dropStreams()
    }

    private func dropStreams() {
        streams.values.forEach { $0.connection.connection.cancel() }
        streams.removeAll()
        connectedPhones = 0
    }

    // MARK: Pairing

    /// 휴대폰 카메라로 찍을 연결 주소 (키 포함). QR 코드로 보여 줍니다.
    var pairingURL: URL? {
        guard !addresses.isEmpty, let key = Data(base64Encoded: config.key) else { return nil }
        let name = Host.current().localizedName ?? "Mac"
        return PhonePairing(id: config.id, name: name, hosts: addresses, port: MobileServer.port, key: key).url
    }

    /// Wi-Fi·유선의 사설망 IPv4 주소. 기본 인터페이스(en0)가 먼저 옵니다.
    func refreshAddresses() {
        var found: [(name: String, address: String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = pointer.pointee
            let flags = Int32(item.ifa_flags)
            guard let socket = item.ifa_addr, socket.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: item.ifa_name)
            // VPN 터널(utun 등)은 휴대폰이 들어올 수 없는 주소라 뺍니다.
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            let bytes = socket.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                withUnsafeBytes(of: pointer.pointee.sin_addr) { [UInt8]($0) }
            }
            guard LocalNetwork.isLocal(ipv4: bytes), bytes[0] != 169 else { continue }
            found.append((name, bytes.map(String.init).joined(separator: ".")))
        }
        addresses = found.sorted { $0.name < $1.name }.map(\.address)
    }

    /// 새 키를 만들어 연결된 휴대폰을 모두 끊습니다. 휴대폰은 QR 코드를 다시 찍어야 합니다.
    func resetPairing() {
        let key = PhoneCipher.newKeyData()
        config.key = key.base64EncodedString()
        cipher = PhoneCipher(keyData: key)!
        replay = ReplayGuard()
        saveConfig()
        dropStreams()
        objectWillChange.send()
    }

    private func saveConfig() {
        try? FileManager.default.createDirectory(at: HookPaths.supportDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: Self.configURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.configURL.path)
    }

    /// 예전 버전(Tailscale + 웹 푸시)이 남긴 설정을 지웁니다. 공개해 둔 적이 있으면 그 공개도 한 번 거둡니다.
    private static func removeTailscaleSetup() {
        let legacy = HookPaths.supportDirectory.appendingPathComponent("mobile.json")
        guard let data = try? Data(contentsOf: legacy) else { return }
        let published = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["published"] as? Bool == true
        try? FileManager.default.removeItem(at: legacy)
        guard published else { return }
        let cli = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let cli else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["serve", "--https=443", "off"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    // MARK: Routing

    private func handle(_ request: HTTPRequest, _ connection: MobileConnection) {
        guard request.method == "POST", request.path == "/rpc" || request.path == "/events",
              let nonce = PhoneCipher.nonce(of: request.body),
              let plain = try? cipher.open(request.body, context: PhoneCipher.requestContext),
              let envelope = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any],
              let sentAt = envelope["t"] as? Double,
              replay.accept(nonce: nonce, sentAt: Date(timeIntervalSince1970: sentAt)) else {
            // 키가 다르거나(다시 연결 필요) 시계가 크게 어긋났습니다.
            return connection.respond(.text("Forbidden", status: 403))
        }
        if request.path == "/events" {
            let id = ObjectIdentifier(connection)
            streams[id] = (connection, nonce)
            connectedPhones = streams.count
            connection.onClose = { [weak self] in
                self?.streams[id] = nil
                self?.connectedPhones = self?.streams.count ?? 0
            }
            connection.startStream()
            send("state", state(), to: connection, nonce: nonce)
            return
        }
        let method = envelope["m"] as? String ?? "GET"
        let path = envelope["p"] as? String ?? ""
        let body = envelope["b"] as? [String: Any] ?? [:]
        let reply = route(method: method, path: path, body: body)
        let data = (try? JSONSerialization.data(withJSONObject: ["s": reply.status, "b": reply.body], options: [.withoutEscapingSlashes])) ?? Data()
        guard let sealed = try? cipher.seal(data, context: PhoneCipher.replyContext(nonce)) else {
            return connection.respond(.text("Error", status: 500))
        }
        connection.respond(HTTPResponse(status: 200, headers: ["Content-Type": "application/octet-stream", "Cache-Control": "no-store"], body: sealed))
    }

    private func route(method: String, path: String, body: [String: Any]) -> Reply {
        let parts = path.split(separator: "/").map(String.init) // ["api", ...]
        switch (method, parts.dropFirst().first ?? "") {
        case ("GET", "state"):
            return (200, state())
        case ("GET", "sessions"):
            guard parts.count >= 3, let session = agents.session(parts[2]) else { return (404, ["error": "not found"]) }
            return (200, detail(session))
        case ("POST", "requests"):
            guard parts.count >= 3 else { return (400, ["error": "bad request"]) }
            return answer(requestId: parts[2], body: body)
        case ("POST", "prompt"):
            return sendPrompt(body)
        case ("POST", "continue"):
            guard let id = body["sessionId"] as? String, let session = agents.session(id) else { return (404, ["error": "not found"]) }
            scheduler.scheduleContinue(session: session, trigger: .sessionReset)
            return (200, ["ok": true])
        case ("POST", "test"):
            notify(title: String(localized: "Test notification"), body: String(localized: "Notifications from Kongi are working."))
            return (200, ["ok": true])
        default:
            return (404, ["error": "not found"])
        }
    }

    /// 실시간 업데이트 하나를 봉인해서 보냅니다. 스트림마다 연 요청의 nonce로 묶여 다른 스트림에 끼워 넣을 수 없습니다.
    private func send(_ event: String, _ data: [String: Any], to connection: MobileConnection, nonce: Data) {
        guard let plain = try? JSONSerialization.data(withJSONObject: ["e": event, "d": data], options: [.withoutEscapingSlashes]),
              let sealed = try? cipher.seal(plain, context: PhoneCipher.eventContext(nonce)) else { return }
        connection.send(event: "m", data: sealed.base64EncodedString())
    }

    private func broadcast() {
        guard !streams.isEmpty else { return }
        let current = state()
        streams.values.forEach { send("state", current, to: $0.connection, nonce: $0.nonce) }
    }

    /// 휴대폰 앱에 알림을 띄웁니다 (켜 둔 경우). 승인·질문은 휴대폰이 상태를 보고 직접 띄우므로 여기로 오지 않습니다.
    func notify(title: String, body: String) {
        guard running, UserDefaults.standard.bool(forKey: AppSettings.mobileNotifications), !streams.isEmpty else { return }
        streams.values.forEach { send("notify", ["title": title, "body": body], to: $0.connection, nonce: $0.nonce) }
    }

    // MARK: State

    private static let iso = ISO8601DateFormatter()

    private func state() -> [String: Any] {
        let now = Date()
        let limits: [[String: Any]] = (usage.snapshot?.limits ?? []).map { item in
            [
                "kind": item.kind.rawValue,
                "title": item.kind.title,
                "percent": item.percent,
                "reset": Formatters.resetDescription(item.resetsAt, now: now),
                "severity": item.percent >= 90 ? "critical" : item.percent >= 70 ? "warning" : "normal",
            ]
        }
        let sessions: [[String: Any]] = agents.sessions.prefix(30).map { session in
            [
                "id": session.id,
                "project": session.projectName,
                "state": session.state.label,
                "attention": session.state.needsAttention,
                "busy": session.state.isBusy,
                "ended": session.state == .ended,
                "updated": Self.iso.string(from: session.updatedAt),
                "added": session.added,
                "removed": session.removed,
                "terminal": TerminalJumper.appName(for: session.context) ?? "",
                "canType": TerminalJumper.canType(into: session.context),
                "continueScheduled": scheduler.pendingContinue(sessionId: session.id) != nil,
                // 지금 하는 일 (목록에서 실시간으로 보여 줌)
                "step": session.activities.last(where: { $0.status == .running }).map { $0.activity.label } ?? "",
                "stepKind": session.activities.last(where: { $0.status == .running })?.activity.kind.rawValue ?? "",
                "thinking": session.state == .thinking || session.state == .starting,
                "done": session.state == .done,
                "mood": Self.mood(of: session).rawValue,
                // 최근 단계 세 개 (휴대폰의 단계 줄기)
                "steps": session.activities.suffix(3).map { activity in
                    [
                        "id": activity.id,
                        "title": activity.activity.target.isEmpty ? activity.activity.verb : activity.activity.target,
                        "status": activity.status.rawValue,
                    ]
                },
            ]
        }
        let requests: [[String: Any]] = agents.requests.map { request in
            var item: [String: Any] = [
                "id": request.id.uuidString,
                "sessionId": request.sessionId,
                "project": agents.session(request.sessionId)?.projectName ?? "",
            ]
            switch request.kind {
            case let .permission(info):
                item["kind"] = "permission"
                item["tool"] = info.toolName
                item["title"] = String(localized: "Allow \(info.toolName)?")
                item["detail"] = info.detail
                item["rules"] = PermissionRule.rules(in: info.suggestions).map { "\($0.text) · \($0.scopeLabel)" }
            case let .question(questions, _):
                item["kind"] = "question"
                item["questions"] = questions.map { question in
                    [
                        "question": question.question,
                        "header": question.header ?? "",
                        "multiSelect": question.multiSelect,
                        "options": question.options.map { ["label": $0.label, "description": $0.description ?? ""] },
                    ] as [String: Any]
                }
            }
            return item
        }
        var result: [String: Any] = [
            "mac": Host.current().localizedName ?? "Mac",
            "plan": usage.credentials?.planName ?? "",
            "limits": limits,
            "sessions": sessions,
            "requests": requests,
            "updated": Self.iso.string(from: now),
        ]
        if let status = usage.serviceStatus, status.hasProblem {
            result["outage"] = ["summary": status.summary, "incidents": status.incidents.map(\.name)]
        }
        return result
    }

    /// 콩이 기분: 끝난 세션은 잠, 방금 명령이 실패했으면 시무룩
    private static func mood(of session: AgentSession) -> Kongi.Mood {
        if session.state == .ended { return .sleeping }
        if !session.state.isBusy, let last = session.activities.last, last.status == .failed,
           Date().timeIntervalSince(last.date) < 5 { return .sad }
        return AgentStore.mood(of: session)
    }

    private func detail(_ session: AgentSession) -> [String: Any] {
        [
            "id": session.id,
            "project": session.projectName,
            "state": session.state.label,
            "busy": session.state.isBusy,
            "thinking": session.state == .thinking || session.state == .starting,
            "updated": Self.iso.string(from: session.updatedAt),
            "activities": session.activities.suffix(60).reversed().map { activity in
                var item: [String: Any] = [
                    "id": activity.id,
                    "kind": activity.activity.kind.rawValue,
                    "label": activity.activity.label,
                    "status": activity.status.rawValue,
                    "time": Self.iso.string(from: activity.date),
                ]
                if let output = activity.output { item["output"] = output }
                if let preview = activity.preview {
                    item["preview"] = preview.hunks.flatMap(\.lines).filter { $0.kind != .context }.prefix(12).map { line in
                        ["k": line.kind.rawValue, "t": line.text]
                    }
                }
                return item
            },
            "messages": session.messages.suffix(40).reversed().map { message in
                [
                    "id": message.id,
                    "role": message.role.rawValue,
                    "text": message.text,
                    "time": Self.iso.string(from: message.date),
                    "queued": message.queued == true,
                ] as [String: Any]
            },
            "changes": session.changes.map { change in
                [
                    "name": change.name,
                    "path": Formatters.relativePath(change.path, in: session.cwd),
                    "added": change.diff.added,
                    "removed": change.diff.removed,
                    // 휴대폰으로 보내는 줄 수를 제한합니다.
                    "hunks": change.diff.hunks.prefix(30).map { hunk in
                        hunk.lines.prefix(200).map { line in
                            ["k": line.kind.rawValue, "t": line.text, "n": line.newNumber ?? line.oldNumber ?? 0] as [String: Any]
                        }
                    },
                ] as [String: Any]
            },
        ]
    }

    // MARK: Actions

    private func answer(requestId: String, body: [String: Any]) -> Reply {
        guard let request = agents.requests.first(where: { $0.id.uuidString == requestId }) else {
            return (409, ["error": "This request was already answered."])
        }
        switch body["action"] as? String {
        case "allow": agents.allow(request)
        case "always": agents.allow(request, always: true)
        case "deny": agents.deny(request)
        case "terminal": agents.replyInTerminal(request)
        case "answer":
            let answers = body["answers"] as? [String: String] ?? [:]
            agents.answer(request, answers: answers)
        default:
            return (400, ["error": "bad request"])
        }
        return (200, ["ok": true])
    }

    /// 휴대폰에서 보낸 프롬프트: 그 대화의 터미널에 바로 입력하거나, 터미널이 없으면 같은 대화를 이어서 실행합니다.
    private func sendPrompt(_ body: [String: Any]) -> Reply {
        guard let text = (body["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let id = body["sessionId"] as? String, let session = agents.session(id) else {
            return (400, ["error": "bad request"])
        }
        switch agents.send(text, to: session.id, from: "Kongi on their phone") {
        case .sent: return (200, ["ok": true, "via": "conversation"])
        case .queued: return (200, ["ok": true, "via": "queued"])
        case .resumed: return (200, ["ok": true, "via": "resume"])
        case .needsUpdate: return (409, ["error": "update the Claude Code connection in Kongi on the Mac"])
        case .failed: return (500, ["error": "could not send"])
        }
    }
}
