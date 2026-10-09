import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var model: ChildModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if model.authorization != .approved {
                        banner("Screen Time isn't set up yet", systemImage: "exclamationmark.triangle.fill", tint: .orange,
                               detail: "Open the Setup tab so a parent can finish setting this phone up.")
                    }
                    if let mode = model.modeSummary {
                        banner(mode, systemImage: "moon.stars.fill", tint: .indigo, detail: nil)
                    }
                    if let policy = model.policy {
                        ForEach(policy.groups.filter { !$0.isEssentials && (model.budget(for: $0) != nil || model.used($0) > 0) }) { group in
                            GroupCard(group: group)
                        }
                        RequestsSection()
                    } else {
                        ProgressView("Waiting for your parent's settings…")
                            .padding(.top, 40)
                    }
                }
                .padding(16)
            }
            .navigationTitle(model.policy.map { "Hi \($0.childName)" } ?? "Today")
            .refreshable { await model.syncNow(force: true) }
        }
    }

    private func banner(_ title: String, systemImage: String, tint: Color, detail: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage).foregroundStyle(tint).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct GroupCard: View {
    @EnvironmentObject private var model: ChildModel
    let group: AppGroup

    var body: some View {
        let budget = model.budget(for: group)
        let used = model.used(group)
        let remaining = model.remainingMinutes(for: group)
        let progress = budget.map { $0 == 0 ? 1 : Double(used) / Double($0) } ?? 0

        HStack(spacing: 16) {
            ZStack {
                UsageRing(progress: progress, color: group.color.color)
                    .frame(width: 64, height: 64)
                Image(systemName: group.symbol).foregroundStyle(group.color.color)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(group.name).font(.headline)
                if let remaining {
                    Text(remaining == 0 ? "Time's up for today" : "\(MinutesFormat.short(remaining)) left")
                        .foregroundStyle(remaining == 0 ? .red : .secondary)
                } else {
                    Text("\(MinutesFormat.short(used)) used").foregroundStyle(.secondary)
                }
                if let reason = model.reason(for: group), case .windDown = reason {
                    Text("Paused to help you wind down").font(.footnote).foregroundStyle(.indigo)
                }
            }
            Spacer()
            if remaining == 0, model.policy?.childMayRequestMoreTime == true {
                Button("Ask") { model.askForMoreTime(in: group) }
                    .buttonStyle(.borderedProminent)
                    .tint(group.color.color)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct RequestsSection: View {
    @EnvironmentObject private var model: ChildModel

    var body: some View {
        let recent = model.requests.prefix(5)
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your requests").font(.headline)
                ForEach(Array(recent)) { item in
                    HStack {
                        Text(label(for: item.request.kind))
                        Spacer()
                        switch item.status {
                        case .pending: StatusPill(text: "Waiting", systemImage: "clock", tint: .orange)
                        case .approved: StatusPill(text: "Approved", systemImage: "checkmark", tint: .green)
                        case .denied: StatusPill(text: "Not now", systemImage: "xmark", tint: .red)
                        }
                    }
                    .font(.subheadline)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func label(for kind: RequestKind) -> String {
        switch kind {
        case .moreTime(let id):
            return "More \(model.policy?.group(id)?.name ?? "time")"
        case .endFocus(let id):
            return "End \(model.policy?.schedule(id)?.name ?? "focus") early"
        case .endPause:
            return "Resume screen time"
        }
    }
}
