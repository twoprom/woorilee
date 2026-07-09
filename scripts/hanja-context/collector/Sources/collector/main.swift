// Step 5a offline Kiwi collector (문맥 기반 한자 변환 — docs/plans/context-aware-hanja-conversion.md §7 5a).
//     Copyright (C) 2026 Seungjin Lee.
//
// Turns the prefiltered wiki corpus (filtered/part-NNNN.txt, `kind<TAB>sentence`) into raw
// (signal, reading, hanja, morpheme-feature) counts, using the LOCAL vendored Kiwi Swift package
// so the offline morpheme space matches the woorilee runtime exactly (never kiwipiepy).
//
// Modes:
//   collect [--parts 0-14|0,3,5] [--workers N] [--limit-lines N]
//       Analyze filtered corpus parts, write per-part sorted TSVs
//       counts/part-NNNN.{paren,anchor}.tsv (`reading\thanja\tfeature\tcount`, LC_ALL=C order)
//       plus counts/part-NNNN.stats.json. Resumable: parts with all three outputs are skipped
//       (unless --limit-lines is set, which writes to *.smoke.* files instead).
//   merge
//       K-way streaming merge of all part TSVs into counts/paren-counts.tsv and
//       counts/anchor-counts.tsv (summing counts for equal keys). No global in-memory table.
//   dump-tokens
//       Analyze the 195 eval sentences and write
//       scripts/hanja-context/verification-tokens.tsv (`sentence<TAB>form/TAG,...`, content tags
//       only, raw filtered token sequence — no dedupe/cap) for the 형태소 공간 일치 검증.
//   collect-defs
//       Analyze NIKL definition rows (work/hanja-context/nikl/definitions.tsv,
//       `reading<TAB>hanja<TAB>source<TAB>definition`) into counts/dict-counts.tsv
//       (same `reading\thanja\tfeature\tcount` format; features deduped, cap 30, no span
//       exclusion — the (reading,hanja) label comes from the row itself).
//
// Morpheme-space contract (MUST match woorilee/KiwiAnalysisService.swift
// `realtimeAnalysisMatchOptions` / `isContextContentMorphemeTag` and
// scripts/hanja-context/README.md "형태소 공간 계약"; pinned by
// woorileeTests/KiwiOfflinePipelineConsistencyTests.swift):
//   - options [.allWithNormalizing, .joinNounPrefix, .joinNounSuffix], topN=1 (first result)
//   - content tags NNG, NNP, VV, VV-I, VA, VA-I, MAG, XR; feature key "form/TAG"
//     (TAG = POSTag.description, so irregulars serialize as VV-I / VA-I)
//
// Counting-unit note: each corpus line is already a rough-split sentence, so the whole line is
// treated as ONE counting unit; Token.sentencePosition is ignored. Anchor n-gram joins require
// UTF-16 contiguity (no gap between consecutive tokens) so a join never spans a space.

import Foundation
import Kiwi

// MARK: - Contract

enum Contract {
    static let matchOptions: MatchOptions = [.allWithNormalizing, .joinNounPrefix, .joinNounSuffix]
    static let contentTags: Set<POSTag> = [.nng, .nnp, .vv, .vvi, .va, .vai, .mag, .xr]
    static let topN = 1
    static let maxFeaturesPerLine = 30
    static let maxAnchorNGram = 5

    static func feature(form: String, tag: POSTag) -> String {
        form + "/" + tag.description
    }

    static var describeOptions: String {
        "[.allWithNormalizing, .joinNounPrefix, .joinNounSuffix] (raw=\(matchOptions.rawValue))"
    }

    static let describeTags = "NNG,NNP,VV,VV-I,VA,VA-I,MAG,XR"
}

// MARK: - Paths

enum Paths {
    // #filePath = .../woorilee/scripts/hanja-context/collector/Sources/collector/main.swift
    static let woorileeRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Sources/collector
        .deletingLastPathComponent() // Sources
        .deletingLastPathComponent() // collector
        .deletingLastPathComponent() // hanja-context
        .deletingLastPathComponent() // scripts
        .deletingLastPathComponent() // woorilee root

