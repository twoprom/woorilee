// Tests for HanjaContextAssociationStore's hanja-context.txt parser.
//     Copyright (C) 2026 Seungjin Lee.
//
// See docs/plans/context-aware-hanja-conversion.md §7 5c and scripts/hanja-context/README.md for
// the format contract: 읽기:한자:형태소=가중치,형태소=가중치,... with '%'->'%25', ':'->'%3A',
// ','->'%2C', '='->'%3D' percent-escaping applied to feature text only.

import XCTest
@testable import woorilee

final class HanjaContextAssociationStoreTests: XCTestCase {
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: - Inline fixture: percent-escaping + malformed-line tolerance

    func testParseDecodesPercentEscapedFeatureAndSkipsMalformedLines() throws {
        let fixture = """
        # comment line, must be ignored
        가경:佳景:집%3A수도%2C%25%3D류/NNG=50,단순/NNGX=200
        noColonAtAllHere
        가경:假景
        가경::빈한자
        가경:私景:정상/NNG=300
        """

        let table = HanjaContextAssociationStore.parse(contents: fixture)

        // Only the well-formed line survives.
        XCTAssertEqual(table.count, 1)
        let features = try XCTUnwrap(table["가경"]?["佳景"])
        XCTAssertEqual(features, ["집:수도,%=류/NNG": 50, "단순/NNGX": 200])

        // "가경:假景" (no feature field), "가경::빈한자" (empty hanja), and the bare malformed line
        // must all be skipped without throwing.
        XCTAssertNil(table["가경"]?["假景"])

        // "가경:私景" has a single feature whose weight (300) exceeds the text format's signed
        // -255...255 quantization range (D3, docs/plans/hanja-context-scaling-plan.md §5 "0c 포맷
        // 명세") — the entry is dropped, and since it was the line's only feature, the whole
        // (reading, hanja) pair is dropped too (a line with zero surviving features is malformed).
        XCTAssertNil(table["가경"]?["私景"])
    }

    // MARK: - D3: signed weight range (docs/plans/hanja-context-scaling-plan.md §5 "0c 포맷 명세")

    /// A negative weight (the offline export's signed text grid can now emit these) must parse
    /// exactly like any positive weight — negated.
    func testParseAcceptsNegativeWeightsWithinTheSignedRange() {
        let fixture = "가경:私景:정상/NNG=-200"

        let table = HanjaContextAssociationStore.parse(contents: fixture)

        XCTAssertEqual(table["가경"]?["私景"]?["정상/NNG"], -200)
    }

    /// The widened range is still bounded at ±255 — weights one past either boundary must still
    /// be dropped (and, per the "zero surviving features ⇒ malformed line" rule, drop the whole
    /// (reading, hanja) pair when they were its only features).
    func testParseIgnoresWeightsOutsideTheSignedRange() {
        let fixture = "가경:私景:정상/NNG=256,반대/NNG=-256"

        let table = HanjaContextAssociationStore.parse(contents: fixture)

        XCTAssertNil(table["가경"]?["私景"])
    }

    /// The exact boundary values (-255 and 255) must both survive — the range is inclusive on
    /// both ends.
    func testParseAcceptsTheSignedRangeBoundaries() {
        let fixture = "가경:私景:최소/NNG=-255,최대/NNG=255"

        let table = HanjaContextAssociationStore.parse(contents: fixture)

        XCTAssertEqual(table["가경"]?["私景"]?["최소/NNG"], -255)
        XCTAssertEqual(table["가경"]?["私景"]?["최대/NNG"], 255)
    }

    // MARK: - Real bundled file: parser<->artifact agreement spot-checks

