import Foundation
import SwiftUI

/// 시스템·하드웨어 상태 알림: 기기가 뜨거워짐(발열 제한), 메모리 부족, 저장 공간 부족.
/// macOS가 알려 주는 신호만 듣고, 같은 종류는 1시간에 한 번만 알립니다.
@MainActor
final class SystemAlerts {
    private var memorySource: DispatchSourceMemoryPressure?
    private var thermalObserver: NSObjectProtocol?
    private var diskTimer: Timer?
    private var lastAlert: [String: Date] = [:]

    func start() {
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.checkThermal() } }

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            let critical = source?.data.contains(.critical) == true
            Task { @MainActor in self?.memoryPressure(critical: critical) }
        }
        source.resume()
        memorySource = source

        diskTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkDisk() }
        }
        checkDisk()
    }

    private func alert(_ kind: String, symbol: String, tint: Color, title: String, detail: String) {
        guard UserDefaults.standard.bool(forKey: AppSettings.systemAlerts),
              Date().timeIntervalSince(lastAlert[kind] ?? .distantPast) > 3600 else { return }
        lastAlert[kind] = Date()
        AppServices.shared.devices.post(.init(key: "system-\(kind)", symbol: symbol, tint: tint, title: title, detail: detail), for: 8)
    }

    private func checkThermal() {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            alert("thermal", symbol: "thermometer.high", tint: KongiTheme.orange,
                  title: String(localized: "Your Mac is running hot"),
                  detail: String(localized: "It may slow down to cool off"))
        default: break
        }
    }

    private func memoryPressure(critical: Bool) {
        alert("memory", symbol: "memorychip", tint: critical ? KongiTheme.red : KongiTheme.orange,
              title: String(localized: "Memory is running low"),
              detail: String(localized: "Quit apps you aren't using"))
    }

    private func checkDisk() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let free = values.volumeAvailableCapacityForImportantUsage, let total = values.volumeTotalCapacity, total > 0 else { return }
        // 10GB 아래이거나 5% 아래면
        if free < 10_000_000_000 || Double(free) / Double(total) < 0.05 {
            let size = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            alert("disk", symbol: "externaldrive.badge.exclamationmark", tint: KongiTheme.orange,
                  title: String(localized: "Storage is almost full"),
                  detail: String(localized: "\(size) left"))
        }
    }
}
