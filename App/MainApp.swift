import SwiftUI

@main
struct MainApp: App {
    @State private var appState = AppState()
    @State private var stores = Stores()
    @State private var router = Router()

    init() {
        Analytics.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(stores)
                .environment(router)
        }
    }
}
