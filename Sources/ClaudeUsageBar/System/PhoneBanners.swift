import AppKit
import ApplicationServices
import SwiftUI

/// 같은 iCloud의 iPhone에서 오는 전화·알림을 아일랜드에 보여 줍니다.
/// iPhone이 Mac에 띄우는 알림 배너(연속성 통화, iPhone 미러링 알림)를 손쉬운 사용 권한으로 읽습니다.
/// 공개 API가 없어 알림 센터 화면을 읽는 방식이라, macOS가 크게 바뀌면 고쳐야 할 수 있습니다.
@MainActor
final class PhoneBanners {
    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var pid: pid_t = 0
    private var timer: Timer?
    private var seen: [String] = []
    private var scanQueued = false
    private var macApps: Set<String> = []
    private var macAppsAt = Date.distantPast
    /// 앱을 켠 직후 첫 apply는 nil (그때는 묻지 않음)
    private var wasOn: Bool?

    private static let notificationCenter = "com.apple.notificationcenterui"
    /// 전화가 오면 배너를 띄우는 앱 (시스템 언어 이름 + 영어 이름)
    private static let callApps: Set<String> = Set(["Phone", "FaceTime"] + ["Phone.app", "FaceTime.app"].flatMap {
        displayNames("/System/Applications/\($0)")
    })

