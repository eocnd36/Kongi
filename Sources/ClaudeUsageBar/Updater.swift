import AppKit
import ClaudeUsageCore
import os
import SwiftUI

/// GitHub 릴리스로 앱을 업데이트합니다.
///
/// 켤 때와 12시간마다 최신 릴리스를 확인하고, 새 버전이 있으면 아일랜드와 알림으로 알려 줍니다.
/// "지금 업데이트"를 누르면 zip과 서명을 내려받아 **서명이 맞을 때만** 앱을 바꾸고 다시 엽니다.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppUpdate.Release)
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?

    private var loop: Task<Void, Never>?
    private let log = Logger(subsystem: "io.github.claudeusagebar", category: "update")

    /// 이 빌드가 업데이트를 받을 수 있는지 (저장소 주소와 숫자 버전이 있는 배포 빌드만)
    var isSupported: Bool {
        AppInfo.repositoryURL.flatMap(AppUpdate.latestReleaseURL(repository:)) != nil
            && AppUpdate.isNewer(AppInfo.version, than: "0")
    }

    func start() {
        loop?.cancel()
        let defaults = UserDefaults.standard
        // 알림이나 자동 설치 중 하나라도 켜져 있으면 확인합니다.
        guard isSupported, defaults.bool(forKey: AppSettings.checkForUpdates) || defaults.bool(forKey: AppSettings.autoInstallUpdates) else { return }
        loop = Task { [weak self] in
            // 켜자마자 네트워크를 쓰지 않도록 잠시 기다렸다가
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            while !Task.isCancelled {
                await self?.check(userInitiated: false)
                try? await Task.sleep(nanoseconds: 12 * 3600 * 1_000_000_000)
            }
        }
    }

    // MARK: Checking

    func check(userInitiated: Bool) async {
        guard isSupported, let repository = AppInfo.repositoryURL,
              let api = AppUpdate.latestReleaseURL(repository: repository) else { return }
        if case .installing = state { return }
        state = .checking
        var request = URLRequest(url: api, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Kongi/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            lastChecked = Date()
            guard (response as? HTTPURLResponse)?.statusCode == 200, let release = AppUpdate.parseRelease(data) else {
                state = userInitiated ? .failed(String(localized: "Couldn't check for updates.")) : .idle
                return
            }
            if AppUpdate.isNewer(release.version, than: AppInfo.version) {
                state = .available(release)
                if !userInitiated, UserDefaults.standard.bool(forKey: AppSettings.autoInstallUpdates) {
                    await installWhenIdle()
                } else if userInitiated || UserDefaults.standard.bool(forKey: AppSettings.checkForUpdates) {
                    announce(release)
                }
            } else {
                state = .upToDate
            }
        } catch {
            log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            state = userInitiated ? .failed(String(localized: "Couldn't check for updates.")) : .idle
        }
    }

    /// 새 버전마다 한 번만 알립니다.
    private func announce(_ release: AppUpdate.Release) {
        let key = "lastAnnouncedUpdate"
        guard UserDefaults.standard.string(forKey: key) != release.version else { return }
        UserDefaults.standard.set(release.version, forKey: key)
        let title = String(localized: "Kongi \(release.version) is available")
        AppServices.shared.devices.post(.init(
            key: "update-\(release.version)", symbol: "arrow.down.circle.fill", tint: .green,
            title: title, detail: String(localized: "Click to update"), action: .openAbout
        ), for: 8)
        Notifier.post(title: title, body: String(localized: "Open Kongi Settings → About to update."), phone: false)
    }

    // MARK: Installing

    /// 자동 설치: Claude·Codex가 일하는 중이면 다시 열리지 않게 끝날 때까지 기다립니다 (최대 6시간, 1분마다 확인).
    private func installWhenIdle() async {
        for _ in 0..<360 {
            // 기다리는 동안 설정을 끄거나 확인이 다시 시작되면(취소) 설치하지 않습니다.
            guard !Task.isCancelled, UserDefaults.standard.bool(forKey: AppSettings.autoInstallUpdates) else { return }
            if !AppServices.shared.agents.activeSessions.contains(where: { $0.state.isBusy }) {
                await install()
                return
            }
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        }
    }

    func install() async {
        guard case let .available(release) = state else { return }
        state = .installing
        do {
            try await replaceApp(with: release)
        } catch let failure as Failure {
            state = .failed(failure.message)
        } catch {
            log.error("Update failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(String(localized: "Couldn't update. You can download the new version from GitHub."))
        }
    }

    private struct Failure: Error { let message: String }

    private func replaceApp(with release: AppUpdate.Release) async throws {
        let current = Bundle.main.bundleURL
        let fileManager = FileManager.default
        guard current.pathExtension == "app", fileManager.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            throw Failure(message: String(localized: "Kongi can't replace itself in this folder. Download the new version from GitHub."))
        }

        // 1. zip과 서명을 내려받아 서명부터 확인합니다.
        let (archive, _) = try await URLSession.shared.download(from: release.archiveURL)
        let (signature, _) = try await URLSession.shared.data(from: release.signatureURL)
        guard AppUpdate.verify(try Data(contentsOf: archive), signature: signature) else {
            throw Failure(message: String(localized: "The download couldn't be verified, so nothing was changed."))
        }

        // 2. 같은 디스크의 임시 폴더에 풀고, 같은 앱의 새 버전인지 확인합니다.
        let work = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: current, create: true)
        defer { try? fileManager.removeItem(at: work) }
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, work.path])
        let newApp = work.appendingPathComponent(current.lastPathComponent)
        let fallback = work.appendingPathComponent("Kongi.app")
        let candidate = fileManager.fileExists(atPath: newApp.path) ? newApp : fallback
        guard let bundle = Bundle(url: candidate),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              version == release.version else {
            throw Failure(message: String(localized: "The download wasn't the expected version, so nothing was changed."))
        }
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", candidate.path])

        // 3. 한 번에 바꿔 끼우고 다시 엽니다.
        _ = try fileManager.replaceItemAt(current, withItemAt: candidate)
        relaunch(current)
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure(message: String(localized: "Couldn't update. You can download the new version from GitHub.")) }
    }

    /// 지금 앱이 끝난 뒤 새 앱을 엽니다.
    private func relaunch(_ app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1.5; /usr/bin/open \"$0\"", app.path]
        try? process.run()
        AppServices.shared.agents.flushHistory()
        NSApp.terminate(nil)
    }
}