    static let workDir = woorileeRoot
        .deletingLastPathComponent()
        .appendingPathComponent("wooriHanjaModel/work/hanja-context")

    static let filteredDir = workDir.appendingPathComponent("filtered")
    static let inventoryDir = workDir.appendingPathComponent("inventory")
    static let countsDir = workDir.appendingPathComponent("counts")
    static let niklDefsTSV = workDir.appendingPathComponent("nikl/definitions.tsv")

    static let modelDir = woorileeRoot.appendingPathComponent("woorilee/KiwiModels")
    static let hanjaTxt = woorileeRoot.appendingPathComponent("woorilee/data/hanja/hanja.txt")
    static let evalTSV = woorileeRoot.appendingPathComponent("eval/hanja-context-eval-set.tsv")
    static let verificationTokensTSV = woorileeRoot
        .appendingPathComponent("scripts/hanja-context/verification-tokens.tsv")

    static func partURL(_ part: Int) -> URL {
        filteredDir.appendingPathComponent(String(format: "part-%04d.txt", part))
    }

    static func countsURL(part: Int, signal: String, smoke: Bool) -> URL {
        countsDir.appendingPathComponent(
            String(format: "part-%04d.%@%@.tsv", part, signal, smoke ? ".smoke" : ""))
    }

    static func statsURL(part: Int, smoke: Bool) -> URL {
        countsDir.appendingPathComponent(
            String(format: "part-%04d.stats%@.json", part, smoke ? ".smoke" : ""))
    }
}

// MARK: - Small utilities

func cOrderLess(_ a: String, _ b: String) -> Bool {
    a.utf8.lexicographicallyPrecedes(b.utf8)
}

final class LineWriter {
    private let handle: FileHandle
    private var buffer = Data()

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func write(_ line: String) {
        buffer.append(Data(line.utf8))
        buffer.append(0x0A)
        if buffer.count > 1 << 20 { flush() }
    }

    func flush() {
        if !buffer.isEmpty {
            handle.write(buffer)
            buffer.removeAll(keepingCapacity: true)
        }
    }

    func close() {
        flush()
        try? handle.close()
    }
}

final class Logger {
    private let handle: FileHandle?
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()

    init(url: URL?) {
        if let url {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        } else {
            handle = nil
        }
    }

    func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        let data = Data(line.utf8)
        handle?.write(data)
        FileHandle.standardOutput.write(data)
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
    exit(1)
}

func writeSortedCounts(_ counts: [String: Int], to url: URL) throws {
    let keys = counts.keys.sorted(by: cOrderLess)
    let writer = try LineWriter(url: url)
    for key in keys {
        writer.write(key + "\t" + String(counts[key]!))
    }
    writer.close()
}

func dataLines(of url: URL) throws -> [Substring] {
    let text = try String(contentsOf: url, encoding: .utf8)
    return text.split(separator: "\n", omittingEmptySubsequences: true)
        .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
}

// MARK: - Inventory

struct Inventory {
    let targetReadings: Set<String>
    let hanjaDict: [String: Set<String>] // reading -> hanja set (hanja.txt, 병기 validation)
    let anchorMap: [String: [(target: String, candidate: String)]] // anchor_reading -> pairs
    let maxAnchorReadingLength: Int

