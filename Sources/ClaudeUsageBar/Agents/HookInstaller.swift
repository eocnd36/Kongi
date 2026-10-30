import ClaudeUsageCore
import Foundation

/// Claude Code 연동(훅) 설치·제거. ~/.claude/settings.json을 고치기 전에 항상 백업합니다.
enum HookInstaller {
    enum InstallError: LocalizedError {
        case helperMissing
        case invalidSettings

        var errorDescription: String? {
            switch self {
            case .helperMissing:
                return String(localized: "The hook helper is missing from the app. Reinstall Kongi.")
            case .invalidSettings:
                return String(localized: "~/.claude/settings.json isn't valid JSON, so it was left unchanged. Fix it and try again.")
            }
        }
    }

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// 앱 번들 안의 도우미 (Contents/MacOS/claude-usage-hook)
    static var bundledHelper: URL? {
        Bundle.main.url(forAuxiliaryExecutable: HookPaths.helperName)
    }

    static var command: String {
        HookSettingsEditor.command(forHelperAt: HookPaths.installedHelper.path)
    }

    static var isInstalled: Bool {
        guard FileManager.default.isExecutableFile(atPath: HookPaths.installedHelper.path) else { return false }
        return cachedStatus().installed
    }

    /// settings.json은 화면이 다시 그려질 때마다 읽지 않고, 파일이 바뀌었을 때만 다시 읽습니다.
    private static var cache: (modified: Date?, size: Int, installed: Bool, canContinue: Bool)?

    private static func cachedStatus() -> (installed: Bool, canContinue: Bool) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: settingsURL.path)
        let modified = attributes?[.modificationDate] as? Date
        let size = attributes?[.size] as? Int ?? -1
        if let cache, cache.modified == modified, cache.size == size { return (cache.installed, cache.canContinue) }
        let settings = (try? HookSettingsEditor.parse(try? Data(contentsOf: settingsURL))) ?? [:]
        let status = (HookSettingsEditor.isInstalled(in: settings), HookSettingsEditor.canContinue(in: settings))
        cache = (modified, size, status.0, status.1)
        return status
    }

    /// 멈춘 대화를 이어서 깨우는 도우미까지 연결돼 있는지. 예전 버전으로 연결했으면 "업데이트"가 필요합니다.
    static var canContinue: Bool { cachedStatus().canContinue }

    /// 설치하면 settings.json의 백업 경로를 돌려줍니다 (원래 파일이 없었으면 nil).
    @discardableResult
    static func install() throws -> URL? {
        try copyHelper()
        let fm = FileManager.default
        let existing = try? Data(contentsOf: settingsURL)
        guard let settings = try? HookSettingsEditor.parse(existing) else { throw InstallError.invalidSettings }

        var backup: URL?
        if let existing {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let url = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.backup-\(stamp)")
            try existing.write(to: url)
            backup = url
        } else {
            try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let updated = HookSettingsEditor.install(into: settings, command: command)
        try HookSettingsEditor.serialize(updated).write(to: settingsURL, options: .atomic)
        return backup
    }

    static func uninstall() throws {
        if let existing = try? Data(contentsOf: settingsURL) {
            guard let settings = try? HookSettingsEditor.parse(existing) else { throw InstallError.invalidSettings }
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try existing.write(to: settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.backup-\(stamp)"))
            try HookSettingsEditor.serialize(HookSettingsEditor.uninstall(from: settings)).write(to: settingsURL, options: .atomic)
        }
        try? FileManager.default.removeItem(at: HookPaths.installedHelper)
    }

    /// 앱을 업데이트하면 설치된 도우미도 새 버전으로 바꿔 둡니다.
    static func refreshHelperIfInstalled() {
        guard FileManager.default.fileExists(atPath: HookPaths.installedHelper.path) else { return }
        try? copyHelper()
    }

    private static func copyHelper() throws {
        guard let source = bundledHelper else { throw InstallError.helperMissing }
        let fm = FileManager.default
        let destination = HookPaths.installedHelper
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.appendingPathExtension("new")
        try? fm.removeItem(at: temporary)
        try fm.copyItem(at: source, to: temporary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        // 실행 중인 훅이 있어도 깨지지 않도록 바꿔치기합니다.
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: destination)
        }
    }
}
