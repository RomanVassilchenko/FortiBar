import Foundation
import Darwin

// Pure building blocks of the tunnel monitor: health verdicts from probe results, traffic
// counters and the helpers that read them from the system. VPNManager owns the timing and
// the connections; everything here is value logic that can be tested on its own.

/// What the health check knows about a connected tunnel.
nonisolated enum TunnelHealth: Equatable {
    /// Not probed yet, switched off, or the tunnel has nothing that answers probes
    case unknown
    /// The probe target answered; round trip in milliseconds
    case good(latency: Double)
    /// Probes failed, but not often enough to call the tunnel dead
    case failing
    /// Enough probes in a row failed: the tunnel is up on paper but passes no traffic
    case unresponsive

    var isProblem: Bool {
        self == .failing || self == .unresponsive
    }
}

/// Decides from consecutive probe results whether a tunnel is alive.
///
/// A tunnel is only declared dead after it answered at least once on this connection: a
/// target that never answers (ICMP filtered, host not routed through the tunnel) would
/// otherwise restart a perfectly good tunnel in a loop. Such a target switches the check
/// off for the connection instead.
nonisolated struct HealthTracker: Equatable {
    /// Failed probes in a row that make a once-working tunnel unresponsive
    static let failureThreshold = 3
    /// Failed probes before the first success after which the target is given up on
    static let baselineAttempts = 4

    private(set) var established = false
    private(set) var consecutiveFailures = 0
    private var failuresBeforeFirstSuccess = 0

    enum Verdict: Equatable {
        case good(latency: Double)
        /// Still looking for a first answer
        case waiting
        case failing
        case unresponsive
        /// The target never answered: stop probing this connection
        case notMeasurable
    }

    /// Feeds one probe result (round trip in ms, nil for no reply) and returns the new verdict.
    mutating func record(latency: Double?) -> Verdict {
        if let latency {
            established = true
            consecutiveFailures = 0
            return .good(latency: latency)
        }
        guard established else {
            failuresBeforeFirstSuccess += 1
            return failuresBeforeFirstSuccess >= Self.baselineAttempts ? .notMeasurable : .waiting
        }
        consecutiveFailures += 1
        return consecutiveFailures >= Self.failureThreshold ? .unresponsive : .failing
    }

    /// After wake-up or a network change the old failures say nothing about the new situation.
    mutating func resetFailures() {
        consecutiveFailures = 0
    }
}

/// Bytes through a tunnel's interface since it came up, plus the current rate.
/// The kernel counters of `getifaddrs` are 32-bit and wrap around: deltas are what is summed.
nonisolated struct TrafficAccumulator: Equatable {
    private(set) var rxBytes: UInt64 = 0
    private(set) var txBytes: UInt64 = 0
    private(set) var rxRate: Double = 0
    private(set) var txRate: Double = 0
    private var last: (rx: UInt32, tx: UInt32, date: Date)?

    static func == (lhs: TrafficAccumulator, rhs: TrafficAccumulator) -> Bool {
        lhs.rxBytes == rhs.rxBytes && lhs.txBytes == rhs.txBytes
            && lhs.rxRate == rhs.rxRate && lhs.txRate == rhs.txRate
    }

    /// Adds a sample of the raw interface counters. The first sample is the baseline.
    mutating func update(rx: UInt32, tx: UInt32, at date: Date) {
        defer { last = (rx, tx, date) }
        guard let last else { return }

        let rxDelta = UInt64(rx &- last.rx)
        let txDelta = UInt64(tx &- last.tx)
        rxBytes += rxDelta
        txBytes += txDelta

        let elapsed = date.timeIntervalSince(last.date)
        if elapsed > 0 {
            rxRate = Double(rxDelta) / elapsed
            txRate = Double(txDelta) / elapsed
        }
    }
}

nonisolated enum InterfaceCounters {
    /// Raw receive and transmit byte counters of every network interface, by name.
    static func read() -> [String: (rx: UInt32, tx: UInt32)] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [:] }
        defer { freeifaddrs(list) }

        var result: [String: (rx: UInt32, tx: UInt32)] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                  Int32(address.pointee.sa_family) == AF_LINK,
                  let data = entry.pointee.ifa_data else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            result[String(cString: entry.pointee.ifa_name)] = (counters.ifi_ibytes, counters.ifi_obytes)
        }
        return result
    }
}

nonisolated enum TunnelProbe {
    /// Hostnames and IPv4 addresses only: the value is handed to /sbin/ping as an argument.
    static func isValidHost(_ value: String) -> Bool {
        guard value.count <= 253 else { return false }
        return value.range(of: "^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$", options: .regularExpression) != nil
    }

    /// Blocking: one ICMP echo to `host`, sent through `interface` when given.
    /// Returns the round trip in milliseconds, or nil without a reply.
    static func ping(host: String, interface: String?) -> Double? {
        guard isValidHost(host) else { return nil }
        var arguments = ["-n", "-c", "1", "-W", "2000"]
        if let interface, interface.range(of: "^[a-z]+[0-9]+$", options: .regularExpression) != nil {
            arguments += ["-b", interface]
        }
        arguments.append(host)
        // The watchdog also covers a hostname lookup that never returns
        let result = Subprocess.run("/sbin/ping", arguments, timeout: 6)
        return result.status == 0 ? latency(inPingOutput: result.output) : nil
    }

    /// "64 bytes from 10.0.0.1: icmp_seq=0 ttl=64 time=12.345 ms" → 12.345
    static func latency(inPingOutput output: String) -> Double? {
        guard let range = output.range(of: #"time[=<]\s*[0-9]+(\.[0-9]+)?"#, options: .regularExpression) else { return nil }
        let digits = output[range].drop { !$0.isNumber }
        return Double(digits)
    }

    /// The far end of a point-to-point interface: "inet 10.0.0.2 --> 169.254.2.1 netmask …"
    static func peerAddress(inIfconfig output: String) -> String? {
        for line in output.components(separatedBy: .newlines) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 4, fields[0] == "inet", fields[2] == "-->" else { continue }
            let peer = String(fields[3])
            if isValidHost(peer) { return peer }
        }
        return nil
    }

    /// Blocking: the peer address of a ppp interface, e.g. "ppp0" → "169.254.2.1".
    static func peerAddress(of interface: String) -> String? {
        guard interface.range(of: "^ppp[0-9]+$", options: .regularExpression) != nil else { return nil }
        return peerAddress(inIfconfig: Subprocess.run("/sbin/ifconfig", [interface], timeout: 5).output)
    }
}

/// Live numbers of one connected tunnel, shown in the panel. Kept apart from `TunnelStatus`
/// so a traffic tick does not rewrite state.json for the command line tool.
nonisolated struct TunnelLive: Equatable {
    var traffic = TrafficAccumulator()
    var health: TunnelHealth = .unknown
}
