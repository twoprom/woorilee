// Loads and queries the bundled (reading, hanja) -> content-morpheme association table.
//     Copyright (C) 2026 Seungjin Lee.
//
// Step 5c (런타임 통합) — see docs/plans/context-aware-hanja-conversion.md §7. Step 0c (docs/plans/
// hanja-context-scaling-plan.md §5 "0c 포맷 명세") replaced the bundled artifact with a binary
// format (`woorilee/data/hanja/hanja-context.bin`, magic "HJC2" version 2) produced by
// scripts/hanja-context/build_association_table.py's `encode_binary` — the text file
// (`hanja-context.txt`, same directory) stays in the repo for tests/diff but is no longer bundled.
// `parse(contents:)` (text) is kept for that purpose; production `warmUp` loads the binary only.
import Foundation

@MainActor
final class HanjaContextAssociationStore {
    enum Status: Equatable {
        case uninitialized
        case loading
        case ready
        case unavailable(String)
    }

    static let shared = HanjaContextAssociationStore()

    private(set) var status: Status = .uninitialized
    /// Feature values are `Double` in the same numeric range as the text format's 1..255 UInt8
    /// grid (loader semantics, docs/plans/hanja-context-scaling-plan.md §5 "0c 포맷 명세" 로더 의미
    /// 보존 rule): the text parser converts its UInt8 weight exactly to Double; the binary loader
    /// converts `(qw × readingScaleNats) / globalScaleNats`, which lands in the same range but
    /// with finer (per-reading, not global) quantization precision.
    private var table: [String: [String: [String: Double]]] = [:]
    private var pendingWarmUpCompletions: [() -> Void] = []

    private init() {}

    var isAvailable: Bool {
        if case .ready = status {
            return true
        }

        return false
    }

    var isLoading: Bool {
        if case .loading = status {
            return true
        }

        return false
    }

    func warmUp(completion: (() -> Void)? = nil) {
        if let completion {
            pendingWarmUpCompletions.append(completion)
        }

        switch status {
        case .ready, .unavailable:
            drainPendingWarmUpCompletions()
            return
        case .loading:
            return
        case .uninitialized:
            break
        }

        status = .loading
        let bundle = Bundle.main

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let resourceURL = bundle.url(
                forResource: AppRuntimePaths.hanjaContextResourceName,
                withExtension: AppRuntimePaths.hanjaContextResourceExtension,
                subdirectory: AppRuntimePaths.hanjaResourceSubdirectory
            )

            let resolvedStatus: Status
            var loadedTable: [String: [String: [String: Double]]] = [:]

            if let resourceURL, let data = try? Data(contentsOf: resourceURL) {
                if let parsed = Self.parseBinary(data: data) {
                    loadedTable = parsed
                    resolvedStatus = .ready
                } else {
                    resolvedStatus = .unavailable(
                        "Bundled hanja context association binary at \(resourceURL.path) failed validation "
                            + "(bad magic/version/length/CRC) — falling back to an empty table"
                    )
                }
            } else if let resourceURL {
                resolvedStatus = .unavailable("Failed to load hanja context association table from \(resourceURL.path)")
            } else {
                resolvedStatus = .unavailable(
                    "Bundled hanja context association table was not found at "
                        + "\(AppRuntimePaths.hanjaResourceSubdirectory)/\(AppRuntimePaths.hanjaContextResourceName).\(AppRuntimePaths.hanjaContextResourceExtension)"
                )
            }

            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }

