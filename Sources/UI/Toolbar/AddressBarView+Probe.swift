import AppKit

extension AddressBarView {
    /// Phase 4's tests type into the bar this way: enters edit mode if needed, then submits.
    func submitForTesting(_ text: String) async {
        beginEditing()
        editField.stringValue = text
        await submit(text)
    }
}
