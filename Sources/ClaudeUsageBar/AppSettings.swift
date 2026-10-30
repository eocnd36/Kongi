import AppKit
import ClaudeUsageCore
import Foundation
import ServiceManagement

enum AppSettings {
    static let menuBarStyle = "menuBarStyle"
    /// GitHub 릴리스에서 새 버전을 자동으로 확인 (켤 때와 12시간마다)
    static let checkForUpdates = "checkForUpdates"
    static let refreshMinutes = "refreshMinutes"
    static let connected = "connected"
    /// 사용량 알림 켜기/끄기와 기준 (쉼표로 구분한 퍼센트, 예: "80,95")
    static let notificationsEnabled = "notificationsEnabled"
    static let alertThresholdsKey = "alertThresholds"
    /// 초기화 전 알림 / 초기화되면 알림, 그리고 두 알림에 공통으로 쓰는 최소 사용률
    static let resetReminderEnabled = "resetReminderEnabled"
    static let resetReminderMinutes = "resetReminderMinutes"
    static let notifyOnReset = "notifyOnReset"
    static let resetReminderMinimumPercent = "resetReminderMinimumPercent"
    /// Claude 장애 알림
    static let statusAlertsEnabled = "statusAlertsEnabled"
    /// 알림과 함께 소리를 낼지
    static let notificationSound = "notificationSound"
    /// 발생 알림을 보낸, 아직 복구되지 않은 장애 (ID → 이름)
    static let notifiedIncidents = "notifiedIncidents"
    /// Claude Code 아일랜드
    static let islandEnabled = "islandEnabled"
    /// 세션이 없으면 아일랜드를 숨길지 (노치 뒤로 숨음)
    static let islandAutoHide = "islandAutoHide"
    /// 권한 요청·질문을 아일랜드에서 받을지 (끄면 항상 터미널에서 묻습니다)
    static let approvalsInIsland = "approvalsInIsland"
    /// 아일랜드에서 답이 없으면 몇 초 뒤 터미널로 넘길지 (0 = 넘기지 않음)
    static let approvalFallbackSeconds = "approvalFallbackSeconds"
    /// 작업 완료·승인 필요 알림
    static let agentNotifications = "agentNotifications"

    static let approvalFallbackOptions = [30, 60, 120, 300, 0]
    /// 아일랜드 모드: Claude Code 전용(콩이) 또는 아이폰 같은 다이나믹 아일랜드(음악 등, 캐릭터 없음)
    static let islandModeKey = "islandMode"
    /// 펼친 아일랜드에 CPU·GPU·메모리·저장공간 표시
    static let showSystemStats = "showSystemStats"
    /// 다이나믹 아일랜드에 잠깐 띄울 Mac의 일들 (아이폰처럼)
    static let islandShowsDevices = "islandShowsDevices"
    static let islandShowsCharging = "islandShowsCharging"
    static let islandShowsPrivacy = "islandShowsPrivacy"
    static let islandShowsVolume = "islandShowsVolume"
    /// 작업 완료 요약, 사용량 속도 경고 (아일랜드)
    static let islandShowsCompletion = "islandShowsCompletion"
    static let islandShowsPace = "islandShowsPace"
    /// 안드로이드 앱 연결 (같은 Wi-Fi)
    static let mobileEnabled = "mobileEnabled"
    /// 안드로이드 앱으로도 알림 보내기
    static let mobileNotifications = "mobileNotifications"

    static var islandMode: IslandMode {
        IslandMode(rawValue: UserDefaults.standard.string(forKey: islandModeKey) ?? "") ?? .claude
    }
    /// 세션 기록 보관 기간 (일, 0 = 남기지 않음)
    static let historyRetentionDaysKey = "historyRetentionDays"
    static let historyRetentionOptions = [1, 7, 30, 0]

    static var historyRetentionDays: Int {
        UserDefaults.standard.integer(forKey: historyRetentionDaysKey)
    }

    static let refreshOptions = [1, 2, 5, 10, 15, 30]
    static let maxAlertThresholds = 5
    static let resetReminderMinutesRange = 1...720
    static let minimumPercentRange = 0...100

