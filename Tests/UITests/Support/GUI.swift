import CoreGraphics
import XCTest

/// Skips a GUI-dependent test when there is no window server (CI without a login session, ssh).
func requireGUISession() throws {
    guard CGSessionCopyCurrentDictionary() != nil else { throw XCTSkip("needs a window server (GUI login session)") }
}
