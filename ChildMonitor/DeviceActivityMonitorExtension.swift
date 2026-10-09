import DeviceActivity
import Foundation

/// Runs in the background whenever iOS reaches one of the intervals or usage
/// thresholds registered by `MonitoringPlanner`. Keep this light: extensions are
/// tightly memory-limited, so it only updates the shared tally and re-applies shields.
final class DeviceActivityMonitorExtension: DeviceActivityMonitor {
    private let coordinator = EnforcementCoordinator()

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        coordinator.refresh()
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        coordinator.refresh()
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        if let parsed = ThresholdPlan.parseEvent(event.rawValue) {
            coordinator.recordUsage(groupID: parsed.group, sessionMinutes: parsed.minutes)
            coordinator.notifyIfRunningLow(groupID: parsed.group)
        }
        coordinator.refresh()
    }
}
