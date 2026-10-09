import SwiftUI

struct InboxView: View {
    @EnvironmentObject private var model: ParentModel

    var body: some View {
        NavigationStack {
            List {
                let pending = model.pendingInbox
                if pending.isEmpty {
                    ContentUnavailableLabel(title: "All caught up", systemImage: "checkmark.circle",
                                            detail: "Requests and finished chores show up here.")
                }
                ForEach(pending) { item in
                    InboxRow(item: item)
                }
                let handled = model.inbox.filter { $0.state != .pending }.sorted { $0.receivedAt > $1.receivedAt }.prefix(10)
                if !handled.isEmpty {
                    Section("Recently handled") {
                        ForEach(Array(handled)) { item in
                            HStack {
                                Text(InboxRow.title(for: item, in: model))
                                Spacer()
                                Image(systemName: item.state == .approved ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(item.state == .approved ? .green : .red)
                            }
                            .font(.subheadline)
                        }
                    }
                }
            }
            .navigationTitle("Requests")
            .refreshable { await model.syncAll() }
        }
    }
}

struct ContentUnavailableLabel: View {
    var title: String
    var systemImage: String
    var detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .listRowBackground(Color.clear)
    }
}

private struct InboxRow: View {
    @EnvironmentObject private var model: ParentModel
    let item: InboxItem

    static func title(for item: InboxItem, in model: ParentModel) -> String {
        let child = model.child(item.childID)
        let name = child?.name ?? "Your child"
        switch item.content {
        case .request(let request):
            switch request.kind {
            case .moreTime(let id):
                return "\(name) wants more \(child?.policy.group(id)?.name ?? "time")"
            case .endFocus(let id):
                return "\(name) asks to end \(child?.policy.schedule(id)?.name ?? "focus time") early"
            case .endPause:
                return "\(name) asks to resume screen time"
            }
        case .task(let completion):
            return "\(name) finished: \(child?.policy.task(completion.taskID)?.title ?? "a chore")"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Self.title(for: item, in: model)).font(.headline)
            Text(item.receivedAt.formatted(.relative(presentation: .named)))
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                switch item.content {
                case .request(let request):
                    switch request.kind {
                    case .moreTime:
                        approveButton("+15 min", minutes: 15)
                        approveButton("+30 min", minutes: 30)
                    case .endFocus:
                        approveButton("15 min", minutes: 15)
                        approveButton("30 min", minutes: 30)
                    case .endPause:
                        approveButton("Resume", minutes: 0)
                    }
                case .task(let completion):
                    if let task = model.child(item.childID)?.policy.task(completion.taskID) {
                        approveButton("Approve +\(task.rewardMinutes) min", minutes: task.rewardMinutes)
                    }
                }
                Button("Not now", role: .destructive) { Task { await model.deny(item) } }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    private func approveButton(_ title: String, minutes: Int) -> some View {
        Button(title) { Task { await model.approve(item, minutes: minutes) } }
            .buttonStyle(.borderedProminent)
    }
}
