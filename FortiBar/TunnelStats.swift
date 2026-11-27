import Foundation
import Combine
import os

private let log = Logger(subsystem: "com.romanvassilchenko.FortiBar", category: "stats")

/// One finished (or still running) connection of a server.
nonisolated struct SessionRecord: Codable, Equatable {
    enum End: String, Codable {
        /// Disconnected by the user, or by switching servers
        case user
        /// The tunnel went down by itself
        case dropped
        /// Stopped by the health check because it no longer passed traffic
        case unresponsive
        /// FortiBar quit
        case quit
        /// Still connected (never stored)
        case active
    }

    var serverID: String
    var serverName: String
    var start: Date
    var end: Date
    var rxBytes: UInt64
    var txBytes: UInt64
    var endedBy: End

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    /// Connections that ended without the user asking for it
    var wasInterruption: Bool { endedBy == .dropped || endedBy == .unresponsive }
}

/// What the Statistics tab shows for one server.
nonisolated struct ServerStatsSummary: Equatable, Identifiable {
    let serverID: String
    var serverName: String
    var connectedTime: TimeInterval = 0
    var sessions = 0
    var interruptions = 0
    var rxBytes: UInt64 = 0
    var txBytes: UInt64 = 0
    /// Connected seconds per local calendar day, oldest first, ending today
    var dailyConnected: [TimeInterval] = []

    var id: String { serverID }
}

nonisolated enum StatsCalculator {
    /// Sessions that overlap the last `days` calendar days (today included), summed per server.
    /// Traffic and the interruption count are attributed in full to sessions that ended inside
    /// the window; connected time is clipped to the window and split across days.
    static func summaries(
        sessions: [SessionRecord],
        days: Int,
        now: Date,
        calendar: Calendar = .current
    ) -> [ServerStatsSummary] {
        let today = calendar.startOfDay(for: now)
        guard days > 0, let windowStart = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        let dayStarts: [Date] = (0..<days).compactMap { calendar.date(byAdding: .day, value: $0, to: windowStart) }
        guard dayStarts.count == days else { return [] }

        var byServer: [String: ServerStatsSummary] = [:]
        var order: [String] = []

        for session in sessions.sorted(by: { $0.start < $1.start }) where session.end > windowStart && session.start <= now {
            var summary = byServer[session.serverID] ?? ServerStatsSummary(
                serverID: session.serverID, serverName: session.serverName,
                dailyConnected: Array(repeating: 0, count: days)
            )
            if byServer[session.serverID] == nil { order.append(session.serverID) }
            // The newest name wins: the profile may have been renamed
            summary.serverName = session.serverName
            summary.sessions += 1
            if session.wasInterruption { summary.interruptions += 1 }
            summary.rxBytes += session.rxBytes
            summary.txBytes += session.txBytes

            for (index, dayStart) in dayStarts.enumerated() {
                let dayEnd = index + 1 < dayStarts.count
                    ? dayStarts[index + 1]
                    : (calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart)
                let overlap = min(session.end, dayEnd).timeIntervalSince(max(session.start, dayStart))
                if overlap > 0 {
                    summary.dailyConnected[index] += overlap
                    summary.connectedTime += overlap
                }
            }
            byServer[session.serverID] = summary
        }
        return order.compactMap { byServer[$0] }.sorted { $0.connectedTime > $1.connectedTime }
    }
}

/// Finished connections, kept on disk for the Statistics tab (stats.json next to config.json).
/// Main thread only.
final class StatsStore: ObservableObject {
    static let shared = StatsStore()

    @Published private(set) var sessions: [SessionRecord]

    /// Older sessions are dropped: the tab shows a week, a quarter is plenty of history
    static let retention: TimeInterval = 90 * 24 * 3600
    static let maxSessions = 2000

    private let url: URL

    init(url: URL = ConfigManager.configPath.deletingLastPathComponent().appendingPathComponent("stats.json")) {
        self.url = url
        sessions = Self.load(from: url)
    }

    func record(_ session: SessionRecord) {
        // Sub-second flaps (a failed attempt that briefly looked connected) are noise
        guard session.duration >= 1 else { return }
        var updated = sessions + [session]
        let cutoff = Date().addingTimeInterval(-Self.retention)
        updated.removeAll { $0.end < cutoff }
        if updated.count > Self.maxSessions {
            updated.removeFirst(updated.count - Self.maxSessions)
        }
        sessions = updated
        save()
    }

    func clear() {
        sessions = []
        try? FileManager.default.removeItem(at: url)
    }

    private static func load(from url: URL) -> [SessionRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try decoder().decode([SessionRecord].self, from: data)
        } catch {
            log.error("Unreadable stats file, starting over: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(sessions).write(to: url, options: .atomic)
        } catch {
            log.error("Could not save stats: \(String(describing: error), privacy: .public)")
        }
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
