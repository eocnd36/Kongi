import AppKit
import ClaudeUsageCore
import os

/// 세션이 실행 중인 터미널 창으로 이동합니다.
/// Terminal과 iTerm2는 정확한 탭까지 찾아가고, 그 밖의 앱은 앱을 앞으로 가져옵니다
/// (VS Code 계열은 해당 프로젝트 창).
@MainActor
enum TerminalJumper {
    private static let log = Logger(subsystem: "io.github.claudeusagebar", category: "terminal")

    /// VS Code 계열 → Claude Code 확장의 링크 주소 (scheme://anthropic.claude-code/open?session=…)
    private static let vscodeSchemes: [String: String] = [
        "com.microsoft.VSCode": "vscode",
        "com.microsoft.VSCodeInsiders": "vscode-insiders",
        "com.todesktop.230313mzl4w4u92": "cursor",
        "com.exafunction.windsurf": "windsurf",
        "com.vscodium": "vscodium",
    ]

    /// TERM_PROGRAM 값 → 번들 ID (__CFBundleIdentifier가 없을 때)
    private static let termPrograms: [String: String] = [
        "Apple_Terminal": "com.apple.Terminal",
        "iTerm.app": "com.googlecode.iterm2",
        "WarpTerminal": "dev.warp.Warp-Stable",
        "ghostty": "com.mitchellh.ghostty",
        "WezTerm": "com.github.wez.wezterm",
        "vscode": "com.microsoft.VSCode",
    ]

    static func bundleId(for context: HookContext) -> String? {
        context.bundleId ?? context.termProgram.flatMap { termPrograms[$0] }
    }

    static func appName(for context: HookContext) -> String? {
        guard let id = bundleId(for: context), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            return context.termProgram
        }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func jump(to session: AgentSession) {
        let context = session.context
        let bundleId = bundleId(for: context)

        if let tty = context.tty {
            if bundleId == "com.apple.Terminal", runScript(terminalScript(tty: tty)) { return }
            if bundleId == "com.googlecode.iterm2", runScript(itermScript(tty: tty)) { return }
        }
        if let bundleId, let scheme = vscodeSchemes[bundleId] {
            jumpToEditor(session, bundleId: bundleId, scheme: scheme)
            return
        }
        if let bundleId, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            app.activate(options: [.activateAllWindows])
            return
        }
        if let bundleId, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// VS Code 계열: 대화가 있는 창을 앞으로 가져오고, 확장에서 실행된 대화면 그 대화 탭을 엽니다.
    /// 대화 중 `cd`로 바뀐 cwd를 열면 새 창이 생기므로, 대화를 시작한 폴더(작업 영역)만 씁니다.
    private static func jumpToEditor(_ session: AgentSession, bundleId: String, scheme: String) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
        let inExtension = session.context.entrypoint.map { $0.contains("vscode") } ?? (session.context.tty == nil)
        let link = inExtension && UUID(uuidString: session.id) != nil
            ? URL(string: "\(scheme)://anthropic.claude-code/open?session=\(session.id)") : nil

        // 창이 여러 개면 그 작업 영역 창으로 (이미 열린 폴더는 새 창 없이 그 창이 앞으로 옴).
        // 창이 하나뿐이거나 시작 폴더를 모르면 앱만 앞으로 가져옵니다.
        if let directory = session.launchDirectory, let running, windowCount(of: running) > 1 {
            NSWorkspace.shared.open([URL(fileURLWithPath: directory)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else if let running {
            running.activate(options: [.activateAllWindows])
        } else {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
        guard let link else { return }
        // 링크는 마지막으로 앞에 있던 창이 받으므로, 창이 바뀐 다음에 엽니다.
        DispatchQueue.main.asyncAfter(deadline: .now() + (running == nil ? 2.0 : 0.4)) {
            NSWorkspace.shared.open(link)
        }
    }

    /// 앱의 일반 창 개수 (화면 녹화 권한 없이도 개수는 알 수 있음)
    private static func windowCount(of app: NSRunningApplication) -> Int {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return 0 }
        return list.filter {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
                && ($0[kCGWindowLayer as String] as? Int) == 0
                && (($0[kCGWindowBounds as String] as? [String: CGFloat])?["Height"] ?? 0) > 200
        }.count
    }

    /// 이 터미널에 직접 입력할 수 있는지 (Terminal, iTerm)
    static func canType(into context: HookContext) -> Bool {
        guard context.tty != nil else { return false }
        return ["com.apple.Terminal", "com.googlecode.iterm2"].contains(bundleId(for: context) ?? "")
    }

    /// 세션이 실행 중인 터미널에 글자를 입력하고 Return을 보냅니다 (Terminal, iTerm만 정확한 탭을 찾을 수 있음).
    /// 실제로 보냈으면 true.
    static func send(_ text: String, to context: HookContext) -> Bool {
        guard let tty = context.tty else { return false }
        // 여러 줄은 첫 줄에서 바로 전송되므로 한 줄로 합칩니다.
        let line = escaped(text.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " "))
        switch bundleId(for: context) {
        case "com.apple.Terminal":
            return runScript("""
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(escaped(tty))" then
                            do script "\(line)" in t
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
            """)
        case "com.googlecode.iterm2":
            return runScript("""
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(escaped(tty))" then
                                tell s to write text "\(line)"
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
            """)
        default:
            return false
        }
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func terminalScript(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(escaped(tty))" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
    }

    private static func itermScript(tty: String) -> String {
        """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(escaped(tty))" then
                            select w
                            tell t to select
                            tell s to select
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
        """
    }

    /// 처음 한 번은 macOS가 "Kongi가 Terminal을 제어하려고 합니다" 허용을 묻습니다.
    private static func runScript(_ source: String) -> Bool {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            log.error("AppleScript failed: \(error, privacy: .public)")
            return false
        }
        return result?.booleanValue ?? false
    }
}