    static func load() throws -> Inventory {
        var targetReadings = Set<String>()
        for line in try dataLines(of: Paths.inventoryDir.appendingPathComponent("targets.tsv")) {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 3 else { continue }
            targetReadings.insert(String(cols[0]))
        }
        guard !targetReadings.isEmpty else { fail("targets.tsv produced no readings") }

        var anchorMap: [String: [(String, String)]] = [:]
        var maxLen = 0
        var seenRows = Set<String>()
        for line in try dataLines(of: Paths.inventoryDir.appendingPathComponent("anchors.tsv")) {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 5 else { continue }
            let target = String(cols[0])
            let candidate = String(cols[1])
            let anchorReading = String(cols[2])
            let rowKey = anchorReading + "\t" + target + "\t" + candidate
            guard seenRows.insert(rowKey).inserted else { continue }
            anchorMap[anchorReading, default: []].append((target, candidate))
            maxLen = max(maxLen, anchorReading.count)
        }
        guard !anchorMap.isEmpty else { fail("anchors.tsv produced no anchors") }

        var hanjaDict: [String: Set<String>] = [:]
        for rawLine in try dataLines(of: Paths.hanjaTxt) {
            // reading:hanja:comment — first colon, second colon, ignore the rest
            // (mirrors buildDominantHanjaMap's parse in woorilee/HanjaContextRanker.swift).
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let c1 = line.firstIndex(of: ":") else { continue }
            let reading = String(line[..<c1])
            let rest = line[line.index(after: c1)...]
            guard let c2 = rest.firstIndex(of: ":") else { continue }
            let hanja = String(rest[..<c2])
            guard !reading.isEmpty, !hanja.isEmpty else { continue }
            hanjaDict[reading, default: []].insert(hanja)
        }
        guard !hanjaDict.isEmpty else { fail("hanja.txt produced no entries") }

        return Inventory(
            targetReadings: targetReadings,
            hanjaDict: hanjaDict,
            anchorMap: anchorMap,
            maxAnchorReadingLength: maxLen
        )
    }
}

struct EvalRow {
    let sentence: String
    let reading: String
    let answer: String
}

func loadEvalRows() throws -> [EvalRow] {
    var rows: [EvalRow] = []
    for line in try dataLines(of: Paths.evalTSV) {
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard cols.count >= 3, !cols[0].isEmpty, !cols[1].isEmpty, !cols[2].isEmpty else { continue }
        rows.append(EvalRow(sentence: cols[0], reading: cols[1], answer: cols[2]))
    }
    return rows
}

// MARK: - Kiwi

func buildKiwi(numThreads: Int) throws -> Kiwi {
    // KiwiBuilder defaults (BuildOptions.default, Dialect.standard) match the runtime's
    // KiwiBuilder(bundle:modelDirectory:) path in woorilee/KiwiAnalysisService.swift.
    try KiwiBuilder(modelPath: Paths.modelDir.path, numThreads: numThreads).build()
}

func contentFeatureLine(tokens: [Token]) -> (order: [String], tokenIndices: [String: [Int]]) {
    // First `maxFeaturesPerLine` DISTINCT content features in token order; later instances of an
    // already-admitted feature still record their token index (needed for span exclusion).
    var order: [String] = []
    var indices: [String: [Int]] = [:]
    for (index, token) in tokens.enumerated() where Contract.contentTags.contains(token.tag) {
        let feature = Contract.feature(form: token.form, tag: token.tag)
        if indices[feature] != nil {
            indices[feature]!.append(index)
        } else if order.count < Contract.maxFeaturesPerLine {
            order.append(feature)
            indices[feature] = [index]
        }
    }
    return (order, indices)
}

// MARK: - collect

struct PartStats: Codable {
    var part: Int
    var lines = 0
    var anchorHitLines = 0
    var parenValidatedLines = 0
    var anchorPairLines: [String: Int] = [:] // "reading\thanja" -> lines with a token-level anchor hit
    var parenPairLines: [String: Int] = [:] // "reading\thanja" -> lines with a validated 병기
    var elapsedSec: Double = 0
}

final class Progress {
    private let lock = NSLock()
    private var count = 0
    private let total: Int
    private let start = Date()

    init(total: Int) {
        self.total = total
    }

    func tick(logger: Logger) {
        lock.lock()
        count += 1
        let c = count
        lock.unlock()
        guard c == 10_000 || c % 100_000 == 0 else { return }
        let elapsed = Date().timeIntervalSince(start)
        let rate = Double(c) / max(elapsed, 0.001)
        let etaMinutes = total > c ? Double(total - c) / rate / 60 : 0
        logger.log(String(
            format: "progress lines=%d/%d rate=%.0f lines/s eta=%.1f min", c, total, rate, etaMinutes))
    }
}

