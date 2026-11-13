import PhotosUI
import SwiftUI

/// Creator-only: write a new post or edit an existing one.
struct ComposePostView: View {
    /// The post being edited, or nil for a new one.
    let editing: Post?

    @Environment(Stores.self) private var stores
    @Environment(\.dismiss) private var dismiss

    @State private var kind: PostKind = .post
    @State private var text = ""
    @State private var linkText = ""
    @State private var preview = Media.LinkPreview()
    @State private var previewURL: URL?
    @State private var isFetchingPreview = false

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var attachment: Attachment?
    @State private var isPreparingMedia = false

    @State private var isEarly = true
    @State private var hasPublicDate = false
    @State private var publicAt = Calendar.current.date(byAdding: .day, value: 2, to: .now) ?? .now

    @State private var agentContext = ""
    @State private var isPosting = false
    @State private var errorMessage: String?
    @State private var didLoad = false

    /// What's attached to a new post: one or more photos (two or more make a
    /// carousel), or a single video.
    private enum Attachment {
        case images([Media.PreparedImage])
        case video(Media.PreparedVideo)

        var thumbnails: [UIImage] {
            switch self {
            case .images(let images): return images.map(\.image)
            case .video(let video): return [video.poster.image]
            }
        }

        var label: String {
            switch self {
            case .images(let images):
                return images.count == 1 ? "Photo" : "\(images.count) photos · swipeable"
            case .video(let video):
                return "Video · \(Int(video.duration.rounded()))s"
            }
        }
    }

    private static let maxPhotos = 10

    private var link: URL? {
        let raw = linkText.trimmed
        guard !raw.isEmpty else { return nil }
        let withScheme = raw.contains("://") ? raw : "https://\(raw)"
        guard let url = URL(string: withScheme), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil else { return nil }
        return url
    }

    private var hasContent: Bool {
        !text.trimmed.isEmpty || link != nil || attachment != nil || editing?.mediaPath != nil
    }

