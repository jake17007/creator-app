import SwiftUI

/// One message bubble. Mine sit on the right in teal; theirs on the left.
struct ChatBubble: View {
    let text: String
    let isMine: Bool

    var body: some View {
        HStack(spacing: 0) {
            if isMine { Spacer(minLength: 56) }
            Text(text.linkified)
                .font(.body)
                .foregroundStyle(isMine ? Color.white : Color.primary)
                .tint(isMine ? Color.white : Theme.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    isMine ? Theme.fill : Theme.bubble,
                    in: RoundedRectangle(cornerRadius: 19, style: .continuous)
                )
                .textSelection(.enabled)
                .privateContent()
            if !isMine { Spacer(minLength: 56) }
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
    }
}

/// "Today" / "Yesterday" / "Nov 12" between messages from different days.
struct DayDivider: View {
    let date: Date

    var body: some View {
        Text(date.dayLabel)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }
}

/// Three dots in a bubble while the other side is writing.
struct TypingBubble: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 7, height: 7)
                        .opacity(animating ? 1 : 0.3)
                        .animation(
                            .easeInOut(duration: 0.6).repeatForever().delay(Double(index) * 0.2),
                            value: animating
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(Theme.bubble, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            Spacer(minLength: 56)
        }
        .onAppear { animating = true }
        .accessibilityLabel("Writing a reply")
    }
}

/// The message field + send button pinned above the keyboard.
struct ComposerBar: View {
    @Binding var text: String
    var placeholder: String
    var isBusy: Bool
    var onSend: () -> Void

    private var canSend: Bool { !text.trimmed.isEmpty && !isBusy }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .privateContent()

            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(canSend ? Theme.fill : Color(.tertiaryLabel))
            }
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// A one-line problem shown above the composer, dismissible.
struct NoticeBar: View {
    let text: String
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.orange)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
    }
}

/// Wraps messages in a bottom-anchored scroll view that follows new content.
struct ChatScroll<Content: View>: View {
    /// Changes whenever something is appended, to trigger a scroll to the end.
    let followKey: Int
    @ViewBuilder var content: () -> Content

    private let bottomID = "chat-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 6) {
                    content()
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: followKey) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
        }
    }
}
