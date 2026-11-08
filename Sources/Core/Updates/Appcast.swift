import Foundation

/// One `<item>` of the Sparkle appcast (install-previous-version spec, Components). `build` is `sparkle:version`
/// (the release workflow's commit count, monotonic); `version` is `sparkle:shortVersionString`.
public struct AppcastItem: Sendable, Equatable, Identifiable {
    public var version: String
    public var build: Int
    public var channel: String?
    public var pubDate: Date?
    public var notesURL: URL?
    public var enclosureURL: URL
    public var length: Int64?
    public var edSignature: String
    public var minimumSystemVersion: String?

    public var id: Int { build }

    public init(version: String, build: Int, channel: String? = nil, pubDate: Date? = nil, notesURL: URL? = nil,
                enclosureURL: URL, length: Int64? = nil, edSignature: String, minimumSystemVersion: String? = nil) {
        self.version = version
        self.build = build
        self.channel = channel
        self.pubDate = pubDate
        self.notesURL = notesURL
        self.enclosureURL = enclosureURL
        self.length = length
        self.edSignature = edSignature
        self.minimumSystemVersion = minimumSystemVersion
    }
}

public enum AppcastParseError: Error, Equatable {
    case malformed(String)
}

/// Parses the appcast `scripts/release/appcast.py` writes. Items without a numeric build, an enclosure URL or an
/// EdDSA signature are dropped (nothing installable could come from them).
public enum AppcastParser {
    public static func parse(_ data: Data) throws -> [AppcastItem] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else {
            throw AppcastParseError.malformed(parser.parserError.map { String(describing: $0) } ?? "unknown error")
        }
        return delegate.items
    }

    static let sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"

    /// RFC 822 dates as `email.utils.formatdate(usegmt=True)` writes them ("Sun, 08 Nov 2026 07:32:05 GMT").
    static func date(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss zzz"] {
            f.dateFormat = format
            if let d = f.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines)) { return d }
        }
        return nil
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var items: [AppcastItem] = []
        private var fields: [String: String]?
        private var enclosure: [String: String] = [:]
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            text = ""
            if name == "item", namespaceURI?.isEmpty ?? true {
                fields = [:]
                enclosure = [:]
            } else if name == "enclosure", fields != nil {
                // With namespace processing on, prefixed attributes keep their qualified name.
                enclosure = attributes
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            defer { text = "" }
            guard fields != nil else { return }
            if name == "item", namespaceURI?.isEmpty ?? true {
                if let item = makeItem() { items.append(item) }
                fields = nil
                return
            }
            let key = namespaceURI == AppcastParser.sparkle ? "sparkle:\(name)" : name
            fields?[key] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func makeItem() -> AppcastItem? {
            guard let f = fields,
                  let buildText = f["sparkle:version"], let build = Int(buildText),
                  let urlText = enclosure["url"], let url = URL(string: urlText),
                  let signature = enclosure["sparkle:edSignature"] ?? enclosure["edSignature"], !signature.isEmpty
            else { return nil }
            let version = f["sparkle:shortVersionString"].flatMap { $0.isEmpty ? nil : $0 } ?? buildText
            return AppcastItem(
                version: version, build: build,
                channel: f["sparkle:channel"].flatMap { $0.isEmpty ? nil : $0 },
                pubDate: f["pubDate"].flatMap(AppcastParser.date),
                notesURL: f["sparkle:releaseNotesLink"].flatMap(URL.init(string:)),
                enclosureURL: url,
                length: enclosure["length"].flatMap { Int64($0) },
                edSignature: signature,
                minimumSystemVersion: f["sparkle:minimumSystemVersion"].flatMap { $0.isEmpty ? nil : $0 })
        }
    }
}
