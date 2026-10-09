import SwiftUI

extension GroupColor {
    var color: Color {
        switch self {
        case .blue: return .blue
        case .green: return .green
        case .orange: return .orange
        case .pink: return .pink
        case .purple: return .purple
        case .red: return .red
        case .teal: return .teal
        case .indigo: return .indigo
        case .gray: return .gray
        }
    }
}

enum SymbolChoices {
    static let groups = [
        "gamecontroller.fill", "bubble.left.and.bubble.right.fill", "play.rectangle.fill", "book.fill",
        "graduationcap.fill", "music.note", "camera.fill", "paintbrush.fill", "safari.fill", "cart.fill",
        "phone.fill", "tv.fill", "sportscourt.fill", "globe"
    ]
    static let schedules = ["moon.stars.fill", "graduationcap.fill", "pencil.and.ruler.fill", "fork.knife",
                            "figure.and.child.holdinghands", "bed.double.fill", "sunset.fill", "book.fill"]
    static let chores = ["checkmark.circle.fill", "book.closed.fill", "bed.double.fill", "trash.fill",
                         "fork.knife", "pawprint.fill", "figure.walk", "pencil.and.ruler.fill"]
}

/// A circular progress ring.
struct UsageRing: View {
    var progress: Double
    var color: Color
    var lineWidth: CGFloat = 10

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(progress, 0), 1)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: progress)
        }
    }
}

struct GroupBadge: View {
    var group: AppGroup
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: group.symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(group.color.color.gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct StatusPill: View {
    var text: String
    var systemImage: String
    var tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// Stepper over minutes that follows the monitoring grid (5 min, then 15 min after 2 h).
struct MinutesStepper: View {
    @Binding var minutes: Int?
    var label: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            if let value = minutes {
                Text(MinutesFormat.short(value)).monospacedDigit().foregroundStyle(.secondary)
                Stepper("", onIncrement: { minutes = ThresholdPlan.stepUp(value) },
                        onDecrement: { minutes = value <= 0 ? 0 : ThresholdPlan.stepDown(value) })
                    .labelsHidden()
                Button {
                    minutes = nil
                } label: {
                    Image(systemName: "infinity")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove limit")
            } else {
                Button("No limit") { minutes = 60 }
                    .buttonStyle(.borderless)
            }
        }
    }
}