    private var canPost: Bool {
        hasContent && !isPosting && !isPreparingMedia && (linkText.trimmed.isEmpty || link != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        Text("My post").tag(PostKind.post)
                        Text("Share a link").tag(PostKind.share)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                Section {
                    TextField(kind == .post ? "What's new?" : "Why you're sharing it", text: $text, axis: .vertical)
                        .lineLimit(4...14)
                }

                Section {
                    TextField("https://", text: $linkText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !linkText.trimmed.isEmpty && link == nil {
                        Text("That doesn't look like a web address.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } else if isFetchingPreview {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Getting the preview…").font(.footnote).foregroundStyle(.secondary)
                        }
                    } else if let link, previewURL == link, preview.title != nil || preview.image != nil {
                        HStack(spacing: 12) {
                            if let image = preview.image {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 52, height: 52)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            Text(preview.title ?? link.absoluteString)
                                .font(.subheadline)
                                .lineLimit(2)
                        }
                    }
                } header: {
                    Text("Link")
                }

                mediaSection

                if kind == .post {
                    Section {
                        Toggle("Early access", isOn: $isEarly)
                        if isEarly {
                            Toggle("Set a public date", isOn: $hasPublicDate)
                            if hasPublicDate {
                                DatePicker("Goes public", selection: $publicAt, displayedComponents: [.date])
                            }
                        }
                    } footer: {
                        Text("Marks the post EARLY: members are seeing it before it's on your public accounts.")
                    }
                }

                Section {
                    TextField("Transcript, backstory, anything \(Creator.agentName) should know", text: $agentContext, axis: .vertical)
                        .lineLimit(3...10)
                } header: {
                    Text("Notes for \(Creator.agentName)")
                } footer: {
                    Text("Never shown to members. \(Creator.agentName) can't watch videos or see images, so this is how it knows what's in them.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(editing == nil ? "New post" : "Edit post")
            .navigationBarTitleDisplayMode(.inline)
            .trackScreen(editing == nil ? "New post" : "Edit post")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isPosting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isPosting {
                        ProgressView()
                    } else {
                        Button(editing == nil ? "Post" : "Save") { Task { await submit() } }
                            .fontWeight(.semibold)
                            .disabled(!canPost)
                    }
                }
            }
            .interactiveDismissDisabled(isPosting)
            .task { await loadExisting() }
            .task(id: linkText) { await refreshPreview() }
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await prepare(items) }
            }
        }
    }

    @ViewBuilder
    private var mediaSection: some View {
        Section {
            if let editing, editing.mediaPath != nil {
                Label(
                    editing.mediaKind == .video
                        ? "Video attached"
                        : (editing.carousel.isEmpty ? "Photo attached" : "\(editing.carousel.count) photos attached"),
                    systemImage: editing.mediaKind == .video ? "video" : "photo"
                )
                .foregroundStyle(.secondary)
            } else if isPreparingMedia {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Preparing…").foregroundStyle(.secondary)
                }
            } else if let attachment {
                VStack(alignment: .leading, spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(attachment.thumbnails.enumerated()), id: \.offset) { _, thumbnail in
                                Image(uiImage: thumbnail)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        }
                    }
                    HStack {
                        Text(attachment.label)
                        Spacer()
                        Button("Remove", role: .destructive) {
                            self.attachment = nil
                            pickerItems = []
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } else {
                PhotosPicker(
                    selection: $pickerItems,
                    maxSelectionCount: Self.maxPhotos,
                    selectionBehavior: .ordered,
                    matching: .any(of: [.images, .videos])
                ) {
                    Label("Add photos or a video", systemImage: "photo.on.rectangle")
                }
            }
        } header: {
            Text("Media")
        } footer: {
            if editing?.mediaPath != nil {
                Text("To change the media, delete this post and post again.")
            } else if attachment == nil {
                Text("Pick several photos to make a carousel members can swipe through, or one video.")
            }
        }
    }

    // MARK: Loading

    private func loadExisting() async {
        guard !didLoad else { return }
        didLoad = true
        guard let editing else { return }
        kind = editing.kind
        text = editing.body
        linkText = editing.linkURL ?? ""
        isEarly = editing.isEarly
        if let date = editing.publicAt {
            hasPublicDate = true
            publicAt = date
        }
        agentContext = await stores.feed.agentContext(for: editing)
    }

    /// Fetch the title + image for the typed link once typing pauses.
    private func refreshPreview() async {
        guard let link else {
            previewURL = nil
            return
        }
        // Editing and the link is unchanged: keep the stored preview.
        if let editing, editing.link == link { return }
        guard previewURL != link else { return }
        try? await Task.sleep(for: .milliseconds(700))
        guard !Task.isCancelled else { return }
        isFetchingPreview = true
        let fetched = await Media.linkPreview(for: link)
        isFetchingPreview = false
        guard !Task.isCancelled else { return }
        preview = fetched
        previewURL = link
    }

    private func prepare(_ items: [PhotosPickerItem]) async {
        isPreparingMedia = true
        errorMessage = nil
        defer { isPreparingMedia = false }
        do {
            let isMovie: (PhotosPickerItem) -> Bool = { item in
                item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            }
            if let video = items.first(where: isMovie) {
                // A post carries one video; any photos picked alongside it are dropped.
                guard let movie = try await video.loadTransferable(type: PickedMovie.self) else {
                    throw AppError("That video couldn't be loaded.")
                }
                defer { try? FileManager.default.removeItem(at: movie.url) }
                attachment = .video(try await Media.prepareVideo(from: movie.url))
                if items.count > 1 {
                    errorMessage = "A post can have one video or several photos, so only the video was kept."
                }
            } else {
                var prepared: [Media.PreparedImage] = []
                for item in items.prefix(Self.maxPhotos) {
                    guard let data = try await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else {
                        throw AppError("One of those photos couldn't be loaded.")
                    }
                    prepared.append(try Media.prepareImage(image))
                }
                attachment = .images(prepared)
            }
        } catch {
            attachment = nil
            pickerItems = []
            errorMessage = friendlyMessage(error)
        }
    }

    // MARK: Saving

    private func submit() async {
        isPosting = true
        errorMessage = nil
        var uploaded: [String] = []
        do {
            var fields = PostFields(
                kind: kind,
                body: text.trimmed,
                linkURL: link?.absoluteString,
                linkTitle: nil,
                linkImagePath: nil,
                mediaKind: editing?.mediaKind,
                mediaPath: editing?.mediaPath,
                mediaPosterPath: editing?.mediaPosterPath,
                mediaWidth: editing?.mediaWidth,
                mediaHeight: editing?.mediaHeight,
                mediaDuration: editing?.mediaDuration,
                isEarly: kind == .post && isEarly,
                publicAt: (kind == .post && isEarly && hasPublicDate) ? publicAt : nil
            )

            // Link preview: keep what's stored if the link didn't change.
            if let link {
                if let editing, editing.link == link {
                    fields.linkTitle = editing.linkTitle
                    fields.linkImagePath = editing.linkImagePath
                } else {
                    if previewURL != link {
                        preview = await Media.linkPreview(for: link)
                        previewURL = link
                    }
                    fields.linkTitle = preview.title.map { String($0.prefix(300)) }
                    if let image = preview.image {
                        let prepared = try Media.prepareImage(image, maxSide: 400, quality: 0.8)
                        let path = try await Media.upload(prepared, folder: "links")
                        uploaded.append(path)
                        fields.linkImagePath = path
                    }
                }
            }

            // Keep an edited post's photos; a new attachment below replaces them.
            fields.gallery = editing?.gallery ?? []

            switch attachment {
            case .images(let images):
                var gallery: [GalleryImage] = []
                for image in images {
                    let path = try await Media.upload(image, folder: "images")
                    uploaded.append(path)
                    gallery.append(GalleryImage(path: path, width: image.width, height: image.height))
                }
                // The first photo doubles as the post's single image, which is
                // what app builds from before carousels show.
                fields.mediaKind = .image
                fields.mediaPath = gallery.first?.path
                fields.mediaWidth = images.first?.width
                fields.mediaHeight = images.first?.height
                fields.gallery = gallery.count > 1 ? gallery : []
            case .video(let video):
                let poster = try await Media.upload(video.poster, folder: "posters")
                uploaded.append(poster)
                let path = try await Media.uploadVideo(at: video.fileURL)
                uploaded.append(path)
                fields.mediaKind = .video
                fields.mediaPath = path
                fields.mediaPosterPath = poster
                fields.mediaWidth = video.width
                fields.mediaHeight = video.height
                fields.mediaDuration = video.duration
            case .none:
                break
            }

            if let editing {
                try await stores.feed.update(editing, with: fields, agentContext: agentContext)
                // The old link thumbnail is orphaned once the link changes.
                if let old = editing.linkImagePath, old != fields.linkImagePath {
                    await Media.remove([old])
                }
            } else {
                try await stores.feed.create(fields, agentContext: agentContext)
            }
            if case .video(let video) = attachment {
                try? FileManager.default.removeItem(at: video.fileURL)
            }
            dismiss()
        } catch {
            // Don't leave half a post's files behind.
            await Media.remove(uploaded)
            errorMessage = friendlyMessage(error)
            isPosting = false
        }
    }
}
