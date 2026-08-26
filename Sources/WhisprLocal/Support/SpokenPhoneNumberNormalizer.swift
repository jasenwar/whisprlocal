import Foundation

enum SpokenPhoneNumberNormalizer {
    private static let digitValues: [String: Int] = [
        "zero": 0,
        "oh": 0,
        "one": 1,
        "two": 2,
        "three": 3,
        "four": 4,
        "five": 5,
        "six": 6,
        "seven": 7,
        "eight": 8,
        "nine": 9,
    ]

    private static let digitPattern = digitValues.keys
        .sorted { $0.count > $1.count }
        .map(NSRegularExpression.escapedPattern)
        .joined(separator: "|")

    private static let contactCuePattern = #"(?:call|text|reach|contact)(?:\s+me)?(?:\s+(?:at|on))?"#

    private static let spokenNumberRegex = try! NSRegularExpression(
        pattern:
            #"(?i)(?<![\p{L}\p{N}_])(?<cue>"#
            + contactCuePattern
            + #")\s+(?<digits>(?:"#
            + digitPattern
            + #")(?:[\s,.-]+(?:"#
            + digitPattern
            + #")){6,10})(?![\s,.-]+(?:"#
            + digitPattern
            + #")(?![\p{L}\p{N}_]))(?![\p{L}\p{N}_])"#
    )

    static func normalize(_ text: String) -> String {
        var result = text
        let range = NSRange(text.startIndex..., in: text)
        let matches = spokenNumberRegex.matches(in: text, range: range)

        for match in matches.reversed() {
            guard let wholeRange = Range(match.range, in: result),
                  let cue = substring(named: "cue", in: result, match: match),
                  let spokenDigits = substring(
                    named: "digits",
                    in: result,
                    match: match
                  )
            else {
                continue
            }

            let digits = lexicalWords(in: spokenDigits).compactMap {
                digitValues[$0]
            }
            guard let formatted = format(digits) else { continue }
            result.replaceSubrange(wholeRange, with: "\(cue) \(formatted)")
        }
        return result
    }

    private static func format(_ digits: [Int]) -> String? {
        let value = digits.map(String.init).joined()
        switch digits.count {
        case 7:
            return "\(value.prefix(3))-\(value.suffix(4))"
        case 10:
            let areaEnd = value.index(value.startIndex, offsetBy: 3)
            let exchangeEnd = value.index(areaEnd, offsetBy: 3)
            return "(\(value[..<areaEnd])) \(value[areaEnd..<exchangeEnd])-\(value[exchangeEnd...])"
        case 11 where digits.first == 1:
            let national = String(value.dropFirst())
            let areaEnd = national.index(national.startIndex, offsetBy: 3)
            let exchangeEnd = national.index(areaEnd, offsetBy: 3)
            return "+1 (\(national[..<areaEnd])) \(national[areaEnd..<exchangeEnd])-\(national[exchangeEnd...])"
        default:
            return nil
        }
    }

    private static func lexicalWords(in value: String) -> [String] {
        value.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
    }

    private static func substring(
        named name: String,
        in text: String,
        match: NSTextCheckingResult
    ) -> String? {
        let range = match.range(withName: name)
        guard range.location != NSNotFound,
              let swiftRange = Range(range, in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }
}
