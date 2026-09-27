import ActivityKit
import Foundation

/// One Live Activity for the session on screen while it works, updated here
/// while the app is open and by the Mac's pushes after that. Ends a few
/// minutes after the session goes quiet, so the Lock Screen is not a graveyard.
@MainActor
final class LiveActivityController {
    private var activity: Activity<SessionActivityAttributes>?
    private var tokenTask: Task<Void, Never>?
    private var endTask: Task<Void, Never>?
    /// Hands each activity's push token to the Mac through the store.
    var onToken: ((_ tabID: String, _ token: String) -> Void)?
    /// Says which tab's activity ended here, so the Mac stops pushing to it.
    var onEnd: ((_ tabID: String) -> Void)?

    var runningTabID: String? { activity?.attributes.tabID }

    /// Reflects the selected tab. Starts when it works, updates on change, ends when it is gone.
    func reflect(tab: RemoteTab?, prompt: RemotePrompt?, mac: String?, macID: String?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let tab else {
            end()
            return
        }
        let state = SessionActivityAttributes.ContentState(
            status: tab.status.raw, since: Int(Date().timeIntervalSince1970), asking: prompt?.verified == true)
        if let activity, activity.attributes.tabID == tab.id {
            // Keep `since` when the status did not change, so the timer does not restart.
            let previous = activity.content.state
            let next =
                previous.status == state.status && previous.asking == state.asking
                ? previous : state
            if next != previous {
                Task { await activity.update(ActivityContent(state: next, staleDate: nil)) }
            }
            scheduleEndIfQuiet(next)
            return
        }
        if activity != nil { end() }
        guard tab.status == .working || prompt?.verified == true else { return }
        let attributes = SessionActivityAttributes(
            tabID: tab.id, title: tab.title, provider: tab.providerName ?? "Session", mac: mac ?? "Mac", macID: macID)
        do {
            let started = try Activity.request(
                attributes: attributes, content: ActivityContent(state: state, staleDate: nil), pushType: .token)
            activity = started
            tokenTask = Task { [weak self] in
                for await data in started.pushTokenUpdates {
                    let token = data.map { String(format: "%02x", $0) }.joined()
                    await MainActor.run { self?.onToken?(tab.id, token) }
                }
            }
        } catch {
            // Live Activities can be off in Settings; the app works without one.
        }
    }

    private func scheduleEndIfQuiet(_ state: SessionActivityAttributes.ContentState) {
        endTask?.cancel()
        guard state.status != "working", !state.asking else { return }
        let delay: Duration = state.status == "exited" ? .seconds(60) : .seconds(300)
        endTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.end()
        }
    }

    func end() {
        tokenTask?.cancel()
        tokenTask = nil
        endTask?.cancel()
        endTask = nil
        guard let activity else { return }
        self.activity = nil
        let final = activity.content.state
        onEnd?(activity.attributes.tabID)
        Task { await activity.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .default) }
    }
}
