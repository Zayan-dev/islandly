import AppKit
import Darwin

// MARK: - Live system stats (CPU, memory, network)

final class StatsModel: ObservableObject {
    @Published private(set) var cpu: Double = 0            // 0...1
    @Published private(set) var memoryUsed: Double = 0     // bytes
    @Published private(set) var downRate: Double = 0       // bytes/s
    @Published private(set) var upRate: Double = 0         // bytes/s
    let memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)

    var memoryFraction: Double { memoryTotal > 0 ? memoryUsed / memoryTotal : 0 }

    private var lastTicks: [UInt32]?
    private var lastNet: (rx: UInt64, tx: UInt64, at: Date)?

    func refresh() {
        refreshCPU()
        refreshMemory()
        refreshNetwork()
    }

    private func refreshCPU() {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        // user, system, idle, nice
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
        if let last = lastTicks {
            let d = zip(ticks, last).map { Double($0 &- $1) }
            let total = d.reduce(0, +)
            if total > 0 { cpu = (total - d[2]) / total }
        }
        lastTicks = ticks
    }

    private func refreshMemory() {
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        // Matches Activity Monitor's "Memory Used": app memory + wired + compressed.
        let page = Double(vm_kernel_page_size)
        let app = Double(vm.internal_page_count) - Double(vm.purgeable_count)
        memoryUsed = (app + Double(vm.wire_count) + Double(vm.compressor_page_count)) * page
    }

    private func refreshNetwork() {
        var rx: UInt64 = 0, tx: UInt64 = 0
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return }
        var cursor = ifaddr
        while let ptr = cursor {
            let ifa = ptr.pointee
            let name = String(cString: ifa.ifa_name)
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
               name.hasPrefix("en") || name.hasPrefix("pdp_ip"),
               let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self) {
                rx += UInt64(data.pointee.ifi_ibytes)
                tx += UInt64(data.pointee.ifi_obytes)
            }
            cursor = ifa.ifa_next
        }
        freeifaddrs(ifaddr)

        let now = Date()
        if let last = lastNet {
            let dt = now.timeIntervalSince(last.at)
            if dt > 0 {
                downRate = rx >= last.rx ? Double(rx - last.rx) / dt : 0
                upRate = tx >= last.tx ? Double(tx - last.tx) / dt : 0
            }
        }
        lastNet = (rx, tx, now)
    }
}

func formatBytes(_ bytes: Double, style: ByteCountFormatter.CountStyle = .file) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: style)
}

