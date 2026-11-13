import Foundation
import Observation

enum AppTab: Hashable {
    case feed
    case agent
    case direct
    case goals
    case you
}

/// Which tab is showing. Lets one screen send the member to another
/// (e.g. "Ask <agent>" on a post).
@MainActor
@Observable
final class Router {
    var tab: AppTab = .feed
}

/// Everything that belongs to the signed-in account. Started when someone
/// signs in and emptied when they sign out, so no data outlives its owner.
@MainActor
@Observable
final class Stores {
    let goals = GoalsStore()
    let feed = FeedStore()
    let agent = AgentStore()
    let inbox = InboxStore()
    let notes = NotesStore()
    /// A member's own thread with the creator. Nil for the creator, who has an inbox.
    private(set) var direct: DirectStore?

    private var activeUser: UUID?
    private var activeIsAdmin = false

    /// Unread count for the badge on the creator / Inbox tab.
    var unreadDirect: Int {
        activeIsAdmin ? inbox.totalUnread : (direct?.unread ?? 0)
    }

    func begin(userId: UUID, isAdmin: Bool) async {
        guard activeUser != userId || activeIsAdmin != isAdmin else { return }
        await end()
        activeUser = userId
        activeIsAdmin = isAdmin

        if isAdmin {
            await inbox.start()
        } else {
            let thread = DirectStore(threadId: userId, myId: userId)
            direct = thread
            await thread.start()
        }
        async let goalsLoad: Void = goals.load(for: userId)
        async let feedLoad: Void = feed.load()
        async let agentLoad: Void = agent.load(for: userId)
        _ = await (goalsLoad, feedLoad, agentLoad)
    }

    func end() async {
        await direct?.stop()
        direct = nil
        await inbox.stop()
        goals.reset()
        feed.reset()
        agent.reset()
        activeUser = nil
        activeIsAdmin = false
    }

    /// Called when the app comes back to the foreground.
    func refresh() async {
        guard let activeUser else { return }
        async let feedLoad: Void = feed.load()
        async let agentLoad: Void = agent.load(for: activeUser)
        async let directLoad: Void = reloadDirect()
        _ = await (feedLoad, agentLoad, directLoad)
    }

    private func reloadDirect() async {
        if activeIsAdmin {
            await inbox.load()
        } else {
            await direct?.load()
        }
    }
}
