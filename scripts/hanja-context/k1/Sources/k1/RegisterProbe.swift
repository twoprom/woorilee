// register-probe: minimal mechanism probe for Part 2 (docs/plans/hanja-context-scaling-plan.md
// §12 K1a, item 3) — multi-sense support / sense_id ceiling, donor failure modes, POS tag effect.
import CKiwi
import Foundation

struct ProbeResult: Codable {
    let alias: String
    let pos: String
    let senseId: Int
    let dialect: Int
    let donor: String
    let returnCode: Int32
    let success: Bool
    let errorMessage: String?
}

struct RegisterProbeStats: Codable {
    var multiSenseResults: [ProbeResult]
    var multiSenseMaxSuccessfulSenseId: Int?
    var multiSenseFirstFailureSenseId: Int?
    var ceilingProbeResults: [ProbeResult]
    var ceilingProbeNote: String
    var donorFailureResults: [ProbeResult]
    var posVariantResults: [ProbeResult]
}

/// A hand-picked list of common, real dictionary nouns to use as donors for the multi-sense
/// stress test — they don't need to be semantically related to 전기 (this probes the mechanism,
/// not signal quality), just distinct existing NNG morphemes so each registration borrows
/// different LM statistics.
let commonNNGDonors = [
    "사과", "학교", "나라", "정부", "하늘", "사람", "나무", "강", "여름", "겨울",
    "봄", "가을", "바다", "산", "구름", "바람", "도시", "마을", "회사", "학생",
    "병원", "은행", "공원", "극장", "우체국", "경찰서", "소방서", "신문", "라디오", "자동차",
    "자전거", "지하철", "비행기", "기차", "버스", "우산", "안경", "시계", "가방", "의자",
]

func registerAndCheck(
    _ builder: KiwiBuilderRaw, alias: String, pos: String, senseId: Int, dialect: Int, score: Float, donor: String
) -> ProbeResult {
    let rc = builder.addAliasWordWithDef(
        alias: alias, pos: pos, senseId: Int32(senseId), dialect: Int32(dialect), score: score, origWord: donor)
    var errorMessage: String?
    if rc != 0 {
        errorMessage = kiwi_error().map { String(cString: $0) }
        kiwi_clear_error()
    }
    return ProbeResult(
        alias: alias, pos: pos, senseId: senseId, dialect: dialect, donor: donor,
        returnCode: rc, success: rc == 0, errorMessage: errorMessage)
}

