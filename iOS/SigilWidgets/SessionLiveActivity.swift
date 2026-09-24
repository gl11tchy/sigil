import ActivityKit
import SwiftUI
import WidgetKit

/// The working session on the Lock Screen and in the Dynamic Island: its name,
/// its provider, what it is doing, and for how long. Tapping opens the app on
/// that session; nothing here sends a keystroke.
struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(SessionLink.url(tabID: context.attributes.tabID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StatusDot(state: context.state)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(StatusWords.detail(context.attributes, context.state))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Elapsed(state: context.state)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                StatusDot(state: context.state)
            } compactTrailing: {
                Text(StatusWords.short(context.state))
                    .font(.caption2)
                    .foregroundStyle(StatusWords.colour(context.state))
            } minimal: {
                StatusDot(state: context.state)
            }
            .widgetURL(SessionLink.url(tabID: context.attributes.tabID))
        }
    }
}

private struct LockScreenView: View {
    let attributes: SessionActivityAttributes
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(state: state)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(attributes.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(StatusWords.detail(attributes, state))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(StatusWords.short(state))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StatusWords.colour(state))
                Elapsed(state: state)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }
}

private struct StatusDot: View {
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        Circle()
            .fill(StatusWords.colour(state))
            .frame(width: 10, height: 10)
            .accessibilityLabel(StatusWords.short(state))
    }
}

/// Counts up from when the status began; the system redraws it without a push.
private struct Elapsed: View {
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        if state.status == "working" || state.asking {
            Text(Date(timeIntervalSince1970: TimeInterval(state.since)), style: .timer)
        } else {
            Text(Date(timeIntervalSince1970: TimeInterval(state.since)), style: .relative)
        }
    }
}

enum StatusWords {
    static func short(_ state: SessionActivityAttributes.ContentState) -> String {
        if state.asking { return "Asking" }
        switch state.status {
        case "working": return "Working"
        case "idle": return "Done"
        case "exited": return "Ended"
        case "starting": return "Starting"
        default: return state.status.capitalized
        }
    }

    static func detail(_ attributes: SessionActivityAttributes, _ state: SessionActivityAttributes.ContentState) -> String {
        if state.asking { return "\(attributes.provider) is waiting for your answer" }
        switch state.status {
        case "working": return "\(attributes.provider) is working"
        case "idle": return "\(attributes.provider) finished and is waiting"
        case "exited": return "\(attributes.provider) ended"
        default: return "\(attributes.provider) · \(attributes.mac)"
        }
    }

    static func colour(_ state: SessionActivityAttributes.ContentState) -> Color {
        if state.asking { return .orange }
        switch state.status {
        case "working": return Color(red: 0.24, green: 0.60, blue: 1.00)
        case "idle": return .green
        case "starting": return .yellow
        default: return .gray
        }
    }
}

/// The one link a widget may open: the app, on a session. It navigates only.
enum SessionLink {
    static func url(tabID: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "sigilremote"
        parts.host = "session"
        parts.queryItems = [URLQueryItem(name: "tab", value: tabID)]
        return parts.url
    }
}