    func testParsesRealRepoFileAndMatchesKnownSpotCheckValues() throws {
        let url = repoRoot().appendingPathComponent("woorilee/data/hanja/hanja-context.txt")
        let contents = try String(contentsOf: url, encoding: .utf8)
        let table = HanjaContextAssociationStore.parse(contents: contents)

        // 집/NNG=40 (house — the word that disambiguates "우리 집 수도") is back in the table as
        // of 단계 0c: the M=100 cut (docs/plans/hanja-context-scaling-plan.md §5) that dropped it
        // after 단계 0a removed the eval-27 evidence floor was widened to M=300 once the binary
        // format's smaller footprint gave room in the 8MB budget (5.49 MiB at M=300, still under
        // cap) — see the 0c M-experiment report for the full comparison. 수돗물/NNG (tap water,
        // 水道's top feature by selection utility) and the 修道/首都 spot-check features are
        // unchanged from M=100/200 (top-utility features are the first admitted regardless of M).
        XCTAssertEqual(table["수도"]?["水道"]?["수돗물/NNG"], 186)
        XCTAssertEqual(table["수도"]?["水道"]?["집/NNG"], 40)
        XCTAssertEqual(table["수도"]?["修道"]?["기도/NNG"], 123)
        XCTAssertEqual(table["수도"]?["首都"]?["서울/NNP"], 76)
    }

    // MARK: - Step 0c binary format (docs/plans/hanja-context-scaling-plan.md §5 "0c 포맷 명세")

    /// Hand-built binary fixture matching the format spec exactly: one reading (가경) with two
    /// candidates, three total features. Deliberately does NOT call into
    /// `HanjaContextAssociationStore`/`encode_binary` internals (both are `private` to their own
    /// files anyway) — a from-scratch byte builder plus an independent CRC32 reimplementation, so
    /// this is a genuine roundtrip test of `parseBinary`, not a tautology.
    ///
    /// Feature IDs (sorted by Unicode code point, per spec): 꾸미/VV=0, 정경/NNG=1, 집/NNG=2.
    /// readingScaleNats=2.0, globalScaleNats=1.0 -> loader value = qw * 2.0.
    ///   佳景: 정경/NNG qw=50 -> 100.0, 집/NNG qw=100 -> 200.0
    ///   假景: 꾸미/VV qw=10 -> 20.0
    private static func makeFixtureBinaryData(
        corruptCRC: Bool = false,
        biasForJing: Float32 = 0.0,
        biasForJia: Float32 = 0.0
    ) -> Data {
        func packString(_ s: String) -> [UInt8] {
            let utf8 = Array(s.utf8)
            let len = UInt16(utf8.count)
            return [UInt8(len & 0xFF), UInt8((len >> 8) & 0xFF)] + utf8
        }
        func packUInt16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func packUInt32(_ v: UInt32) -> [UInt8] {
            [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        }
        func packFloat32(_ v: Float32) -> [UInt8] { packUInt32(v.bitPattern) }
        func packInt8(_ v: Int8) -> [UInt8] { [UInt8(bitPattern: v)] }

        let features = ["꾸미/VV", "정경/NNG", "집/NNG"] // already code-point sorted
        var section1: [UInt8] = []
        for f in features { section1 += packString(f) }

        var section2: [UInt8] = []
        section2 += packString("가경")
        section2 += packFloat32(2.0) // readingScaleNats
        section2 += packUInt16(2)    // candidateCount

        var section3: [UInt8] = []
        // 佳景: 정경/NNG(id=1, qw=50), 집/NNG(id=2, qw=100) — featureIDs ascending.
        section3 += packString("佳景")
        section3 += packFloat32(biasForJing) // bias — D3, defaults to 0.0 (pre-D3 fixture value)
        section3 += packUInt32(2)    // entryCount
        section3 += packUInt32(1) + packUInt32(2)
        section3 += packInt8(50) + packInt8(100)
        // 假景: 꾸미/VV(id=0, qw=10).
        section3 += packString("假景")
        section3 += packFloat32(biasForJia) // bias — D3, defaults to 0.0 (pre-D3 fixture value)
        section3 += packUInt32(1)
        section3 += packUInt32(0)
        section3 += packInt8(10)

        let payload = section1 + section2 + section3
        let realCRC = fixtureCRC32(payload)
        let crc = corruptCRC ? realCRC ^ 0xFFFF_FFFF : realCRC

        var header: [UInt8] = Array("HJC2".utf8)
        header += packUInt16(2)  // version
        header += packUInt16(0)  // flags
        header += packUInt32(crc)
        header += packUInt32(UInt32(features.count))
        header += packUInt32(1)  // readingCount
        header += packUInt32(2)  // candidateProfileCount
        header += packUInt32(3)  // featureEntryCount
        header += packFloat32(1.0) // globalScaleNats

        return Data(header + payload)
    }

    /// Standalone CRC-32 (IEEE 802.3), independent of `HanjaContextAssociationStore`'s private
    /// implementation — verified against Python's `zlib.crc32` during development.
    private static func fixtureCRC32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1 != 0) ? (0xEDB8_8320 ^ (crc >> 1)) : (crc >> 1)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    func testParseBinaryParsesValidFixture() throws {
        let table = try XCTUnwrap(HanjaContextAssociationStore.parseBinary(data: Self.makeFixtureBinaryData()))

        XCTAssertEqual(table.count, 1)
        let candidates = try XCTUnwrap(table["가경"])
        XCTAssertEqual(Set(candidates.keys), ["佳景", "假景"])

        let jingFeatures = try XCTUnwrap(candidates["佳景"])
        XCTAssertEqual(jingFeatures.count, 2)
        XCTAssertEqual(jingFeatures["정경/NNG"] ?? -1, 100.0, accuracy: 0.0001)
        XCTAssertEqual(jingFeatures["집/NNG"] ?? -1, 200.0, accuracy: 0.0001)

        let ga2Features = try XCTUnwrap(candidates["假景"])
        XCTAssertEqual(ga2Features.count, 1)
        XCTAssertEqual(ga2Features["꾸미/VV"] ?? -1, 20.0, accuracy: 0.0001)
    }

