import Foundation
import MacxFS

public enum SpotlightPredicate {
    /// True when the criteria can match nothing (an empty kinds or extensions set, e.g. `kind:pdf` typed with the
    /// Kind filter set to Image). SpotlightSearch short-circuits these without starting a query.
    public static func matchesNothing(_ c: SearchCriteria) -> Bool {
        c.kinds?.isEmpty == true || c.extensions?.isEmpty == true
    }

    /// Never a value predicate: NSMetadataQuery raises NSInvalidArgumentException on FALSEPREDICATE/TRUEPREDICATE
    /// (even nested in a compound). No file has an empty name, so this comparison is always false.
    static var nothing: NSPredicate { NSPredicate(format: "%K == %@", "kMDItemFSName", "") }

    public static func make(_ request: SpotlightRequest) -> NSPredicate {
        let c = request.criteria
        var clauses: [NSPredicate] = []
        for term in c.nameTerms {
            clauses.append(NSPredicate(format: "%K LIKE[cd] %@", "kMDItemFSName", likePattern(term)))
        }
        for term in request.contentTerms {
            clauses.append(NSPredicate(format: "%K CONTAINS[cd] %@", "kMDItemTextContent", term))
        }
        if let kinds = c.kinds {
            var ors: [NSPredicate] = []
            for kind in kinds.sorted(by: { $0.rawValue < $1.rawValue }) {
                if kind == .folder { ors.append(NSPredicate(format: "%K == %@", "kMDItemContentType", "public.folder")); continue }
                for id in kind.typeIdentifiers { ors.append(NSPredicate(format: "%K == %@", "kMDItemContentTypeTree", id)) }
            }
            clauses.append(or(ors))
        }
        if let exts = c.extensions {
            clauses.append(or(exts.sorted().map { NSPredicate(format: "%K LIKE[c] %@", "kMDItemFSName", "*." + escape($0)) }))
        }
        if let size = c.size {
            if let l = size.lower { clauses.append(NSPredicate(format: "%K >= %@", "kMDItemFSSize", NSNumber(value: l))) }
            if let u = size.upper { clauses.append(NSPredicate(format: "%K < %@", "kMDItemFSSize", NSNumber(value: u))) }
        }
        dates(c.modified, "kMDItemFSContentChangeDate", into: &clauses)
        dates(c.created, "kMDItemFSCreationDate", into: &clauses)
        if clauses.isEmpty { return NSPredicate(format: "%K LIKE %@", "kMDItemFSName", "*") }
        return clauses.count == 1 ? clauses[0] : NSCompoundPredicate(andPredicateWithSubpredicates: clauses)
    }

    static func likePattern(_ term: NameTerm) -> String {
        let text = escape(term.text)
        guard term.isGlob else { return "*" + text + "*" }
        var out = "", lastStar = false
        for ch in text {
            if ch == "*" { if !lastStar { out.append(ch) }; lastStar = true } else { out.append(ch); lastStar = false }
        }
        return out
    }

    static func escape(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\") }

    static func or(_ ps: [NSPredicate]) -> NSPredicate {
        switch ps.count {
        case 0: return nothing
        case 1: return ps[0]
        default: return NSCompoundPredicate(orPredicateWithSubpredicates: ps)
        }
    }

    static func dates(_ range: TimeRange?, _ key: String, into clauses: inout [NSPredicate]) {
        guard let range else { return }
        func date(_ ns: Int64) -> NSDate { Date(timeIntervalSince1970: Double(ns) / 1e9) as NSDate }
        if let l = range.lower { clauses.append(NSPredicate(format: "%K >= %@", key, date(l))) }
        if let u = range.upper { clauses.append(NSPredicate(format: "%K < %@", key, date(u))) }
    }
}
