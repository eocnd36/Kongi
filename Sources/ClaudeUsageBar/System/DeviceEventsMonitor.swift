import AppKit
import AudioToolbox
import CoreAudio
import CoreMediaIO
import Foundation
import IOKit.ps
import SwiftUI

/// 아이폰 다이나믹 아일랜드처럼 잠깐 띄울 Mac의 일들:
/// 에어팟·헤드폰 연결(배터리), 충전 시작·배터리 부족, 마이크·카메라 사용 중, 음량.
/// 모두 공개 API(CoreAudio, CoreMediaIO, IOKit)만 쓰며 추가 권한이 필요 없습니다.
@MainActor
final class DeviceEventsMonitor: ObservableObject {
    enum DeviceKind: Equatable {
        case airpods, airpodsPro, airpodsMax, beats, headphones, speaker, airplay

        var symbol: String {
            switch self {
            case .airpods: return "airpods"
            case .airpodsPro: return "airpodspro"
            case .airpodsMax: return "airpodsmax"
            case .beats: return "beats.headphones"
            case .headphones: return "headphones"
            case .speaker: return "hifispeaker.fill"
            case .airplay: return "airplayaudio"
            }
        }
    }

    struct Battery: Equatable {
        var left: Int?
        var right: Int?
        var caseLevel: Int?
        var main: Int?

        /// 한 줄 요약에 쓸 값 (양쪽 중 낮은 것)
        var headline: Int? { [left, right].compactMap { $0 }.min() ?? main }
    }

    /// 기능들이 아일랜드에 잠깐 띄우는 소식 (작업 완료, 명령 끝, 회의 등)
    struct Notice: Equatable {
        enum Action: Equatable {
            case openSession(String)
            case openURL(URL)
            case openWindow
            /// 설정 → 정보 (업데이트)
            case openAbout
        }

        var key: String
        var symbol: String
        var tint: Color
        var title: String
        var detail: String?
        /// 오른쪽 끝에 작게 (예: +120 −40, 9분)
        var trailing: String?
        var action: Action?
    }

    enum Event: Equatable {
        case audioDevice(name: String, kind: DeviceKind, battery: Battery?)
        case charging(level: Int)
        case lowBattery(level: Int)
        case volume(level: Double, muted: Bool)
        case notice(Notice)

        /// 같은 종류의 새 소식이면 섬을 다시 키우지 않고 내용만 바꿉니다.
        var key: String {
            switch self {
            case let .audioDevice(name, _, _): return "device-\(name)"
            case .charging: return "charging"
            case .lowBattery: return "low"
            case .volume: return "volume"
            case let .notice(notice): return "notice-" + notice.key
            }
        }
    }

    @Published private(set) var event: Event?
    @Published private(set) var micInUse = false
    @Published private(set) var cameraInUse = false

    private var active = false
    private var clearTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var outputDevice: AudioObjectID = 0
    private var inputDevice: AudioObjectID = 0
    private var lastDeviceChange = Date.distantPast
    private var powerSource: CFRunLoopSource?
    private var lastPower: (onAC: Bool, level: Int)?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    private var defaults: UserDefaults { .standard }

    func setActive(_ active: Bool) {
        guard active != self.active else { return }
        self.active = active
        if active { start() } else { stop() }
    }

    // MARK: Lifecycle

