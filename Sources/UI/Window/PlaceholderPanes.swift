import AppKit
import Core
import MacxFS

/// A plain view that takes keyboard focus, so the placeholder panes sit in the responder chain.
@MainActor
final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// P1-26 placeholder content: the current folder's row count. P1-31 deletes this type (ContentViewController).
@MainActor
final class PlaceholderContentViewController: CommandHandlingViewController {
    let session: BrowserSession
    private let countLabel = NSTextField(labelWithString: "")
    private var sessionToken: ObserverToken?
    private var folderToken: ObserverToken?

    init(session: BrowserSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("created in code") }

    override var focusContext: FocusContext { .content }
    override var commandTarget: CommandTarget? { .contentSelection(session.folder) }

    var countText: String { countLabel.stringValue }

    override func loadView() {
        let root = FocusableView()
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.setAccessibilityIdentifier(AXID.statusCount)
        countLabel.textColor = .secondaryLabelColor
        root.addSubview(countLabel)
        NSLayoutConstraint.activate([
            countLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            countLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        sessionToken = session.observe { [weak self] event in
            if case .folderChanged(let model) = event { self?.bind(model) }
        }
        bind(session.folder)
    }

    private func bind(_ folder: FolderModel) {
        folderToken = folder.observe { [weak self] _ in self?.updateCount() }
        updateCount()
    }

    private func updateCount() {
        countLabel.stringValue = String(format: L10n.string("%ld items"), session.folder.rowCount)
    }
}

/// P1-26 placeholder sidebar. P1-28 deletes this type (SidebarViewController).
@MainActor
final class PlaceholderSidebarViewController: CommandHandlingViewController {
    override var focusContext: FocusContext { .sidebarFavorites }

    override func loadView() {
        let root = FocusableView()
        root.setAccessibilityIdentifier(AXID.sidebar)
        root.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        view = root
    }
}
