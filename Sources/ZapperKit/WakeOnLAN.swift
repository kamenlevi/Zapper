import Foundation

/// A powered-off webOS TV drops its websocket, so powering back on has to
/// happen out of band: a Wake-on-LAN magic packet. This needs the TV's
/// "Quick Start+" (or "Mobile TV On") setting enabled.
public enum WakeOnLAN {

    public static func send(mac: String, broadcastAddresses: [String] = defaultBroadcasts()) throws {
        guard let macBytes = parse(mac) else {
            throw RemoteError.commandFailed("Invalid MAC address: \(mac)")
        }

        // Magic packet: six 0xFF bytes, then the MAC repeated sixteen times.
        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: macBytes) }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw RemoteError.commandFailed("Could not open UDP socket") }
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        var sentAny = false
        // Port 9 is the conventional target; 7 is a common alternative.
        for address in broadcastAddresses {
            for port in [UInt16(9), UInt16(7)] {
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port.bigEndian
                addr.sin_addr.s_addr = inet_addr(address)

                let sent = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(fd, packet, packet.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if sent > 0 { sentAny = true }
            }
        }

        guard sentAny else { throw RemoteError.commandFailed("Wake-on-LAN packet was not sent") }
    }

    /// Global broadcast plus the directed broadcast for every IPv4 interface,
    /// because some routers drop 255.255.255.255 but pass 192.168.1.255.
    public static func defaultBroadcasts() -> [String] {
        var results: Set<String> = ["255.255.255.255"]

        var ifaddrsPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrsPtr) == 0, let first = ifaddrsPtr else { return Array(results) }
        defer { freeifaddrs(ifaddrsPtr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }

            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_LOOPBACK == 0,
                  flags & IFF_BROADCAST != 0,
                  let addr = entry.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET),
                  let broadcast = entry.pointee.ifa_dstaddr
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(broadcast, socklen_t(broadcast.pointee.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let address = String(cString: host)
                if !address.isEmpty { results.insert(address) }
            }
        }
        return Array(results)
    }

    private static func parse(_ mac: String) -> [UInt8]? {
        let cleaned = mac.replacingOccurrences(of: "-", with: ":")
        let parts = cleaned.split(separator: ":")
        guard parts.count == 6 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard let byte = UInt8(part, radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }

    /// Looks up a host's hardware address in the local ARP table. Only works
    /// while the device is still reachable, so we cache it at pairing time.
    public static func arpLookup(host: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-n", host]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return nil }
        // e.g. "? (192.168.1.212) at 20:28:bc:a8:2:68 on en0 ifscope [ethernet]"
        guard let atRange = output.range(of: " at ") else { return nil }
        let rest = output[atRange.upperBound...]
        guard let end = rest.firstIndex(of: " ") else { return nil }
        let candidate = String(rest[..<end])
        guard candidate.split(separator: ":").count == 6 else { return nil }

        // arp prints single-digit octets unpadded; normalise to two digits.
        return candidate.split(separator: ":")
            .map { $0.count == 1 ? "0\($0)" : String($0) }
            .joined(separator: ":")
    }
}