    /// Every corruption mode must fall back to nil (fail open — the store's existing convention),
    /// never crash.
    func testParseBinaryFallsBackToNilOnCorruption() {
        let valid = Self.makeFixtureBinaryData()

        var badMagic = [UInt8](valid)
        badMagic[0] = 0x00
        XCTAssertNil(HanjaContextAssociationStore.parseBinary(data: Data(badMagic)), "bad magic must fall back to nil")

        var badVersion = [UInt8](valid)
        badVersion[4] = 0xFF
        XCTAssertNil(HanjaContextAssociationStore.parseBinary(data: Data(badVersion)), "bad version must fall back to nil")

        XCTAssertNil(HanjaContextAssociationStore.parseBinary(data: valid.prefix(20)), "truncated file must fall back to nil")
        XCTAssertNil(HanjaContextAssociationStore.parseBinary(data: Data()), "empty file must fall back to nil")

        let badCRC = Self.makeFixtureBinaryData(corruptCRC: true)
        XCTAssertNil(HanjaContextAssociationStore.parseBinary(data: badCRC), "CRC mismatch must fall back to nil")
    }

    // MARK: - D3: bias slot (docs/plans/hanja-context-scaling-plan.md §5 "0c 포맷 명세" §3)

    /// `parseBinaryWithBias` must surface a distinct bias per candidate, including a candidate
    /// whose bias is exactly 0.0 (must round-trip as 0.0, not be dropped/confused with "no
    /// entry" — `bias(reading:hanja:)`'s `nil` is reserved for "pair absent from the table"). The
    /// feature-weight values (unaffected by this D3 addition) are re-checked here too, to confirm
    /// the new bias read didn't shift the reader's cursor and corrupt the surrounding parse.
    func testParseBinaryWithBiasSurfacesNonZeroAndZeroBiasPerCandidate() throws {
        let data = Self.makeFixtureBinaryData(biasForJing: 12.5, biasForJia: 0.0)
        let parsed = try XCTUnwrap(HanjaContextAssociationStore.parseBinaryWithBias(data: data))

        XCTAssertEqual(parsed.biases["가경"]?["佳景"] ?? -1, 12.5, accuracy: 0.0001)
        XCTAssertEqual(
            parsed.biases["가경"]?["假景"] ?? -1, 0.0, accuracy: 0.0001,
            "a zero bias entry must round-trip as 0.0, not be dropped/absent"
        )

        // Feature weights must be untouched by the bias addition.
        XCTAssertEqual(parsed.features["가경"]?["佳景"]?["정경/NNG"] ?? -1, 100.0, accuracy: 0.0001)
        XCTAssertEqual(parsed.features["가경"]?["假景"]?["꾸미/VV"] ?? -1, 20.0, accuracy: 0.0001)
    }

