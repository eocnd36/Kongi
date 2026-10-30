import Foundation

/// ~/.claude/settings.json에 이 앱의 훅을 추가하거나 지웁니다.
/// 사용자가 직접 넣은 훅이나 다른 설정은 건드리지 않고, 우리 도우미를 가리키는 항목만 다룹니다.
public enum HookSettingsEditor {
    public struct EventSpec: Sendable {
        public var name: String
        /// 도구 이벤트만 matcher가 필요합니다.
        public var matchesTools: Bool
        /// 초. 승인·질문은 사람의 답을 기다리므로 길게 둡니다.
        public var timeout: Int
    }

    public static let events: [EventSpec] = [
        EventSpec(name: "SessionStart", matchesTools: false, timeout: 10),
        EventSpec(name: "SessionEnd", matchesTools: false, timeout: 10),
        EventSpec(name: "UserPromptSubmit", matchesTools: false, timeout: 10),
        EventSpec(name: "PreToolUse", matchesTools: true, timeout: 3600),
        EventSpec(name: "PostToolUse", matchesTools: true, timeout: 10),
        EventSpec(name: "PostToolUseFailure", matchesTools: true, timeout: 10),
        EventSpec(name: "PermissionRequest", matchesTools: true, timeout: 3600),
        EventSpec(name: "Notification", matchesTools: false, timeout: 10),
        EventSpec(name: "Stop", matchesTools: false, timeout: 10),
    ]

    /// 대화가 멈추면(끝남, 한도 등 오류) 뒤에서 기다렸다가 Kongi가 보내는 말로 같은 대화를 깨우는 도우미.
    /// Claude Code의 asyncRewake: 기다리는 동안 아무것도 막지 않고, 종료 코드 2로 끝나면 그 말이 대화에 전달됩니다.
    /// StopFailure를 모르는 예전 Claude Code에서도 나머지 훅은 그대로 동작합니다 (확인함).
    public static let waitEvents = ["Stop", "StopFailure"]
    public static let waitArgument = "--wait"
    /// 주간 초기화까지 기다릴 수 있게 8일
    public static let waitTimeout = 8 * 24 * 3600

    /// 셸 명령으로 쓸 수 있게 경로를 따옴표로 감쌉니다 ("Application Support"에 공백이 있음).
    public static func command(forHelperAt path: String) -> String {
        "\"\(path.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    static func isOurs(_ handler: Any) -> Bool {
        guard let handler = handler as? [String: Any], let command = handler["command"] as? String else { return false }
        return command.contains(HookPaths.helperName)
    }

    static func ourHandlers(_ hooks: [String: Any], event: String) -> [[String: Any]] {
        (hooks[event] as? [Any] ?? []).flatMap { group in
            ((group as? [String: Any])?["hooks"] as? [Any] ?? []).filter(isOurs).compactMap { $0 as? [String: Any] }
        }
    }

    static func isWaiter(_ handler: [String: Any]) -> Bool {
        (handler["command"] as? String)?.hasSuffix(" " + waitArgument) == true && handler["asyncRewake"] as? Bool == true
    }

    /// 기본 연동(세션 보기, 승인, 질문)이 설치돼 있는지
    public static func isInstalled(in settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { !ourHandlers(hooks, event: $0.name).filter { !isWaiter($0) }.isEmpty }
    }

    /// 멈춘 대화를 이어서 깨우는 도우미까지 설치돼 있는지 (예전 버전으로 연결했으면 false → "업데이트" 필요)
    public static func canContinue(in settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return waitEvents.allSatisfy { ourHandlers(hooks, event: $0).contains(where: isWaiter) }
    }

    /// 이미 설치돼 있으면 우리 항목을 새 명령으로 바꿔 끼웁니다 (중복 없음).
    public static func install(into settings: [String: Any], command: String) -> [String: Any] {
        var result = uninstall(from: settings)
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        for spec in events {
            var groups = hooks[spec.name] as? [Any] ?? []
            var group: [String: Any] = [
                "hooks": [["type": "command", "command": command, "timeout": spec.timeout] as [String: Any]],
            ]
            if spec.matchesTools { group["matcher"] = "*" }
            groups.append(group)
            hooks[spec.name] = groups
        }
        for event in waitEvents {
            var groups = hooks[event] as? [Any] ?? []
            groups.append([
                "hooks": [[
                    "type": "command", "command": command + " " + waitArgument,
                    "asyncRewake": true, "timeout": waitTimeout,
                ] as [String: Any]],
            ] as [String: Any])
            hooks[event] = groups
        }
        result["hooks"] = hooks
        return result
    }

    public static func uninstall(from settings: [String: Any]) -> [String: Any] {
        var result = settings
        guard var hooks = result["hooks"] as? [String: Any] else { return result }
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            let cleaned: [Any] = groups.compactMap { group in
                guard var group = group as? [String: Any], let handlers = group["hooks"] as? [Any] else { return group }
                let remaining = handlers.filter { !isOurs($0) }
                if remaining.isEmpty { return nil }
                group["hooks"] = remaining
                return group
            }
            hooks[event] = cleaned.isEmpty ? nil : cleaned
        }
        result["hooks"] = hooks.isEmpty ? nil : hooks
        return result
    }

    public static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return object
    }

    public static func serialize(_ settings: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(Data("\n".utf8))
        return data
    }
}
