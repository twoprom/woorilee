// Background warm-up of Kiwi morphological analyzer.
//     Copyright (C) 2026 Seungjin Lee.

import Foundation
import Kiwi

@MainActor
final class KiwiAnalysisService {
    private static let realtimeAnalysisCandidateCount = 3

    enum Status: Equatable {
        case uninitialized
        case loading
        case ready
        case unavailable(String)
    }

    static let shared = KiwiAnalysisService()

    private(set) var status: Status = .uninitialized
    private(set) var kiwi: Kiwi?
    private var pendingWarmUpCompletions: [() -> Void] = []

    private init() {}

    var isAvailable: Bool {
        if case .ready = status {
            return true
        }

        return false
    }

    var isLoading: Bool {
        if case .loading = status {
            return true
        }

        return false
    }

    func warmUp(completion: (() -> Void)? = nil) {
        if let completion {
            pendingWarmUpCompletions.append(completion)
        }

        switch status {
        case .ready, .unavailable:
            drainPendingWarmUpCompletions()
            return
        case .loading:
            return
        case .uninitialized:
            break
        }

        status = .loading
        let bundle = Bundle.main

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var loadedKiwi: Kiwi?
            var failureReason: String?

            do {
                let builder = try KiwiBuilder(bundle: bundle, modelDirectory: AppRuntimePaths.kiwiModelDirectory)
                loadedKiwi = try builder.build()
            } catch {
                failureReason = String(describing: error)
            }

            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                if let loadedKiwi {
                    self.kiwi = loadedKiwi
                    self.status = .ready
                } else {
                    self.kiwi = nil
                    self.status = .unavailable(failureReason ?? "Unknown Kiwi warm-up error")
                }

                self.drainPendingWarmUpCompletions()
            }
        }
    }

    func analyzeClause(
        _ clause: String,
        hanjaService: HanjaDictionaryService
    ) -> [HanjaSegment] {
        guard !clause.isEmpty, let kiwi else {
            return []
        }

        do {
            let results = try kiwi.analyze(
                clause,
                topN: Self.realtimeAnalysisCandidateCount,
                options: [.allWithNormalizing, .joinNounPrefix, .joinNounSuffix]
            )
            return Self.bestRealtimeSegments(
                from: results,
                in: clause,
                candidateLookup: { key in
                    let numericCandidates = NumericHanjaCandidateGenerator.candidates(for: key)
                    return numericCandidates.isEmpty ? hanjaService.exactCandidates(for: key) : numericCandidates
                },
                hangulUsageLookup: hanjaService.hangulUsageCount(for:)
            )
        } catch {
            return []
        }
    }

    static func bestRealtimeSegments(
        from results: [TokenResult],
        in clause: String,
        candidateLookup: (String) -> [HanjaCandidate],
        hangulUsageLookup: (String) -> Int = { _ in 0 }
    ) -> [HanjaSegment] {
        var bestSegments: [HanjaSegment] = []
        var bestConvertibleLength = -1

        for result in results {
            let segments = makeRealtimeSegments(
                from: result.tokens,
                in: clause,
                candidateLookup: candidateLookup,
                hangulUsageLookup: hangulUsageLookup
            )
            let convertibleLength = segments
                .filter(\.isConvertible)
                .reduce(0) { $0 + $1.sourceRange.length }

            if convertibleLength > bestConvertibleLength {
                bestSegments = segments
                bestConvertibleLength = convertibleLength
            }
        }

        return bestSegments
    }

    static func makeRealtimeSegments(
        from tokens: [Token],
        in clause: String,
        candidateLookup: (String) -> [HanjaCandidate],
        hangulUsageLookup: (String) -> Int = { _ in 0 }
    ) -> [HanjaSegment] {
        let tokenSegments: [HanjaSegment] = tokens.compactMap { token -> HanjaSegment? in
            guard isRealtimeHanjaEligibleTag(token.tag),
                  token.length > 0
            else {
                return nil
            }

            let sourceRange = NSRange(location: token.position, length: token.length)
            guard let stringRange = Range(sourceRange, in: clause) else {
                return nil
            }

            let surface = String(clause[stringRange])
            let normalizedLookupKey = NumericHanjaCandidateGenerator.normalizedDigits(from: surface) ?? surface
            let candidates = candidateLookup(normalizedLookupKey)
            let topHanjaUsage = candidates.first?.usageCount ?? 0
            let hangulUsage = hangulUsageLookup(normalizedLookupKey)
            let preferHangul = hangulUsage > 0 && hangulUsage >= topHanjaUsage
            let allowsAutoConversion = isRealtimeAutoConvertEligibleTag(token.tag)
            let previewCandidate: HanjaCandidate? =
                (preferHangul || !allowsAutoConversion) ? nil : candidates.first
            return HanjaSegment(
                sourceRange: sourceRange,
                surface: surface,
                normalizedLookupKey: normalizedLookupKey,
                tag: token.tag,
                isConvertible: !candidates.isEmpty,
                previewCandidate: previewCandidate
            )
        }

        let numericSegments = makeNumericSegments(
            in: clause,
            candidateLookup: candidateLookup
        )
        guard !numericSegments.isEmpty else {
            return tokenSegments
        }

        return (tokenSegments.filter { tokenSegment in
            !numericSegments.contains { numericSegment in
                rangesOverlap(tokenSegment.sourceRange, numericSegment.sourceRange)
            }
        } + numericSegments)
        .sorted {
            if $0.sourceRange.location != $1.sourceRange.location {
                return $0.sourceRange.location < $1.sourceRange.location
            }

            return $0.sourceRange.length > $1.sourceRange.length
        }
    }

    /// 사용자가 그은 경계(`boundaries`)로 소스를 빈틈없이 분할해 `[HanjaSegment]`를 만든다. Kiwi 토큰 불필요.
    /// 각 span은 표면형으로 사전/숫자 후보를 조회해 후보가 있으면 변환 가능으로 본다.
    /// 의도적으로 POS 태그 필터를 적용하지 않는다 — 사용자가 명시적으로 경계를 그었으므로,
    /// 평소 자동 변환에서 제외되던 표면형(예: 조사)도 후보가 있으면 변환 가능으로 노출한다(설계 4.1 절충).
    static func makeManualSegments(
        boundaries: [Int],
        in clause: String,
        candidateLookup: (String) -> [HanjaCandidate]
    ) -> [HanjaSegment] {
        guard !clause.isEmpty else {
            return []
        }

        let n = inputUTF16Length(of: clause)
        let internalPoints = Set(boundaries.filter { $0 > 0 && $0 < n })
        let edges = [0] + internalPoints.sorted() + [n]

        var segments: [HanjaSegment] = []
        for i in 0..<(edges.count - 1) {
            let range = NSRange(location: edges[i], length: edges[i + 1] - edges[i])
            guard range.length > 0, let stringRange = Range(range, in: clause) else {
                continue
            }

            let surface = String(clause[stringRange])
            let normalizedDigits = NumericHanjaCandidateGenerator.normalizedDigits(from: surface)
            let normalizedLookupKey = normalizedDigits ?? surface
            let candidates = candidateLookup(normalizedLookupKey)
            let isNumeric = normalizedDigits != nil
            // 후보가 있으면 첫 후보를 프리뷰(태그 필터 미적용). 숫자는 기존 UX대로 아라비아 표기 유지.
            let previewCandidate = (isNumeric || candidates.isEmpty) ? nil : candidates.first
            segments.append(
                HanjaSegment(
                    sourceRange: range,
                    surface: surface,
                    normalizedLookupKey: normalizedLookupKey,
                    tag: isNumeric ? .sn : .nng,
                    isConvertible: !candidates.isEmpty,
                    previewCandidate: previewCandidate
                )
            )
        }

        return segments
    }

    static func isRealtimeHanjaEligibleTag(_ tag: POSTag) -> Bool {
        switch tag {
        case .nng, .nnp, .nnb,
             .nr, .np, .sn,
             .vv, .vvi,
             .va, .vai,
             .vx, .vxi,
             .mm, .mag, .maj, .ic,
             .xpn, .xsn, .xsv, .xsa, .xsai, .xr:
            return true
        default:
            return false
        }
    }

    private static func makeNumericSegments(
        in clause: String,
        candidateLookup: (String) -> [HanjaCandidate]
    ) -> [HanjaSegment] {
        var segments: [HanjaSegment] = []
        var spanStart: String.Index?
        var spanContainsDigit = false

        func flushSpan(before end: String.Index) {
            guard let start = spanStart, spanContainsDigit else {
                spanStart = nil
                spanContainsDigit = false
                return
            }

            let surface = String(clause[start..<end])
            guard let normalizedLookupKey = NumericHanjaCandidateGenerator.normalizedDigits(from: surface) else {
                spanStart = nil
                spanContainsDigit = false
                return
            }

            let candidates = candidateLookup(normalizedLookupKey)
            if !candidates.isEmpty {
                let sourceRange = NSRange(start..<end, in: clause)
                segments.append(
                    HanjaSegment(
                        sourceRange: sourceRange,
                        surface: surface,
                        normalizedLookupKey: normalizedLookupKey,
                        tag: .sn,
                        isConvertible: true,
                        previewCandidate: nil
                    )
                )
            }

            spanStart = nil
            spanContainsDigit = false
        }

        var index = clause.startIndex
        while index < clause.endIndex {
            let character = clause[index]
            if character == "," || NumericHanjaCandidateGenerator.isNumericStartCharacter(character) {
                if spanStart == nil {
                    spanStart = index
                }
                if NumericHanjaCandidateGenerator.isNumericStartCharacter(character) {
                    spanContainsDigit = true
                }
            } else {
                flushSpan(before: index)
            }

            index = clause.index(after: index)
        }

        flushSpan(before: clause.endIndex)
        return segments
    }

    private static func rangesOverlap(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        lhs.location < rhs.location + rhs.length && rhs.location < lhs.location + lhs.length
    }

    static func isRealtimeAutoConvertEligibleTag(_ tag: POSTag) -> Bool {
        switch tag {
        case .np, .ic, .vx, .vxi, .xsv, .xsa, .xsai, .xsn:
            return false
        default:
            return isRealtimeHanjaEligibleTag(tag)
        }
    }

    private func drainPendingWarmUpCompletions() {
        guard !pendingWarmUpCompletions.isEmpty else {
            return
        }

        let completions = pendingWarmUpCompletions
        pendingWarmUpCompletions.removeAll()
        for completion in completions {
            completion()
        }
    }
}
