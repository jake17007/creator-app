import AVFoundation
import CoreTransferable
import LinkPresentation
import Supabase
import UIKit
import UniformTypeIdentifiers

/// Reads from and writes to the app's private media bucket (`Backend.mediaBucket`).
enum Media {
    // MARK: Reading

    private static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 120
        return cache
    }()

    /// Downloads (or returns the cached copy of) an image in the bucket.
    static func image(at path: String) async throws -> UIImage {
        if let cached = imageCache.object(forKey: path as NSString) { return cached }
        let data = try await supabase.storage.from(Backend.mediaBucket).download(path: path)
        guard let image = UIImage(data: data) else { throw AppError("That image couldn't be read.") }
        imageCache.setObject(image, forKey: path as NSString)
        return image
    }

    static func cache(_ image: UIImage, at path: String) {
        imageCache.setObject(image, forKey: path as NSString)
    }

    /// A short-lived URL the video player can stream from.
    static func streamURL(for path: String) async throws -> URL {
        try await SignedURLCache.shared.url(for: path)
    }

    // MARK: Writing (creator only; storage policies enforce it)

    struct PreparedImage {
        let data: Data
        let image: UIImage
        var width: Int { Int(image.size.width * image.scale) }
        var height: Int { Int(image.size.height * image.scale) }
    }

    struct PreparedVideo {
        let fileURL: URL
        let poster: PreparedImage
        let width: Int
        let height: Int
        let duration: Double
    }

    /// Downscales to at most `maxSide` on the long edge and encodes as JPEG.
    static func prepareImage(_ source: UIImage, maxSide: CGFloat = 2048, quality: CGFloat = 0.82) throws -> PreparedImage {
        let longest = max(source.size.width, source.size.height)
        let scale = min(1, maxSide / max(longest, 1))
        let target = CGSize(width: (source.size.width * scale).rounded(), height: (source.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = resized.jpegData(compressionQuality: quality) else {
            throw AppError("That image couldn't be prepared for upload.")
        }
        return PreparedImage(data: data, image: resized)
    }

    /// Re-encodes a picked video as 1080p HEVC small enough to upload on a
    /// phone connection, and grabs a poster frame for the feed.
    static func prepareVideo(from source: URL) async throws -> PreparedVideo {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AppError("That file doesn't contain a video.")
        }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let oriented = natural.applying(transform)
        let width = Int(abs(oriented.width).rounded())
        let height = Int(abs(oriented.height).rounded())

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVC1920x1080)
            ?? AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw AppError("This video can't be exported on this device.")
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString).mp4")
        export.outputURL = output
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        // Stay under the storage upload ceiling; quality scales down to fit.
        export.fileLengthLimit = 48 * 1024 * 1024
        await export.export()
        guard export.status == .completed else {
            throw AppError(export.error?.localizedDescription ?? "The video couldn't be prepared for upload.")
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        let time = CMTime(seconds: min(0.5, max(duration / 2, 0)), preferredTimescale: 600)
        let frame = try await generator.image(at: time).image
        let poster = try prepareImage(UIImage(cgImage: frame), maxSide: 1280, quality: 0.8)

        return PreparedVideo(fileURL: output, poster: poster, width: width, height: height, duration: duration)
    }

    @discardableResult
    static func upload(_ image: PreparedImage, folder: String) async throws -> String {
        let path = "\(folder)/\(UUID().uuidString.lowercased()).jpg"
        try await supabase.storage.from(Backend.mediaBucket)
            .upload(path, data: image.data, options: FileOptions(cacheControl: "31536000", contentType: "image/jpeg"))
        cache(image.image, at: path)
        return path
    }

    static func uploadVideo(at fileURL: URL) async throws -> String {
        let path = "videos/\(UUID().uuidString.lowercased()).mp4"
        try await supabase.storage.from(Backend.mediaBucket)
            .upload(path, fileURL: fileURL, options: FileOptions(cacheControl: "31536000", contentType: "video/mp4"))
        return path
    }

    static func remove(_ paths: [String]) async {
        guard !paths.isEmpty else { return }
        _ = try? await supabase.storage.from(Backend.mediaBucket).remove(paths: paths)
    }

    // MARK: Link previews

    struct LinkPreview {
        var title: String?
        var image: UIImage?
    }

    /// Fetches a page's title and preview image on the creator's device at
    /// compose time, so members never hit third-party sites just to render the feed.
    @MainActor
    static func linkPreview(for url: URL) async -> LinkPreview {
        let provider = LPMetadataProvider()
        provider.timeout = 12
        guard let metadata = try? await provider.startFetchingMetadata(for: url) else {
            return LinkPreview()
        }
        var preview = LinkPreview(title: metadata.title)
        if let imageProvider = metadata.imageProvider, imageProvider.canLoadObject(ofClass: UIImage.self) {
            preview.image = await withCheckedContinuation { continuation in
                _ = imageProvider.loadObject(ofClass: UIImage.self) { object, _ in
                    continuation.resume(returning: object as? UIImage)
                }
            }
        }
        return preview
    }
}

/// Signed URLs are valid for an hour; reuse them until shortly before expiry.
actor SignedURLCache {
    static let shared = SignedURLCache()

    private var entries: [String: (url: URL, expires: Date)] = [:]

    func url(for path: String) async throws -> URL {
        if let entry = entries[path], entry.expires > Date().addingTimeInterval(120) {
            return entry.url
        }
        let url = try await supabase.storage.from(Backend.mediaBucket)
            .createSignedURL(path: path, expiresIn: 3600)
        entries[path] = (url, Date().addingTimeInterval(3600))
        return url
    }
}

/// A video chosen in the photo picker, copied somewhere we can read it.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}