    /// A non-finite bias Float32 (NaN or ±Infinity) must fail the WHOLE parse (fail open, this
    /// parser's existing convention for every other corruption mode) — not just drop the one
    /// affected candidate into a partial table.
    func testParseBinaryWithBiasFailsWholeParseOnNonFiniteBias() {
        let nanData = Self.makeFixtureBinaryData(biasForJing: Float32.nan, biasForJia: 0.0)
        XCTAssertNil(
            HanjaContextAssociationStore.parseBinaryWithBias(data: nanData),
            "NaN bias must fail the whole parse, not just drop one candidate"
        )

        let infData = Self.makeFixtureBinaryData(biasForJing: Float32.infinity, biasForJia: 0.0)
        XCTAssertNil(HanjaContextAssociationStore.parseBinaryWithBias(data: infData), "+Infinity bias must fail the whole parse")

        let negInfData = Self.makeFixtureBinaryData(biasForJing: 0.0, biasForJia: -Float32.infinity)
        XCTAssertNil(HanjaContextAssociationStore.parseBinaryWithBias(data: negInfData), "-Infinity bias must fail the whole parse")
    }

    /// `parseBinary` (the thin feature-only wrapper) is defined straight in terms of
    /// `parseBinaryWithBias` — a non-finite bias must fail through it too, not be silently
    /// swallowed because the wrapper only looks at `.features`.
    func testParseBinaryAlsoFailsOnNonFiniteBiasViaTheThinWrapper() {
        let nanData = Self.makeFixtureBinaryData(biasForJing: Float32.nan, biasForJia: 0.0)
        XCTAssertNil(HanjaContextAssociationStore.parseBinary(data: nanData))
    }

    // MARK: - Real bundled file: text vs binary parser agreement

    /// Entry-set + value-tolerance agreement between `parse` (text) and `parseBinary` on the SAME
    /// build's real bundled artifacts. Sample: the flagship 수도 reading (all candidates) plus a
    /// deterministic spread across the rest of the table (every 200th reading in sorted order) —
    /// a full 500k+-entry sweep isn't needed to catch a systematic writer/loader bug, and this
    /// keeps the test fast and its failure diagnostics (specific reading/hanja/feature) useful.
    func testTextAndBinaryParsersAgreeOnRealRepoDataSpotSamples() throws {
        let root = repoRoot()
        let textContents = try String(
            contentsOf: root.appendingPathComponent("woorilee/data/hanja/hanja-context.txt"), encoding: .utf8)
        let textTable = HanjaContextAssociationStore.parse(contents: textContents)

        let binData = try Data(contentsOf: root.appendingPathComponent("woorilee/data/hanja/hanja-context.bin"))
        let binTable = try XCTUnwrap(HanjaContextAssociationStore.parseBinary(data: binData))

        var sampleReadings: Set<String> = ["수도"]
        let sortedReadings = textTable.keys.sorted()
        var i = 0
        while i < sortedReadings.count {
            sampleReadings.insert(sortedReadings[i])
            i += 200
        }

        var comparedEntries = 0
        for reading in sampleReadings {
            guard let textCandidates = textTable[reading] else { continue }
            guard let binCandidates = binTable[reading] else {
                XCTFail("binary table missing reading \(reading) present in text table")
                continue
            }
            XCTAssertEqual(
                Set(textCandidates.keys), Set(binCandidates.keys),
                "candidate set mismatch for reading \(reading)"
            )

            // Per-reading tolerance: the binary format's Int8 weights (127 steps) are HALF the
            // resolution of the text format's UInt8 weights (255 steps), so a reading whose own
            // top feature is already close to the text file's GLOBAL max (i.e. its per-reading
            // quantization grid, readingScaleNats = localMax/127, ends up comparable to or
            // coarser than the text grid's fixed global_max/255 step) legitimately needs more
            // than 1.0 global unit of slack — this is the documented Int8-vs-UInt8 range
            // trade-off (docs/plans/hanja-context-scaling-plan.md §5 "0c 포맷 명세"), not a
            // defect. `readingScaleNats`, expressed in the text's own global-unit grid, equals
            // exactly `localMaxTextWeight / 127` (both grids are linear over the same score
            // axis), so this is derivable straight from the text table without needing the
            // binary's raw header fields. Typical readings (local max « global max) still floor
            // at 1.0 global unit, matching the common-case target.
            let readingLocalMaxTextWeight = textCandidates.values.flatMap(\.values).max() ?? 0
            let tolerance = max(1.0, readingLocalMaxTextWeight / 127.0)

            for (hanja, textFeatures) in textCandidates {
                guard let binFeatures = binCandidates[hanja] else {
                    XCTFail("binary table missing candidate \(reading):\(hanja)")
                    continue
                }
                XCTAssertEqual(
                    Set(textFeatures.keys), Set(binFeatures.keys),
                    "feature set mismatch for \(reading):\(hanja)"
                )
                for (feature, textValue) in textFeatures {
                    guard let binValue = binFeatures[feature] else {
                        XCTFail("binary table missing feature \(feature) for \(reading):\(hanja)")
                        continue
                    }
                    XCTAssertEqual(
                        textValue, binValue, accuracy: tolerance,
                        "\(reading):\(hanja):\(feature) text=\(textValue) binary=\(binValue) exceeds ±\(tolerance) global-unit tolerance"
                    )
                    comparedEntries += 1
                }
            }
        }

        XCTAssertGreaterThan(comparedEntries, 0)
        print("HJC0C|compared_entries=\(comparedEntries) sample_readings=\(sampleReadings.count)")
    }

