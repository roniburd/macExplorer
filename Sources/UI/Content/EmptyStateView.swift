// Sources/UI/Content/EmptyStateView.swift
import AppKit
import Darwin
import Core

enum EmptyStateAction: Equatable, Sendable {
    case openPrivacySettings, properties, retry
    case searchSubfolders, searchAgain                  // search results (P3-09)

    @MainActor var title: String {
        switch self {
        case .openPrivacySettings: L10n.string("Open Privacy Settings")
        case .properties: L10n.string("Properties")
        case .retry: L10n.string("Retry")
        case .searchSubfolders: L10n.string("search.empty.action.searchSubfolders")
        case .searchAgain: L10n.string("search.empty.action.searchAgain")
        }
    }
}

/// §5.5 empty states. notFound/volumeGone return nil: the window navigates to the nearest ancestor (§4.3).
struct EmptyStateContent: Equatable {
    var title: String
    var detail: String?
    var action: EmptyStateAction?
    var showsSpinner = false

    @MainActor
    static func make(state: FolderState, folderName: String, visibleCount: Int, filter: String) -> EmptyStateContent? {
        func titled(_ key: String) -> String { String(format: L10n.string(key), folderName) }
        switch state {
        case .loading, .partial:
            return nil
        case .complete:
            guard visibleCount == 0 else { return nil }
            if !filter.isEmpty { return EmptyStateContent(title: String(format: L10n.string("No items match '%@'"), filter)) }
            return EmptyStateContent(title: L10n.string("This folder is empty"))
        case .error(let reason):
            switch reason {
            case .permissionTCC:
                return EmptyStateContent(title: titled("macOS is blocking access to '%@'"), action: .openPrivacySettings)
            case .permissionPOSIX:
                return EmptyStateContent(title: titled("You don't have permission to view '%@'"), action: .properties)
            case .notFound, .volumeGone:
                return nil
            case .notADirectory:
                return EmptyStateContent(title: titled("Can't open '%@'"), detail: String(cString: strerror(ENOTDIR)), action: .retry)
            case .other(let code):
                return EmptyStateContent(title: titled("Can't open '%@'"), detail: "\(String(cString: strerror(code))) (\(code))",
                                         action: .retry)
            }
        case .unresponsive:
            return EmptyStateContent(title: L10n.string("Location not responding"), action: .retry)
        case .waitingForPermission:
            return EmptyStateContent(title: L10n.string("Waiting for macOS permission…"), showsSpinner: true)
        }
    }
}

extension EmptyStateContent {
    /// Search results' empty states (P3-09), only while there are no rows. `query` is the search text, or the root
    /// folder's name for `.rootUnreadable` (ContentViewController passes it).
    @MainActor
    static func make(search state: SearchState, notices: [SearchNotice], rowCount: Int, query: String) -> EmptyStateContent? {
        guard rowCount == 0 else { return nil }
        func content(_ titleKey: String, _ arg: String? = nil, detail: String? = nil, action: EmptyStateAction? = nil,
                     spinner: Bool = false) -> EmptyStateContent {
            let title = arg.map { String(format: L10n.string(titleKey), $0) } ?? L10n.string(titleKey)
            return EmptyStateContent(title: title, detail: detail.map(L10n.string), action: action, showsSpinner: spinner)
        }
        switch state {
        case .searching:
            return content("search.empty.searching", spinner: true)
        case .complete, .stopped:
            if notices.contains(.spotlightOff) {
                return content("search.empty.spotlightOff", detail: "search.empty.spotlightOff.detail", action: .searchSubfolders)
            }
            if case .stopped = state { return content("search.empty.stopped", action: .searchAgain) }
            if notices.contains(.mayNotBeIndexed) {
                return content("search.empty.noResults", query, detail: "search.empty.mayNotBeIndexed", action: .searchSubfolders)
            }
            return content("search.empty.noResults", query)
        case .failed(.rootUnreadable(let reason)):
            switch reason {
            case .notFound, .volumeGone: return content("search.empty.rootGone", query, action: .searchAgain)
            default: return content("search.empty.noPermission", query, action: .searchAgain)
            }
        case .failed(.volumeUnresponsive):
            return content("search.empty.unresponsive", action: .searchAgain)
        case .failed(.spotlightFailed):
            return content("search.empty.spotlightFailed", action: .searchAgain)
        }
    }
}

/// Overlay above the list. Only its button takes clicks; everything else falls through to the list (empty-space
/// context menu, drops).
final class EmptyStateView: NSView {
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private(set) var content: EmptyStateContent?
    var onAction: ((EmptyStateAction) -> Void)?
    var currentText: String? { content?.title }

    init() {
        super.init(frame: .zero)
        setAccessibilityIdentifier(AXID.emptyState)
        spinner.style = .spinning
        spinner.controlSize = .small
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.alignment = .center
        button.target = self
        button.action = #selector(buttonPressed(_:))
        button.bezelStyle = .push
        let stack = NSStackView(views: [spinner, titleLabel, detailLabel, button])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("EmptyStateView is created in code") }

    func show(_ content: EmptyStateContent?) {
        self.content = content
        isHidden = content == nil
        guard let content else { spinner.stopAnimation(nil); return }
        titleLabel.stringValue = content.title
        detailLabel.stringValue = content.detail ?? ""
        detailLabel.isHidden = content.detail == nil
        button.title = content.action?.title ?? ""
        button.isHidden = content.action == nil
        spinner.isHidden = !content.showsSpinner
        if content.showsSpinner { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    func performAction() { buttonPressed(nil) }

    @objc private func buttonPressed(_ sender: Any?) {
        if let action = content?.action { onAction?(action) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard let hit, !button.isHidden, hit === button || hit.isDescendant(of: button) else { return nil }
        return hit
    }
}
