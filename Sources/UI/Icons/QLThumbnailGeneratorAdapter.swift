// Sources/UI/Icons/QLThumbnailGeneratorAdapter.swift
import AppKit
import QuickLookThumbnailing
import MacxFS

/// CGImage is immutable; handed once from the QL callback to the main actor.
private struct SendableImage: @unchecked Sendable { let image: CGImage? }

/// ThumbnailGenerating over QLThumbnailGenerator.shared. Quick Look renders out of process; nothing here reads the
/// file on the main thread.
@MainActor
final class QLThumbnailGeneratorAdapter: ThumbnailGenerating {
    private var requests: [ThumbnailTicket: QLThumbnailGenerator.Request] = [:]
    private var next: UInt64 = 0

    func generate(url: URL, pointSize: CGFloat, scale: CGFloat, completion: @escaping @MainActor (CGImage?) -> Void) -> ThumbnailTicket {
        next += 1
        let ticket = ThumbnailTicket(raw: next)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: pointSize, height: pointSize),
                                                   scale: scale, representationTypes: .thumbnail)
        requests[ticket] = request
        let state = PerfSignposts.signposter.beginInterval(PerfSignposts.thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            let box = SendableImage(image: representation?.cgImage)
            Task { @MainActor in
                PerfSignposts.signposter.endInterval(PerfSignposts.thumbnail, state)
                guard let self, self.requests.removeValue(forKey: ticket) != nil else { return }   // cancelled
                completion(box.image)
            }
        }
        return ticket
    }

    func cancel(_ ticket: ThumbnailTicket) {
        if let request = requests.removeValue(forKey: ticket) { QLThumbnailGenerator.shared.cancel(request) }
    }
}
