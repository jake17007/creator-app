import AVKit
import SwiftUI

/// The creator's posts, newest first. The creator account also gets a compose button.
struct FeedView: View {
    @Environment(AppState.self) private var appState
    @Environment(Stores.self) private var stores
    @Environment(Router.self) private var router

    @State private var composing = false
    @State private var editing: Post?
    @State private var deleting: Post?
    @State private var playing: Post?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let message = stores.feed.errorMessage, stores.feed.posts.isEmpty {
                        ContentUnavailableView {
                            Label("Couldn't load the feed", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(message)
                        } actions: {
                            Button("Try again") { Task { await stores.feed.load() } }
                        }
                        .padding(.top, 80)
                    } else if stores.feed.posts.isEmpty && stores.feed.hasLoaded {
                        ContentUnavailableView {
                            Label("Nothing here yet", systemImage: "newspaper")
                        } description: {
                            Text(appState.isAdmin
                                 ? "Tap + to post. Members see it here before anywhere else."
                                 : "New posts land here first, before they go anywhere else.")
                        }
                        .padding(.top, 80)
                    } else if !stores.feed.hasLoaded {
                        ProgressView().padding(.top, 80)
                    }

                    ForEach(stores.feed.posts) { post in
                        PostCard(
                            post: post,
                            isAdmin: appState.isAdmin,
                            onAsk: {
                                Analytics.event("ask_about_post")
                                stores.agent.aboutPost = post
                                router.tab = .agent
                            },
                            onPlay: {
                                Analytics.event("video_played")
                                playing = post
                            },
                            onEdit: { editing = post },
                            onDelete: { deleting = post }
                        )
                        Divider()
                    }
                }
            }
            .refreshable { await stores.feed.load() }
            .navigationTitle("Feed")
            .toolbar {
                if appState.isAdmin {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            composing = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityLabel("New post")
                    }
                }
            }
            .sheet(isPresented: $composing) {
                ComposePostView(editing: nil)
            }
            .sheet(item: $editing) { post in
                ComposePostView(editing: post)
            }
            .fullScreenCover(item: $playing) { post in
                VideoScreen(post: post)
            }
            .confirmationDialog(
                "Delete this post?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let post = deleting { Task { await stores.feed.delete(post) } }
                    deleting = nil
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: {
                Text("It disappears for every member. This can't be undone.")
            }
        }
    }
}

// MARK: - One post

struct PostCard: View {
    let post: Post
    let isAdmin: Bool
    var onAsk: () -> Void
    var onPlay: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if !post.body.trimmed.isEmpty {
                Text(post.body.linkified)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            media

            if let url = post.link {
                Button {
                    openURL(url)
                } label: {
                    LinkCard(title: post.linkTitle, url: url, imagePath: post.linkImagePath)
                }
                .buttonStyle(.plain)
            }

            Button(action: onAsk) {
                Label("Ask \(Creator.agentName)", systemImage: "bubble.left")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.borderless)
            .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            CreatorAvatar(size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Creator.name).font(.subheadline.weight(.semibold))
                    Text(post.createdAt.feedStamp)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if post.isStillEarly { EarlyBadge() }
                }
                if let caption = statusLine {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if isAdmin {
                Menu {
                    Button(action: onEdit) { Label("Edit", systemImage: "pencil") }
                    Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Post options")
            }
        }
    }

    /// The small line under the name: what kind of post, and its early status.
    private var statusLine: String? {
        var parts: [String] = []
        if post.kind == .share { parts.append("Shared a link") }
        if post.isEarly {
            if post.isStillEarly, let publicAt = post.publicAt {
                parts.append("Public \(publicAt.formatted(.dateTime.month(.abbreviated).day()))")
            } else if post.isStillEarly {
                parts.append("Only here for now")
            } else {
                parts.append("You saw it here first")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var media: some View {
        switch post.mediaKind {
        case .image:
            if !post.carousel.isEmpty {
                CarouselView(images: post.carousel)
            } else if let path = post.mediaPath {
                StorageImage(path: path, aspect: post.mediaAspect)
            }
        case .video:
            Button(action: onPlay) {
                ZStack {
                    if let poster = post.mediaPosterPath {
                        StorageImage(path: poster, aspect: post.mediaAspect)
                    } else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.bubble)
                            .aspectRatio(post.mediaAspect, contentMode: .fit)
                    }
                    Image(systemName: "play.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 58, height: 58)
                        .background(.black.opacity(0.55), in: Circle())
                    if let duration = post.mediaDuration, duration > 0 {
                        Text(Self.clock(duration))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.6), in: Capsule())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .padding(10)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play video")
        case .none:
            EmptyView()
        }
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}

// MARK: - Pieces

/// Several photos in one post: swipe sideways through them.
struct CarouselView: View {
    let images: [GalleryImage]
    @State private var page = 0

    /// Every photo sits in one box shaped by the first photo, so the post
    /// doesn't change height as you swipe.
    private var aspect: CGFloat {
        guard let first = images.first, let w = first.width, let h = first.height, w > 0, h > 0 else {
            return 1
        }
        return min(max(CGFloat(w) / CGFloat(h), 0.75), 1.91)
    }

    var body: some View {
        VStack(spacing: 8) {
            TabView(selection: $page) {
                ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                    StorageImage(path: image.path, aspect: aspect)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .aspectRatio(aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Text("\(page + 1)/\(images.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(10)
            }

            HStack(spacing: 6) {
                ForEach(images.indices, id: \.self) { index in
                    Circle()
                        .fill(index == page ? Theme.accent : Color(.tertiaryLabel))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Photo \(page + 1) of \(images.count)")
    }
}

/// An image from the private bucket, sized up front so the feed doesn't jump.
struct StorageImage: View {
    let path: String
    let aspect: CGFloat

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Theme.bubble)
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if failed {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .task(id: path) {
                do {
                    image = try await Media.image(at: path)
                    failed = false
                } catch {
                    failed = image == nil
                }
            }
    }
}

struct LinkCard: View {
    let title: String?
    let url: URL
    let imagePath: String?

    var body: some View {
        HStack(spacing: 12) {
            if let imagePath {
                StorageThumb(path: imagePath)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 64, height: 64)
                    .overlay {
                        Image(systemName: "link")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title?.trimmed.isEmpty == false ? title! : url.absoluteString)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(url.host()?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(Theme.bubble, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// A small square crop of a stored image (link previews).
struct StorageThumb: View {
    let path: String
    @State private var image: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(.tertiarySystemFill))
            .frame(width: 64, height: 64)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .task(id: path) { image = try? await Media.image(at: path) }
    }
}

/// Full-screen player for a video post.
struct VideoScreen: View {
    let post: Post
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var errorMessage: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea(edges: .bottom)
            } else if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .padding(.leading, 16)
            .padding(.top, 8)
            .accessibilityLabel("Close")
        }
        .task {
            guard let path = post.mediaPath else {
                errorMessage = "This video is missing."
                return
            }
            do {
                let url = try await Media.streamURL(for: path)
                // A video someone chose to play should have sound even when
                // the phone's ring switch is on silent.
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                let player = AVPlayer(url: url)
                self.player = player
                player.play()
            } catch {
                errorMessage = friendlyMessage(error)
            }
        }
        .onDisappear { player?.pause() }
    }
}