    private func start() {
        outputDevice = Self.defaultDevice(output: true)
        inputDevice = Self.defaultDevice(output: false)
        listen(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            self?.outputChanged()
        }
        listen(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultInputDevice) { [weak self] in
            self?.inputChanged()
        }
        listenToDeviceProperties()

        let source = IOPSNotificationCreateRunLoopSource({ _ in
            DispatchQueue.main.async { NotificationCenter.default.post(name: .kongiPowerChanged, object: nil) }
        }, nil)?.takeRetainedValue()
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
        NotificationCenter.default.addObserver(self, selector: #selector(powerChanged), name: .kongiPowerChanged, object: nil)
        lastPower = Self.readPower()

        // 카메라는 알림 대신 가볍게 확인합니다.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshPrivacy()
                try? await Task.sleep(nanoseconds: 3 * NSEC_PER_SEC)
            }
        }
    }

    private func stop() {
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
        }
        listeners.removeAll()
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
        powerSource = nil
        NotificationCenter.default.removeObserver(self, name: .kongiPowerChanged, object: nil)
        pollTask?.cancel()
        clearTask?.cancel()
        // 기능들이 띄운 소식은 모드와 상관없이 남겨 둡니다.
        if case .notice? = event {} else { event = nil }
        micInUse = false
        cameraInUse = false
    }

    // MARK: Showing

    /// 아일랜드에 잠깐 띄웁니다 (Claude 모드, 다이나믹 아일랜드 모드 모두). 기기 소식보다 길게 둡니다.
    func post(_ notice: Notice, for seconds: Double = 5) {
        show(.notice(notice), for: seconds)
    }

    #if DEBUG
    /// 데모 영상: 기기 소식을 직접 띄웁니다.
    func showPreview(_ event: Event, for seconds: Double) { show(event, for: seconds) }
    #endif

    private func show(_ event: Event, for seconds: Double) {
        self.event = event
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.event = nil
        }
    }

    // MARK: Audio devices

    private func outputChanged() {
        let device = Self.defaultDevice(output: true)
        guard device != outputDevice else { return }
        outputDevice = device
        lastDeviceChange = Date()
        listenToDeviceProperties()
        guard defaults.bool(forKey: AppSettings.islandShowsDevices),
              let name = Self.name(of: device), let kind = Self.kind(of: device, name: name) else { return }
        show(.audioDevice(name: name, kind: kind, battery: nil), for: 4)
        // 배터리는 블루투스 정보에서 따로 읽습니다 (0.1초 남짓).
        guard kind != .airplay, kind != .speaker || Self.isBluetooth(device) else { return }
        Task.detached(priority: .utility) {
            let battery = Self.bluetoothBattery(named: name)
            await MainActor.run { [weak self] in
                guard let self, let battery, case let .audioDevice(current, kind, nil)? = self.event, current == name else { return }
                self.event = .audioDevice(name: name, kind: kind, battery: battery)
            }
        }
    }

    private func inputChanged() {
        inputDevice = Self.defaultDevice(output: false)
        listenToDeviceProperties()
        refreshPrivacy()
    }

    /// 지금 출력·입력 장치의 음량과 "사용 중" 신호를 듣습니다 (장치가 바뀌면 다시 붙임).
    private func listenToDeviceProperties() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for (object, address, block) in listeners where object != system {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
        }
        listeners.removeAll { $0.0 != system }
        listen(outputDevice, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput) { [weak self] in
            self?.volumeChanged()
        }
        listen(outputDevice, selector: kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput) { [weak self] in
            self?.volumeChanged()
        }
        listen(inputDevice, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) { [weak self] in
            self?.refreshPrivacy()
        }
    }

    private func volumeChanged() {
        // 장치가 바뀔 때 같이 오는 음량 신호는 무시합니다.
        guard defaults.bool(forKey: AppSettings.islandShowsVolume), Date().timeIntervalSince(lastDeviceChange) > 1 else { return }
        var volume = Float32(0)
        var muted = UInt32(0)
        _ = Self.get(outputDevice, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput, into: &volume)
        _ = Self.get(outputDevice, selector: kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, into: &muted)
        show(.volume(level: Double(volume), muted: muted != 0), for: 1.6)
    }

    // MARK: Microphone and camera

    private func refreshPrivacy() {
        guard defaults.bool(forKey: AppSettings.islandShowsPrivacy) else {
            if micInUse { micInUse = false }
            if cameraInUse { cameraInUse = false }
            return
        }
        var running = UInt32(0)
        let mic = inputDevice != 0 && Self.get(inputDevice, selector: kAudioDevicePropertyDeviceIsRunningSomewhere, into: &running) && running != 0
        if mic != micInUse { micInUse = mic }
        let camera = Self.cameraRunning()
        if camera != cameraInUse { cameraInUse = camera }
    }

    private static func cameraRunning() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == 0, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &devices) == 0 else { return false }
        address.mSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
        return devices.contains { device in
            var running: UInt32 = 0
            var used: UInt32 = 0
            return CMIOObjectGetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running) == 0 && running != 0
        }
    }

    // MARK: Power

    @objc private func powerChanged() {
        guard let now = Self.readPower() else { return }
        defer { lastPower = now }
        guard defaults.bool(forKey: AppSettings.islandShowsCharging), let before = lastPower else { return }
        if now.onAC, !before.onAC {
            show(.charging(level: now.level), for: 3.5)
        } else if !now.onAC, [20, 10, 5].contains(where: { now.level <= $0 && before.level > $0 }) {
            show(.lowBattery(level: now.level), for: 5)
        }
    }

    /// 배터리가 없는 Mac(데스크톱)이면 nil
    private static func readPower() -> (onAC: Bool, level: Int)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return (onAC, max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current)
        }
        return nil
    }

    // MARK: CoreAudio helpers

    private func listen(
        _ object: AudioObjectID, selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, handler: @escaping @MainActor () -> Void
    ) {
        guard object != 0 else { return }
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return }
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in handler() }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr {
            listeners.append((object, address, block))
        }
    }

    private static func get<T>(
        _ object: AudioObjectID, selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, into value: inout T
    ) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return false }
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }

    private static func defaultDevice(output: Bool) -> AudioObjectID {
        var device = AudioObjectID(0)
        _ = get(
            AudioObjectID(kAudioObjectSystemObject),
            selector: output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice,
            into: &device
        )
        return device
    }

    private static func name(of device: AudioObjectID) -> String? {
        var name: Unmanaged<CFString>?
        guard get(device, selector: kAudioObjectPropertyName, into: &name), let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func transport(of device: AudioObjectID) -> UInt32 {
        var transport = UInt32(0)
        _ = get(device, selector: kAudioDevicePropertyTransportType, into: &transport)
        return transport
    }

    private static func isBluetooth(_ device: AudioObjectID) -> Bool {
        [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(transport(of: device))
    }

    /// 내장 스피커·모니터로 돌아갈 때는 띄우지 않습니다 (nil).
    private static func kind(of device: AudioObjectID, name: String) -> DeviceKind? {
        let transport = transport(of: device)
        let lower = name.lowercased()
        if lower.contains("airpods max") { return .airpodsMax }
        if lower.contains("airpods pro") { return .airpodsPro }
        if lower.contains("airpods") { return .airpods }
        if lower.contains("beats") { return .beats }
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return lower.contains("speaker") || lower.contains("스피커") ? .speaker : .headphones
        case kAudioDeviceTransportTypeAirPlay:
            return .airplay
        case kAudioDeviceTransportTypeUSB:
            return lower.contains("speaker") ? .speaker : .headphones
        default:
            return nil
        }
    }

    /// `system_profiler`가 알려 주는 블루투스 기기 배터리 (에어팟은 양쪽과 케이스)
    nonisolated private static func bluetoothBattery(named name: String) -> Battery? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = (json["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = root["device_connected"] as? [[String: Any]] else { return nil }
        func percent(_ value: Any?) -> Int? {
            (value as? String).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
        }
        for entry in connected {
            for (deviceName, value) in entry where deviceName == name {
                guard let info = value as? [String: Any] else { continue }
                let battery = Battery(
                    left: percent(info["device_batteryLevelLeft"]),
                    right: percent(info["device_batteryLevelRight"]),
                    caseLevel: percent(info["device_batteryLevelCase"]),
                    main: percent(info["device_batteryLevelMain"] ?? info["device_batteryLevel"])
                )
                return battery == Battery() ? nil : battery
            }
        }
        return nil
    }

    #if DEBUG
    func setPreview(_ event: Event?, mic: Bool = false, camera: Bool = false) {
        self.event = event
        micInUse = mic
        cameraInUse = camera
    }
    #endif
}

extension Notification.Name {
    static let kongiPowerChanged = Notification.Name("io.github.claudeusagebar.powerChanged")
}
