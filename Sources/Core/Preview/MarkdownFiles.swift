import Foundation
import MacxFS

/// Markdown files the preview pane renders (Rendered | Source switch), and the local images they show.
public enum MarkdownFiles {
    /// Extensions treated as Markdown (case-insensitive). By name only: the preview already reads the file as text.
    public static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext"]

    public static func isMarkdown(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    /// The largest local image a preview reads (bigger ones stay a placeholder).
    public static let imageByteLimit = 16 << 20

    /// The bytes of a local image a Markdown file references, read on the read lanes without downloading a
    /// dataless (iCloud) item. nil when it is missing, unreadable, not a regular file or over `imageByteLimit`.
    public static func loadImage(_ url: URL, lanes: LanePool, volume: VolumeID) async -> Data? {
        guard url.isFileURL else { return nil }
        let path = url.path(percentEncoded: false)
        let limit = imageByteLimit
        let result = try? await lanes.perform(on: volume) { _ in
            withNoMaterialization { PreviewProbe.read(path, count: limit + 1) }
        }
        guard case .success(let bytes)? = result, !bytes.isEmpty, bytes.count <= limit else { return nil }
        return Data(bytes)
    }
}