final class SentenceProcessor {
    let inventory: Inventory
    let parenRegex: NSRegularExpression

    init(inventory: Inventory) {
        self.inventory = inventory
        // 한글run(한자run) — BMP CJK ranges only, so Character count == UTF-16 count.
        parenRegex = try! NSRegularExpression(pattern: "([가-힣]+)\\(([一-鿿㐀-䶿]+)\\)")
    }

    struct LineSignals {
        var parenTuples = Set<String>() // "reading\thanja\tfeature"
        var anchorTuples = Set<String>()
        var parenPairs = Set<String>() // "reading\thanja"
        var anchorPairs = Set<String>()
    }

    func process(sentence: String, kiwi: Kiwi) -> LineSignals {
        var signals = LineSignals()
        let tokens = (try? kiwi.analyze(sentence, topN: Contract.topN, options: Contract.matchOptions))?
            .first?.tokens ?? []
        let (featureOrder, featureTokens) = contentFeatureLine(tokens: tokens)

        // --- anchor signal: token n-grams (1...5, UTF-16 contiguous) matching anchor readings ---
        var anchorSpans: [String: [(Int, Int)]] = [:]
        var i = 0
        while i < tokens.count {
            var joined = ""
            var expectedPosition = tokens[i].position
            var j = i
            while j < tokens.count, j < i + Contract.maxAnchorNGram {
                guard tokens[j].position == expectedPosition else { break } // no gap (space) inside a join
                joined += tokens[j].form
                expectedPosition = tokens[j].position + tokens[j].length
                if joined.count > inventory.maxAnchorReadingLength { break }
                if inventory.anchorMap[joined] != nil {
                    anchorSpans[joined, default: []].append((i, j))
                }
                j += 1
            }
            i += 1
        }

        for (anchorReading, spans) in anchorSpans {
            guard let pairs = inventory.anchorMap[anchorReading] else { continue }
            var excluded = Set<Int>()
            for (start, end) in spans {
                for k in start...end { excluded.insert(k) }
            }
            // A feature survives if at least one of its token instances lies outside the matched span(s).
            let features = featureOrder.filter { feature in
                featureTokens[feature]!.contains { !excluded.contains($0) }
            }
            for (target, candidate) in pairs {
                let pairKey = target + "\t" + candidate
                signals.anchorPairs.insert(pairKey)
                for feature in features {
                    signals.anchorTuples.insert(pairKey + "\t" + feature)
                }
            }
        }

        // --- 병기 signal: 한글run(漢字run), suffix-validated against hanja.txt + target readings ---
        let ns = sentence as NSString
        let matches = parenRegex.matches(in: sentence, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            let hangulRange = match.range(at: 1)
            let hanja = ns.substring(with: match.range(at: 2))
            let hanjaLength = (hanja as NSString).length // BMP-only, == Character count
            guard hangulRange.length >= hanjaLength else { continue }
            let hangulRun = ns.substring(with: hangulRange) as NSString
            let suffix = hangulRun.substring(from: hangulRange.length - hanjaLength)
            guard inventory.targetReadings.contains(suffix),
                  inventory.hanjaDict[suffix]?.contains(hanja) == true
            else { continue }
            let pairKey = suffix + "\t" + hanja
            signals.parenPairs.insert(pairKey)
            for feature in featureOrder {
                let hasInstanceOutsideRun = featureTokens[feature]!.contains { index in
                    let token = tokens[index]
                    let overlaps = token.position < hangulRange.location + hangulRange.length
                        && hangulRange.location < token.position + token.length
                    return !overlaps
                }
                if hasInstanceOutsideRun {
                    signals.parenTuples.insert(pairKey + "\t" + feature)
                }
            }
        }

        return signals
    }

