// Shared Codable types for Hanja candidate key and source.
//     Copyright (C) 2026 Seungjin Lee.

import Foundation

enum HanjaPersonalizationStorage {
    static let currentVersion = 1
}

struct HanjaCandidateKey: Codable, Equatable, Hashable {
    let reading: String
    let value: String
}

enum HanjaCandidateSource: String, Codable {
    case system
    case userDefined
}

struct UserHanjaEntry: Codable, Equatable, Identifiable {
    let id: UUID
    var reading: String
    var value: String
    var comment: String
    var createdAt: Date
    var updatedAt: Date

    var candidateKey: HanjaCandidateKey {
        HanjaCandidateKey(reading: reading, value: value)
    }
}

struct HanjaUsageRecord: Codable, Equatable {
    let lookupKey: String
    let value: String
    var count: Int
    var lastSelectedAt: Date

    var candidateKey: HanjaCandidateKey {
        HanjaCandidateKey(reading: lookupKey, value: value)
    }
}

struct HanjaCandidateSeed: Equatable {
    let reading: String
    let value: String
    let comment: String
    let source: HanjaCandidateSource
    let baseRank: Int

    var candidateKey: HanjaCandidateKey {
        HanjaCandidateKey(reading: reading, value: value)
    }
}

struct HanjaCandidate: Equatable {
    let reading: String
    let value: String
    let comment: String
    let source: HanjaCandidateSource
    let usageCount: Int
    let frequency: Int
    let baseRank: Int

    var candidateKey: HanjaCandidateKey {
        HanjaCandidateKey(reading: reading, value: value)
    }
}

struct VersionedEntriesEnvelope<Entry: Codable>: Codable {
    let version: Int
    let entries: [Entry]
}

func mergeHanjaCandidates(
    userEntries: [UserHanjaEntry],
    systemCandidates: [HanjaCandidateSeed],
    usageCounts: [HanjaCandidateKey: Int],
    frequencyLookup: (String) -> Int
) -> [HanjaCandidate] {
    var merged: [HanjaCandidateKey: HanjaCandidate] = [:]

    for candidate in systemCandidates {
        let key = candidate.candidateKey
        merged[key] = HanjaCandidate(
            reading: candidate.reading,
            value: candidate.value,
            comment: candidate.comment,
            source: candidate.source,
            usageCount: usageCounts[key] ?? 0,
            frequency: frequencyLookup(candidate.value),
            baseRank: candidate.baseRank
        )
    }

    for (index, entry) in userEntries.enumerated() {
        let key = entry.candidateKey
        let existing = merged[key]
        let comment = entry.comment.isEmpty ? (existing?.comment ?? "") : entry.comment
        merged[key] = HanjaCandidate(
            reading: entry.reading,
            value: entry.value,
            comment: comment,
            source: .userDefined,
            usageCount: usageCounts[key] ?? 0,
            frequency: frequencyLookup(entry.value),
            baseRank: index
        )
    }

    return merged.values.sorted(by: compareHanjaCandidate(_:_:))
}

func compareHanjaCandidate(_ lhs: HanjaCandidate, _ rhs: HanjaCandidate) -> Bool {
    if lhs.source != rhs.source {
        return lhs.source == .userDefined
    }

    if lhs.usageCount != rhs.usageCount {
        return lhs.usageCount > rhs.usageCount
    }

    if lhs.frequency != rhs.frequency {
        return lhs.frequency > rhs.frequency
    }

    if lhs.baseRank != rhs.baseRank {
        return lhs.baseRank < rhs.baseRank
    }

    if lhs.value != rhs.value {
        return lhs.value < rhs.value
    }

    return lhs.reading < rhs.reading
}
