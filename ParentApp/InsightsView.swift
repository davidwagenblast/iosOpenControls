import SwiftUI
import Charts

struct InsightsView: View {
    @EnvironmentObject private var model: ParentModel

    private struct Point: Identifiable {
        let id = UUID()
        let day: String
        let group: String
        let minutes: Int
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ChildPicker()
                    if let child = model.selectedChild {
                        content(for: child)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Insights")
            .refreshable { await model.syncAll() }
        }
    }

    @ViewBuilder
    private func content(for child: ChildProfile) -> some View {
        let days = days(for: child)
        let names = Dictionary(uniqueKeysWithValues: child.policy.groups.map { ($0.id, $0.name) })
        let points: [Point] = days.flatMap { day in
            day.minutes.compactMap { id, minutes -> Point? in
                guard let name = names[id], id != AppGroup.essentialsID, minutes > 0 else { return nil }
                return Point(day: Self.label(day.dayKey), group: name, minutes: minutes)
            }
        }

        if points.isEmpty {
            ContentUnavailableLabel(title: "No data yet", systemImage: "chart.bar",
                                    detail: "Usage appears after \(child.name)'s phone has reported a day of activity.")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Daily screen time").font(.headline)
                Chart(points) { point in
                    BarMark(x: .value("Day", point.day), y: .value("Minutes", point.minutes))
                        .foregroundStyle(by: .value("Group", point.group))
                }
                .chartForegroundStyleScale(domain: child.policy.groups.filter { !$0.isEssentials }.map(\.name),
                                           range: child.policy.groups.filter { !$0.isEssentials }.map { $0.color.color })
                .frame(height: 220)
            }
            .padding(16)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            summary(child: child, days: days)
        }
    }

    private func summary(child: ChildProfile, days: [DailyUsage]) -> some View {
        let totals = days.map(\.total)
        let average = totals.isEmpty ? 0 : totals.reduce(0, +) / totals.count
        var perGroup: [UUID: Int] = [:]
        for day in days { for (id, m) in day.minutes where id != AppGroup.essentialsID { perGroup[id, default: 0] += m } }
        let top = perGroup.max { $0.value < $1.value }.flatMap { child.policy.group($0.key)?.name }
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        let requests = model.inbox.filter { $0.childID == child.id && $0.receivedAt > weekAgo }
        let asked = requests.filter { if case .request = $0.content { return true } else { return false } }.count
        let chores = requests.filter { if case .task = $0.content { return $0.state == .approved } else { return false } }.count

        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            stat("Daily average", MinutesFormat.short(average), "clock.fill", .blue)
            stat("Most used", top ?? "–", "star.fill", .orange)
            stat("Asked for more", "\(asked)× this week", "hand.raised.fill", .pink)
            stat("Chores done", "\(chores) this week", "checkmark.seal.fill", .green)
        }
    }

    private func stat(_ title: String, _ value: String, _ symbol: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(value).font(.title3.bold()).minimumScaleFactor(0.7).lineLimit(1)
            Text(title).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Past days from the child's history plus today's running total.
    private func days(for child: ChildProfile) -> [DailyUsage] {
        guard let status = child.lastStatus else { return [] }
        var days = status.history.filter { $0.dayKey != status.dayKey }
        days.append(DailyUsage(dayKey: status.dayKey, minutes: status.usageToday))
        return Array(days.sorted { $0.dayKey < $1.dayKey }.suffix(14))
    }

    private static func label(_ dayKey: String) -> String {
        let parts = dayKey.split(separator: "-")
        guard parts.count == 3 else { return dayKey }
        return "\(parts[1])/\(parts[2])"
    }
}