    static func registerDefaults() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            menuBarStyle: MenuBarStyle.sessionAndWeekly.rawValue,
            checkForUpdates: true,
            refreshMinutes: 5,
            connected: false,
            notificationsEnabled: true,
            alertThresholdsKey: "80,95",
            resetReminderEnabled: true,
            resetReminderMinutes: 15,
            notifyOnReset: false,
            resetReminderMinimumPercent: 50,
            statusAlertsEnabled: true,
            notificationSound: true,
            islandEnabled: true,
            islandAutoHide: false,
            approvalsInIsland: true,
            approvalFallbackSeconds: 60,
            agentNotifications: true,
            historyRetentionDaysKey: 7,
            islandModeKey: IslandMode.claude.rawValue,
            showSystemStats: true,
            mobileEnabled: false,
            mobileNotifications: true,
            islandShowsDevices: true,
            islandShowsCharging: true,
            islandShowsPrivacy: true,
            // macOS도 음량을 띄우므로 기본은 꺼 둡니다.
            islandShowsVolume: false,
            islandShowsCompletion: true,
            islandShowsPace: true,
        ])
        // 1.0.0에서는 "0분 전"이 꺼짐을 뜻했습니다.
        if defaults.object(forKey: resetReminderMinutes) != nil, defaults.integer(forKey: resetReminderMinutes) == 0 {
            defaults.set(false, forKey: resetReminderEnabled)
            defaults.set(15, forKey: resetReminderMinutes)
        }
    }

    static var alertThresholds: [Int] {
        parseThresholds(UserDefaults.standard.string(forKey: alertThresholdsKey) ?? "")
    }

    static func parseThresholds(_ string: String) -> [Int] {
        let values = string.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return Array(Set(values.filter { (1...100).contains($0) })).sorted()
    }

    static func formatThresholds(_ values: [Int]) -> String {
        values.map(String.init).joined(separator: ",")
    }

    /// 알림을 하나라도 쓰면 알림 권한이 필요합니다.
    static var wantsNotifications: Bool {
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: notificationsEnabled)
            || defaults.bool(forKey: resetReminderEnabled)
            || defaults.bool(forKey: notifyOnReset)
            || defaults.bool(forKey: statusAlertsEnabled)
    }

    static var refreshInterval: TimeInterval {
        let minutes = UserDefaults.standard.integer(forKey: refreshMinutes)
        return TimeInterval(max(minutes, 1)) * 60
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// 빌드 스크립트가 Info.plist에 넣어 주는 저장소 주소 (CI에서는 자동으로 현재 저장소)
    static var repositoryURL: URL? {
        guard
            let string = Bundle.main.object(forInfoDictionaryKey: "ClaudeUsageBarRepositoryURL") as? String,
            !string.isEmpty
        else { return nil }
        return URL(string: string)
    }

    static let claudeCodeDocsURL = URL(string: "https://docs.claude.com/en/docs/claude-code/setup")!
    static let claudeUsageURL = URL(string: "https://claude.ai/settings/usage")!
}

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    private static let refreshedKey = "loginItemRegisteredName"

    /// macOS는 로그인 항목을 등록할 때의 앱 이름("Claude Usage Bar")을 기억합니다.
    /// 이름이 바뀐 뒤 한 번, 켜져 있으면 다시 등록해 시스템 설정에 새 이름과 아이콘이 보이게 합니다.
    static func refreshRegistrationIfRenamed() {
        let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "Kongi"
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: refreshedKey) != name else { return }
        guard isEnabled else {
            defaults.set(name, forKey: refreshedKey)
            return
        }
        // 지우는 것이 끝나기 전에 다시 등록하면 예전 기록이 그대로 남아, 잠시 뒤에 다시 등록합니다.
        SMAppService.mainApp.unregister { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if (try? SMAppService.mainApp.register()) != nil {
                    defaults.set(name, forKey: refreshedKey)
                }
            }
        }
    }
}

/// 앱 표시 언어. 기본은 시스템 언어를 따르고, 설정에서 바꾸면 앱을 다시 실행합니다.
enum AppLanguage {
    /// Resources/*.lproj 와 같은 목록
    static let supported = ["en", "ko", "ja", "zh-Hans", "zh-Hant", "es", "fr", "de", "it", "pt-BR", "ru"]

    private static let key = "AppleLanguages"

    /// 사용자가 앱에서 직접 고른 언어 (nil = 시스템 설정 따름)
    static var override: String? {
        guard let domain = Bundle.main.bundleIdentifier else { return nil }
        return (UserDefaults.standard.persistentDomain(forName: domain)?[key] as? [String])?.first
    }

    /// 각 언어 이름을 그 언어로 표시합니다 (예: 한국어, 日本語).
    static func nativeName(_ code: String) -> String {
        let locale = Locale(identifier: code)
        let name = locale.localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    static func set(_ code: String?) {
        if let code {
            UserDefaults.standard.set([code], forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.synchronize()
        relaunch()
    }

    private static func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }
}

enum IslandMode: String, CaseIterable, Identifiable {
    /// Claude Code 전용: 콩이가 있고, 세션이 없으면 숨길 수 있음
    case claude
    /// 아이폰 다이나믹 아일랜드처럼: 평소엔 작게, 음악·Claude 작업이 있을 때 넓어짐 (캐릭터 없음)
    case dynamic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return String(localized: "Claude Code (with Kongi)")
        case .dynamic: return String(localized: "Dynamic Island (music and more)")
        }
    }
}
