import SwiftUI

/// Settings › Statistics: how each server did over the last week, from the connection
/// history in stats.json plus the tunnels that are up right now.
struct StatisticsView: View {
    @ObservedObject private var store = StatsStore.shared
    @ObservedObject private var vpn = VPNManager.shared
    @State private var confirmingClear = false

    private let days = 7

    var body: some View {
        // Re-evaluated every 30 seconds so a running connection keeps counting
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let summaries = StatsCalculator.summaries(
                sessions: store.sessions + vpn.activeSessions(now: context.date),
                days: days, now: context.date
            )
            VStack(spacing: 0) {
                if summaries.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(summaries) { summary in
                                ServerStatsCard(summary: summary, now: context.date)
                            }
                        }
                        .padding(16)
                    }
                }

                Divider()
                HStack {
                    Text("Last \(days) days")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear History…") { confirmingClear = true }
                        .buttonStyle(.borderless)
                        .disabled(store.sessions.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .confirmationDialog("Clear the connection history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { store.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Connection times, traffic and interruptions are removed. Running tunnels keep counting from now.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No Statistics Yet")
                .font(.title3.weight(.semibold))
            Text("Connection time, traffic and interruptions appear here once you have connected.")
                .font(.callout)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ServerStatsCard: View {
    let summary: ServerStatsSummary
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(summary.serverName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(CommandLineTool.duration(summary.connectedTime))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                Label(interruptionsText, systemImage: summary.interruptions == 0 ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(summary.interruptions == 0 ? Color.secondary : Color.orange)
                Label(ByteFormat.size(summary.rxBytes), systemImage: "arrow.down")
                Label(ByteFormat.size(summary.txBytes), systemImage: "arrow.up")
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()

            DailyBars(values: summary.dailyConnected, now: now)
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var interruptionsText: String {
        switch summary.interruptions {
        case 0: return "No interruptions"
        case 1: return "1 interruption"
        default: return "\(summary.interruptions) interruptions"
        }
    }
}

/// Connected time per day, one bar per day, a full bar being 24 hours.
private struct DailyBars: View {
    let values: [TimeInterval]
    let now: Date

    private let barHeight: CGFloat = 34

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, seconds in
                VStack(spacing: 4) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                        if seconds > 0 {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                // Even a short connection stays visible
                                .fill(Color.accentColor.opacity(index == values.count - 1 ? 1 : 0.7))
                                .frame(height: max(3, barHeight * min(1, seconds / 86_400)))
                        }
                    }
                    .frame(height: barHeight)
                    .help(dayLabel(index) + ": " + CommandLineTool.duration(seconds))

                    Text(weekday(index))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func date(_ index: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: index - (values.count - 1), to: now) ?? now
    }

    private func weekday(_ index: Int) -> String {
        let name = date(index).formatted(.dateTime.weekday(.abbreviated))
        return String(name.prefix(2))
    }

    private func dayLabel(_ index: Int) -> String {
        date(index).formatted(.dateTime.weekday(.wide).day().month())
    }
}