    private var callsOn: Bool { UserDefaults.standard.bool(forKey: AppSettings.iPhoneCalls) }
    private var noticesOn: Bool { UserDefaults.standard.bool(forKey: AppSettings.iPhoneNotices) }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// 설정이 바뀔 때마다 불립니다.
    func apply() {
        let on = callsOn || noticesOn
        defer { wasOn = on }
        if on {
            guard timer == nil else { return }
            // 설정에서 직접 켰을 때만 macOS의 허용 창을 띄웁니다 (앱을 켤 때마다 묻지 않게).
            // 허용이 안 돼 있으면 설정의 "손쉬운 사용에서 Kongi 허용" 줄이 안내합니다.
            if wasOn == false {
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
            // 권한을 나중에 주거나 알림 센터가 다시 시작돼도 따라 붙습니다.
            timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.attach() }
            }
            attach()
        } else {
            timer?.invalidate()
            timer = nil
            detach()
        }
    }

    private func attach() {
        guard AXIsProcessTrusted(),
              let current = NSRunningApplication.runningApplications(withBundleIdentifier: Self.notificationCenter).first?.processIdentifier,
              current != pid || observer == nil else { return }
        detach()
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<PhoneBanners>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { me.queueScan() }
        }
        guard AXObserverCreate(current, callback, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(current)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // 배너가 뜨면 "Notification Center" 창이 생기고, 이미 떠 있으면 레이아웃이 바뀝니다.
        AXObserverAddNotification(created, app, kAXWindowCreatedNotification as CFString, refcon)
        AXObserverAddNotification(created, app, kAXLayoutChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        appElement = app
        pid = current
    }

    private func detach() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
        appElement = nil
        pid = 0
    }

    /// 이벤트가 몰려 와도 한 번만 훑습니다.
    private func queueScan() {
        guard !scanQueued else { return }
        scanQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                self?.scanQueued = false
                self?.scan()
            }
        }
    }

    private func scan() {
        guard let appElement else { return }
        for window in Self.elements(appElement, kAXWindowsAttribute) where Self.string(window, kAXSubroleAttribute) == "AXSystemDialog" {
            // 알림 센터를 열어 둔 화면(지난 알림 목록, "위젯 편집" 버튼이 있음)은 건너뛰고, 새로 뜬 배너만 봅니다.
            if Self.contains(window, depth: 0, where: { Self.string($0, kAXIdentifierAttribute)?.hasPrefix("widget-edit") == true }) { continue }
            for banner in Self.banners(in: window, depth: 0) { handle(banner) }
        }
    }

    private func handle(_ banner: AXUIElement) {
        guard let id = Self.string(banner, kAXIdentifierAttribute), !seen.contains(id) else { return }
        var fields: [String: String] = [:]
        for child in Self.elements(banner, kAXChildrenAttribute) {
            if let key = Self.string(child, kAXIdentifierAttribute), let value = Self.string(child, kAXValueAttribute) { fields[key] = value }
        }
        guard let title = fields["title"], !title.isEmpty else { return }
        seen.append(id)
        if seen.count > 100 { seen.removeFirst(50) }

        // 설명은 "<앱 이름> <제목>, <부제>, <본문>"
        let description = Self.string(banner, kAXDescriptionAttribute) ?? ""
        let app = description.range(of: " " + title).map { String(description[..<$0.lowerBound]) } ?? ""
        let detail = [fields["subtitle"], fields["body"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")

        if Self.callApps.contains(app) {
            guard callsOn else { return }
            AppServices.shared.devices.post(.init(
                key: "iphone-call-\(id)", symbol: "phone.fill", tint: KongiTheme.green,
                title: String(title.prefix(60)), detail: detail.isEmpty ? nil : String(detail.prefix(100)), trailing: "iPhone"
            ), for: 15)
        } else if noticesOn, !app.isEmpty, isFromiPhone(app) {
            AppServices.shared.devices.post(.init(
                key: "iphone-\(id)", symbol: "iphone", tint: KongiTheme.accent,
                title: String(title.prefix(60)), detail: detail.isEmpty ? nil : String(detail.prefix(100)), trailing: String(app.prefix(16))
            ), for: 6)
        }
    }

    /// iPhone 미러링 알림은 iPhone 앱 이름으로 옵니다. 이 Mac에 그 이름의 앱이 없으면 iPhone에서 온 것으로 봅니다.
    // shortcut: 같은 이름의 앱이 Mac에도 있으면 Mac 알림으로 보고 건너뜁니다. 배너에 iPhone 표시가 읽히면 그걸로 바꿀 것.
    private func isFromiPhone(_ app: String) -> Bool {
        if macApps.contains(app) { return false }
        // 새로 설치한 앱일 수 있으니 가끔 다시 찾아봅니다.
        if Date().timeIntervalSince(macAppsAt) > 600 {
            macAppsAt = Date()
            macApps = Self.installedAppNames()
        }
        return !macApps.contains(app)
    }

    private static func installedAppNames() -> Set<String> {
        let fileManager = FileManager.default
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                     "/System/Library/CoreServices", "/System/Library/CoreServices/Applications",
                     fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var names: Set<String> = []
        func add(_ folder: String, depth: Int) {
            for name in (try? fileManager.contentsOfDirectory(atPath: folder)) ?? [] {
                let path = folder + "/" + name
                if name.hasSuffix(".app") {
                    names.formUnion(displayNames(path))
                    names.insert(String(name.dropLast(4)))
                } else if depth == 0, !name.hasPrefix(".") {
                    add(path, depth: 1) // "/Applications/<회사>/<앱>.app"
                }
            }
        }
        roots.forEach { add($0, depth: 0) }
        return names
    }

    /// 알림 배너는 시스템 언어의 앱 이름을 씁니다 (Spotlight 이름). Kongi의 언어 이름도 함께.
    private static func displayNames(_ path: String) -> [String] {
        let spotlight = NSMetadataItem(url: URL(fileURLWithPath: path))?.value(forAttribute: NSMetadataItemDisplayNameKey) as? String
        return [spotlight, FileManager.default.displayName(atPath: path)].compactMap { $0?.replacingOccurrences(of: ".app", with: "") }
    }

    // MARK: 손쉬운 사용 읽기

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? { value(element, attribute) as? String }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        (value(element, attribute) as? [AXUIElement]) ?? []
    }

    private static func contains(_ element: AXUIElement, depth: Int, where match: (AXUIElement) -> Bool) -> Bool {
        if match(element) { return true }
        guard depth < 3 else { return false }
        return elements(element, kAXChildrenAttribute).contains { contains($0, depth: depth + 1, where: match) }
    }

    private static func banners(in element: AXUIElement, depth: Int) -> [AXUIElement] {
        if string(element, kAXSubroleAttribute) == "AXNotificationCenterBanner" { return [element] }
        guard depth < 8 else { return [] }
        return elements(element, kAXChildrenAttribute).flatMap { banners(in: $0, depth: depth + 1) }
    }
}
