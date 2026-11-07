import Foundation
import MacxFS

public enum MetadataScope: Sendable, Hashable { case localComputer, folders([URL]) }

public struct SpotlightRequest: Sendable, Hashable {
    public var criteria: SearchCriteria
    public var contentTerms: [String]
    public var scope: MetadataScope
    public var within: URL?               // post-filter: path strictly below this folder
    public var directChildrenOf: URL?     // post-filter: parent equals this folder (This folder + Contents)
    public init(criteria: SearchCriteria, contentTerms: [String], scope: MetadataScope, within: URL? = nil, directChildrenOf: URL? = nil) {
        self.criteria = criteria; self.contentTerms = contentTerms; self.scope = scope
        self.within = within; self.directChildrenOf = directChildrenOf
    }
}