    func processPart(
        _ part: Int, kiwi: Kiwi, logger: Logger, progress: Progress, limitLines: Int?
    ) throws -> PartStats {
        let smoke = limitLines != nil
        let text = try String(contentsOf: Paths.partURL(part), encoding: .utf8)
        var stats = PartStats(part: part)
        var parenCounts: [String: Int] = [:]
        var anchorCounts: [String: Int] = [:]
        let start = Date()

        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let limit = limitLines, stats.lines >= limit { break }
            // Strip the `kind<TAB>` prefix; the kind column is otherwise ignored (both signal
            // extractions run on every line — re-scanning is required anyway for exact spans).
            let sentence: String
            if let tab = raw.firstIndex(of: "\t") {
                sentence = String(raw[raw.index(after: tab)...])
            } else {
                sentence = String(raw)
            }

            let signals = process(sentence: sentence, kiwi: kiwi)
            stats.lines += 1
            if !signals.anchorPairs.isEmpty { stats.anchorHitLines += 1 }
            if !signals.parenPairs.isEmpty { stats.parenValidatedLines += 1 }
            for pair in signals.anchorPairs { stats.anchorPairLines[pair, default: 0] += 1 }
            for pair in signals.parenPairs { stats.parenPairLines[pair, default: 0] += 1 }
            for tuple in signals.anchorTuples { anchorCounts[tuple, default: 0] += 1 }
            for tuple in signals.parenTuples { parenCounts[tuple, default: 0] += 1 }
            progress.tick(logger: logger)
        }

        stats.elapsedSec = Date().timeIntervalSince(start)
        try writeSortedCounts(parenCounts, to: Paths.countsURL(part: part, signal: "paren", smoke: smoke))
        try writeSortedCounts(anchorCounts, to: Paths.countsURL(part: part, signal: "anchor", smoke: smoke))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(stats).write(to: Paths.statsURL(part: part, smoke: smoke))
        return stats
    }
}

func countLines(_ url: URL) throws -> Int {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    var n = 0
    data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
        for byte in buffer where byte == 0x0A { n += 1 }
    }
    if let last = data.last, last != 0x0A { n += 1 }
    return n
}

