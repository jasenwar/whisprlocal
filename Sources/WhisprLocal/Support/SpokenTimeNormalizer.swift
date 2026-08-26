import Foundation

enum SpokenTimeNormalizer {
    private static let hourValues: [String: Int] = [
        "one": 1,
        "two": 2,
        "three": 3,
        "four": 4,
        "five": 5,
        "six": 6,
        "seven": 7,
        "eight": 8,
        "nine": 9,
        "ten": 10,
        "eleven": 11,
        "twelve": 12,
    ]

    private static let minuteValues: [String: Int] = {
        let smallNumbers = [
            "zero", "one", "two", "three", "four", "five", "six",
            "seven", "eight", "nine", "ten", "eleven", "twelve",
            "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
            "eighteen", "nineteen",
        ]
        let tens = [
            20: "twenty",
            30: "thirty",
            40: "forty",
            50: "fifty",
        ]
        var values: [String: Int] = [
            "o'clock": 0,
            "o’clock": 0,
            "oclock": 0,
            "oh zero": 0,
            "zero zero": 0,
        ]

        for minute in 1...9 {
            let word = smallNumbers[minute]
            values["oh \(word)"] = minute
            values["zero \(word)"] = minute
        }
        for minute in 10...19 {
            values[smallNumbers[minute]] = minute
        }
        for base in [20, 30, 40, 50] {
            guard let tensWord = tens[base] else { continue }
            values[tensWord] = base
            for remainder in 1...9 {
                values["\(tensWord) \(smallNumbers[remainder])"] =
                    base + remainder
            }
        }
        return values
    }()

    private static let cuePattern = [
        "around", "before", "after", "until", "about", "from", "till",
        "at", "by",
    ]
    .sorted { $0.count > $1.count }
    .joined(separator: "|")

    private static let hourPattern = hourValues.keys
        .sorted { $0.count > $1.count }
        .map(NSRegularExpression.escapedPattern)
        .joined(separator: "|")

    private static let minutePattern = minuteValues.keys
        .sorted { $0.count > $1.count }
        .map(flexiblePattern)
        .joined(separator: "|")

    private static let meridiemPattern =
        #"(?:a\.?\s*m\.?|p\.?\s*m\.?)"#

    private static let timeAfterCueRegex = try! NSRegularExpression(
        pattern:
            #"(?i)(?<![\p{L}\p{N}_])(?<cue>"#
            + cuePattern
            + #")\s+(?<hour>"#
            + hourPattern
            + #")\s+(?<minute>"#
            + minutePattern
            + #")(?<meridiem>\s+"#
            + meridiemPattern
            + #")?(?![-\p{L}\p{N}_])"#
    )

    private static let timeWithMeridiemRegex = try! NSRegularExpression(
        pattern:
            #"(?i)(?<![\p{L}\p{N}_])(?<hour>"#
            + hourPattern
            + #")\s+(?<minute>"#
            + minutePattern
            + #")(?<meridiem>\s+"#
            + meridiemPattern
            + #")(?![-\p{L}\p{N}_])"#
    )

    private static let numericTimeAfterCueRegex = try! NSRegularExpression(
        pattern:
            #"(?i)(?<![\p{L}\p{N}_])(?<cue>"#
            + cuePattern
            + #")\s+(?<hour>1[0-2]|0?[1-9])\s+(?<minute>[0-5]?\d)(?<meridiem>\s+"#
            + meridiemPattern
            + #")?(?![-\p{L}\p{N}_])(?!\s+\d)"#
    )

    private static let numericTimeWithMeridiemRegex =
        try! NSRegularExpression(
            pattern:
                #"(?i)(?<![\p{L}\p{N}_])(?<hour>1[0-2]|0?[1-9])\s+(?<minute>[0-5]?\d)(?<meridiem>\s+"#
                + meridiemPattern
                + #")(?![-\p{L}\p{N}_])(?!\s+\d)"#
        )

    private static let dottedTimeWithMeridiemRegex =
        try! NSRegularExpression(
            pattern:
                #"(?i)(?<![\p{L}\p{N}_])(?<hour>1[0-2]|0?[1-9])\.(?<minute>[0-5]\d)(?<meridiem>\s*"#
                + meridiemPattern
                + #")(?![-\p{L}\p{N}_])"#
        )

    static func normalize(_ text: String) -> String {
        var result = replacingMatches(
            in: text,
            regex: timeAfterCueRegex,
            includesCue: true
        )
        result = replacingMatches(
            in: result,
            regex: timeWithMeridiemRegex,
            includesCue: false
        )
        result = replacingNumericMatches(
            in: result,
            regex: numericTimeAfterCueRegex,
            includesCue: true
        )
        result = replacingNumericMatches(
            in: result,
            regex: numericTimeWithMeridiemRegex,
            includesCue: false
        )
        result = replacingNumericMatches(
            in: result,
            regex: dottedTimeWithMeridiemRegex,
            includesCue: false
        )
        return result
    }

    private static func replacingMatches(
        in text: String,
        regex: NSRegularExpression,
        includesCue: Bool
    ) -> String {
        var result = text
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)

        for match in matches.reversed() {
            guard let wholeRange = Range(match.range, in: result),
                  let hour = value(
                    named: "hour",
                    in: result,
                    match: match,
                    values: hourValues
                  ),
                  let minute = value(
                    named: "minute",
                    in: result,
                    match: match,
                    values: minuteValues
                  )
            else {
                continue
            }

            var replacement = "\(hour):\(String(format: "%02d", minute))"
            if let meridiem = substring(
                named: "meridiem",
                in: result,
                match: match
            ) {
                replacement += " " + normalizedMeridiem(meridiem)
            }
            if includesCue,
               let cue = substring(named: "cue", in: result, match: match) {
                replacement = cue + " " + replacement
            }
            result.replaceSubrange(wholeRange, with: replacement)
        }
        return result
    }

    private static func replacingNumericMatches(
        in text: String,
        regex: NSRegularExpression,
        includesCue: Bool
    ) -> String {
        var result = text
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)

        for match in matches.reversed() {
            guard let wholeRange = Range(match.range, in: result),
                  let hourText = substring(
                    named: "hour",
                    in: result,
                    match: match
                  ),
                  let minuteText = substring(
                    named: "minute",
                    in: result,
                    match: match
                  ),
                  let hour = Int(hourText),
                  let minute = Int(minuteText)
            else {
                continue
            }

            var replacement = "\(hour):\(String(format: "%02d", minute))"
            if let meridiem = substring(
                named: "meridiem",
                in: result,
                match: match
            ) {
                replacement += " " + normalizedMeridiem(meridiem)
            }
            if includesCue,
               let cue = substring(named: "cue", in: result, match: match) {
                replacement = cue + " " + replacement
            }
            result.replaceSubrange(wholeRange, with: replacement)
        }
        return result
    }

    private static func value(
        named name: String,
        in text: String,
        match: NSTextCheckingResult,
        values: [String: Int]
    ) -> Int? {
        guard let phrase = substring(named: name, in: text, match: match) else {
            return nil
        }
        return values[normalizedPhrase(phrase)]
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

    private static func normalizedPhrase(_ value: String) -> String {
        value.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func normalizedMeridiem(_ value: String) -> String {
        let compact = value.lowercased().filter(\.isLetter)
        return compact == "pm" ? "PM" : "AM"
    }

    private static func flexiblePattern(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: #"\s+"#)
    }
}