                    self.table = loadedTable
                    self.status = resolvedStatus
                    self.drainPendingWarmUpCompletions()
                }
            }
        }
    }

    /// Matched-feature weights for `(reading, hanja)`, or nil if the pair has no surviving features
    /// (either the reading wasn't ambiguous enough to be a step-5a target, or the store isn't ready).
    func features(reading: String, hanja: String) -> [String: Double]? {
        table[reading]?[hanja]
    }

    /// Parses `hanja-context.txt` contents: `읽기:한자:형태소=가중치,형태소=가중치,...` per line, `#`
    /// header/comment lines and malformed lines skipped. Percent-escaped feature text (`%25`→`%`,
    /// `%3A`→`:`, `%2C`→`,`, `%3D`→`=`) is decoded AFTER splitting on the raw `:`/`,`/`=` delimiters,
    /// with `%25` decoded LAST (see scripts/hanja-context/README.md 단계 5b). Weights are the
    /// integer 1..255 text grid, converted exactly to `Double` — kept for tests/diff against the
    /// bundled binary (`parseBinary`), not used by production `warmUp` since step 0c.
    nonisolated static func parse(contents: String) -> [String: [String: [String: Double]]] {
        var result: [String: [String: [String: Double]]] = [:]
        result.reserveCapacity(3_000)

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard !rawLine.hasPrefix("#") else { continue }

            guard let firstColon = rawLine.firstIndex(of: ":") else { continue }
            let reading = String(rawLine[rawLine.startIndex..<firstColon])
            guard !reading.isEmpty else { continue }

            let afterReading = rawLine[rawLine.index(after: firstColon)...]
            guard let secondColon = afterReading.firstIndex(of: ":") else { continue }
            let hanja = String(afterReading[afterReading.startIndex..<secondColon])
            guard !hanja.isEmpty else { continue }

            let featureList = afterReading[afterReading.index(after: secondColon)...]
            guard !featureList.isEmpty else { continue }

            var features: [String: Double] = [:]
            for entry in featureList.split(separator: ",", omittingEmptySubsequences: true) {
                guard let equalsIndex = entry.lastIndex(of: "="), entry.startIndex < equalsIndex else { continue }
                let featureRaw = entry[entry.startIndex..<equalsIndex]
                let weightRaw = entry[entry.index(after: equalsIndex)...]
                // Same range the text format's quantizer emits (1...255) — matches the old
                // UInt8(weightRaw) parse's effective range (0...255, only >0 features are ever
                // emitted) now that the stored value type is Double, not UInt8.
                guard let weight = Int(weightRaw), (0...255).contains(weight), !featureRaw.isEmpty else { continue }
                features[percentDecodeFeature(featureRaw)] = Double(weight)
            }

            guard !features.isEmpty else { continue }
            result[reading, default: [:]][hanja] = features
        }

        return result
    }

    nonisolated private static func percentDecodeFeature(_ raw: Substring) -> String {
        // Fast path: only 65 of the ~535,000 feature occurrences in the bundled table contain a
        // '%' at all (spot-checked against the real file) — skip the four allocation-heavy
        // replacingOccurrences passes entirely for the common case.
        guard raw.contains("%") else { return String(raw) }

        var decoded = String(raw)
        decoded = decoded.replacingOccurrences(of: "%3A", with: ":")
        decoded = decoded.replacingOccurrences(of: "%2C", with: ",")
        decoded = decoded.replacingOccurrences(of: "%3D", with: "=")
        decoded = decoded.replacingOccurrences(of: "%25", with: "%")
        return decoded
    }

    // MARK: - Step 0c binary format

    /// Parses a `hanja-context.bin` buffer (docs/plans/hanja-context-scaling-plan.md §5 "0c 포맷
    /// 명세"), or nil on ANY validation failure (short/truncated file, bad magic, bad version, CRC
    /// mismatch, out-of-range feature id, or trailing/undersized payload) — callers fall back to an
    /// empty table (fail open, the store's existing convention for a broken resource).
    ///
    /// Layout: 32-byte header (magic "HJC2", version 2, flags, payloadCRC32, four section counts,
    /// globalScaleNats), then payload = §1 feature string table + §2 reading index (readingCount ×
    /// {reading, readingScaleNats, candidateCount} — a SEPARATE contiguous block, no candidate data
    /// interleaved) + §3 candidate profiles (grouped by §2's reading order — consumed sequentially
    /// right after §2, not per-reading-then-its-candidates).
    ///
    /// Per-entry value: `(qw × readingScaleNats) / globalScaleNats` — the loader semantics pinned
    /// by the format spec, landing in the same numeric range as the text parser's Double(UInt8)
    /// values but with finer (per-reading) quantization precision.
    nonisolated static func parseBinary(data: Data) -> [String: [String: [String: Double]]]? {
        guard data.count >= HanjaContextBinaryFormat.headerSize else { return nil }

        var header = HanjaContextBinaryReader(data: data.prefix(HanjaContextBinaryFormat.headerSize))
        guard let magic = header.readBytes(4), magic.elementsEqual(HanjaContextBinaryFormat.magic) else { return nil }
        guard let version = header.readUInt16(), version == HanjaContextBinaryFormat.version else { return nil }
        guard header.readUInt16() != nil else { return nil } // flags, reserved
        guard let storedCRC = header.readUInt32() else { return nil }
        guard let featureStringCount = header.readUInt32() else { return nil }
        guard let readingCount = header.readUInt32() else { return nil }
        guard let candidateProfileCount = header.readUInt32() else { return nil }
        guard let featureEntryCount = header.readUInt32() else { return nil }
        guard let globalScaleNats = header.readFloat32(), globalScaleNats > 0 else { return nil }
        guard header.isAtEnd else { return nil }

        let payload = data.suffix(from: data.startIndex + HanjaContextBinaryFormat.headerSize)
        guard HanjaContextBinaryCRC32.checksum(payload) == storedCRC else { return nil }

        var reader = HanjaContextBinaryReader(data: payload)

        // §1 — feature string table (feature id = 0-based order of appearance).
        var features: [String] = []
        features.reserveCapacity(Int(featureStringCount))
        for _ in 0..<featureStringCount {
            guard let feature = reader.readLengthPrefixedString() else { return nil }
            features.append(feature)
        }

        // §2 — reading index: fully separate block, every reading's {name, scale, candidateCount}
        // before any candidate profile data.
        var readingIndex: [(reading: String, scaleNats: Float32, candidateCount: UInt16)] = []
        readingIndex.reserveCapacity(Int(readingCount))
        for _ in 0..<readingCount {
            guard let reading = reader.readLengthPrefixedString(),
                  let scaleNats = reader.readFloat32(), scaleNats > 0,
                  let candidateCount = reader.readUInt16()
            else { return nil }
            readingIndex.append((reading, scaleNats, candidateCount))
        }

        // §3 — candidate profiles, consumed sequentially in §2's order.
        var result: [String: [String: [String: Double]]] = [:]
        result.reserveCapacity(Int(readingCount))
        var candidateProfilesSeen: UInt32 = 0
        var featureEntriesSeen: UInt32 = 0

        for (reading, scaleNats, candidateCount) in readingIndex {
            var candidateMap: [String: [String: Double]] = [:]
            candidateMap.reserveCapacity(Int(candidateCount))

            for _ in 0..<candidateCount {
                guard let hanja = reader.readLengthPrefixedString(),
                      reader.readFloat32() != nil, // bias — D3 slot, unused in 0c
                      let entryCount = reader.readUInt32()
                else { return nil }

                var featureIDs: [UInt32] = []
                featureIDs.reserveCapacity(Int(entryCount))
                for _ in 0..<entryCount {
                    guard let featureID = reader.readUInt32() else { return nil }
                    featureIDs.append(featureID)
                }

                var featureMap: [String: Double] = [:]
                featureMap.reserveCapacity(Int(entryCount))
                for featureID in featureIDs {
                    guard let weight = reader.readInt8() else { return nil }
                    guard featureID < UInt32(features.count) else { return nil }
                    let value = (Double(weight) * Double(scaleNats)) / Double(globalScaleNats)
                    featureMap[features[Int(featureID)]] = value
                }

                candidateMap[hanja] = featureMap
                candidateProfilesSeen += 1
                featureEntriesSeen += UInt32(entryCount)
            }

            result[reading] = candidateMap
        }

        guard reader.isAtEnd else { return nil }
        guard candidateProfilesSeen == candidateProfileCount else { return nil }
        guard featureEntriesSeen == featureEntryCount else { return nil }

        return result
    }

    private func drainPendingWarmUpCompletions() {
        guard !pendingWarmUpCompletions.isEmpty else {
            return
        }

        let completions = pendingWarmUpCompletions
        pendingWarmUpCompletions.removeAll()
        for completion in completions {
            completion()
        }
    }
}

