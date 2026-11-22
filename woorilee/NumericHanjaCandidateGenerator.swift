// Generates Hanja candidates for numeric input.
//     Copyright (C) 2026 Seungjin Lee.

import Foundation

enum NumericHanjaCandidateGenerator {
    private static let hanjaDigitsWithLing = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
    private static let hanjaDigitsWithCircle = ["〇", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
    private static let hangulDigits = ["영", "일", "이", "삼", "사", "오", "육", "칠", "팔", "구"]
    private static let hanjaSmallUnits = ["", "十", "百", "千"]
    private static let hangulSmallUnits = ["", "십", "백", "천"]
    private static let hanjaLargeUnits = ["", "萬", "億", "兆", "京"]
    private static let hangulLargeUnits = ["", "만", "억", "조", "경"]

    static func candidates(for sourceText: String) -> [HanjaCandidate] {
        guard let normalizedDigits = normalizedDigits(from: sourceText) else {
            return []
        }

        let digits = normalizedDigits.compactMap(\.wholeNumberValue)
        guard !digits.isEmpty else {
            return []
        }

        let hasLeadingZero = normalizedDigits.count > 1 && normalizedDigits.first == "0"
        let canUseQuantityUnits = !hasLeadingZero && groupCount(forDigitCount: digits.count) <= hangulLargeUnits.count
        let containsZero = digits.contains(0)
        var values: [(value: String, comment: String)] = []

        if !canUseQuantityUnits {
            values.append((digitReading(for: digits, using: hanjaDigitsWithLing), "漢字"))
            if containsZero {
                values.append((digitReading(for: digits, using: hanjaDigitsWithCircle), "漢字"))
            }
            values.append((digitReading(for: digits, using: hangulDigits), "한글"))
            return makeCandidates(values: values, reading: normalizedDigits)
        }

        values.append((quantityReading(for: digits, digits: hanjaDigitsWithLing, smallUnits: hanjaSmallUnits, largeUnits: hanjaLargeUnits), "漢字"))
        values.append((digitReading(for: digits, using: hanjaDigitsWithLing), "漢字"))
        if containsZero {
            values.append((digitReading(for: digits, using: hanjaDigitsWithCircle), "漢字"))
        }
        values.append((quantityReading(for: digits, digits: hangulDigits, smallUnits: hangulSmallUnits, largeUnits: hangulLargeUnits), "한글"))
        if let grouped = groupedUnitReading(for: normalizedDigits, largeUnits: hangulLargeUnits) {
            values.append((grouped, "혼용"))
        }
        if let grouped = groupedUnitReading(for: normalizedDigits, largeUnits: hanjaLargeUnits) {
            values.append((grouped, "混用"))
        }

        return makeCandidates(values: values, reading: normalizedDigits)
    }

    static func hanjaQuantityReading(for value: Int) -> String {
        quantityReading(
            for: String(value).compactMap(\.wholeNumberValue),
            digits: hanjaDigitsWithLing, smallUnits: hanjaSmallUnits, largeUnits: hanjaLargeUnits
        )
    }

    static func hanjaDigitReading(for value: Int) -> String {
        digitReading(for: String(value).compactMap(\.wholeNumberValue), using: hanjaDigitsWithCircle)
    }

    static func isNumericCandidateSource(_ text: String) -> Bool {
        normalizedDigits(from: text) != nil
    }

    static func isNumericStartCharacter(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    static func normalizedDigits(from text: String) -> String? {
        guard !text.isEmpty else {
            return nil
        }

        var digits = ""
        for character in text {
            if character == "," {
                continue
            }

            guard character.isASCII, character.isNumber else {
                return nil
            }

            digits.append(character)
        }

        return digits.isEmpty ? nil : digits
    }

    private static func makeCandidates(values: [(value: String, comment: String)], reading: String) -> [HanjaCandidate] {
        var seen: Set<String> = []
        var candidates: [HanjaCandidate] = []

        for (value, comment) in values where !value.isEmpty && seen.insert(value).inserted {
            candidates.append(
                HanjaCandidate(
                    reading: reading,
                    value: value,
                    comment: comment,
                    source: .system,
                    usageCount: 0,
                    frequency: 0,
                    baseRank: candidates.count
                )
            )
        }

        return candidates
    }

    private static func digitReading(for digits: [Int], using digitTable: [String]) -> String {
        digits.map { digitTable[$0] }.joined()
    }

    private static func quantityReading(
        for digits: [Int],
        digits digitTable: [String],
        smallUnits: [String],
        largeUnits: [String]
    ) -> String {
        let groups = fourDigitGroups(from: digits)
        guard groups.contains(where: { $0.contains { $0 != 0 } }) else {
            return digitTable[0]
        }

        var result = ""
        for (index, group) in groups.enumerated() {
            guard group.contains(where: { $0 != 0 }) else {
                continue
            }

            let unitIndex = groups.count - index - 1
            result += smallGroupReading(group, digits: digitTable, smallUnits: smallUnits)
            result += largeUnits[unitIndex]
        }

        return result
    }

    private static func smallGroupReading(
        _ group: [Int],
        digits digitTable: [String],
        smallUnits: [String]
    ) -> String {
        var result = ""
        for (offset, digit) in group.enumerated() {
            guard digit != 0 else {
                continue
            }

            let unitIndex = group.count - offset - 1
            if digit == 1, unitIndex > 0 {
                result += smallUnits[unitIndex]
            } else {
                result += digitTable[digit] + smallUnits[unitIndex]
            }
        }

        return result
    }

    private static func groupedUnitReading(for normalizedDigits: String, largeUnits: [String]) -> String? {
        let groups = fourDigitStringGroups(from: normalizedDigits)
        guard groups.count > 1, groups.count <= largeUnits.count else {
            return nil
        }

        var parts: [String] = []
        for (index, group) in groups.enumerated() {
            guard let value = Int(group), value != 0 else {
                continue
            }

            let unitIndex = groups.count - index - 1
            parts.append("\(value)\(largeUnits[unitIndex])")
        }

        let result = parts.joined()
        return result.isEmpty ? nil : result
    }

    private static func fourDigitGroups(from digits: [Int]) -> [[Int]] {
        let paddedCount = groupCount(forDigitCount: digits.count) * 4
        let paddedDigits = Array(repeating: 0, count: paddedCount - digits.count) + digits
        return stride(from: 0, to: paddedDigits.count, by: 4).map { start in
            Array(paddedDigits[start..<start + 4])
        }
    }

    private static func fourDigitStringGroups(from normalizedDigits: String) -> [String] {
        let paddedCount = groupCount(forDigitCount: normalizedDigits.count) * 4
        let padded = String(repeating: "0", count: paddedCount - normalizedDigits.count) + normalizedDigits
        return stride(from: 0, to: padded.count, by: 4).map { offset in
            let start = padded.index(padded.startIndex, offsetBy: offset)
            let end = padded.index(start, offsetBy: 4)
            return String(padded[start..<end])
        }
    }

    private static func groupCount(forDigitCount digitCount: Int) -> Int {
        max(1, Int(ceil(Double(digitCount) / 4.0)))
    }
}
