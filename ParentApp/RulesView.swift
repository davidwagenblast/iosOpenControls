import SwiftUI

struct RulesView: View {
    @EnvironmentObject private var model: ParentModel

    var body: some View {
        NavigationStack {
            if let child = model.selectedChild {
                List {
                    Section { ChildPicker().listRowBackground(Color.clear) }
                        .listRowInsets(EdgeInsets())

                    Section {
                        ForEach(child.policy.groups) { group in
                            NavigationLink {
                                GroupEditor(childID: child.id, groupID: group.id)
                            } label: {
                                HStack {
                                    GroupBadge(group: group, size: 30)
                                    VStack(alignment: .leading) {
                                        Text(group.name)
                                        Text(summary(of: group)).font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .onDelete { offsets in
                            let ids = offsets.map { child.policy.groups[$0].id }.filter { $0 != AppGroup.essentialsID }
                            model.updatePolicy(child.id) { $0.groups.removeAll { ids.contains($0.id) } }
                        }
                        Button {
                            let group = AppGroup(name: "New group", symbol: "square.grid.2x2.fill", color: .blue,
                                                 budget: .uniform(60))
                            model.updatePolicy(child.id) { $0.groups.append(group) }
                        } label: { Label("Add group", systemImage: "plus") }
                    } header: {
                        Text("App groups & daily limits")
                    } footer: {
                        Text("Choose which apps go in each group on \(child.name)'s phone (Family tab → setup). Limits are shared across all apps in a group.")
                    }

                    Section {
                        ForEach(child.policy.schedules) { schedule in
                            NavigationLink {
                                ScheduleEditor(childID: child.id, scheduleID: schedule.id)
                            } label: {
                                Label {
                                    VStack(alignment: .leading) {
                                        Text(schedule.name)
                                        Text("\(schedule.start.formatted()) – \(schedule.end.formatted())")
                                            .font(.footnote).foregroundStyle(.secondary)
                                    }
                                } icon: { Image(systemName: schedule.symbol) }
                            }
                        }
                        .onDelete { offsets in
                            let ids = offsets.map { child.policy.schedules[$0].id }
                            model.updatePolicy(child.id) { $0.schedules.removeAll { ids.contains($0.id) } }
                        }
                        Button {
                            let schedule = FocusSchedule(name: "Homework", symbol: "pencil.and.ruler.fill",
                                                         start: TimeOfDay(hour: 16), end: TimeOfDay(hour: 18),
                                                         weekdays: Weekday.schoolDays)
                            model.updatePolicy(child.id) { $0.schedules.append(schedule) }
                        } label: { Label("Add focus schedule", systemImage: "plus") }
                    } header: {
                        Text("Focus schedules")
                    } footer: {
                        Text("During a schedule only the groups you allow stay open. Wind-down turns off chosen groups ahead of time.")
                    }

                    Section {
                        ForEach(child.policy.tasks) { task in
                            NavigationLink {
                                TaskEditor(childID: child.id, taskID: task.id)
                            } label: {
                                Label {
                                    VStack(alignment: .leading) {
                                        Text(task.title)
                                        Text("+\(task.rewardMinutes) min of \(child.policy.group(task.rewardGroupID)?.name ?? "time")")
                                            .font(.footnote).foregroundStyle(.secondary)
                                    }
                                } icon: { Image(systemName: task.symbol) }
                            }
                        }
                        .onDelete { offsets in
                            let ids = offsets.map { child.policy.tasks[$0].id }
                            model.updatePolicy(child.id) { $0.tasks.removeAll { ids.contains($0.id) } }
                        }
                        Button {
                            guard let target = child.policy.limitedGroups.first ?? child.policy.groups.first else { return }
                            let task = ChoreTask(title: "New chore", rewardMinutes: 15, rewardGroupID: target.id)
                            model.updatePolicy(child.id) { $0.tasks.append(task) }
                        } label: { Label("Add chore", systemImage: "plus") }
                    } header: {
                        Text("Earn time")
                    } footer: {
                        Text("Your child marks a chore done; you approve it from the Requests tab and the bonus minutes are added.")
                    }

                    Section {
                        NavigationLink("More options") { OptionsEditor(childID: child.id) }
                    }
                }
                .navigationTitle("Rules")
            } else {
                Text("Add a child first.")
            }
        }
    }

    private func summary(of group: AppGroup) -> String {
        if group.isEssentials { return "Always allowed" }
        if group.budget.isUnlimited { return "No limit" }
        let weekday = group.budget.minutes(forWeekday: 2)
        let weekend = group.budget.minutes(forWeekday: 7)
        func text(_ m: Int?) -> String { m.map { MinutesFormat.short($0) } ?? "no limit" }
        if weekday == weekend { return "\(text(weekday)) a day" }
        return "\(text(weekday)) weekdays · \(text(weekend)) weekends"
    }
}

// MARK: - Group editor

struct GroupEditor: View {
    @EnvironmentObject private var model: ParentModel
    let childID: UUID
    let groupID: UUID

    private var group: AppGroup? { model.child(childID)?.policy.group(groupID) }

    private func binding<V>(_ keyPath: WritableKeyPath<AppGroup, V>, default fallback: V) -> Binding<V> {
        Binding(
            get: { group?[keyPath: keyPath] ?? fallback },
            set: { newValue in
                model.updatePolicy(childID) { policy in
                    if let i = policy.groups.firstIndex(where: { $0.id == groupID }) {
                        policy.groups[i][keyPath: keyPath] = newValue
                    }
                }
            })
    }

    var body: some View {
        if let group {
            Form {
                Section {
                    TextField("Name", text: binding(\.name, default: ""))
                        .disabled(group.isEssentials)
                    Picker("Icon", selection: binding(\.symbol, default: "square.grid.2x2.fill")) {
                        ForEach(SymbolChoices.groups, id: \.self) { Label($0, systemImage: $0).labelStyle(.iconOnly).tag($0) }
                    }
                    Picker("Color", selection: binding(\.color, default: .blue)) {
                        ForEach(GroupColor.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                }
                if !group.isEssentials {
                    Section {
                        ForEach(Weekday.all, id: \.self) { weekday in
                            MinutesStepper(minutes: Binding(
                                get: { group.budget.minutes(forWeekday: weekday) },
                                set: { newValue in
                                    model.updatePolicy(childID) { policy in
                                        if let i = policy.groups.firstIndex(where: { $0.id == groupID }) {
                                            policy.groups[i].budget.set(newValue, forWeekday: weekday)
                                        }
                                    }
                                }), label: Weekday.shortName(weekday))
                        }
                    } header: {
                        Text("Daily limit")
                    } footer: {
                        Text("One shared allowance for every app in this group. Limits move in 5-minute steps (15 after two hours).")
                    }
                } else {
                    Section {
                        Text("Phone, Messages, Maps and anything else that must always work. These stay available during bedtime, school and pauses.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(group.name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Schedule editor

struct ScheduleEditor: View {
    @EnvironmentObject private var model: ParentModel
    let childID: UUID
    let scheduleID: UUID

    private var child: ChildProfile? { model.child(childID) }
    private var schedule: FocusSchedule? { child?.policy.schedule(scheduleID) }

    private func binding<V>(_ keyPath: WritableKeyPath<FocusSchedule, V>, default fallback: V) -> Binding<V> {
        Binding(
            get: { schedule?[keyPath: keyPath] ?? fallback },
            set: { newValue in
                model.updatePolicy(childID) { policy in
                    if let i = policy.schedules.firstIndex(where: { $0.id == scheduleID }) {
                        policy.schedules[i][keyPath: keyPath] = newValue
                    }
                }
            })
    }

    private func timeBinding(_ keyPath: WritableKeyPath<FocusSchedule, TimeOfDay>) -> Binding<Date> {
        Binding(
            get: {
                let t = schedule?[keyPath: keyPath] ?? TimeOfDay(hour: 9)
                return Calendar.current.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                let value = TimeOfDay(hour: c.hour ?? 0, minute: c.minute ?? 0)
                model.updatePolicy(childID) { policy in
                    if let i = policy.schedules.firstIndex(where: { $0.id == scheduleID }) {
                        policy.schedules[i][keyPath: keyPath] = value
                    }
                }
            })
    }

    var body: some View {
        if let child, let schedule {
            let others = child.policy.groups.filter { !$0.isEssentials }
            Form {
                Section {
                    TextField("Name", text: binding(\.name, default: ""))
                    Toggle("Enabled", isOn: binding(\.isEnabled, default: true))
                    DatePicker("Starts", selection: timeBinding(\.start), displayedComponents: .hourAndMinute)
                    DatePicker("Ends", selection: timeBinding(\.end), displayedComponents: .hourAndMinute)
                    if let window = schedule.focusWindow, window.durationMinutes < 15 {
                        Text("iOS needs at least 15 minutes between start and end.").foregroundStyle(.red)
                    }
                }
                Section("Days") {
                    HStack {
                        ForEach(Weekday.all, id: \.self) { day in
                            let on = schedule.weekdays.contains(day)
                            Button {
                                var days = schedule.weekdays
                                if on { days.remove(day) } else { days.insert(day) }
                                binding(\.weekdays, default: []).wrappedValue = days
                            } label: {
                                Text(String(Weekday.shortName(day).prefix(2)))
                                    .font(.footnote.weight(.semibold))
                                    .frame(width: 32, height: 32)
                                    .background(on ? Color.accentColor : Color(.tertiarySystemFill), in: Circle())
                                    .foregroundStyle(on ? Color.white : Color.primary)
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                Section {
                    ForEach(others) { group in
                        Toggle(isOn: Binding(
                            get: { schedule.allowedGroupIDs.contains(group.id) },
                            set: { on in
                                var ids = schedule.allowedGroupIDs
                                if on { ids.insert(group.id) } else { ids.remove(group.id) }
                                binding(\.allowedGroupIDs, default: []).wrappedValue = ids
                            })) {
                            Label(group.name, systemImage: group.symbol)
                        }
                    }
                } header: {
                    Text("Allowed during this schedule")
                } footer: {
                    Text("Essentials are always allowed. Everything else is blocked.")
                }
                Section {
                    Stepper(schedule.windDownMinutes == 0 ? "Wind-down: off" : "Wind-down: \(schedule.windDownMinutes) min before",
                            value: binding(\.windDownMinutes, default: 0), in: 0...120, step: 15)
                    if schedule.windDownMinutes > 0 {
                        ForEach(others) { group in
                            Toggle(isOn: Binding(
                                get: { schedule.windDownGroupIDs.contains(group.id) },
                                set: { on in
                                    var ids = schedule.windDownGroupIDs
                                    if on { ids.insert(group.id) } else { ids.remove(group.id) }
                                    binding(\.windDownGroupIDs, default: []).wrappedValue = ids
                                })) {
                                Label("Turn off \(group.name)", systemImage: group.symbol)
                            }
                        }
                    }
                } header: {
                    Text("Wind-down")
                } footer: {
                    Text("Switches off the chosen groups before the schedule starts, so screens fade out gradually instead of all at once.")
                }
                Section {
                    Toggle("Child can ask to end early", isOn: binding(\.allowsEarlyExitRequests, default: true))
                }
            }
            .navigationTitle(schedule.name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Chore editor

struct TaskEditor: View {
    @EnvironmentObject private var model: ParentModel
    let childID: UUID
    let taskID: UUID

    private var task: ChoreTask? { model.child(childID)?.policy.task(taskID) }

    private func binding<V>(_ keyPath: WritableKeyPath<ChoreTask, V>, default fallback: V) -> Binding<V> {
        Binding(
            get: { task?[keyPath: keyPath] ?? fallback },
            set: { newValue in
                model.updatePolicy(childID) { policy in
                    if let i = policy.tasks.firstIndex(where: { $0.id == taskID }) {
                        policy.tasks[i][keyPath: keyPath] = newValue
                    }
                }
            })
    }

    var body: some View {
        if let task, let child = model.child(childID) {
            Form {
                TextField("What needs doing?", text: binding(\.title, default: ""))
                Picker("Icon", selection: binding(\.symbol, default: "checkmark.circle.fill")) {
                    ForEach(SymbolChoices.chores, id: \.self) { Label($0, systemImage: $0).labelStyle(.iconOnly).tag($0) }
                }
                Section("Reward") {
                    Stepper("+\(task.rewardMinutes) minutes", value: binding(\.rewardMinutes, default: 15), in: 5...120, step: 5)
                    Picker("Added to", selection: binding(\.rewardGroupID, default: task.rewardGroupID)) {
                        ForEach(child.policy.groups.filter { !$0.isEssentials }) { Text($0.name).tag($0.id) }
                    }
                    Stepper("Up to \(task.maxPerDay)× a day", value: binding(\.maxPerDay, default: 1), in: 1...5)
                }
                Toggle("Enabled", isOn: binding(\.isEnabled, default: true))
            }
            .navigationTitle(task.title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Other options

struct OptionsEditor: View {
    @EnvironmentObject private var model: ParentModel
    let childID: UUID
    @State private var pin = ""

    private var policy: Policy? { model.child(childID)?.policy }

    var body: some View {
        if let policy {
            Form {
                Section {
                    Toggle("Child can ask for more time", isOn: Binding(
                        get: { policy.childMayRequestMoreTime },
                        set: { value in model.updatePolicy(childID) { $0.childMayRequestMoreTime = value } }))
                    Toggle("Tamper protection", isOn: Binding(
                        get: { policy.tamperProtection },
                        set: { value in model.updatePolicy(childID) { $0.tamperProtection = value } }))
                } footer: {
                    Text("Tamper protection forces automatic date & time (so the clock can't be changed to dodge limits) and blocks deleting apps.")
                }
                Section {
                    SecureField(policy.pin == nil ? "Set a PIN" : "New PIN", text: $pin)
                        .keyboardType(.numberPad)
                    Button("Save PIN") {
                        model.setPIN(pin, for: childID)
                        pin = ""
                    }
                    .disabled(pin.count < 4)
                    if policy.pin != nil {
                        Button("Remove PIN", role: .destructive) { model.setPIN(nil, for: childID) }
                    }
                } header: {
                    Text("Parent PIN")
                } footer: {
                    Text("Locks the setup screen on \(policy.childName)'s phone (choosing apps, unpairing).")
                }
            }
            .navigationTitle("More options")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
