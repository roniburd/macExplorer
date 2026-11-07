import Foundation

/// A search the user saved to the sidebar's SEARCHES section (§11 Phase 3). Re-running it re-plans `spec`.
public struct SavedSearch: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var spec: SearchSpec
    public init(id: UUID = UUID(), name: String, spec: SearchSpec) {
        self.id = id
        self.name = name
        self.spec = spec
    }
}

public enum SavedSearchNaming {
    /// `proposed` trimmed; nil when blank. On a case-insensitive clash with `existing` appends " 2", " 3", … (first free).
    public static func uniqueName(_ proposed: String, existing: [String]) -> String? {
        let base = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        let taken = Set(existing.map { $0.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }
}
