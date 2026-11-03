import XCTest

/// Every `L10n.string("…")` literal in Sources/UI and Sources/App has an entry in the String Catalog. Read-only.
final class LocalizationCoverageTests: XCTestCase {
    private static let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testEveryL10nLiteralIsInTheCatalog() throws {
        let catalogURL = Self.repo.appending(path: "Sources/UI/Resources/Localizable.xcstrings")
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        let keys = Set((catalog["strings"] as? [String: Any] ?? [:]).keys)
        let pattern = try NSRegularExpression(pattern: #"L10n\.string\("((?:[^"\\]|\\.)*)"\)"#)
        var missing: [String] = []
        for directory in ["Sources/UI", "Sources/App"] {
            let base = Self.repo.appending(path: directory)
            let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let range = Range(match.range(at: 1), in: text) else { continue }
                    let key = String(text[range])
                    if !keys.contains(key) { missing.append("\(file.lastPathComponent): \(key)") }
                }
            }
        }
        XCTAssertEqual(missing, [], "add these keys to Localizable.xcstrings")
    }
}
