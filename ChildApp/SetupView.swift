import SwiftUI
import FamilyControls

/// The parent-only area of the child's phone: Screen Time access, choosing which apps
/// belong to each group, and pairing. Locked behind the parent's PIN once one is set.
struct SetupView: View {
    @EnvironmentObject private var model: ChildModel

    var body: some View {
        NavigationStack {
            Group {
                if model.isSetupUnlocked {
                    SetupForm()
                } else {
                    PinGate()
                }
            }
            .navigationTitle("Parent setup")
        }
    }
}

private struct PinGate: View {
    @EnvironmentObject private var model: ChildModel
    @State private var pin = ""
    @State private var wrong = false
    @State private var attempts = 0
    @State private var lockedUntil = Date.distantPast

    var body: some View {
        Form {
            Section {
                Text("This area is for parents. Enter the parent PIN to continue.")
                SecureField("PIN", text: $pin)
                    .keyboardType(.numberPad)
                Button("Unlock") { submit() }
                    .disabled(pin.isEmpty || Date() < lockedUntil)
                if wrong {
                    Text(Date() < lockedUntil ? "Too many tries. Wait a minute." : "Wrong PIN.")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func submit() {
        if model.unlockSetup(pin: pin) { return }
        attempts += 1
        wrong = true
        pin = ""
        if attempts >= 5 {
            lockedUntil = Date().addingTimeInterval(60)
            attempts = 0
        }
    }
}

private struct SetupForm: View {
    @EnvironmentObject private var model: ChildModel
    @State private var pickingGroup: AppGroup?
    @State private var confirmUnpair = false

    var body: some View {
        Form {
            accessSection
            if let policy = model.policy {
                appsSection(policy)
            }
            syncSection
            if !model.problems.isEmpty {
                Section("Problems") {
                    ForEach(model.problems, id: \.self) { Text($0).foregroundStyle(.orange) }
                }
            }
        }
        .sheet(item: $pickingGroup) { group in
            AppPickerSheet(group: group)
        }
        .confirmationDialog("Unpair from your parent?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { model.unpair() }
        } message: {
            Text("Limits will stop being enforced on this phone.")
        }
    }

    private var accessSection: some View {
        Section {
            HStack {
                Text("Screen Time access")
                Spacer()
                switch model.authorization {
                case .approved: StatusPill(text: "On", systemImage: "checkmark.circle.fill", tint: .green)
                case .denied: StatusPill(text: "Denied", systemImage: "xmark.circle.fill", tint: .red)
                case .notDetermined: StatusPill(text: "Not set up", systemImage: "exclamationmark.circle.fill", tint: .orange)
                }
            }
            if model.authorization != .approved {
                Button("Turn on (parent signs in)") {
                    Task { await model.requestAuthorization(testMode: false) }
                }
                Button("Turn on in test mode") {
                    Task { await model.requestAuthorization(testMode: true) }
                }
                .foregroundStyle(.secondary)
            } else if model.isTestMode {
                Label("Test mode: limits can be turned off in Settings. Not for real use.", systemImage: "flask")
                    .font(.footnote).foregroundStyle(.orange)
            }
        } header: {
            Text("Access")
        } footer: {
            Text("A parent must approve with their Apple ID through Family Sharing. Test mode only works for development and adult accounts.")
        }
    }

    private func appsSection(_ policy: Policy) -> some View {
        Section {
            ForEach(policy.groups) { group in
                Button {
                    pickingGroup = group
                } label: {
                    HStack {
                        GroupBadge(group: group, size: 30)
                        VStack(alignment: .leading) {
                            Text(group.name).foregroundStyle(.primary)
                            Text(summary(for: group)).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                    }
                }
                .disabled(model.authorization != .approved)
            }
        } header: {
            Text("Apps in each group")
        } footer: {
            Text("Choose individual apps for Essentials and any group that stays open during Bedtime or School. Entire categories can only be blocked, not allowed.")
        }
    }

    private func summary(for group: AppGroup) -> String {
        guard let selection = model.selections[group.id], !SelectionBook.isEmpty(selection) else { return "No apps chosen" }
        var parts: [String] = []
        if !selection.applicationTokens.isEmpty { parts.append("\(selection.applicationTokens.count) apps") }
        if !selection.categoryTokens.isEmpty { parts.append("\(selection.categoryTokens.count) categories") }
        if !selection.webDomainTokens.isEmpty { parts.append("\(selection.webDomainTokens.count) sites") }
        return parts.joined(separator: ", ")
    }

    private var syncSection: some View {
        Section("Sync") {
            if let name = model.policy?.childName {
                LabeledContent("Paired as", value: name)
            }
            if let last = model.lastSync {
                LabeledContent("Last sync", value: last.formatted(date: .omitted, time: .shortened))
            }
            Button(model.isSyncing ? "Syncing…" : "Sync now") {
                Task { await model.syncNow(force: true) }
            }
            .disabled(model.isSyncing)
            Button("Unpair this phone", role: .destructive) { confirmUnpair = true }
        }
    }
}

private struct AppPickerSheet: View {
    @EnvironmentObject private var model: ChildModel
    @Environment(\.dismiss) private var dismiss
    let group: AppGroup
    @State private var selection = FamilyActivitySelection()

    var body: some View {
        NavigationStack {
            FamilyActivityPicker(selection: $selection)
                .navigationTitle(group.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            model.save(selection: selection, for: group.id)
                            dismiss()
                        }
                    }
                }
        }
        .onAppear { selection = model.selections[group.id] ?? FamilyActivitySelection() }
    }
}
