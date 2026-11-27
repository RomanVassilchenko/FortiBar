import Foundation
import Testing
@testable import FortiBar

struct HealthTrackerTests {
    @Test func aWorkingTunnelBecomesUnresponsiveAfterThreeMissedProbes() {
        var tracker = HealthTracker()
        #expect(tracker.record(latency: 12) == .good(latency: 12))
        #expect(tracker.record(latency: nil) == .failing)
        #expect(tracker.record(latency: nil) == .failing)
        #expect(tracker.record(latency: nil) == .unresponsive)
    }

    @Test func oneAnswerClearsTheFailures() {
        var tracker = HealthTracker()
        _ = tracker.record(latency: 5)
        _ = tracker.record(latency: nil)
        _ = tracker.record(latency: nil)
        #expect(tracker.record(latency: 7) == .good(latency: 7))
        #expect(tracker.record(latency: nil) == .failing)
    }

    @Test func aTargetThatNeverAnsweredIsGivenUpOnInsteadOfRestartingTheTunnel() {
        var tracker = HealthTracker()
        for _ in 1..<HealthTracker.baselineAttempts {
            #expect(tracker.record(latency: nil) == .waiting)
        }
        #expect(tracker.record(latency: nil) == .notMeasurable)
        #expect(!tracker.established)
    }

    @Test func aFirstAnswerAfterSomeMissesStillEstablishesTheBaseline() {
        var tracker = HealthTracker()
        #expect(tracker.record(latency: nil) == .waiting)
        #expect(tracker.record(latency: 3) == .good(latency: 3))
        #expect(tracker.established)
    }

    @Test func resettingFailuresRestartsTheCount() {
        var tracker = HealthTracker()
        _ = tracker.record(latency: 5)
        _ = tracker.record(latency: nil)
        _ = tracker.record(latency: nil)
        tracker.resetFailures()
        #expect(tracker.record(latency: nil) == .failing)
    }
}

struct TrafficAccumulatorTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func firstSampleIsOnlyTheBaseline() {
        var traffic = TrafficAccumulator()
        traffic.update(rx: 5_000, tx: 900, at: t0)
        #expect(traffic.rxBytes == 0 && traffic.txBytes == 0)
    }

    @Test func sumsDeltasAndComputesRates() {
        var traffic = TrafficAccumulator()
        traffic.update(rx: 1_000, tx: 100, at: t0)
        traffic.update(rx: 3_000, tx: 300, at: t0.addingTimeInterval(2))
        #expect(traffic.rxBytes == 2_000 && traffic.txBytes == 200)
        #expect(traffic.rxRate == 1_000 && traffic.txRate == 100)
        traffic.update(rx: 3_000, tx: 300, at: t0.addingTimeInterval(4))
        #expect(traffic.rxBytes == 2_000)
        #expect(traffic.rxRate == 0)
    }

    @Test func survivesTheKernelCounterWrappingAround() {
        var traffic = TrafficAccumulator()
        traffic.update(rx: UInt32.max - 99, tx: 0, at: t0)
        traffic.update(rx: 100, tx: 0, at: t0.addingTimeInterval(1))
        #expect(traffic.rxBytes == 200)
    }

    @Test func readsCountersOfTheLoopbackInterface() {
        #expect(InterfaceCounters.read()["lo0"] != nil)
    }
}

struct TunnelProbeTests {
    @Test func parsesTheRoundTripFromPingOutput() {
        let output = """
        PING 10.0.0.1 (10.0.0.1): 56 data bytes
        64 bytes from 10.0.0.1: icmp_seq=0 ttl=64 time=12.345 ms
        """
        #expect(TunnelProbe.latency(inPingOutput: output) == 12.345)
        #expect(TunnelProbe.latency(inPingOutput: "Request timeout for icmp_seq 0") == nil)
    }

    @Test func findsTheFarEndOfAPointToPointLink() {
        let output = """
        ppp0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1354
        \tinet 10.212.134.200 --> 169.254.2.1 netmask 0xffffffff
        """
        #expect(TunnelProbe.peerAddress(inIfconfig: output) == "169.254.2.1")
        #expect(TunnelProbe.peerAddress(inIfconfig: "lo0: flags=8049\n\tinet 127.0.0.1 netmask 0xff000000") == nil)
    }

    @Test func onlyHostNamesAndAddressesReachPing() {
        #expect(TunnelProbe.isValidHost("10.0.0.1"))
        #expect(TunnelProbe.isValidHost("intranet.example.com"))
        #expect(!TunnelProbe.isValidHost("-c 1000000"))
        #expect(!TunnelProbe.isValidHost("host name"))
        #expect(!TunnelProbe.isValidHost("host;rm"))
        #expect(!TunnelProbe.isValidHost(""))
        #expect(TunnelProbe.ping(host: "-f", interface: nil) == nil)
    }

    @Test func pingsTheLoopbackThroughABoundInterface() {
        let latency = TunnelProbe.ping(host: "127.0.0.1", interface: "lo0")
        #expect(latency != nil)
    }

