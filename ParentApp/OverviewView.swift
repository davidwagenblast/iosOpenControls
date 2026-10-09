import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var model: ParentModel
    @State private var showBonus = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ChildPicker()
                    if let child = model.selectedChild {
                        StatusCard(child: child)
                        QuickActions(child: child, showBonus: $showBonus)
                        UsageCard(child: child)
                    }
                }
                .padding(16)
            }
            .navigationTitle(model.selectedChild?.name ?? "Overview")
            .refreshable { await model.syncAll() }
            .sheet(isPresented: $showBonus) {
                if let child = model.selectedChild { BonusSheet(child: child) }
            }
        }
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct StatusCard: View {
    let child: ChildProfile

    var body: some View {
        Card {
            if let status = child.lastStatus {
                HStack {
                    if status.authorization == .approved && status.problems.isEmpty {
                        StatusPill(text: "Protected", systemImage: "checkmark.shield.fill", tint: .green)
                    } else if status.authorization != .approved {
                        StatusPill(text: "Screen Time is off", systemImage: "exclamationmark.shield.fill", tint: .red)
                    } else {
                        StatusPill(text: "Needs attention", systemImage: "exclamationmark.triangle.fill", tint: .orange)
                    }
                    Spacer()
                    Text("Updated \(status.sentAt.formatted(.relative(presentation: .named)))")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let mode = status.modeSummary {
                    Label(mode, systemImage: "moon.stars.fill").foregroundStyle(.indigo)
                }
                if status.isTestMode {
                    Label("Test mode is on — limits can be bypassed.", systemImage: "flask").font(.footnote).foregroundStyle(.orange)
                }
                if !status.groupsMissingApps.isEmpty {
                    Label("Some groups have no apps yet. Finish setup on \(child.name)'s phone.",
                          systemImage: "iphone.gen3.badge.exclamationmark")
                        .font(.footnote).foregroundStyle(.orange)
                }
                ForEach(status.problems, id: \.self) { Text($0).font(.footnote).foregroundStyle(.orange) }
                if status.policyVersion < child.policy.version {
                    Label("Newest rules haven't reached the phone yet.", systemImage: "arrow.triangle.2.circlepath")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                StatusPill(text: "Not connected yet", systemImage: "link.badge.plus", tint: .orange)
                Text("Open **OpenControls Kid** on \(child.name)'s phone and pair it using the QR code in the Family tab.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

private struct QuickActions: View {
    @EnvironmentObject private var model: ParentModel
    let child: ChildProfile
    @Binding var showBonus: Bool

    var body: some View {
        Card {
            Text("Quick actions").font(.headline)
            let paused = child.pause?.isActive(at: Date()) == true
            HStack(spacing: 10) {
                if paused {
                    Button {
                        Task { await model.resume(child.id) }
                    } label: {
                        Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Menu {
                        Button("15 minutes") { Task { await model.pause(child.id, minutes: 15) } }
                        Button("30 minutes") { Task { await model.pause(child.id, minutes: 30) } }
                        Button("1 hour") { Task { await model.pause(child.id, minutes: 60) } }
                        Button("Until I resume") { Task { await model.pause(child.id, minutes: nil) } }
                    } label: {
                        Label("Pause all", systemImage: "pause.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                }
                Button {
                    showBonus = true
                } label: {
                    Label("Bonus time", systemImage: "gift.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            if paused, let until = child.pause?.until {
                Text("Paused until \(until.formatted(date: .omitted, time: .shortened)).")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if paused {
                Text("Paused until you resume.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

private struct UsageCard: View {
    @EnvironmentObject private var model: ParentModel
    let child: ChildProfile

    var body: some View {
        Card {
            Text("Today").font(.headline)
            let today = DayKey.string(for: Date())
            let usage = child.lastStatus?.dayKey == today ? (child.lastStatus?.usageToday ?? [:]) : [:]
            let weekday = Calendar.current.component(.weekday, from: Date())
            ForEach(child.policy.groups.filter { !$0.isEssentials }) { group in
                let used = usage[group.id] ?? 0
                let base = group.budget.minutes(forWeekday: weekday)
                let limit = base.map { $0 + model.bonusToday(for: child.id, groupID: group.id) }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        GroupBadge(group: group, size: 26)
                        Text(group.name)
                        Spacer()
                        if let limit {
                            Text("\(MinutesFormat.short(used)) of \(MinutesFormat.short(limit))")
                                .foregroundStyle(used >= limit ? .red : .secondary)
                        } else {
                            Text(MinutesFormat.short(used)).foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)
                    if let limit, limit > 0 {
                        ProgressView(value: min(Double(used), Double(limit)), total: Double(limit))
                            .tint(group.color.color)
                    }
                }
            }
        }
    }
}

private struct BonusSheet: View {
    @EnvironmentObject private var model: ParentModel
    @Environment(\.dismiss) private var dismiss
    let child: ChildProfile
    @State private var groupID: UUID?
    @State private var minutes = 15

    var body: some View {
        NavigationStack {
            Form {
                Picker("Group", selection: $groupID) {
                    ForEach(child.policy.limitedGroups) { Text($0.name).tag(Optional($0.id)) }
                }
                Stepper("\(MinutesFormat.long(minutes)) extra today", value: $minutes, in: 5...120, step: 5)
            }
            .navigationTitle("Bonus time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Give") {
                        if let groupID { Task { await model.giveBonus(child.id, groupID: groupID, minutes: minutes) } }
                        dismiss()
                    }
                    .disabled(groupID == nil)
                }
            }
            .onAppear { groupID = child.policy.limitedGroups.first?.id }
        }
        .presentationDetents([.medium])
    }
}
