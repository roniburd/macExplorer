import Foundation

/// The rules of one batch rename (P4-11, spec §11 "Batch rename"). Pure; the sheet (P4-12) edits them and
/// `BatchRenamePlanner` previews them. Applied in this order to the part chosen by `scope`: find/replace, case change,
/// prefix and suffix, numbering.
public struct BatchRenameRules: Sendable, Codable, Equatable {
    public enum Scope: String, Sendable, Codable, CaseIterable { case baseName, wholeName, extensionOnly }
    public enum CaseChange: String, Sendable, Codable, CaseIterable { case none, lower, upper, title, sentence }
    public struct Numbering: Sendable, Codable, Equatable {
        public enum Position: String, Sendable, Codable, CaseIterable { case prefix, suffix, replaceName }
        public var start: Int = 1
        public var step: Int = 1
        public var minDigits: Int = 1
        public var position: Position = .suffix
        public var separator: String = " "
        /// `.replaceName`: "Trip" → "Trip (1)", "Trip (2)" (Explorer style).
        public var baseName: String = ""
        public init() {}

        private enum CodingKeys: String, CodingKey { case start, step, minDigits, position, separator, baseName }
        /// Absent keys decode to their defaults.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Numbering()
            start = try c.decodeIfPresent(Int.self, forKey: .start) ?? d.start
            step = try c.decodeIfPresent(Int.self, forKey: .step) ?? d.step
            minDigits = try c.decodeIfPresent(Int.self, forKey: .minDigits) ?? d.minDigits
            position = try c.decodeIfPresent(Position.self, forKey: .position) ?? d.position
            separator = try c.decodeIfPresent(String.self, forKey: .separator) ?? d.separator
            baseName = try c.decodeIfPresent(String.self, forKey: .baseName) ?? d.baseName
        }
    }
    public var find: String = ""
    public var replace: String = ""
    public var useRegex = false
    public var caseSensitive = false
    public var prefix = ""
    public var suffix = ""
    public var caseChange: CaseChange = .none
    public var numbering: Numbering? = nil
    public var scope: Scope = .baseName
    public init() {}

    private enum CodingKeys: String, CodingKey { case find, replace, useRegex, caseSensitive, prefix, suffix, caseChange, numbering, scope }
    /// Absent keys decode to their defaults.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        find = try c.decodeIfPresent(String.self, forKey: .find) ?? ""
        replace = try c.decodeIfPresent(String.self, forKey: .replace) ?? ""
        useRegex = try c.decodeIfPresent(Bool.self, forKey: .useRegex) ?? false
        caseSensitive = try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        suffix = try c.decodeIfPresent(String.self, forKey: .suffix) ?? ""
        caseChange = try c.decodeIfPresent(CaseChange.self, forKey: .caseChange) ?? .none
        numbering = try c.decodeIfPresent(Numbering.self, forKey: .numbering)
        scope = try c.decodeIfPresent(Scope.self, forKey: .scope) ?? .baseName
    }

    /// Pure. `index` = position in the selection's display order. Treats `name` as a file's name.
    public func apply(to name: String, index: Int) throws(BatchRenameRuleError) -> String {
        try compiled().apply(to: name, index: index, isDirectory: false)
    }

    /// Pure. Folders (`isDirectory`) are all base name: "v1.0" has no extension.
    public func apply(to name: String, index: Int, isDirectory: Bool) throws(BatchRenameRuleError) -> String {
        try compiled().apply(to: name, index: index, isDirectory: isDirectory)
    }

    /// The rules with the find pattern compiled once (previews apply them to thousands of names).
    func compiled() throws(BatchRenameRuleError) -> Compiled {
        guard useRegex, !find.isEmpty else { return Compiled(rules: self, regex: nil) }
        guard let re = try? NSRegularExpression(pattern: find, options: caseSensitive ? [] : [.caseInsensitive]) else {
            throw .invalidPattern(find)
        }
        return Compiled(rules: self, regex: re)
    }

    /// (base, extension) by `NSString.pathExtension` rules: ".bashrc" and "README" have no extension; folders neither.
    static func split(_ name: String, isDirectory: Bool) -> (base: String, ext: String) {
        guard !isDirectory else { return (name, "") }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, name.count > ext.count + 1 else { return (name, "") }
        return (String(name.dropLast(ext.count + 1)), ext)
    }

    struct Compiled {
        let rules: BatchRenameRules
        let regex: NSRegularExpression?

        func apply(to name: String, index: Int, isDirectory: Bool) -> String {
            let (base, ext) = BatchRenameRules.split(name, isDirectory: isDirectory)
            switch rules.scope {
            case .wholeName: return transform(name, index: index)
            case .baseName:
                let b = transform(base, index: index)
                return ext.isEmpty ? b : "\(b).\(ext)"
            case .extensionOnly: return ext.isEmpty ? name : "\(base).\(transform(ext, index: index))"
            }
        }

        private func transform(_ part: String, index: Int) -> String {
            var s = part
            if !rules.find.isEmpty {
                if let regex {
                    let ns = s as NSString
                    var out = "", last = 0
                    for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                        out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                        out += RegexTemplate.expand(rules.replace, match: m, in: ns)
                        last = m.range.location + m.range.length
                    }
                    s = out + ns.substring(from: last)
                } else {
                    s = s.replacingOccurrences(of: rules.find, with: rules.replace,
                                               options: rules.caseSensitive ? [.literal] : [.literal, .caseInsensitive])
                }
            }
            switch rules.caseChange {
            case .none: break
            case .lower: s = s.lowercased()                 // Swift's case mapping is locale-independent
            case .upper: s = s.uppercased()
            case .title:
                var out = "", startOfWord = true
                for ch in s {
                    out += startOfWord ? ch.uppercased() : ch.lowercased()
                    startOfWord = ch == " " || ch == "-" || ch == "_" || ch == "."
                }
                s = out
            case .sentence: s = s.prefix(1).uppercased() + s.dropFirst().lowercased()
            }
            s = rules.prefix + s + rules.suffix
            if let n = rules.numbering {
                let value = n.start &+ index &* n.step          // wrapping: huge sheet values never trap
                let raw = String(value.magnitude)
                let num = (value < 0 ? "-" : "") + String(repeating: "0", count: max(0, min(n.minDigits, 255) - raw.count)) + raw
                switch n.position {
                case .prefix: s = "\(num)\(n.separator)\(s)"
                case .suffix: s = "\(s)\(n.separator)\(num)"
                case .replaceName: s = "\(n.baseName) (\(num))"
                }
            }
            return s
        }
    }
}

public enum BatchRenameRuleError: Error, Sendable, Equatable { case invalidPattern(String) }
