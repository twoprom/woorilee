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

        // "가경:私景" has a single feature whose weight (300) exceeds UInt8's range — the entry is
        // dropped, and since it was the line's only feature, the whole (reading, hanja) pair is
        // dropped too (a line with zero surviving features is malformed).
        XCTAssertNil(table["가경"]?["私景"])
    }

    // MARK: - Real bundled file: parser<->artifact agreement spot-checks

    func testParsesRealRepoFileAndMatchesKnownSpotCheckValues() throws {
        let url = repoRoot().appendingPathComponent("woorilee/data/hanja/hanja-context.txt")
        let contents = try String(contentsOf: url, encoding: .utf8)
        let table = HanjaContextAssociationStore.parse(contents: contents)

        XCTAssertEqual(table["수도"]?["水道"]?["집/NNG"], 37)
        XCTAssertEqual(table["수도"]?["修道"]?["기도/NNG"], 121)
        XCTAssertEqual(table["수도"]?["首都"]?["서울/NNP"], 75)
    }
}
