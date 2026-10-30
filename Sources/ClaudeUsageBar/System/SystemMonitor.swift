import Darwin
import Foundation
import IOKit

/// CPU · GPU · 메모리 · 저장공간 사용량. 아일랜드가 펼쳐져 있을 때만 몇 초마다 읽습니다.
@MainActor
final class SystemMonitor: ObservableObject {
    struct Snapshot: Equatable {
        /// 0...1
        var cpu: Double
        /// 0...1 (읽을 수 없는 Mac이면 nil)
        var gpu: Double?
        var memoryUsed: UInt64
        var memoryTotal: UInt64
        var diskUsed: UInt64
        var diskTotal: UInt64
    }

    @Published private(set) var snapshot: Snapshot?

    private var task: Task<Void, Never>?
    private var previousTicks: (busy: UInt64, total: UInt64)?

    /// 보는 사람이 없을 때는 멈춰서 자원을 쓰지 않습니다.
    func setActive(_ active: Bool) {
        if active {
            guard task == nil else { return }
            task = Task { [weak self] in
                while !Task.isCancelled {
                    self?.sample()
                    try? await Task.sleep(nanoseconds: 2 * NSEC_PER_SEC)
                }
            }
        } else {
            task?.cancel()
            task = nil
        }
    }

    #if DEBUG
    func setPreview(_ snapshot: Snapshot) { self.snapshot = snapshot }
    #endif

    private func sample() {
        let memory = Self.memory()
        let disk = Self.disk()
        snapshot = Snapshot(
            cpu: cpuUsage(),
            gpu: Self.gpuUsage(),
            memoryUsed: memory.used,
            memoryTotal: memory.total,
            diskUsed: disk.used,
            diskTotal: disk.total
        )
    }

    private func cpuUsage() -> Double {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return 0 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        for cpu in 0..<Int(count) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(info[base + Int(CPU_STATE_USER)])
            let system = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)])
            let idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            busy += user + system + nice
            total += user + system + nice + idle
        }
        defer { previousTicks = (busy, total) }
        guard let previous = previousTicks, total > previous.total else { return 0 }
        return Double(busy - previous.busy) / Double(total - previous.total)
    }

    /// 활성 상태 모니터의 "사용된 메모리"와 비슷하게: 앱 메모리 + 고정 + 압축
    private static func memory() -> (used: UInt64, total: UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS else { return (0, total) }
        let page = UInt64(vm_kernel_page_size)
        let app = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return (min(used, total), total)
    }

    private static func disk() -> (used: UInt64, total: UInt64) {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage else { return (0, 0) }
        return (UInt64(max(Int64(total) - available, 0)), UInt64(total))
    }

    /// IOAccelerator의 "Device Utilization %" (Apple Silicon과 대부분의 GPU에서 제공)
    private static func gpuUsage() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard let property = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
                let value = property["Device Utilization %"] as? NSNumber else { continue }
            best = max(best ?? 0, value.doubleValue / 100)
        }
        return best
    }
}
