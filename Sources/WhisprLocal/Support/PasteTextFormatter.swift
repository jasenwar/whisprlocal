import Foundation

enum PasteTextFormatter {
    static func withTrailingSpace(_ text: String) -> String {
        guard let last = text.last else { return text }
        return last.isWhitespace ? text : text + " "
    }
}
