import Foundation

// MARK: - Profile

struct Profile: Codable, Identifiable, Equatable {
    let id: UUID
    var displayName: String
    var isAdmin: Bool
    var onboardedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case isAdmin = "is_admin"
        case onboardedAt = "onboarded_at"
    }
}

// MARK: - Goals

enum GoalStatus: String, Codable {
    case active
    case done
}

struct Goal: Codable, Identifiable, Equatable {
    let id: UUID
    let userId: UUID
    var title: String
    var details: String
    var status: GoalStatus
    /// Calendar day as "yyyy-MM-dd" (a Postgres `date`, so no time zone).
    var targetDate: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title, details, status
        case userId = "user_id"
        case targetDate = "target_date"
        case createdAt = "created_at"
    }

    var target: Date? { targetDate.flatMap(DayFormat.date(from:)) }
}

/// The editable fields of a goal, for inserts and updates.
struct GoalFields: Encodable {
    var title: String
    var details: String
    var status: GoalStatus
    var targetDate: String?

    enum CodingKeys: String, CodingKey {
        case title, details, status
        case targetDate = "target_date"
    }

    // Always send target_date (as null when cleared) so an update can remove it.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(details, forKey: .details)
        try container.encode(status, forKey: .status)
        try container.encode(targetDate, forKey: .targetDate)
    }
}

enum DayFormat {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(from string: String) -> Date? { formatter.date(from: string) }
    static func string(from date: Date) -> String { formatter.string(from: date) }
}

// MARK: - Feed

enum PostKind: String, Codable, CaseIterable {
    case post
    case share
}

enum MediaKind: String, Codable {
    case image
    case video
}

/// One photo of a carousel post.
struct GalleryImage: Codable, Equatable, Hashable {
    let path: String
    var width: Int?
    var height: Int?
}

struct Post: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var kind: PostKind
    var body: String
    var linkURL: String?
    var linkTitle: String?
    var linkImagePath: String?
    var mediaKind: MediaKind?
    var mediaPath: String?
    var mediaPosterPath: String?
    var mediaWidth: Int?
    var mediaHeight: Int?
    var mediaDuration: Double?
    /// The photos of a carousel post, in order. Empty for everything else.
    var gallery: [GalleryImage]?
    var isEarly: Bool
    var publicAt: Date?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, kind, body, gallery
        case linkURL = "link_url"
        case linkTitle = "link_title"
        case linkImagePath = "link_image_path"
        case mediaKind = "media_kind"
        case mediaPath = "media_path"
        case mediaPosterPath = "media_poster_path"
        case mediaWidth = "media_width"
        case mediaHeight = "media_height"
        case mediaDuration = "media_duration"
        case isEarly = "is_early"
        case publicAt = "public_at"
        case createdAt = "created_at"
    }

    var link: URL? { linkURL.flatMap(URL.init(string:)) }

    /// Width / height of the attached media, clamped so a very tall or very
    /// wide asset still gets a sensible box in the feed.
    var mediaAspect: CGFloat {
        guard let w = mediaWidth, let h = mediaHeight, w > 0, h > 0 else { return 1 }
        return min(max(CGFloat(w) / CGFloat(h), 0.6), 1.91)
    }

    /// True while this is something members have that the public doesn't yet.
    var isStillEarly: Bool {
        guard isEarly else { return false }
        guard let publicAt else { return true }
        return publicAt > .now
    }

    /// The photos to swipe through, when this is a carousel (two or more).
    var carousel: [GalleryImage] {
        let images = gallery ?? []
        return images.count > 1 ? images : []
    }

    /// Every storage object this post owns (for cleanup on delete).
    var storagePaths: [String] {
        let single = [mediaPath, mediaPosterPath, linkImagePath].compactMap { $0 }
        return Array(Set(single + (gallery ?? []).map(\.path)))
    }
}

