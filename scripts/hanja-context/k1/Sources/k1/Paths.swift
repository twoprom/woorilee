import Foundation

// Path layout mirrors scripts/hanja-context/collector/Sources/collector/main.swift `enum Paths`.
enum Paths {
    // #filePath = .../woorilee/scripts/hanja-context/k1/Sources/k1/Paths.swift
    static let woorileeRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Sources/k1
        .deletingLastPathComponent() // Sources
        .deletingLastPathComponent() // k1
        .deletingLastPathComponent() // hanja-context
        .deletingLastPathComponent() // scripts
        .deletingLastPathComponent() // woorilee root

    static let modelDir = woorileeRoot.appendingPathComponent("woorilee/KiwiModels")
    static let evalTSV = woorileeRoot.appendingPathComponent("eval/hanja-context-eval-set.tsv")
    static let trackedDumpTokensTSV = woorileeRoot
        .appendingPathComponent("scripts/hanja-context/verification-tokens.tsv")
    static let collectorDir = woorileeRoot.appendingPathComponent("scripts/hanja-context/collector")
    static let assocTxt = woorileeRoot.appendingPathComponent("woorilee/data/hanja/hanja-context.txt")

    // Bulk/gitignored work area (계획 §1 실행 공통 규칙 — 대용량 산출물은 woorilee 리포 밖).
    static let hanjaContextWorkDir = woorileeRoot
        .deletingLastPathComponent()
        .appendingPathComponent("wooriHanjaModel/work/hanja-context")
    static let inventoryDir = hanjaContextWorkDir.appendingPathComponent("inventory")
    static let seedsDir = hanjaContextWorkDir.appendingPathComponent("seeds")
    static let niklDefsTSV = hanjaContextWorkDir.appendingPathComponent("nikl/definitions.tsv")
    static let filteredDir = hanjaContextWorkDir.appendingPathComponent("filtered")
    static let outDir = hanjaContextWorkDir.appendingPathComponent("k1")
    // K1b (§12 K1b) — coordinator-built measurement set, already on disk; K1b only reads it.
    static let measureDir = outDir.appendingPathComponent("measure")
}

func dataLines(of url: URL) throws -> [Substring] {
    let text = try String(contentsOf: url, encoding: .utf8)
    return text.split(separator: "\n", omittingEmptySubsequences: true)
        .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
    exit(1)
}

func ensureOutDir() throws {
    try FileManager.default.createDirectory(at: Paths.outDir, withIntermediateDirectories: true)
}

func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url)
}
