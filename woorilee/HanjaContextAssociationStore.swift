// Loads and queries the bundled (reading, hanja) -> content-morpheme association table.
//     Copyright (C) 2026 Seungjin Lee.
//
// Step 5c (런타임 통합) — see docs/plans/context-aware-hanja-conversion.md §7. Backing file is
// woorilee/data/hanja/hanja-context.txt, produced by scripts/hanja-context/build_association_table.py
// (format + percent-escaping contract documented in scripts/hanja-context/README.md).

import Foundation

@MainActor
final class HanjaContextAssociationStore {
    enum Status: Equatable {
        case uninitialized
        case loading
        case ready
        case unavailable(String)
    }

    static let shared = HanjaContextAssociationStore()

    private(set) var status: Status = .uninitialized
    private var table: [String: [String: [String: UInt8]]] = [:]
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
            let resourceURL = bundle.url(
                forResource: AppRuntimePaths.hanjaContextResourceName,
                withExtension: AppRuntimePaths.hanjaResourceExtension,
                subdirectory: AppRuntimePaths.hanjaResourceSubdirectory
            )

            let resolvedStatus: Status
            var loadedTable: [String: [String: [String: UInt8]]] = [:]

            if let resourceURL, let contents = try? String(contentsOf: resourceURL, encoding: .utf8) {
                loadedTable = Self.parse(contents: contents)
                resolvedStatus = .ready
            } else if let resourceURL {
                resolvedStatus = .unavailable("Failed to load hanja context association table from \(resourceURL.path)")
            } else {
                resolvedStatus = .unavailable(
                    "Bundled hanja context association table was not found at "
                        + "\(AppRuntimePaths.hanjaResourceSubdirectory)/\(AppRuntimePaths.hanjaContextResourceName).\(AppRuntimePaths.hanjaResourceExtension)"
                )
            }

            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }

                    self.table = loadedTable
                    self.status = resolvedStatus
                    self.drainPendingWarmUpCompletions()
                }
            }
        }
    }

    /// Matched-feature weights for `(reading, hanja)`, or nil if the pair has no surviving features
    /// (either the reading wasn't ambiguous enough to be a step-5a target, or the store isn't ready).
    func features(reading: String, hanja: String) -> [String: UInt8]? {
        table[reading]?[hanja]
    }

    /// Parses `hanja-context.txt` contents: `읽기:한자:형태소=가중치,형태소=가중치,...` per line, `#`
    /// header/comment lines and malformed lines skipped. Percent-escaped feature text (`%25`→`%`,
    /// `%3A`→`:`, `%2C`→`,`, `%3D`→`=`) is decoded AFTER splitting on the raw `:`/`,`/`=` delimiters,
    /// with `%25` decoded LAST (see scripts/hanja-context/README.md 단계 5b).
    nonisolated static func parse(contents: String) -> [String: [String: [String: UInt8]]] {
        var result: [String: [String: [String: UInt8]]] = [:]
        result.reserveCapacity(3_000)

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard !rawLine.hasPrefix("#") else { continue }

            guard let firstColon = rawLine.firstIndex(of: ":") else { continue }
            let reading = String(rawLine[rawLine.startIndex..<firstColon])
            guard !reading.isEmpty else { continue }

            let afterReading = rawLine[rawLine.index(after: firstColon)...]
            guard let secondColon = afterReading.firstIndex(of: ":") else { continue }
            let hanja = String(afterReading[afterReading.startIndex..<secondColon])
            guard !hanja.isEmpty else { continue }

            let featureList = afterReading[afterReading.index(after: secondColon)...]
            guard !featureList.isEmpty else { continue }

            var features: [String: UInt8] = [:]
            for entry in featureList.split(separator: ",", omittingEmptySubsequences: true) {
                guard let equalsIndex = entry.lastIndex(of: "="), entry.startIndex < equalsIndex else { continue }
                let featureRaw = entry[entry.startIndex..<equalsIndex]
                let weightRaw = entry[entry.index(after: equalsIndex)...]
                guard let weight = UInt8(weightRaw), !featureRaw.isEmpty else { continue }
                features[percentDecodeFeature(featureRaw)] = weight
            }

            guard !features.isEmpty else { continue }
            result[reading, default: [:]][hanja] = features
        }

        return result
    }

    nonisolated private static func percentDecodeFeature(_ raw: Substring) -> String {
        // Fast path: only 65 of the ~535,000 feature occurrences in the bundled table contain a
        // '%' at all (spot-checked against the real file) — skip the four allocation-heavy
        // replacingOccurrences passes entirely for the common case.
        guard raw.contains("%") else { return String(raw) }

        var decoded = String(raw)
        decoded = decoded.replacingOccurrences(of: "%3A", with: ":")
        decoded = decoded.replacingOccurrences(of: "%2C", with: ",")
        decoded = decoded.replacingOccurrences(of: "%3D", with: "=")
        decoded = decoded.replacingOccurrences(of: "%25", with: "%")
        return decoded
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