func runRegisterProbe() throws {
    print("=== register-probe ===")
    let builder = try KiwiBuilderRaw(modelPath: Paths.modelDir.path)

    // --- 1. multi-sense: N aliases of the SAME surface form "전기" (a real target reading with
    // up to 26 candidates per the plan), sense_id 1...40, each backed by a distinct real donor. ---
    print("--- multi-sense probe: alias=전기 pos=NNG sense_id=1..40 ---")
    var multiSenseResults: [ProbeResult] = []
    for senseId in 1...40 {
        let donor = commonNNGDonors[(senseId - 1) % commonNNGDonors.count]
        let result = registerAndCheck(builder, alias: "전기", pos: "NNG", senseId: senseId, dialect: 0, score: 0, donor: donor)
        multiSenseResults.append(result)
        print("  sense=\(senseId) donor=\(donor) rc=\(result.returnCode) success=\(result.success)"
            + (result.errorMessage.map { " error=\($0)" } ?? ""))
    }
    let maxSuccess = multiSenseResults.filter(\.success).map(\.senseId).max()
    let firstFailure = multiSenseResults.first { !$0.success }?.senseId
    print("max successful sense_id in 1..40 = \(maxSuccess.map(String.init) ?? "none")")
    print("first failing sense_id in 1..40 = \(firstFailure.map(String.init) ?? "none (all 40 succeeded)")")

    // --- 2. ceiling probe: push further (only if 1..40 was clean) to find where sense_id
    // actually breaks, on a separate synthetic alias so 전기's own probed state stays clean for
    // interpretation. kiwi_token_info_t.sense_id is `uint8_t` in capi.h, so 255 is the hard
    // type-level ceiling regardless of what the loop finds — probing past it (256+) checks
    // whether out-of-range values are rejected outright or silently wrap. ---
    var ceilingResults: [ProbeResult] = []
    var ceilingNote = ""
    if firstFailure == nil {
        print("--- ceiling probe: alias=전기실험용 pos=NNG sense_id=41..300 (cycling donors), stop at first failure ---")
        for senseId in 41...300 {
            let donor = commonNNGDonors[(senseId - 1) % commonNNGDonors.count]
            let result = registerAndCheck(builder, alias: "전기실험용", pos: "NNG", senseId: senseId, dialect: 0, score: 0, donor: donor)
            ceilingResults.append(result)
            if !result.success {
                ceilingNote = "first failure at sense_id=\(senseId): rc=\(result.returnCode) error=\(result.errorMessage ?? "?")"
                print("  \(ceilingNote)")
                break
            }
        }
        if ceilingResults.allSatisfy(\.success) {
            ceilingNote = "all sense_id 41...300 registered successfully (rc=0) — no return-code-level ceiling found below 300. "
                + "NOTE: kiwi_token_info_t.sense_id is uint8_t (capi.h) so 255 is still the hard storage ceiling; "
                + "this probe did not verify whether sense_id>=256 silently truncates mod 256 (semantic collision) "
                + "rather than erroring — that needs a separate analyze()-level check before Part 2 relies on it."
            print("  \(ceilingNote)")
        }
    } else {
        ceilingNote = "skipped — multi-sense probe already found a failure at sense_id=\(firstFailure!)"
        print("--- ceiling probe skipped (\(ceilingNote)) ---")
    }

    // --- 3. donor failure modes ---
    print("--- donor failure modes ---")
    let donorFailureResults = [
        // (a) donor does not exist as any morpheme at all.
        registerAndCheck(builder, alias: "테스트실패A", pos: "NNG", senseId: 1, dialect: 0, score: 0, donor: "존재하지않는형태소압콰르크123"),
        // (b) donor exists (사과/NNG) but not tagged with the requested pos (VV).
        registerAndCheck(builder, alias: "테스트실패B", pos: "VV", senseId: 1, dialect: 0, score: 0, donor: "사과"),
        // (c) donor exists (서울/NNP) but not tagged with the requested pos (NNG).
        registerAndCheck(builder, alias: "테스트실패C", pos: "NNG", senseId: 1, dialect: 0, score: 0, donor: "서울"),
    ]
    for r in donorFailureResults {
        print("  alias=\(r.alias) pos=\(r.pos) donor=\(r.donor) rc=\(r.returnCode) success=\(r.success)"
            + (r.errorMessage.map { " error=\($0)" } ?? ""))
    }

    // --- 4. POS tag effect: does the requested pos have to match the donor's actual tag? ---
    print("--- POS tag effect (NNG vs NNP) ---")
    let posVariantResults = [
        registerAndCheck(builder, alias: "테스트POS1", pos: "NNG", senseId: 1, dialect: 0, score: 0, donor: "사과"), // 사과 is NNG -> expect success
        registerAndCheck(builder, alias: "테스트POS2", pos: "NNP", senseId: 1, dialect: 0, score: 0, donor: "사과"), // 사과 is not NNP -> expect failure
        registerAndCheck(builder, alias: "테스트POS3", pos: "NNP", senseId: 1, dialect: 0, score: 0, donor: "서울"), // 서울 is NNP -> expect success
        registerAndCheck(builder, alias: "테스트POS4", pos: "NNG", senseId: 1, dialect: 0, score: 0, donor: "서울"), // 서울 is not NNG -> expect failure
    ]
    for r in posVariantResults {
        print("  alias=\(r.alias) pos=\(r.pos) donor=\(r.donor) rc=\(r.returnCode) success=\(r.success)"
            + (r.errorMessage.map { " error=\($0)" } ?? ""))
    }

    try ensureOutDir()
    let stats = RegisterProbeStats(
        multiSenseResults: multiSenseResults,
        multiSenseMaxSuccessfulSenseId: maxSuccess,
        multiSenseFirstFailureSenseId: firstFailure,
        ceilingProbeResults: ceilingResults,
        ceilingProbeNote: ceilingNote,
        donorFailureResults: donorFailureResults,
        posVariantResults: posVariantResults
    )
    try writeJSON(stats, to: Paths.outDir.appendingPathComponent("register-probe-stats.json"))
}
