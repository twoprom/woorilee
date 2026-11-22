// Compile-only shim, NOT a reimplementation of any ranking/segmentation logic.
//     Copyright (C) 2026 Seungjin Lee.
//
// `inputUTF16Length(of:)` is used by the symlinked AppSource/HanjaConversionModels.swift and
// AppSource/KiwiAnalysisService.swift (in code paths this harness never calls — e.g.
// RealtimeClauseState's manual-boundary editing, makeManualSegments), but the function itself is
// only DEFINED in woorilee/InputSession.swift, which imports Cocoa/IMKSwift and was deliberately
// left out of this package's closure (see Package.swift's header comment and the K1b Task 1
// report's file-by-file dependency check). Whole-file compilation requires every declaration in
// the symlinked files to type-check even if this harness's own code never reaches those branches,
// so this one-line shim — byte-identical to InputSession.swift's definition — satisfies the
// compiler without touching woorilee/ or duplicating any ranker/segmentation math.
import Foundation

func inputUTF16Length(of text: String) -> Int {
    text.utf16.count
}
