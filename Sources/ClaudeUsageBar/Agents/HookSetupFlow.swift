import AppKit

/// 연동 설치·제거 전에 무엇이 바뀌는지 알리고 확인을 받습니다.
@MainActor
enum HookSetupFlow {
    /// 설치에 성공하면 true
    @discardableResult
    static func run() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "Connect Claude Code?")
        alert.informativeText = String(localized: "Kongi will add hooks to ~/.claude/settings.json so Claude Code can show its work, ask for approvals and send questions here. Your current file is backed up first, and your own settings are kept. Everything stays on this Mac. If Kongi isn't running, Claude Code works as usual.")
        alert.addButton(withTitle: String(localized: "Connect"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        do {
            let backup = try HookInstaller.install()
            let done = NSAlert()
            done.messageText = String(localized: "Claude Code is connected")
            var info = String(localized: "New Claude Code sessions will show up in the island. Sessions that are already running need to be restarted.")
            if let backup {
                info += "\n\n" + String(localized: "Backup: \(backup.path)")
            }
            done.informativeText = info
            done.runModal()
            return true
        } catch {
            show(error)
            return false
        }
    }

    static func uninstall() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "Disconnect Claude Code?")
        alert.informativeText = String(localized: "Only the hooks added by Kongi are removed from ~/.claude/settings.json. A backup is made first.")
        alert.addButton(withTitle: String(localized: "Remove"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        do {
            try HookInstaller.uninstall()
            return true
        } catch {
            show(error)
            return false
        }
    }

    private static func show(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