    @Test func aHungHelperIsStoppedByTheTimeout() {
        let result = Subprocess.run("/bin/sleep", ["30"], timeout: 0.3)
        #expect(result.status == -2)
    }
}

struct HealthConfigTests {
    @Test func healthCheckIsOnByDefaultAndWrittenOnlyWhenOff() throws {
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"servers":[]}"#.utf8))
        #expect(decoded.healthCheck)

        let on = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(!on.contains("health_check"))

        var off = decoded
        off.healthCheck = false
        let offJSON = try JSONEncoder().encode(off)
        #expect(String(decoding: offJSON, as: UTF8.self).contains(#""health_check":false"#))
        #expect(try JSONDecoder().decode(AppConfig.self, from: offJSON).healthCheck == false)
    }

    @Test func healthCheckHostSurvivesSavingPinningAndIDDeduplication() throws {
        let server = VPNServer(name: "Office", host: "vpn.example.com", port: 443, username: "me",
                               password: nil, trustedCert: nil, id: "a", healthCheckHost: "intranet.local")
        let data = try JSONEncoder().encode(server)
        #expect(try JSONDecoder().decode(VPNServer.self, from: data).healthCheckHost == "intranet.local")
        #expect(server.pinning(certificate: String(repeating: "b", count: 64)).healthCheckHost == "intranet.local")

        let duplicates = AppConfig.uniquingIDs([server, server])
        #expect(duplicates.map(\.healthCheckHost) == ["intranet.local", "intranet.local"])

        let plain = VPNServer(name: "Office", host: "h", port: 443, username: "me", password: nil, trustedCert: nil)
        #expect(!String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("health_check_host"))
    }

    @Test func commandLineRejectsAHostThatCouldBeAPingOption() {
        let bad = VPNServer(name: "Office", host: "h", port: 443, username: "me", password: nil,
                            trustedCert: nil, healthCheckHost: "-f")
        #expect(CommandLineTool.validate(bad) != nil)
    }
}

struct StatisticsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func session(_ start: Date, _ end: Date, id: String = "a", rx: UInt64 = 0, tx: UInt64 = 0,
                         by: SessionRecord.End = .user) -> SessionRecord {
        SessionRecord(serverID: id, serverName: "Server \(id)", start: start, end: end, rxBytes: rx, txBytes: tx, endedBy: by)
    }

    @Test func splitsASessionAcrossMidnightAndSumsTheRest() {
        let now = date(27, 12)
        let sessions = [
            session(date(26, 22), date(27, 2), rx: 100, tx: 10),
            session(date(27, 9), date(27, 10), rx: 50, tx: 5, by: .dropped)
        ]
        let summary = StatsCalculator.summaries(sessions: sessions, days: 7, now: now, calendar: calendar)[0]
        #expect(summary.connectedTime == 5 * 3600)
        #expect(summary.dailyConnected.count == 7)
        #expect(summary.dailyConnected[6] == 3 * 3600)
        #expect(summary.dailyConnected[5] == 2 * 3600)
        #expect(summary.sessions == 2 && summary.interruptions == 1)
        #expect(summary.rxBytes == 150 && summary.txBytes == 15)
    }

    @Test func clipsToTheWindowAndIgnoresOlderSessions() {
        let now = date(27, 12)
        let old = session(date(1, 8), date(1, 9))
        let straddling = session(date(20, 22), date(21, 3))
        let summaries = StatsCalculator.summaries(sessions: [old, straddling], days: 7, now: now, calendar: calendar)
        #expect(summaries.count == 1)
        // 21 Nov 00:00 is the first day of a seven day window ending on the 27th
        #expect(summaries[0].connectedTime == 3 * 3600)
    }

    @Test func groupsPerServerAndOrdersByConnectedTime() {
        let now = date(27, 12)
        let sessions = [
            session(date(27, 1), date(27, 2), id: "a"),
            session(date(27, 3), date(27, 8), id: "b")
        ]
        let summaries = StatsCalculator.summaries(sessions: sessions, days: 7, now: now, calendar: calendar)
        #expect(summaries.map(\.serverID) == ["b", "a"])
    }

    @Test func storeKeepsSessionsAcrossRestartsAndDropsNoise() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fortibar-stats-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = StatsStore(url: url)
        let now = Date()
        store.record(session(now.addingTimeInterval(-3600), now, rx: 7, tx: 3))
        store.record(session(now.addingTimeInterval(-0.2), now))
        #expect(store.sessions.count == 1)

        let reloaded = StatsStore(url: url)
        #expect(reloaded.sessions.count == 1)
        #expect(reloaded.sessions[0].rxBytes == 7)

        // Anything older than the retention period is dropped on the next write
        reloaded.record(session(now.addingTimeInterval(-200 * 24 * 3600), now.addingTimeInterval(-199 * 24 * 3600)))
        reloaded.record(session(now.addingTimeInterval(-60), now))
        #expect(reloaded.sessions.count == 2)

        reloaded.clear()
        #expect(StatsStore(url: url).sessions.isEmpty)
    }
}
