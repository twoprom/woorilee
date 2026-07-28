import CKiwi

// Morpheme-space contract (docs/plans/hanja-context-scaling-plan.md §1 실행 공통 규칙,
// scripts/hanja-context/README.md "형태소 공간 계약"), reconstructed here from the raw CKiwi C
// API rather than via the `Kiwi` Swift package. MUST match
// scripts/hanja-context/collector/Sources/collector/main.swift `enum Contract` exactly — the
// `verify-contract` subcommand proves this rather than assuming it.
enum Contract {
    static let topN: Int32 = 1

    static let contentTags: Set<String> = ["NNG", "NNP", "VV", "VV-I", "VA", "VA-I", "MAG", "XR"]

    // Hand-derived expected raw value from Kiwi/bindings/swift/Sources/Kiwi/MatchOptions.swift:
    //   .all = [.url, .email, .hashtag, .mention, .serial, .emoji, .zCoda]
    //        = (1<<0)|(1<<1)|(1<<2)|(1<<3)|(1<<4)|(1<<5)|(1<<23)
    //        = 1+2+4+8+16+32+8_388_608 = 8_388_671
    //   .allWithNormalizing = .all | .normalizeCoda(1<<16) = 8_388_671 + 65_536 = 8_454_207
    //   contract = .allWithNormalizing | .joinNounPrefix(1<<17) | .joinNounSuffix(1<<18)
    //            = 8_454_207 + 131_072 + 262_144 = 8_847_423
    static let expectedMatchOptionsRaw: Int32 = 8_847_423

    // Same composite, built from the raw C enum constants the k1 runner actually uses at
    // analysis time (KIWI_MATCH_* from capi.h) — if this ever diverges from
    // expectedMatchOptionsRaw, the hand-derivation above is stale and must be recomputed, not
    // silently trusted.
    static let matchOptionsRaw: Int32 = Int32(
        KIWI_MATCH_ALL_WITH_NORMALIZING | KIWI_MATCH_JOIN_NOUN_PREFIX | KIWI_MATCH_JOIN_NOUN_SUFFIX
    )

    // KiwiBuilder(modelPath:) in the vendored Kiwi Swift package defaults to BuildOptions.default
    // (integrateAllomorph | loadDefaultDict | loadTypoDict | loadMultiDict = 1+2+4+8 = 15) and
    // Dialect.standard (0) — this is also what scripts/hanja-context/collector's buildKiwi() uses
    // (KiwiBuilder(modelPath:numThreads:) with no explicit options/dialect override).
    static let expectedBuildOptionsRaw: Int32 = 15
    static let buildOptionsRaw: Int32 = Int32(KIWI_BUILD_DEFAULT)
    static let dialectStandardRaw: Int32 = Int32(KIWI_DIALECT_STANDARD)

    static func feature(form: String, tag: String) -> String { form + "/" + tag }
}
