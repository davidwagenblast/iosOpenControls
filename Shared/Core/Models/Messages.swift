import Foundation

// MARK: - Parent -> child

/// Extra minutes for one group, valid for the day the child device applies it.
struct Grant: Codable, Identifiable, Hashable {
    enum Source: Codable, Hashable {
        case parentBonus
        case task(UUID)
        case request(UUID)
    }

    var id: UUID
    var groupID: UUID
    var minutes: Int
    var issuedAt: Date
    var source: Source
    var note: String?

    init(id: UUID = UUID(), groupID: UUID, minutes: Int, issuedAt: Date = Date(),
         source: Source, note: String? = nil) {
        self.id = id
        self.groupID = groupID
        self.minutes = minutes
        self.issuedAt = issuedAt
        self.source = source
        self.note = note
    }
}

/// Lifts one focus schedule (and its wind-down) until `until`.
struct ScheduleOverride: Codable, Identifiable, Hashable {
    var id: UUID
    var scheduleID: UUID
    var until: Date
    var requestID: UUID?

    init(id: UUID = UUID(), scheduleID: UUID, until: Date, requestID: UUID? = nil) {
        self.id = id
        self.scheduleID = scheduleID
        self.until = until
        self.requestID = requestID
    }
}

/// "Everything off except essentials" right now (dinner, family time, a tantrum).
struct PauseState: Codable, Hashable {
    var id: UUID
    var startedAt: Date
    /// `nil` = until the parent resumes.
    var until: Date?
    var message: String?

    init(id: UUID = UUID(), startedAt: Date = Date(), until: Date?, message: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.until = until
        self.message = message
    }

    func isActive(at date: Date) -> Bool {
        guard date >= startedAt.addingTimeInterval(-60) else { return false }
        if let until { return date < until }
        return true
    }
}

struct RequestDecision: Codable, Hashable {
    var requestID: UUID
    var approved: Bool
    var grantedMinutes: Int
    var decidedAt: Date
    var note: String?
}

struct TaskDecision: Codable, Hashable {
    var completionID: UUID
    var approved: Bool
    var decidedAt: Date
    var note: String?
}

// MARK: - Child -> parent

enum RequestKind: Codable, Hashable {
    case moreTime(groupID: UUID)
    case endFocus(scheduleID: UUID)
    case endPause
}

struct ChildRequest: Codable, Identifiable, Hashable {
    var id: UUID
    var createdAt: Date
    var kind: RequestKind
    var requestedMinutes: Int
    var note: String?

    init(id: UUID = UUID(), createdAt: Date = Date(), kind: RequestKind,
         requestedMinutes: Int, note: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.requestedMinutes = requestedMinutes
        self.note = note
    }
}

struct TaskCompletion: Codable, Identifiable, Hashable {
    var id: UUID
    var taskID: UUID
    var completedAt: Date
    var note: String?

    init(id: UUID = UUID(), taskID: UUID, completedAt: Date = Date(), note: String? = nil) {
        self.id = id
        self.taskID = taskID
        self.completedAt = completedAt
        self.note = note
    }
}

struct DailyUsage: Codable, Hashable, Identifiable {
    var dayKey: String
    var minutes: [UUID: Int]
    var id: String { dayKey }
    var total: Int { minutes.values.reduce(0, +) }
}

enum AuthorizationState: String, Codable, Hashable {
    case notDetermined, approved, denied
}

struct ChildStatus: Codable, Hashable {
    var sentAt: Date
    var dayKey: String
    var authorization: AuthorizationState
    /// True when running with `.individual` authorization (development/testing only).
    var isTestMode: Bool
    var policyVersion: Int
    var usageToday: [UUID: Int]
    var shieldedGroupIDs: [UUID]
    /// Human-readable current mode, e.g. "Bedtime until 7:00 AM".
    var modeSummary: String?
    /// Groups the parent defined that have no apps chosen on the device yet.
    var groupsMissingApps: [UUID]
    var history: [DailyUsage]
    /// Things the parent should know about (authorization revoked, sync stalled...).
    var problems: [String]

    var hasProblem: Bool { authorization != .approved || !problems.isEmpty }
}

// MARK: - Envelope payload

/// Everything that crosses the wire. Encrypted before it leaves the device.
enum Payload: Codable, Hashable {
    // Parent -> child
    case policy(Policy)
    case grant(Grant)
    case pause(PauseState?)
    case scheduleOverride(ScheduleOverride)
    case requestDecision(RequestDecision)
    case taskDecision(TaskDecision)
    // Child -> parent
    case status(ChildStatus)
    case request(ChildRequest)
    case taskCompletion(TaskCompletion)

    /// Plain-text routing label (visible to CloudKit so pushes can be targeted).
    var kind: String {
        switch self {
        case .policy: return "policy"
        case .grant: return "grant"
        case .pause: return "pause"
        case .scheduleOverride: return "override"
        case .requestDecision: return "decision"
        case .taskDecision: return "taskDecision"
        case .status(let s): return s.hasProblem ? "alert" : "status"
        case .request: return "request"
        case .taskCompletion: return "task"
        }
    }
}

// MARK: - Child-side local state

struct UsageTally: Codable, Equatable {
    var dayKey: String
    var minutes: [UUID: Int] = [:]
    /// Minutes already used when the current monitoring session started (see `MonitoringPlanner`).
    var baselines: [UUID: Int] = [:]
    /// Groups we've already shown a "5 minutes left" heads-up for today.
    var warned: Set<UUID> = []
}

struct StoredGrant: Codable, Hashable {
    var grant: Grant
    var dayKey: String
}

struct OutboxItem: Codable, Identifiable, Hashable {
    var id: UUID
    var createdAt: Date
    var payload: Payload

    init(id: UUID = UUID(), createdAt: Date = Date(), payload: Payload) {
        self.id = id
        self.createdAt = createdAt
        self.payload = payload
    }
}

enum DecisionStatus: String, Codable, Hashable {
    case pending, approved, denied
}

struct LocalRequest: Codable, Identifiable, Hashable {
    var request: ChildRequest
    var status: DecisionStatus
    var decidedAt: Date?
    var note: String?
    var id: UUID { request.id }
}

struct LocalTaskEntry: Codable, Identifiable, Hashable {
    var completion: TaskCompletion
    var dayKey: String
    var status: DecisionStatus
    var id: UUID { completion.id }
}

struct ProcessedState: Codable, Equatable {
    /// Highest parent timestamp we have fully handled (milliseconds).
    var watermark: Int64 = 0
    var seenIDs: [UUID] = []
}

/// Optional wrapper so "no value" can be stored as a JSON document.
struct Box<T: Codable>: Codable {
    var value: T?
    init(_ value: T? = nil) { self.value = value }
}