func runCollect(parts requestedParts: [Int], workers requestedWorkers: Int, limitLines: Int?) throws {
    try FileManager.default.createDirectory(at: Paths.countsDir, withIntermediateDirectories: true)
    let logger = Logger(url: Paths.countsDir.appendingPathComponent("collect.log"))
    let smoke = limitLines != nil

    var parts: [Int] = []
    for part in requestedParts {
        guard FileManager.default.fileExists(atPath: Paths.partURL(part).path) else {
            fail("missing part file: \(Paths.partURL(part).path)")
        }
        if !smoke,
           FileManager.default.fileExists(atPath: Paths.countsURL(part: part, signal: "paren", smoke: false).path),
           FileManager.default.fileExists(atPath: Paths.countsURL(part: part, signal: "anchor", smoke: false).path),
           FileManager.default.fileExists(atPath: Paths.statsURL(part: part, smoke: false).path) {
            logger.log("part \(part) already collected — skipping (delete counts/part-\(String(format: "%04d", part)).* to redo)")
            continue
        }
        parts.append(part)
    }
    guard !parts.isEmpty else {
        logger.log("nothing to do — all requested parts already collected")
        return
    }

    let inventory = try Inventory.load()
    let processor = SentenceProcessor(inventory: inventory)
    let workers = max(1, min(requestedWorkers, parts.count))

    var totalLines = 0
    for part in parts {
        let n = try countLines(Paths.partURL(part))
        totalLines += limitLines.map { min($0, n) } ?? n
    }

    logger.log("START collect parts=\(parts.map(String.init).joined(separator: ",")) workers=\(workers)"
        + (limitLines.map { " limitLines=\($0)" } ?? "")
        + " totalLines=\(totalLines) kiwi=\(Kiwi.version) options=\(Contract.describeOptions)"
        + " tags=\(Contract.describeTags) model=\(Paths.modelDir.path)")

    let progress = Progress(total: totalLines)
    let queueLock = NSLock()
    var remaining = parts
    let resultLock = NSLock()
    var allStats: [PartStats] = []
    var workerError: Error?
    let buildLock = NSLock()
    let group = DispatchGroup()
    let wallStart = Date()

    for workerIndex in 0..<workers {
        group.enter()
        Thread.detachNewThread {
            defer { group.leave() }
            do {
                buildLock.lock()
                let kiwiResult = Result { try buildKiwi(numThreads: workers > 1 ? 1 : -1) }
                buildLock.unlock()
                let kiwi = try kiwiResult.get()
                while true {
                    queueLock.lock()
                    guard let part = remaining.first else {
                        queueLock.unlock()
                        break
                    }
                    remaining.removeFirst()
                    queueLock.unlock()
                    logger.log("worker \(workerIndex) part \(part) start")
                    let stats = try processor.processPart(
                        part, kiwi: kiwi, logger: logger, progress: progress, limitLines: limitLines)
                    logger.log("worker \(workerIndex) part \(part) done lines=\(stats.lines)"
                        + " anchorHitLines=\(stats.anchorHitLines) parenLines=\(stats.parenValidatedLines)"
                        + String(format: " elapsed=%.0fs", stats.elapsedSec))
                    resultLock.lock()
                    allStats.append(stats)
                    resultLock.unlock()
                }
            } catch {
                resultLock.lock()
                workerError = error
                resultLock.unlock()
                logger.log("worker \(workerIndex) ERROR: \(error)")
            }
        }
    }
    group.wait()

    if let workerError {
        fail("collect failed: \(workerError)")
    }

    let lines = allStats.reduce(0) { $0 + $1.lines }
    let anchorHit = allStats.reduce(0) { $0 + $1.anchorHitLines }
    let paren = allStats.reduce(0) { $0 + $1.parenValidatedLines }
    let wall = Date().timeIntervalSince(wallStart)
    logger.log(String(
        format: "FINISHED collect parts=%d lines=%d anchorHitLines=%d parenLines=%d wall=%.0fs rate=%.0f lines/s",
        allStats.count, lines, anchorHit, paren, wall, Double(lines) / max(wall, 0.001)))
}

// MARK: - merge

/// K-way streaming merge of LC_ALL=C-sorted `key\tcount` TSVs, summing counts for equal keys.
final class TSVMergeReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var exhausted = false
    var currentKey: String?
    var currentCount = 0

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        advance()
    }

    private func nextLine() -> String? {
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                return String(data: lineData, encoding: .utf8)
            }
            if exhausted {
                guard !buffer.isEmpty else { return nil }
                let lineData = buffer
                buffer = Data()
                return String(data: lineData, encoding: .utf8)
            }
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty {
                exhausted = true
            } else {
                buffer.append(chunk)
            }
        }
    }

    func advance() {
        while let line = nextLine() {
            guard let tab = line.lastIndex(of: "\t"), let count = Int(line[line.index(after: tab)...]) else {
                continue
            }
            currentKey = String(line[..<tab])
            currentCount = count
            return
        }
        currentKey = nil
        currentCount = 0
    }
}

func mergeSignal(_ signal: String, partURLs: [URL], output: URL) throws -> (tuples: Int, total: Int) {
    var readers: [TSVMergeReader] = []
    for url in partURLs {
        readers.append(try TSVMergeReader(url: url))
    }
    let writer = try LineWriter(url: output)
    var distinctTuples = 0
    var totalCount = 0

    while true {
        var minKey: String?
        for reader in readers {
            guard let key = reader.currentKey else { continue }
            if minKey == nil || cOrderLess(key, minKey!) { minKey = key }
        }
        guard let key = minKey else { break }
        var sum = 0
        for reader in readers where reader.currentKey == key {
            sum += reader.currentCount
            reader.advance()
        }
        writer.write(key + "\t" + String(sum))
        distinctTuples += 1
        totalCount += sum
    }
    writer.close()
    return (distinctTuples, totalCount)
}

