import AppKit
@testable import UI

/// A scripted `NamePrompting` (P3-11): records the initial values and titles, answers in order (nil = Cancel).
@MainActor
final class FakePrompter: NamePrompting {
    var answers: [String?]
    var asked: [String] = []
    var titles: [String] = []
    init(_ answers: [String?]) { self.answers = answers }
    func promptForName(title: String, initial: String, on window: NSWindow?) async -> String? {
        asked.append(initial)
        titles.append(title)
        return answers.isEmpty ? nil : answers.removeFirst()
    }
}
