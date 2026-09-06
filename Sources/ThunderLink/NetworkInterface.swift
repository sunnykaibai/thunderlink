import Foundation
import Darwin

struct ThunderboltInterfaceState: Equatable {
    var isActive = false
    var ipv4: String?
    var ipv6: String?

    var summary: String {
        guard isActive else { return "未连接" }
        if let ipv6 { return "bridge0 · \(ipv6)" }
        if let ipv4 { return "bridge0 · \(ipv4)" }
        return "bridge0 · 已连接"
    }
}

enum NetworkInterfaceDetector {
    static func thunderboltBridge() -> ThunderboltInterfaceState {
        var state = ThunderboltInterfaceState()
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return state }
        defer { freeifaddrs(pointer) }

        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let value = item.pointee
            guard String(cString: value.ifa_name) == "bridge0" else { continue }
            let flags = Int32(value.ifa_flags)
            let running = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0
            guard running, let address = value.ifa_addr else { continue }
            state.isActive = true

            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length: socklen_t = family == AF_INET
                ? socklen_t(MemoryLayout<sockaddr_in>.size)
                : socklen_t(MemoryLayout<sockaddr_in6>.size)
            if getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let text = String(cString: host)
                if family == AF_INET {
                    state.ipv4 = text
                } else if text.hasPrefix("fe80:") {
                    state.ipv6 = text.contains("%") ? text : "\(text)%bridge0"
                }
            }
        }
        return state
    }
}
