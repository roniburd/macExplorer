import Darwin
import Foundation
import MacxFS

public struct OpenItem: Sendable, Equatable {
    public var url: URL
    public var kind: Kind
    public var isApplication: Bool

    public init(url: URL, kind: Kind, isApplication: Bool) {
        self.url = url
        self.kind = kind
        self.isApplication = isApplication
    }
}

public enum OpenAction: Sendable, Equatable {
    case navigate(URL)                 // folder in place
    case openInNewWindow(URL)          // ⌘-double-click, or folders of a multi-selection
    case launchApplication(URL)
    case openDocuments([URL])          // default apps
    case brokenLink(URL)               // "The original item can't be found" (Delete / Fix…)
}

public struct OpenPlan: Sendable, Equatable {
    public var actions: [OpenAction]
    public var needsConfirmation: Bool // more than 10 folders would open in new windows

    public init(actions: [OpenAction], needsConfirmation: Bool) {
        self.actions = actions
        self.needsConfirmation = needsConfirmation
    }
}

/// §5.7 Open: folders navigate (or open new windows), `.app`s launch, other packages and files open with their
/// default apps, aliases and symlinks resolve first (a broken one is reported). With several items, folders open in
/// new windows and every document goes into one `openDocuments` action placed where the first document was.
public enum OpenPlanner {
    /// More folders than this opening in new windows needs a confirmation.
    public static let confirmationThreshold = 10

    /// Resolves aliases/symlinks on a read lane; packages other than apps are documents.
    @MainActor public static func plan(_ items: [OpenItem], newWindow: Bool, lanes: LanePool, volumes: Volumes) async -> OpenPlan {
        var targets: [LinkTarget] = []
        targets.reserveCapacity(items.count)
        for item in items {
            switch item.kind {
            case .symlink, .alias:
                let url = item.url
                let volume = volumes.volume(for: url)?.id ?? .unknown
                let resolved = try? await lanes.perform(on: volume, .read) { _ in
                    withNoMaterialization { LinkResolver.resolve(url) }
                }
                targets.append(resolved ?? .document(url))   // unresolvable lane: let LaunchServices try
            case .directory:
                targets.append(item.isApplication ? .application(item.url) : .folder(item.url))
            case .package:
                targets.append(item.isApplication ? .application(item.url) : .document(item.url))
            case .file, .other:
                targets.append(.document(item.url))
            }
        }
        return assemble(targets, originals: items.map(\.url), newWindow: newWindow || items.count > 1)
    }

    static func assemble(_ targets: [LinkTarget], originals: [URL], newWindow: Bool) -> OpenPlan {
        var actions: [OpenAction] = []
        var documentSlot: Int?
        var documents: [URL] = []
        var windows = 0
        for (target, original) in zip(targets, originals) {
            switch target {
            case .folder(let url):
                if newWindow {
                    actions.append(.openInNewWindow(url))
                    windows += 1
                } else {
                    actions.append(.navigate(url))
                }
            case .application(let url):
                actions.append(.launchApplication(url))
            case .document(let url):
                if documentSlot == nil {
                    documentSlot = actions.count
                    actions.append(.openDocuments([]))
                }
                documents.append(url)
            case .broken:
                actions.append(.brokenLink(original))
            }
        }
        if let documentSlot { actions[documentSlot] = .openDocuments(documents) }
        return OpenPlan(actions: actions, needsConfirmation: windows > confirmationThreshold)
    }
}

/// What a link (or plain item) finally points at.
enum LinkTarget: Sendable, Equatable {
    case folder(URL), application(URL), document(URL), broken
}

/// Lane-only resolution of symlink and alias chains.
enum LinkResolver {
    static let maxHops = 32

    static func resolve(_ url: URL) -> LinkTarget {
        assertOffMain()
        var current = url.standardizedFileURL
        for _ in 0..<maxHops {
            var st = stat()
            let path = current.path(percentEncoded: false)
            guard lstat(path, &st) == 0 else { return .broken }
            switch st.st_mode & S_IFMT {
            case S_IFLNK:
                guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return .broken }
                current = destination.hasPrefix("/")
                    ? URL(filePath: destination).standardizedFileURL
                    : current.deletingLastPathComponent().appending(path: destination).standardizedFileURL
            case S_IFDIR:
                let values = try? current.resourceValues(forKeys: [.isApplicationKey, .isPackageKey])
                if values?.isApplication == true { return .application(current) }
                return values?.isPackage == true ? .document(current) : .folder(current)
            case S_IFREG where isAliasFile(current):
                guard let target = try? URL(resolvingAliasFileAt: current, options: [.withoutUI, .withoutMounting]) else {
                    return .broken
                }
                let next = target.standardizedFileURL
                guard next != current else { return .broken }
                current = next
            default:
                return .document(current)
            }
        }
        return .broken   // a loop or an absurdly long chain
    }

    private static func isAliasFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true
    }
}