func runMerge() throws {
    let logger = Logger(url: Paths.countsDir.appendingPathComponent("collect.log"))
    for signal in ["paren", "anchor"] {
        let fileManager = FileManager.default
        let all = try fileManager.contentsOfDirectory(at: Paths.countsDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".\(signal).tsv") && $0.lastPathComponent.hasPrefix("part-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !all.isEmpty else { fail("no part-*.\(signal).tsv files to merge") }
        let output = Paths.countsDir.appendingPathComponent("\(signal)-counts.tsv")
        let (tuples, total) = try mergeSignal(signal, partURLs: all, output: output)
        logger.log("MERGE \(signal): \(all.count) part files -> \(output.lastPathComponent) distinctTuples=\(tuples) totalCount=\(total)")
    }
}

// MARK: - dump-tokens

func runDumpTokens() throws {
    let rows = try loadEvalRows()
    guard !rows.isEmpty else { fail("eval TSV has no rows") }
    let kiwi = try buildKiwi(numThreads: -1)

    var out = ""
    out += "# verification-tokens.tsv — 단계 5a 형태소 공간 일치 검증 덤프 (offline collector `dump-tokens` output)\n"
    out += "# source: eval/hanja-context-eval-set.tsv (\(rows.count) rows, file order)\n"
    out += "# kiwi: vendored Kiwi/bindings/swift (engine \(Kiwi.version)), model: woorilee/KiwiModels\n"
    out += "# analyze: topN=1 options=\(Contract.describeOptions)\n"
    out += "# content tags: \(Contract.describeTags); feature key form/TAG (TAG = POSTag.description);\n"
    out += "#   raw filtered token sequence — no dedupe, no cap. Pinned by\n"
    out += "#   woorileeTests/KiwiOfflinePipelineConsistencyTests.swift against the runtime constants\n"
    out += "#   in woorilee/KiwiAnalysisService.swift (realtimeAnalysisMatchOptions / isContextContentMorphemeTag).\n"
    out += "# format: sentence<TAB>form/TAG,form/TAG,...\n"
    for row in rows {
        let tokens = try kiwi.analyze(row.sentence, topN: Contract.topN, options: Contract.matchOptions)
            .first?.tokens ?? []
        let features = tokens
            .filter { Contract.contentTags.contains($0.tag) }
            .map { Contract.feature(form: $0.form, tag: $0.tag) }
        out += row.sentence + "\t" + features.joined(separator: ",") + "\n"
    }
    try out.write(to: Paths.verificationTokensTSV, atomically: true, encoding: .utf8)
    print("dump-tokens: wrote \(rows.count) rows to \(Paths.verificationTokensTSV.path)")
}

// MARK: - collect-defs

func runCollectDefs() throws {
    guard FileManager.default.fileExists(atPath: Paths.niklDefsTSV.path) else {
        fail("collect-defs input not found: \(Paths.niklDefsTSV.path)")
    }
    try FileManager.default.createDirectory(at: Paths.countsDir, withIntermediateDirectories: true)
    let logger = Logger(url: Paths.countsDir.appendingPathComponent("collect.log"))
    let kiwi = try buildKiwi(numThreads: -1)
    let start = Date()

    var counts: [String: Int] = [:]
    var rowsProcessed = 0
    var rowsMalformed = 0
    var pairRows: [String: Int] = [:] // "reading\thanja" -> definition rows contributing

    logger.log("START collect-defs input=\(Paths.niklDefsTSV.path) kiwi=\(Kiwi.version)"
        + " options=\(Contract.describeOptions) tags=\(Contract.describeTags)")

    for line in try dataLines(of: Paths.niklDefsTSV) {
        let cols = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
        guard cols.count >= 4 else {
            rowsMalformed += 1
            continue
        }
        let reading = String(cols[0])
        let hanja = String(cols[1])
        let definition = String(cols[3])
        guard !reading.isEmpty, !hanja.isEmpty, !definition.isEmpty else {
            rowsMalformed += 1
            continue
        }

        let tokens = (try? kiwi.analyze(definition, topN: Contract.topN, options: Contract.matchOptions))?
            .first?.tokens ?? []
        let (featureOrder, _) = contentFeatureLine(tokens: tokens)
        // The (reading, hanja) label comes from the row itself — no span exclusion needed.
        let pairKey = reading + "\t" + hanja
        for feature in featureOrder {
            counts[pairKey + "\t" + feature, default: 0] += 1
        }
        if !featureOrder.isEmpty {
            pairRows[pairKey, default: 0] += 1
        }
        rowsProcessed += 1
        if rowsProcessed % 100_000 == 0 {
            let elapsed = Date().timeIntervalSince(start)
            logger.log(String(format: "collect-defs progress rows=%d rate=%.0f rows/s", rowsProcessed,
                              Double(rowsProcessed) / max(elapsed, 0.001)))
        }
    }

    try writeSortedCounts(counts, to: Paths.countsDir.appendingPathComponent("dict-counts.tsv"))

    struct DefsStats: Codable {
        var rowsProcessed: Int
        var rowsMalformed: Int
        var distinctPairs: Int
        var distinctTuples: Int
        var pairRows: [String: Int]
        var elapsedSec: Double
    }
    let stats = DefsStats(
        rowsProcessed: rowsProcessed,
        rowsMalformed: rowsMalformed,
        distinctPairs: pairRows.count,
        distinctTuples: counts.count,
        pairRows: pairRows,
        elapsedSec: Date().timeIntervalSince(start)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(stats).write(to: Paths.countsDir.appendingPathComponent("collect-defs-stats.json"))
    logger.log(String(
        format: "FINISHED collect-defs rows=%d malformed=%d pairs=%d tuples=%d elapsed=%.0fs",
        rowsProcessed, rowsMalformed, pairRows.count, counts.count, stats.elapsedSec))
}

// MARK: - CLI

func parseParts(_ spec: String) -> [Int] {
    var parts: Set<Int> = []
    for piece in spec.split(separator: ",") {
        if let dash = piece.firstIndex(of: "-"),
           let lo = Int(piece[..<dash]), let hi = Int(piece[piece.index(after: dash)...]), lo <= hi {
            parts.formUnion(lo...hi)
        } else if let value = Int(piece) {
            parts.insert(value)
        } else {
            fail("bad --parts spec: \(spec)")
        }
    }
    return parts.sorted()
}

func discoverParts() -> [Int] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: Paths.filteredDir.path)) ?? []
    var parts: [Int] = []
    for name in names where name.hasPrefix("part-") && name.hasSuffix(".txt") {
        if let number = Int(name.dropFirst(5).dropLast(4)) {
            parts.append(number)
        }
    }
    return parts.sorted()
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let mode = arguments.first else {
    fail("usage: collector <collect|merge|dump-tokens|collect-defs> [--parts 0-14] [--workers N] [--limit-lines N]")
}

var parts = discoverParts()
var workers = 1
var limitLines: Int?
var index = 1
while index < arguments.count {
    switch arguments[index] {
    case "--parts":
        index += 1
        guard index < arguments.count else { fail("--parts needs a value") }
        parts = parseParts(arguments[index])
    case "--workers":
        index += 1
        guard index < arguments.count, let n = Int(arguments[index]), n >= 1 else { fail("--workers needs a positive integer") }
        workers = n
    case "--limit-lines":
        index += 1
        guard index < arguments.count, let n = Int(arguments[index]), n >= 1 else { fail("--limit-lines needs a positive integer") }
        limitLines = n
    default:
        fail("unknown argument: \(arguments[index])")
    }
    index += 1
}

switch mode {
case "collect":
    try runCollect(parts: parts, workers: workers, limitLines: limitLines)
case "merge":
    try runMerge()
case "dump-tokens":
    try runDumpTokens()
case "collect-defs":
    try runCollectDefs()
default:
    fail("unknown mode: \(mode)")
}
