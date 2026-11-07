import Foundation
import MacxFS

public struct ResolvedSearch: Sendable, Equatable {
    public var criteria: SearchCriteria
    public var contentTerms: [String]
    public var diagnostics: [SyntaxDiagnostic]
    public var isEmpty: Bool { criteria.isEmpty && contentTerms.isEmpty }
}

public enum SearchResolver {
    public static func resolve(_ spec: SearchSpec, now: Date, calendar: Calendar) -> ResolvedSearch {
        let p = QuerySyntax.parse(spec.text)
        let nameTerms = spec.mode == .contents ? p.nameTerms : p.freeTerms + p.nameTerms
        let contentTerms = spec.mode == .contents ? p.freeTerms : []
        var size = p.size
        if let f = spec.filters.size { size = size.map { $0.intersection(f) } ?? f }
        func dates(_ tokens: [DateToken]) -> TimeRange? {
            tokens.map { DateRanges.range($0, now: now, calendar: calendar) }.reduce(nil) { acc, r in acc.map { $0.intersection(r) } ?? r }
        }
        let criteria = SearchCriteria(
            nameTerms: nameTerms.map(NameTerm.init),
            kinds: merge(p.kinds, spec.filters.kinds),
            extensions: merge(p.extensions, Set(spec.filters.extensions.map { $0.lowercased() })),
            size: size,
            modified: dates(p.modified + [spec.filters.modified].compactMap { $0 }),
            created: dates(p.created + [spec.filters.created].compactMap { $0 }))
        return ResolvedSearch(criteria: criteria, contentTerms: contentTerms, diagnostics: p.diagnostics)
    }

    /// Empty = unconstrained. Both constrained → intersection (possibly empty = match nothing).
    static func merge<T: Hashable>(_ a: Set<T>, _ b: Set<T>) -> Set<T>? {
        switch (a.isEmpty, b.isEmpty) {
        case (true, true): return nil
        case (false, true): return a
        case (true, false): return b
        case (false, false): return a.intersection(b)
        }
    }
}