/// 설정 → 정보의 업데이트 줄
struct UpdateSection: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(spacing: 10) {
            switch updater.state {
            case .idle, .upToDate, .failed:
                if case .upToDate = updater.state {
                    Label("Kongi is up to date", systemImage: "checkmark.circle.fill").foregroundStyle(KongiTheme.green)
                }
                if case let .failed(message) = updater.state {
                    Text(verbatim: message).foregroundStyle(KongiTheme.orange).multilineTextAlignment(.center)
                }
                KButton(title: String(localized: "Check for updates"), symbol: "arrow.clockwise") {
                    Task { await updater.check(userInitiated: true) }
                }
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(KongiTheme.secondary)
            case let .available(release):
                Text("Kongi \(release.version) is available").font(.system(size: 14, weight: .semibold))
                HStack(spacing: 8) {
                    KButton(title: String(localized: "Update now"), symbol: "arrow.down.circle", style: .primary) {
                        Task { await updater.install() }
                    }
                    KButton(title: String(localized: "Release notes"), symbol: "arrow.up.right") {
                        NSWorkspace.shared.open(release.pageURL)
                    }
                }
            case .installing:
                ProgressView().controlSize(.small)
                Text("Updating… Kongi will reopen when it's done.").foregroundStyle(KongiTheme.secondary)
            }
        }
        .font(.system(size: 12))
        .animation(.easeInOut(duration: 0.2), value: updater.state)
    }
}
