import SwiftUI

struct ChoresView: View {
    @EnvironmentObject private var model: ChildModel

    var body: some View {
        NavigationStack {
            List {
                if let policy = model.policy {
                    let tasks = policy.tasks.filter(\.isEnabled)
                    if tasks.isEmpty {
                        Text("Your parent hasn't added any ways to earn time yet.").foregroundStyle(.secondary)
                    }
                    ForEach(tasks) { task in
                        TaskRow(task: task, groupName: policy.group(task.rewardGroupID)?.name ?? "time")
                    }
                } else {
                    Text("Waiting for your parent's settings…").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Earn time")
            .refreshable { await model.syncNow(force: true) }
        }
    }
}

private struct TaskRow: View {
    @EnvironmentObject private var model: ChildModel
    let task: ChoreTask
    let groupName: String

    var body: some View {
        let entries = model.completionsToday(for: task)
        HStack(spacing: 12) {
            Image(systemName: task.symbol)
                .font(.title2)
                .foregroundStyle(.yellow)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).font(.headline)
                Text("+\(MinutesFormat.short(task.rewardMinutes)) of \(groupName)")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if let latest = entries.last, !model.canComplete(task) {
                switch latest.status {
                case .pending: StatusPill(text: "Checking", systemImage: "clock", tint: .orange)
                case .approved: StatusPill(text: "Earned", systemImage: "star.fill", tint: .green)
                case .denied: EmptyView()
                }
            } else {
                Button("I did it") { model.complete(task) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }
}
