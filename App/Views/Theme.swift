import SwiftUI

/// The whole visual language: system type, system backgrounds, one teal.
enum Theme {
    /// Tint for icons, links and small labels (brighter in dark mode).
    static let accent = Color.accentColor
    /// Solid fill behind white text (buttons, my chat bubbles).
    static let fill = Color("BrandFill")
    static let bubble = Color(.secondarySystemBackground)
    static let field = Color(.secondarySystemBackground)
}

/// The creator's avatar: their initial, until there's a real photo to use.
struct CreatorAvatar: View {
    var size: CGFloat = 36

    var body: some View {
        Circle()
            .fill(Theme.fill)
            .frame(width: size, height: size)
            .overlay {
                Text(Creator.name.prefix(1).uppercased())
                    .font(.system(size: size * 0.48, weight: .bold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

struct EarlyBadge: View {
    var body: some View {
        Text("EARLY")
            .font(.caption2.weight(.bold))
            .tracking(0.6)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.accent.opacity(0.14), in: Capsule())
            .accessibilityLabel("Early access")
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
    }
}

extension View {
    /// The rounded text-field look used on the sign-in and onboarding screens.
    func fieldStyle() -> some View {
        self
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The same text with any URLs made tappable.
    var linkified: AttributedString {
        var result = AttributedString(self)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return result
        }
        let range = NSRange(startIndex..., in: self)
        for match in detector.matches(in: self, range: range) {
            guard let url = match.url,
                  let stringRange = Range(match.range, in: self),
                  let lower = AttributedString.Index(stringRange.lowerBound, within: result),
                  let upper = AttributedString.Index(stringRange.upperBound, within: result) else { continue }
            result[lower..<upper].link = url
            result[lower..<upper].underlineStyle = .single
        }
        return result
    }
}

extension Date {
    /// "now", "5m", "3h", "2d", then a short date.
    var feedStamp: String {
        let seconds = Date.now.timeIntervalSince(self)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400))d" }
        return formatted(.dateTime.month(.abbreviated).day())
    }

    /// "Today", "Yesterday", or "Nov 12" for chat day dividers.
    var dayLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return "Today" }
        if calendar.isDateInYesterday(self) { return "Yesterday" }
        if calendar.isDate(self, equalTo: .now, toGranularity: .year) {
            return formatted(.dateTime.month(.abbreviated).day())
        }
        return formatted(.dateTime.month(.abbreviated).day().year())
    }
}
