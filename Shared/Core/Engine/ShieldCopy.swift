import Foundation

/// Text shown on the shield that replaces a blocked app, plus the label for the
/// "ask a parent" button (nil = no button).
struct ShieldMessage: Equatable {
    var symbol: String
    var title: String
    var subtitle: String
    var askLabel: String?
}

enum ShieldCopy {
    /// - Parameters:
    ///   - subject: name of the blocked app, if known.
    ///   - groupName: name of the group it belongs to, if known.
    static func message(reason: ShieldReason?, subject: String?, groupName: String?,
                        canAsk: Bool, calendar: Calendar = .current) -> ShieldMessage {
        let thing = subject ?? groupName ?? "This app"
        switch reason {
        case .limitReached(_, let budget)?:
            let name = groupName ?? "screen time"
            return ShieldMessage(
                symbol: "hourglass.bottomhalf.filled",
                title: "That's all for today",
                subtitle: "You've used your \(MinutesFormat.long(budget)) of \(name) today.",
                askLabel: canAsk ? "Ask for more time" : nil)

        case .focus(let name, _, let until)?:
            var subtitle = "\(thing) isn't available during \(name)."
            if let until { subtitle += " Back at \(timeString(until, calendar: calendar))." }
            return ShieldMessage(symbol: "moon.stars.fill", title: "\(name) time", subtitle: subtitle,
                                 askLabel: canAsk ? "Ask to end early" : nil)

        case .windDown(let name, _, let startsAt)?:
            return ShieldMessage(
                symbol: "sunset.fill",
                title: "Winding down",
                subtitle: "\(thing) is off to help you get ready for \(name) at \(startsAt.formatted(calendar: calendar)).",
                askLabel: canAsk ? "Ask for a few more minutes" : nil)

        case .paused(let until, let message)?:
            var subtitle = message ?? "Your parent paused screen time."
            if let until { subtitle += " Back at \(timeString(until, calendar: calendar))." }
            return ShieldMessage(symbol: "pause.circle.fill", title: "Taking a break", subtitle: subtitle,
                                 askLabel: canAsk ? "Ask to resume" : nil)

        case nil:
            return ShieldMessage(symbol: "lock.fill", title: "Not available right now",
                                 subtitle: "\(thing) is limited by your parent.", askLabel: nil)
        }
    }

    private static func timeString(_ date: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }
}

enum MinutesFormat {
    /// "1 h 15 m", "45 m", "2 h"
    static func short(_ minutes: Int) -> String {
        let m = max(0, minutes)
        let h = m / 60, r = m % 60
        if h == 0 { return "\(r) m" }
        if r == 0 { return "\(h) h" }
        return "\(h) h \(r) m"
    }

    /// "1 hour 15 minutes", "45 minutes"
    static func long(_ minutes: Int) -> String {
        let m = max(0, minutes)
        let h = m / 60, r = m % 60
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        if h == 0 { return unit(r, "minute") }
        if r == 0 { return unit(h, "hour") }
        return "\(unit(h, "hour")) \(unit(r, "minute"))"
    }
}
