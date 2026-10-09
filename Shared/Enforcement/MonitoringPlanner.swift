import Foundation
import FamilyControls
import DeviceActivity
import CryptoKit

/// Registers everything the system should call our Monitor extension for:
/// - one daily activity per group with usage-threshold events (drives limits and insights),
/// - one repeating activity per focus schedule and wind-down phase (drives start/end),
/// - one-off activities for a pause or schedule override (so we refresh when they end).
///
/// Restarting monitoring resets the system's counters mid-day, so we record the
/// minutes already used as a *baseline* and add it back when events fire.
struct MonitoringPlanner {
    private let center = DeviceActivityCenter()
    let store: SharedStore

    init(store: SharedStore = .shared) {
        self.store = store
    }

    /// Hash of everything that affects the plan; skip re-planning when unchanged.
    func fingerprint(policy: Policy) -> String {
        struct Fingerprint: Encodable {
            var groups: [AppGroup]
            var schedules: [FocusSchedule]
            var selections: [String: Data]
            var pauseUntil: Date?
            var overrides: [ScheduleOverride]
        }
        let pause = store.pause
        let value = Fingerprint(
            groups: policy.groups, schedules: policy.schedules,
            selections: store.selectionsFile.read(),
            pauseUntil: pause?.until,
            overrides: store.overridesFile.read().filter { $0.until > Date() })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(value)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns human-readable problems (also written to diagnostics).
    @discardableResult
    func replan(policy: Policy, force: Bool = false, now: Date = Date(), calendar: Calendar = .current) -> [String] {
        let planHash = fingerprint(policy: policy)
        if !force, store.planFile.read().value == planHash { return [] }

        var problems: [String] = []
        center.stopMonitoring()

        // Baselines: minutes already used today, so thresholds stay correct after a restart.
        let tally = EnforcementCoordinator(store: store).rolloverIfNeeded(now: now, calendar: calendar)
        store.tallyFile.update { $0.baselines = tally.minutes }

        let selections = SelectionBook(store: store).all()

        for group in policy.groups where !group.isEssentials {
            guard let selection = selections[group.id], !SelectionBook.isEmpty(selection) else { continue }
            var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
            for minutes in ThresholdPlan.steps(upTo: ThresholdPlan.cap(for: group)) {
                let name = DeviceActivityEvent.Name(rawValue: ThresholdPlan.eventName(group: group.id, minutes: minutes))
                events[name] = DeviceActivityEvent(
                    applications: selection.applicationTokens,
                    categories: selection.categoryTokens,
                    webDomains: selection.webDomainTokens,
                    threshold: DateComponents(hour: minutes / 60, minute: minutes % 60))
            }
            let schedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: 0, minute: 0),
                intervalEnd: DateComponents(hour: 23, minute: 59),
                repeats: true)
            start(ThresholdPlan.groupActivity(group.id), schedule, events, &problems, label: group.name)
        }

        for schedule in policy.schedules where schedule.isEnabled {
            if let window = schedule.focusWindow {
                if window.durationMinutes >= 15 {
                    start(ThresholdPlan.focusActivity(schedule.id),
                          DeviceActivitySchedule(intervalStart: schedule.start.dateComponents,
                                                 intervalEnd: schedule.end.dateComponents, repeats: true),
                          [:], &problems, label: schedule.name)
                } else {
                    problems.append("\(schedule.name) is shorter than 15 minutes, so iOS can't schedule it.")
                }
            }
            if let wind = schedule.windDownWindow, wind.durationMinutes >= 15 {
                let startTime = TimeOfDay(minutes: wind.startMinute)
                start(ThresholdPlan.windDownActivity(schedule.id),
                      DeviceActivitySchedule(intervalStart: startTime.dateComponents,
                                             intervalEnd: schedule.start.dateComponents, repeats: true),
                      [:], &problems, label: "\(schedule.name) wind-down")
            }
        }

        if let pause = store.pause, let until = pause.until, until > now {
            start(ThresholdPlan.pauseActivity, oneOffSchedule(until: until, now: now, calendar: calendar),
                  [:], &problems, label: "pause")
        }
        for item in store.overridesFile.read() where item.until > now {
            start(ThresholdPlan.overrideActivity(item.id), oneOffSchedule(until: item.until, now: now, calendar: calendar),
                  [:], &problems, label: "schedule override")
        }

        store.planFile.write(Box(problems.isEmpty ? planHash : nil))
        for problem in problems { store.log("plan: \(problem)") }
        return problems
    }

    func stopAll() {
        center.stopMonitoring()
        store.planFile.write(Box<String>())
    }

    private func start(_ name: String, _ schedule: DeviceActivitySchedule,
                       _ events: [DeviceActivityEvent.Name: DeviceActivityEvent],
                       _ problems: inout [String], label: String) {
        do {
            try center.startMonitoring(DeviceActivityName(rawValue: name), during: schedule, events: events)
        } catch {
            problems.append("Couldn't start monitoring \(label): \(error.localizedDescription)")
        }
    }

    /// iOS needs at least 15 minutes between start and end.
    private func oneOffSchedule(until: Date, now: Date, calendar: Calendar) -> DeviceActivitySchedule {
        let end = max(until, now.addingTimeInterval(15 * 60 + 30))
        let parts: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute]
        return DeviceActivitySchedule(intervalStart: calendar.dateComponents(parts, from: now),
                                      intervalEnd: calendar.dateComponents(parts, from: end),
                                      repeats: false)
    }
}
