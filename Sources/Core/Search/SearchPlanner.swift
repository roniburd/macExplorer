import Foundation
import MacxFS

public struct PlanInputs: Sendable, Equatable {
    public var rootIndexing: IndexingStatus
    public var bootIndexing: IndexingStatus
    public var rootIsLocal: Bool
    public var rootVolumeName: String
    public init(rootIndexing: IndexingStatus, bootIndexing: IndexingStatus, rootIsLocal: Bool, rootVolumeName: String) {
        self.rootIndexing = rootIndexing; self.bootIndexing = bootIndexing
        self.rootIsLocal = rootIsLocal; self.rootVolumeName = rootVolumeName
    }
}

public enum SearchEngine: Sendable, Equatable {
    case none
    case folderFilter(SearchCriteria)
    case crawler(root: URL, criteria: SearchCriteria)
    case spotlight(SpotlightRequest)
}

public struct SearchPlan: Sendable, Equatable {
    public var engine: SearchEngine
    public var notices: [SearchNotice]
    public var diagnostics: [SyntaxDiagnostic]
    public init(engine: SearchEngine, notices: [SearchNotice] = [], diagnostics: [SyntaxDiagnostic] = []) {
        self.engine = engine; self.notices = notices; self.diagnostics = diagnostics
    }
}

/// Engine routing (§11 Phase 3): This folder + name stays the in-memory filter, Subfolders + name is our crawler,
/// This Mac and Contents use Spotlight; Contents on a volume that is not indexed falls back to a name search.
public enum SearchPlanner {
    public static func needsIndexStatus(_ spec: SearchSpec) -> Bool {
        !spec.isEmptyQuery && (spec.scope == .thisMac || spec.mode == .contents)
    }

    public static func plan(_ spec: SearchSpec, resolved: ResolvedSearch, inputs: PlanInputs) -> SearchPlan {
        let d = resolved.diagnostics
        guard !spec.isEmptyQuery, !resolved.isEmpty else { return SearchPlan(engine: .none, diagnostics: d) }
        let root = rootURL(spec.root)
        let criteria = resolved.criteria
        let terms = resolved.contentTerms
        let indexed = inputs.rootIndexing == .enabled || (inputs.rootIndexing == .unknown && inputs.rootIsLocal)
        var fallback = criteria
        fallback.nameTerms += terms.map(NameTerm.init)
        let notIndexed: [SearchNotice] = [.contentsNotIndexed(volumeName: inputs.rootVolumeName)]
        switch spec.scope {
        case .thisFolder:
            if terms.isEmpty { return SearchPlan(engine: .folderFilter(criteria), diagnostics: d) }
            if indexed {
                return SearchPlan(engine: .spotlight(SpotlightRequest(criteria: criteria, contentTerms: terms,
                                                                      scope: .folders([root]), directChildrenOf: root)), diagnostics: d)
            }
            return SearchPlan(engine: .folderFilter(fallback), notices: notIndexed, diagnostics: d)
        case .subfolders:
            if terms.isEmpty { return SearchPlan(engine: .crawler(root: root, criteria: criteria), diagnostics: d) }
            if indexed {
                return SearchPlan(engine: .spotlight(SpotlightRequest(criteria: criteria, contentTerms: terms,
                                                                      scope: .folders([root]), within: root)), diagnostics: d)
            }
            return SearchPlan(engine: .crawler(root: root, criteria: fallback), notices: notIndexed, diagnostics: d)
        case .thisMac:
            if inputs.bootIndexing == .disabled { return SearchPlan(engine: .none, notices: [.spotlightOff], diagnostics: d) }
            return SearchPlan(engine: .spotlight(SpotlightRequest(criteria: criteria, contentTerms: terms, scope: .localComputer)),
                              diagnostics: d)
        }
    }

    /// Lexically cleaned root in the caller's spelling. Not `standardizedFileURL`: that stats the path (planning runs on
    /// the main actor, §4.4) and drops a leading "/private" only when it exists (contract note 15).
    static func rootURL(_ url: URL) -> URL {
        URL(filePath: SearchResultStore.standardizedParent(url), directoryHint: .isDirectory)
    }
}