    /// The finer per-reading binary quantization must never change the RELATIVE candidate order
    /// production ranking produces vs the coarser global text quantization, for a real context
    /// feature on the flagship 수도 reading. Frequencies mirror `HanjaContextRankerTests`'
    /// `sudoCandidatesByFrequency()` (decoded freq-hanjaeo.txt values, §0 실측).
    func testTextAndBinaryParsersProduceIdenticalCandidateOrderingForFlagshipReading() throws {
        let candidates = [
            HanjaCandidate(reading: "수도", value: "首都", comment: "", source: .system, usageCount: 0, frequency: 11750, baseRank: 0),
            HanjaCandidate(reading: "수도", value: "修道", comment: "", source: .system, usageCount: 0, frequency: 2737, baseRank: 1),
            HanjaCandidate(reading: "수도", value: "水道", comment: "", source: .system, usageCount: 0, frequency: 2106, baseRank: 2),
        ]

        let root = repoRoot()
        let textContents = try String(
            contentsOf: root.appendingPathComponent("woorilee/data/hanja/hanja-context.txt"), encoding: .utf8)
        let textTable = HanjaContextAssociationStore.parse(contents: textContents)
        let binData = try Data(contentsOf: root.appendingPathComponent("woorilee/data/hanja/hanja-context.bin"))
        let binTable = try XCTUnwrap(HanjaContextAssociationStore.parseBinary(data: binData))

        // 수돗물/NNG is 水道's top feature by selection utility (established in
        // testParsesRealRepoFileAndMatchesKnownSpotCheckValues) — present regardless of the
        // chosen M, since top-utility features are the last to be pruned.
        let contextFeatures = ["수돗물/NNG"]

        let textScores = associationScores(
            for: candidates, contextFeatures: contextFeatures, lookup: { r, h in textTable[r]?[h] })
        let binScores = associationScores(
            for: candidates, contextFeatures: contextFeatures, lookup: { r, h in binTable[r]?[h] })
        XCTAssertFalse(textScores.isEmpty, "수돗물/NNG must match at least one candidate in the real table")

        let textRanked = rankWithContext(
            candidates: candidates, contextDominantHanja: [], associationScores: textScores, weights: .default)
        let binRanked = rankWithContext(
            candidates: candidates, contextDominantHanja: [], associationScores: binScores, weights: .default)

        XCTAssertEqual(textRanked.map(\.value), binRanked.map(\.value))
    }
}
