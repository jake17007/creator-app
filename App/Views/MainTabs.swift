import SwiftUI

/// The five tabs. Members get a tab named after the creator (their 1:1 thread); the creator account
/// gets "Inbox" (everyone's threads) in the same slot.
struct MainTabs: View {
    @Environment(AppState.self) private var appState
    @Environment(Stores.self) private var stores
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router

        TabView(selection: $router.tab) {
            FeedView()
                .trackScreen("Feed")
                .tabItem { Label("Feed", systemImage: "newspaper") }
                .tag(AppTab.feed)

            AgentChatView()
                .trackScreen(Creator.agentName)
                .tabItem { Label(Creator.agentName, systemImage: "bubble.left.and.text.bubble.right") }
                .tag(AppTab.agent)

            Group {
                if appState.isAdmin {
                    InboxView()
                } else {
                    MemberThreadView()
                }
            }
            .trackScreen(appState.isAdmin ? "Inbox" : Creator.name)
            .tabItem {
                Label(appState.isAdmin ? "Inbox" : Creator.name,
                      systemImage: appState.isAdmin ? "tray" : "person.crop.circle")
            }
            .badge(stores.unreadDirect)
            .tag(AppTab.direct)

            GoalsView()
                .trackScreen("Goals")
                .tabItem { Label("Goals", systemImage: "target") }
                .tag(AppTab.goals)

            YouView()
                .trackScreen("You")
                .tabItem { Label("You", systemImage: "gearshape") }
                .tag(AppTab.you)
        }
    }
}
