// Generates date candidates for Korean relative-day expressions.
//     Copyright (C) 2026 Seungjin Lee.

import Foundation

enum DateHanjaCandidateGenerator {
    private static let dayOffsets: [String: Int] = [
        "오늘": 0, "금일": 0,
        "내일": 1, "명일": 1,
        "모레": 2, "내일모레": 2, "낼모레": 2, "명후일": 2, "재명일": 2,
        "글피": 3, "삼명일": 3,
        "그글피": 4,
        "어제": -1, "어저께": -1, "작일": -1,
        "그제": -2, "그저께": -2, "거거일": -2, "재작": -2, "재작일": -2,
        "그끄저께": -3, "그끄제": -3, "삼작일": -3, "재재작일": -3,
    ]

    private static let expressionPattern: NSRegularExpression = {
        let alternatives = dayOffsets.keys.sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_])(?:\(alternatives))")
    }()

    static func isDateCandidateSource(_ text: String) -> Bool {
        dayOffsets[text] != nil
    }

    // Whole expressions also cover words that Kiwi splits into multiple tokens.
    static func sourceRanges(in text: String, particleStarts: Set<Int> = []) -> [NSRange] {
        expressionPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            if range.upperBound == text.endIndex || particleStarts.contains(NSMaxRange(match.range)) {
                return match.range
            }
            let next = text[range.upperBound]
            return next.isLetter || next.isNumber || next == "_" ? nil : match.range
        }
    }

    static func candidates(
        for sourceText: String,
        referenceDate: Date = Date(),
        timeZone: TimeZone = .current
    ) -> [HanjaCandidate] {
        guard let offset = dayOffsets[sourceText] else {
            return []
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let date = calendar.date(byAdding: .day, value: offset, to: referenceDate) else {
            return []
        }
        let components = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        guard let year = components.year, let month = components.month, let day = components.day,
              let weekday = components.weekday else {
            return []
        }

        let hangulWeekday = ["일", "월", "화", "수", "목", "금", "토"][weekday - 1]
        let hanjaWeekday = ["日", "月", "火", "水", "木", "金", "土"][weekday - 1]
        let slashDate = "\(year)/\(month)/\(day)"
        let quantity = NumericHanjaCandidateGenerator.hanjaQuantityReading(for:)
        let digits = NumericHanjaCandidateGenerator.hanjaDigitReading(for:)
        let values: [(value: String, comment: String)] = [
            ("\(month)/\(day)", "날짜"),
            (slashDate, "날짜"),
            ("\(slashDate)(\(hangulWeekday))", "날짜"),
            ("\(slashDate)(\(hanjaWeekday))", "日字"),
            ("\(year)년 \(month)월 \(day)일", "날짜"),
            ("\(year)年 \(month)月 \(day)日", "日字"),
            ("\(quantity(year))年\(quantity(month))月\(quantity(day))日", "日字"),
            ("\(digits(year))年\(digits(month))月\(digits(day))日", "日字"),
            ("大韓民國\(year - 1918)年\(month)月\(day)日", "大韓民國年號"),
        ]
        return values.enumerated().map { index, entry in
            HanjaCandidate(
                reading: sourceText, value: entry.value, comment: entry.comment,
                source: .system, usageCount: 0, frequency: 0, baseRank: index
            )
        }
    }
}
