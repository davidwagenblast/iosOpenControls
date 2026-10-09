import Foundation
import FamilyControls
import ManagedSettings
import ManagedSettingsUI

enum ShieldTarget {
    case application(ApplicationToken)
    case webDomain(WebDomainToken)
    case category(ActivityCategoryToken)
}

/// Shared logic behind the Shield Configuration and Shield Action extensions.
struct ShieldResponder {
    let store: SharedStore

    init(store: SharedStore = .shared) {
        self.store = store
    }

    struct Resolved {
        var groupID: UUID?
        var reason: ShieldReason?
        var groupName: String?
        var askEnabled: Bool
        var askMinutes: Int
    }

    func resolve(_ target: ShieldTarget) -> Resolved {
        let book = SelectionBook(store: store)
        let candidates: [UUID]
        switch target {
        case .application(let token): candidates = book.groupIDs(containing: token)
        case .webDomain(let token): candidates = book.groupIDs(containing: token)
        case .category(let token): candidates = book.groupIDs(containing: token)
        }

        guard let context = store.context else {
            return Resolved(groupID: candidates.first, reason: nil, groupName: nil, askEnabled: false, askMinutes: 15)
        }
        let decision = context.decision

        // Prefer the group that is actually the reason this thing is blocked.
        let shieldedMatch = candidates.first { decision.shieldedGroups[$0] != nil }
        let groupID = shieldedMatch ?? candidates.first
        let reason: ShieldReason? = {
            if decision.blockAll, let blockReason = decision.blockAllReason { return blockReason }
            if let shieldedMatch { return decision.shieldedGroups[shieldedMatch] }
            return decision.blockAllReason
        }()
        return Resolved(groupID: groupID, reason: reason,
                        groupName: groupID.flatMap { context.groupNames[$0] },
                        askEnabled: context.askEnabled, askMinutes: context.askMinutes)
    }

    func message(for target: ShieldTarget, subject: String?) -> ShieldMessage {
        let resolved = resolve(target)
        var canAsk = resolved.askEnabled
        if case .focus(_, let scheduleID, _)? = resolved.reason,
           let schedule = store.policy?.schedule(scheduleID), !schedule.allowsEarlyExitRequests {
            canAsk = false
        }
        if hasPendingRequest(for: resolved) {
            return ShieldMessage(symbol: "paperplane.fill", title: "Request sent",
                                 subtitle: "Your parent has been asked. You'll get a notification when they answer.",
                                 askLabel: nil)
        }
        return ShieldCopy.message(reason: resolved.reason, subject: subject, groupName: resolved.groupName, canAsk: canAsk)
    }

    /// Handles a button tap. The secondary button files a request for the parent.
    func handle(action: ShieldAction, target: ShieldTarget) -> ShieldActionResponse {
        switch action {
        case .primaryButtonPressed:
            return .close
        case .secondaryButtonPressed:
            fileRequest(for: resolve(target))
            return .close
        @unknown default:
            return .close
        }
    }

    private func requestKind(for resolved: Resolved) -> RequestKind? {
        switch resolved.reason {
        case .limitReached?:
            return resolved.groupID.map { .moreTime(groupID: $0) }
        case .windDown(_, let scheduleID, _)?, .focus(_, let scheduleID, _)?:
            return .endFocus(scheduleID: scheduleID)
        case .paused?:
            return .endPause
        case nil:
            return nil
        }
    }

    private func hasPendingRequest(for resolved: Resolved) -> Bool {
        guard let kind = requestKind(for: resolved) else { return false }
        let cutoff = Date().addingTimeInterval(-30 * 60)
        return store.requestsFile.read().contains {
            $0.status == .pending && $0.request.kind == kind && $0.request.createdAt > cutoff
        }
    }

    private func fileRequest(for resolved: Resolved) {
        guard resolved.askEnabled, let kind = requestKind(for: resolved), !hasPendingRequest(for: resolved) else { return }
        let request = ChildRequest(kind: kind, requestedMinutes: max(15, resolved.askMinutes))
        store.requestsFile.update { $0.append(LocalRequest(request: request, status: .pending)) }
        store.outboxFile.update { $0.append(OutboxItem(payload: .request(request))) }
        LocalNotifier.post(
            title: "Request ready to send",
            body: "Tap to open OpenControls and send it to your parent.",
            identifier: "request-\(request.id.uuidString)")
    }
}