// MARK: - Binary format primitives

private enum HanjaContextBinaryFormat {
    static let magic: [UInt8] = Array("HJC2".utf8)
    static let version: UInt16 = 2
    static let headerSize = 32
}

/// Bounds-checked little-endian cursor over a `Data` buffer — every read returns nil (rather than
/// trapping) past the end, so a truncated/corrupt file fails the whole parse instead of crashing.
private struct HanjaContextBinaryReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(data: Data) {
        bytes = [UInt8](data)
    }

    var isAtEnd: Bool { offset == bytes.count }

    mutating func readBytes(_ count: Int) -> [UInt8]? {
        guard count >= 0, offset + count <= bytes.count else { return nil }
        let slice = Array(bytes[offset..<offset + count])
        offset += count
        return slice
    }

    mutating func readUInt8() -> UInt8? {
        readBytes(1)?[0]
    }

    mutating func readInt8() -> Int8? {
        readUInt8().map { Int8(bitPattern: $0) }
    }

    mutating func readUInt16() -> UInt16? {
        guard let b = readBytes(2) else { return nil }
        return UInt16(b[0]) | (UInt16(b[1]) << 8)
    }

    mutating func readUInt32() -> UInt32? {
        guard let b = readBytes(4) else { return nil }
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }

    mutating func readFloat32() -> Float32? {
        readUInt32().map { Float32(bitPattern: $0) }
    }

    mutating func readLengthPrefixedString() -> String? {
        guard let length = readUInt16(), let bytes = readBytes(Int(length)) else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }
}

/// Standard CRC-32 (IEEE 802.3 / zlib.crc32-compatible), reimplemented here rather than linking
/// libz — this is the same well-known table-based algorithm, verified byte-for-byte against
/// Python's `zlib.crc32` (the offline writer's checksum) during development.
private enum HanjaContextBinaryCRC32 {
    private static let table: [UInt32] = (0...255).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1 != 0) ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func checksum<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
