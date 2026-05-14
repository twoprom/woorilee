import AppKit
import InputMethodKit

final class FakeIMKTextInput: NSObject, IMKTextInput {
    struct InsertCall: Equatable {
        let text: String
        let replacementRange: NSRange
    }

    struct MarkCall: Equatable {
        let text: String
        let selectionRange: NSRange
        let replacementRange: NSRange
    }

    private(set) var insertCalls: [InsertCall] = []
    private(set) var markCalls: [MarkCall] = []
    var stubbedMarkedRange: NSRange = NSRange(location: NSNotFound, length: 0)
    var stubbedSelectedRange: NSRange = NSRange(location: 0, length: 0)

    func insertText(_ string: Any!, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        insertCalls.append(InsertCall(text: text, replacementRange: replacementRange))
    }

    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        markCalls.append(
            MarkCall(text: text, selectionRange: selectionRange, replacementRange: replacementRange)
        )
        if text.isEmpty {
            stubbedMarkedRange = NSRange(location: NSNotFound, length: 0)
        } else {
            let location: Int
            if replacementRange.location != NSNotFound {
                location = replacementRange.location
            } else if stubbedMarkedRange.location != NSNotFound {
                location = stubbedMarkedRange.location
            } else {
                location = stubbedSelectedRange.location == NSNotFound ? 0 : stubbedSelectedRange.location
            }
            stubbedMarkedRange = NSRange(location: location, length: (text as NSString).length)
        }
    }

    func selectedRange() -> NSRange { stubbedSelectedRange }
    func markedRange() -> NSRange { stubbedMarkedRange }
    func attributedSubstring(from range: NSRange) -> NSAttributedString? { nil }
    func length() -> Int { 0 }
    func characterIndex(
        for point: NSPoint,
        tracking: IMKLocationToOffsetMappingMode,
        inMarkedRange: UnsafeMutablePointer<ObjCBool>?
    ) -> Int { NSNotFound }
    func attributes(
        forCharacterIndex index: Int,
        lineHeightRectangle: UnsafeMutablePointer<NSRect>?
    ) -> [AnyHashable: Any]? { nil }
    func validAttributesForMarkedText() -> [Any]? { nil }
    func overrideKeyboard(withKeyboardNamed name: String?) {}
    func selectMode(_ modeIdentifier: String?) {}
    func supportsUnicode() -> Bool { true }
    func bundleIdentifier() -> String? { nil }
    func windowLevel() -> CGWindowLevel { 0 }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
    func uniqueClientIdentifierString() -> String? { nil }
    func string(from range: NSRange, actualRange: NSRangePointer?) -> String? { nil }
    func firstRect(forCharacterRange aRange: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
}
