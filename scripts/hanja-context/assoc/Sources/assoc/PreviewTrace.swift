// Public development fixtures only. Simulates two-beolsik keystrokes, not host IPC or panel UI.
import Foundation
import LibHangul

@MainActor
enum PreviewTrace {
    static func run(inputPath: String, outputPath: String) throws {
        let lines = try String(contentsOfFile: inputPath, encoding: .utf8).split(separator: "\n")
        let kiwi = Fixtures.kiwi
        let table = Fixtures.associationTableFromBinary
        let biases = Fixtures.associationBiasFromBinary
        _ = Fixtures.dominantMap
        _ = Fixtures.candidateLookup("수도")
        HanjaPerformance.observer = { _, _ in }
        defer { HanjaPerformance.observer = nil }
        var output = ""
        for line in lines where !line.hasPrefix("#") && !line.hasPrefix("id\t") {
            let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard c.count == 4 else { continue }
            let keys = keyboardKeys(for: c[1])
            let hangul = LibHangul.createThreadSafeInputContext(keyboard: "2")
            var committed = ""
            var steps: [[String: Any]] = []
            var choices: [String] = []
            for (index, key) in Array(keys).enumerated() {
                let start = DispatchTime.now().uptimeNanoseconds
                if hangul.process(key) {
                    committed += decode(hangul.getCommitString())
                } else {
                    committed += decode(hangul.flush()) + String(key)
                }
                let tail = decode(hangul.getPreeditString())
                let source = committed + tail
                let analysis = KiwiAnalysisService.analyzeClause(source, kiwi: kiwi,
                    candidateLookup: Fixtures.candidateLookup, hangulUsageLookup: { _ in 0 },
                    dominantMap: Fixtures.dominantMap,
                    associationFeatureLookup: { table[$0]?[$1] },
                    associationBiasLookup: { biases[$0]?[$1] },
                    autoConvertGate: Fixtures.autoConvertGate,
                    nativeHomographLookup: Fixtures.nativeHomographLookup,
                    composingTailStart: committed.utf16.count)
                var state = RealtimeClauseState()
                state.rawClauseText = committed
                state.tailPreedit = tail
                state.updateAnalysis(segments: analysis.segments)
                let target = analysis.segments.first { $0.surface == c[2] }
                let choice = target.map { $0.previewCandidate?.value ?? $0.surface } ?? "<unsegmented>"
                choices.append(choice)
                steps.append(["key_index": index + 1, "source": source, "preview": state.previewClauseText,
                    "target_value": choice,
                    "simulation_pipeline_ms": Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000])
            }
            committed += decode(hangul.flush())
            guard committed == c[1] else {
                throw NSError(domain: "PreviewTrace", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Two-beolsik roundtrip mismatch for fixture \(c[0])"])
            }
            let firstCorrect = choices.firstIndex(of: c[3]).map { $0 + 1 } ?? -1
            let lastIncorrect = choices.lastIndex { $0 != c[3] }
            let stableCorrect = choices.last == c[3] ? (lastIncorrect.map { $0 + 2 } ?? 1) : -1
            let changes = zip(choices, choices.dropFirst()).filter { $0 != $1 }.count
            let record: [String: Any] = ["id": c[0], "sentence": c[1], "reading": c[2],
                "expected": c[3], "scope": "analysis_prefix_simulation_not_full_event_loop", "provenance": "authored_development_fixture_not_independent_gold",
                "keys": keys.count, "first_correct_key": firstCorrect,
                "stable_correct_key": stableCorrect, "target_choice_changes": changes, "steps": steps]
            output += String(decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), as: UTF8.self) + "\n"
        }
        try output.write(toFile: outputPath, atomically: true, encoding: .utf8)
        print("app-preview-trace: wrote public development traces -> \(outputPath)")
    }

    private static func decode(_ chars: [UCSChar]) -> String {
        var result = String(String.UnicodeScalarView(chars.compactMap { UnicodeScalar($0) }))
            .precomposedStringWithCanonicalMapping
        result = String(String.UnicodeScalarView(result.unicodeScalars.compactMap { scalar in
            if (0x1100...0x11FF).contains(scalar.value) {
                return UnicodeScalar(HangulCharacter.jamoToCJamo(UCSChar(scalar.value)))
            }
            return scalar
        }))
        return result
    }

    private static func keyboardKeys(for text: String) -> String {
        let initials = ["r","R","s","e","E","f","a","q","Q","t","T","d","w","W","c","z","x","v","g"]
        let vowels = ["k","o","i","O","j","p","u","P","h","hk","ho","hl","y","n","nj","np","nl","b","m","ml","l"]
        let finals = ["","r","R","rt","s","sw","sg","e","f","fr","fa","fq","ft","fx","fv","fg","a","q","qt","t","T","d","w","c","z","x","v","g"]
        return text.unicodeScalars.map { scalar -> String in
            guard (0xAC00...0xD7A3).contains(scalar.value) else { return String(scalar) }
            let offset = Int(scalar.value - 0xAC00)
            return initials[offset / 588] + vowels[(offset % 588) / 28] + finals[offset % 28]
        }.joined()
    }
}
