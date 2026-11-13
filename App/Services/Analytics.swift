import Foundation
import PostHog
import SwiftUI

/// Product analytics and screen recordings (PostHog).
///
/// All of it is off unless creator/app.json has a PostHog token. With one:
///
///   - Events (which screens get opened, that a message was sent, never its
///     text) are sent for everyone.
///   - Screen recordings run for everyone, from launch. The app has no prompt
///     and no off switch; the privacy policy is where people are told, and
///     tools/policy.py adds that disclosure whenever analytics is on. App
///     Review guideline 2.5.14 asks for consent before recording user
///     activity; if that matters for your app, ask before calling `start()`.
///
/// In recordings, anything a member wrote or typed (goals, messages, name,
/// email, password) is masked with `.privateContent()`; the feed and the
/// app's own labels stay visible so the recording is still readable.
enum Analytics {
    private static var isStarted = false

    /// Call once at launch.
    static func start() {
        guard !isStarted, !Creator.postHogToken.isEmpty else { return }
        isStarted = true

        let config = PostHogConfig(projectToken: Creator.postHogToken, host: Creator.postHogHost)
        config.captureApplicationLifecycleEvents = true
        // SwiftUI screens have no useful automatic names; they're reported with screen(_:).
        config.captureScreenViews = false
        config.personProfiles = .identifiedOnly

        config.sessionReplay = true
        config.sessionReplayConfig.screenshotMode = true        // required for SwiftUI
        config.sessionReplayConfig.maskAllTextInputs = false    // private text is masked view by view
        config.sessionReplayConfig.maskAllImages = false        // images here are the creator's own posts
        config.sessionReplayConfig.captureNetworkTelemetry = false

        PostHogSDK.shared.setup(config)
        registerAppProperties()
    }

    /// Sent with every event, so this app can be told apart from the other
    /// products that report to the same PostHog project.
    private static func registerAppProperties() {
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        // "build_type", because PostHog's own app-opened events already carry a "build" (the build number).
        PostHogSDK.shared.register(["app": Creator.analyticsApp, "build_type": build])
    }

    /// Ties events and recordings to the signed-in account (id and name only, no email).
    static func identify(userId: UUID, name: String, isCreator: Bool) {
        guard isStarted else { return }
        PostHogSDK.shared.identify(
            userId.uuidString.lowercased(),
            userProperties: ["name": name, "is_creator": isCreator, "app": Creator.analyticsApp]
        )
    }

    /// Forgets the account that was signed in and starts a fresh anonymous visitor.
    static func signedOut() {
        guard isStarted else { return }
        let sdk = PostHogSDK.shared
        // Nothing to forget on a launch where nobody was signed in.
        guard sdk.getDistinctId() != sdk.getAnonymousId() else { return }
        sdk.reset()
        registerAppProperties()
    }

    static func screen(_ name: String) {
        guard isStarted else { return }
        PostHogSDK.shared.screen(name)
    }

    /// Record that something happened. Never pass what a member wrote.
    static func event(_ name: String, _ properties: [String: Any] = [:]) {
        guard isStarted else { return }
        PostHogSDK.shared.capture(name, properties: properties)
    }
}

extension View {
    /// Hides this view in screen recordings. Use on anything a member wrote or
    /// typed, and on anything that identifies them.
    func privateContent() -> some View {
        postHogMask()
    }

    /// Reports this screen to analytics each time it comes on screen.
    func trackScreen(_ name: String) -> some View {
        onAppear { Analytics.screen(name) }
    }
}