/// The writable fields of a post.
struct PostFields: Encodable {
    var kind: PostKind
    var body: String
    var linkURL: String?
    var linkTitle: String?
    var linkImagePath: String?
    var mediaKind: MediaKind?
    var mediaPath: String?
    var mediaPosterPath: String?
    var mediaWidth: Int?
    var mediaHeight: Int?
    var mediaDuration: Double?
    var gallery: [GalleryImage] = []
    var isEarly: Bool
    var publicAt: Date?

    enum CodingKeys: String, CodingKey {
        case kind, body, gallery
        case linkURL = "link_url"
        case linkTitle = "link_title"
        case linkImagePath = "link_image_path"
        case mediaKind = "media_kind"
        case mediaPath = "media_path"
        case mediaPosterPath = "media_poster_path"
        case mediaWidth = "media_width"
        case mediaHeight = "media_height"
        case mediaDuration = "media_duration"
        case isEarly = "is_early"
        case publicAt = "public_at"
    }

    // Encode every key (nulls included) so edits can clear a link or a date.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(body, forKey: .body)
        try c.encode(linkURL, forKey: .linkURL)
        try c.encode(linkTitle, forKey: .linkTitle)
        try c.encode(linkImagePath, forKey: .linkImagePath)
        try c.encode(mediaKind, forKey: .mediaKind)
        try c.encode(mediaPath, forKey: .mediaPath)
        try c.encode(mediaPosterPath, forKey: .mediaPosterPath)
        try c.encode(mediaWidth, forKey: .mediaWidth)
        try c.encode(mediaHeight, forKey: .mediaHeight)
        try c.encode(mediaDuration, forKey: .mediaDuration)
        try c.encode(gallery, forKey: .gallery)
        try c.encode(isEarly, forKey: .isEarly)
        try c.encode(publicAt, forKey: .publicAt)
    }
}

struct PostContext: Codable {
    let postId: UUID
    var context: String

    enum CodingKeys: String, CodingKey {
        case postId = "post_id"
        case context
    }
}

// MARK: - The agent

enum AgentRole: String, Codable {
    case user
    case assistant
}

struct AgentMessage: Codable, Identifiable, Equatable {
    let id: UUID
    let role: AgentRole
    var content: String
    var postId: UUID?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, role, content
        case postId = "post_id"
        case createdAt = "created_at"
    }
}

struct AgentNote: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var content: String
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title, content
        case updatedAt = "updated_at"
    }
}

struct AgentNoteFields: Encodable {
    var title: String
    var content: String
}

// MARK: - Direct messages

struct DirectMessage: Codable, Identifiable, Equatable {
    let id: UUID
    let threadUserId: UUID
    let senderId: UUID
    let body: String
    let createdAt: Date
    var readAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, body
        case threadUserId = "thread_user_id"
        case senderId = "sender_id"
        case createdAt = "created_at"
        case readAt = "read_at"
    }

    /// True when the member (not the creator) wrote this.
    var isFromMember: Bool { senderId == threadUserId }
}

struct DirectMessageInsert: Encodable {
    let threadUserId: UUID
    let body: String

    enum CodingKeys: String, CodingKey {
        case threadUserId = "thread_user_id"
        case body
    }
}

/// One row of the creator's inbox (the `admin_threads` RPC).
struct ThreadSummary: Codable, Identifiable, Equatable, Hashable {
    let memberId: UUID
    let memberName: String
    let memberEmail: String
    let lastBody: String
    let lastAt: Date
    let lastFromMember: Bool
    let unread: Int
    let activeGoals: Int

    var id: UUID { memberId }

    enum CodingKeys: String, CodingKey {
        case memberId = "member_id"
        case memberName = "member_name"
        case memberEmail = "member_email"
        case lastBody = "last_body"
        case lastAt = "last_at"
        case lastFromMember = "last_from_member"
        case unread
        case activeGoals = "active_goals"
    }

    /// What to call this member in the inbox.
    var title: String {
        if !memberName.trimmingCharacters(in: .whitespaces).isEmpty { return memberName }
        if !memberEmail.isEmpty { return memberEmail }
        return "Member"
    }
}
