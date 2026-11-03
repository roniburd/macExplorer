import Foundation
import Core

/// User-facing text for typed Core problems. Core never produces English (overview Global Constraints).
@MainActor
enum ErrorText {
    static func renameProblem(_ problem: NameProblem, name: String) -> String {
        switch problem {
        case .empty: L10n.string("A name can't be empty.")
        case .containsSlash: L10n.string("A name can't contain '/'.")
        case .tooLong: L10n.string("The name is too long.")
        case .duplicate: String(format: L10n.string("The name '%@' is already taken."), name)
        }
    }
}
