import AppKit
import ClaudeUsageCore
import Combine
import SwiftUI
import UserNotifications

@main
struct ClaudeUsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var store = AppServices.shared.usage
    @AppStorage(AppSettings.menuBarStyle) private var menuBarStyle = MenuBarStyle.sessionAndWeekly.rawValue

    init() {
        AppSettings.registerDefaults()
        AppSettings.registerExtrasDefaults()
    }

    /// "숨김"을 고르면 메뉴 막대에서 빠집니다. ⌘를 누른 채 끌어내도 숨김이 됩니다.
    private var menuBarShown: Binding<Bool> {
        Binding(
            get: { menuBarStyle != MenuBarStyle.hidden.rawValue },
            set: { shown in
                if !shown { menuBarStyle = MenuBarStyle.hidden.rawValue }
                else if menuBarStyle == MenuBarStyle.hidden.rawValue { menuBarStyle = MenuBarStyle.sessionAndWeekly.rawValue }
            }
        )
    }

    var body: some Scene {
        MenuBarExtra(isInserted: menuBarShown) {
            PopoverView()
                .environmentObject(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// 메뉴 막대와 아일랜드가 함께 쓰는 상태
@MainActor
final class AppServices: ObservableObject {
    static let shared = AppServices()

    let usage = UsageStore()
    let agents = AgentStore()
    private(set) lazy var scheduler = PromptScheduler(usage: usage)
    private(set) lazy var mobile = MobileBridge(agents: agents, usage: usage, scheduler: scheduler)
    let nowPlaying = NowPlayingMonitor()
    let system = SystemMonitor()
    let devices = DeviceEventsMonitor()
    let focus = FocusTimer()
    let github = GitHubWatcher()
    let ports = PortWatcher()
    let meetings = MeetingWatcher()
    let clipboard = ClipboardHistory()
    let pace = UsagePaceWatcher()
    let updater = Updater()
    let tasks = TaskBoard()
    let extensions = ExtensionStore()
    let systemAlerts = SystemAlerts()
    let phone = PhoneBanners()
    private var extrasObserver: AnyCancellable?

    /// 설정이 바뀌면 켜고 끕니다.
    func startExtras() {
        pace.start(usage: usage)
        applyExtras()
        extrasObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in self?.applyExtras() } }
    }

    private func applyExtras() {
        github.apply()
        meetings.apply()
        clipboard.apply()
        phone.apply()
        let ports = PortWatcher.ports()
        if ports != lastPorts {
            lastPorts = ports
            self.ports.apply()
        }
    }

    private var lastPorts: [Int] = []
    private(set) lazy var island = IslandController(
        agents: agents, usage: usage, scheduler: scheduler, nowPlaying: nowPlaying, system: system, devices: devices
    )
    /// 예약 창에 미리 채워 열 새 예약
    @Published var scheduleDraft: ScheduleDraft?
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Info.plist의 LSUIElement로도 처리되지만, `swift run`으로 실행할 때도 Dock 아이콘을 숨깁니다.
        NSApp.setActivationPolicy(.accessory)

        #if DEBUG
        DebugSnapshot.runIfRequested()
        #endif

        // 스크린샷 렌더링(디버그)에서는 아일랜드와 소켓 서버를 띄우지 않습니다.
        if !CommandLine.arguments.contains("--render-snapshot"), !CommandLine.arguments.contains("--render-icon"),
           !CommandLine.arguments.contains("--capture-settings") {
            let services = AppServices.shared
            services.agents.start()
            services.scheduler.start()
            services.island.start()
            services.mobile.applySettings()
            HookInstaller.refreshHelperIfInstalled()
            LoginItem.refreshRegistrationIfRenamed()
            services.startExtras()
            services.updater.start()
            services.extensions.start()
            services.systemAlerts.start()
        }

        if Notifier.isAvailable {
            UNUserNotificationCenter.current().delegate = self
            Notifier.removeLegacyScheduledNotifications()
            if UserDefaults.standard.bool(forKey: AppSettings.connected), AppSettings.wantsNotifications {
                Notifier.requestAuthorization()
            }
        }
    }

    /// Finder나 Spotlight에서 다시 열면 설정 창을 엽니다 (메뉴 막대를 숨겼을 때 들어가는 길).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { SettingsWindow.show() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 종료 직전 세션 기록을 저장합니다.
        AppServices.shared.agents.flushHistory()
        AppServices.shared.extensions.stopAll()
    }

    // 메뉴바 앱은 대부분 활성 앱이 아니지만, 팝오버가 열려 있을 때도 배너를 보여줍니다.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // 소리는 Notifier가 직접 재생하므로 여기서는 배너만 보여 줍니다.
        completionHandler([.banner, .list])
    }
}
