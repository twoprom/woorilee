// Repo-relative paths for the K1b Task 1 offline association-ranker harness.
//     Copyright (C) 2026 Seungjin Lee.
import Foundation

enum Paths {
    // #filePath = .../woorilee/scripts/hanja-context/assoc/Sources/assoc/Paths.swift
    static let woorileeRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Sources/assoc
        .deletingLastPathComponent() // Sources
        .deletingLastPathComponent() // assoc
        .deletingLastPathComponent() // hanja-context
        .deletingLastPathComponent() // scripts
        .deletingLastPathComponent() // woorilee root

    static let modelDir = woorileeRoot.appendingPathComponent("woorilee/KiwiModels")
    static let hanjaTxt = woorileeRoot.appendingPathComponent("woorilee/data/hanja/hanja.txt")
    static let freqHanja = woorileeRoot.appendingPathComponent("woorilee/data/hanja/freq-hanja.txt")
    static let freqHanjaeo = woorileeRoot.appendingPathComponent("woorilee/data/hanja/freq-hanjaeo.txt")
    static let assocTxt = woorileeRoot.appendingPathComponent("woorilee/data/hanja/hanja-context.txt")
    static let assocBin = woorileeRoot.appendingPathComponent("woorilee/data/hanja/hanja-context.bin")
    static let evalTSV = woorileeRoot.appendingPathComponent("eval/hanja-context-eval-set.tsv")
    static let hanjaNativeHomograph = woorileeRoot.appendingPathComponent("woorilee/data/hanja/hanja-native-homograph.txt")
}
