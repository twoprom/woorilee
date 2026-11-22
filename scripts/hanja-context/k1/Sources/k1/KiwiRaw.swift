// Thin, self-contained wrapper over the raw CKiwi C API (docs/plans/hanja-context-scaling-plan.md
// §12 K1a). Deliberately does NOT depend on the `Kiwi` Swift package/product — see Package.swift
// header comment for why (two modules wrapping one binary). Mirrors just enough of
// Kiwi/bindings/swift/Sources/Kiwi/{Kiwi,KiwiBuilder,Token}.swift to drive kiwi_analyze and the
// alias-registration API this track needs.
import CKiwi
import Foundation

struct KiwiRawError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Reads kiwi_error() (thread-local) and clears it, mirroring KiwiError.operationFailed's pattern
/// in the vendored Kiwi Swift package.
func kiwiLastError(_ context: String) -> KiwiRawError {
    if let msg = kiwi_error() {
        let s = String(cString: msg)
        kiwi_clear_error()
        return KiwiRawError(message: "\(context): \(s)")
    }
    return KiwiRawError(message: "\(context): unknown error (kiwi_error() empty)")
}

final class KiwiBuilderRaw {
    let handle: kiwi_builder_h

    /// options/enabledDialects default to KIWI_BUILD_DEFAULT (15) / KIWI_DIALECT_STANDARD (0) —
    /// same as KiwiBuilder(modelPath:) in the vendored Kiwi Swift package (BuildOptions.default,
    /// Dialect.standard), so warm-up behavior matches the runtime/collector build path.
    init(modelPath: String, numThreads: Int32 = -1) throws {
        guard let h = kiwi_builder_init(
            modelPath, numThreads, Int32(KIWI_BUILD_DEFAULT), Int32(KIWI_DIALECT_STANDARD)
        ) else {
            throw kiwiLastError("kiwi_builder_init")
        }
        handle = h
    }

    deinit { kiwi_builder_close(handle) }

    /// Returns the raw kiwi_builder_add_alias_word_with_def return code (0 = success) rather than
    /// throwing, since register-probe needs to report failures per-triple rather than abort.
    func addAliasWordWithDef(
        alias: String, pos: String, senseId: Int32, dialect: Int32, score: Float, origWord: String
    ) -> Int32 {
        kiwi_builder_add_alias_word_with_def(handle, alias, pos, senseId, dialect, score, origWord)
    }

    func build() throws -> KiwiRaw {
        guard let h = kiwi_builder_build(handle, nil, 0) else {
            throw kiwiLastError("kiwi_builder_build")
        }
        return KiwiRaw(handle: h)
    }
}

struct TokenRaw {
    let form: String
    let tag: String
    let senseId: Int
    let dialect: Int
    let score: Float
    let position: Int
    let length: Int
}

struct AnalysisResultRaw {
    let prob: Float
    let tokens: [TokenRaw]
}

final class KiwiRaw {
    let handle: kiwi_h

    init(handle: kiwi_h) { self.handle = handle }

    deinit { kiwi_close(handle) }

    /// matchOptionsRaw is the raw KIWI_MATCH_* bitmask (see Contract.swift). Mirrors
    /// Kiwi.swift's analyze() defaults for every other kiwi_analyze_option_t field (blocklist nil,
    /// open_ending 0, allowed_dialects 0 — §12 선행 실측: never turn dialect parsing on, dialect_cost
    /// 3.0, no typo transformer, typo_threshold 2.5) so the only intentional difference from the
    /// runtime/collector path is matchOptionsRaw + topN, which the caller controls explicitly.
    func analyze(_ text: String, topN: Int32, matchOptionsRaw: Int32) throws -> [AnalysisResultRaw] {
        var option = kiwi_analyze_option_t()
        option.match_options = Int32(matchOptionsRaw)
        option.blocklist = nil
        option.open_ending = 0
        option.allowed_dialects = 0
        option.dialect_cost = 3.0
        option.typo_transformer = nil
        option.typo_threshold = 2.5

        guard let result = kiwi_analyze(handle, text, topN, option, nil) else {
            throw kiwiLastError("kiwi_analyze")
        }
        defer { kiwi_res_close(result) }

        let size = kiwi_res_size(result)
        guard size >= 0 else { throw KiwiRawError(message: "kiwi_res_size < 0") }

        var results: [AnalysisResultRaw] = []
        results.reserveCapacity(Int(size))
        for i in 0..<size {
            let prob = kiwi_res_prob(result, i)
            let wordNum = kiwi_res_word_num(result, i)
            guard wordNum >= 0 else { continue }
            var tokens: [TokenRaw] = []
            tokens.reserveCapacity(Int(wordNum))
            for j in 0..<wordNum {
                guard let formPtr = kiwi_res_form(result, i, j),
                      let info = kiwi_res_token_info(result, i, j)
                else { continue }
                let form = String(cString: formPtr)
                let ti = info.pointee
                // Decode the numeric tag byte ourselves (posTagName) rather than trusting
                // kiwi_res_tag()'s string — see POSTagNames.swift header comment for why.
                let tag = posTagName(rawValue: ti.tag)
                tokens.append(TokenRaw(
                    form: form,
                    tag: tag,
                    senseId: Int(ti.sense_id),
                    dialect: Int(ti.dialect),
                    score: ti.score,
                    position: Int(ti.chr_position),
                    length: Int(ti.length)
                ))
            }
            results.append(AnalysisResultRaw(prob: prob, tokens: tokens))
        }
        return results
    }
}

func kiwiVersion() -> String {
    kiwi_version().map { String(cString: $0) } ?? "unknown"
}
