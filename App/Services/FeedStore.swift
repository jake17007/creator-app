import Foundation
import Observation
import Supabase

/// The feed's posts, newest first. Everyone reads; only the creator writes
/// (row-level security enforces that, not this class).
@MainActor
@Observable
final class FeedStore {
    private(set) var posts: [Post] = []
    private(set) var hasLoaded = false
    var errorMessage: String?

    private static let columns = """
        id, kind, body, link_url, link_title, link_image_path, media_kind, media_path, \
        media_poster_path, media_width, media_height, media_duration, gallery, is_early, public_at, created_at
        """

    func load() async {
        do {
            posts = try await supabase
                .from("posts")
                .select(Self.columns)
                .order("created_at", ascending: false)
                .limit(100)
                .execute()
                .value
            hasLoaded = true
            errorMessage = nil
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    func reset() {
        posts = []
        hasLoaded = false
        errorMessage = nil
    }

    // MARK: Creator actions

    func create(_ fields: PostFields, agentContext: String) async throws {
        let created: Post = try await supabase
            .from("posts")
            .insert(fields)
            .select(Self.columns)
            .single()
            .execute()
            .value
        posts.insert(created, at: 0)
        Analytics.event("post_created", [
            "kind": created.kind.rawValue,
            "media": created.carousel.isEmpty ? (created.mediaKind?.rawValue ?? "none") : "carousel",
            "early": created.isEarly,
        ])
        // The post is live at this point; a failed note save must not undo it.
        try? await saveAgentContext(agentContext, for: created.id)
    }

    func update(_ post: Post, with fields: PostFields, agentContext: String) async throws {
        let updated: Post = try await supabase
            .from("posts")
            .update(fields)
            .eq("id", value: post.id.uuidString)
            .select(Self.columns)
            .single()
            .execute()
            .value
        if let index = posts.firstIndex(where: { $0.id == post.id }) {
            posts[index] = updated
        }
        try? await saveAgentContext(agentContext, for: post.id)
    }

    func delete(_ post: Post) async {
        do {
            try await supabase.from("posts").delete().eq("id", value: post.id.uuidString).execute()
            posts.removeAll { $0.id == post.id }
            await Media.remove(post.storagePaths)
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    /// The private notes the agent gets about a post (e.g. a video's transcript).
    func agentContext(for post: Post) async -> String {
        let rows: [PostContext]? = try? await supabase
            .from("post_context")
            .select("post_id, context")
            .eq("post_id", value: post.id.uuidString)
            .execute()
            .value
        return rows?.first?.context ?? ""
    }

    private func saveAgentContext(_ text: String, for postId: UUID) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try await supabase.from("post_context").delete().eq("post_id", value: postId.uuidString).execute()
        } else {
            try await supabase
                .from("post_context")
                .upsert(PostContext(postId: postId, context: trimmed))
                .execute()
        }
    }
}
