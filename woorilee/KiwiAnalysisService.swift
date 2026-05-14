//
//  KiwiAnalysisService.swift
//  woorilee
//
//  Created by Codex on 4/22/26.
//

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
