// Joint candidate selection across a clause's target segments.
//     Copyright (C) 2026 Seungjin Lee.
//
// R2 (docs/plans/hanja-context-scaling-plan.md §7, §0 설계 배경): the plan's literal "분절 A의
// 읽기가 분절 B 후보의 연관 피처에 있으면 가점" definition is SEPARABLE per candidate combination
// (분절 A의 읽기는 v_A와 무관하게 항상 고정이라 A/B 점수가 f(v_A) + g(v_B)로 분해된다), so joint
// search over it would never change the independent argmax — it would be dead code. This file
// implements the coordinator's substitute: candidate ASSOCIATION-PROFILE overlap
// (`associationProfileSimilarity`), which depends on the (v_A, v_B) pair itself and is therefore
// genuinely non-separable. All functions here are pure — no `@MainActor`.

import Foundation

/// R2 결합 탐색 한계값 — 계획 §7-1의 "분절당 상위 후보 k=3 제한, 조합 수 상한".
enum HanjaJointSelectionLimits {
    /// 분절당 결합 탐색에 참여하는 상위 후보 수.
    static let candidatesPerSegment = 3
    /// 결합 탐색에 참여하는 최대 대상 분절 수. 3^5 = 243 ≤ 256(조합 수 상한).
    /// 초과 클로즈는 결합 단계를 통째로 건너뛴다 → 기존(R1) 동작과 완전 동일.
    static let maxSegments = 5
    /// 코사인이 신뢰할 만해지는 최소 공유 피처 수. 실측(조율자 2026-07-25): 공유 3~4개짜리
    /// 소형 프로필이 cos 0.23~0.30의 허위 고득점을 낸다.
    static let minimumSharedFeatures = 5
}

/// 두 후보 연관 프로필의 코사인 유사도 ∈ [0, 1]. 공유 피처가 `minimumSharedFeatures` 미만이면
/// 0(허위 신호 가드 — 실측: 공유 3~4개짜리 소형 프로필이 cos 0.23~0.30의 허위 고득점을 낸다).
/// 작은 쪽 사전을 순회해 공유 피처를 찾는다 — 어느 쪽을 먼저 넘겨도 결과는 같다(교환법칙).
func associationProfileSimilarity(
    _ lhs: [String: Double],
    _ rhs: [String: Double],
    minimumSharedFeatures: Int = HanjaJointSelectionLimits.minimumSharedFeatures
) -> Double {
    guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }

    let (smaller, larger) = lhs.count <= rhs.count ? (lhs, rhs) : (rhs, lhs)
    var dotProduct = 0.0
    var sharedFeatureCount = 0
    for (feature, weight) in smaller {
        guard let otherWeight = larger[feature] else { continue }
        dotProduct += weight * otherWeight
        sharedFeatureCount += 1
    }
    guard sharedFeatureCount >= minimumSharedFeatures else { return 0 }

    let lhsNorm = (lhs.values.reduce(0) { $0 + $1 * $1 }).squareRoot()
    let rhsNorm = (rhs.values.reduce(0) { $0 + $1 * $1 }).squareRoot()
    guard lhsNorm > 0, rhsNorm > 0 else { return 0 }

    return dotProduct / (lhsNorm * rhsNorm)
}

/// 결합 탐색 입력: 분절 하나당 (재랭킹 순서 상위 k개의 boost, 그 후보의 연관 프로필). `boosts`와
/// `profiles`는 같은 순서·같은 길이이며, index 0이 그 분절의 독립 argmax 후보다.
struct HanjaJointSegmentInput {
    let boosts: [Double]
    let profiles: [[String: Double]]
}

/// 완전 탐색으로 조합 점수가 최대인 배치를 고른다.
/// 목적함수: Σ_i boosts[i][c_i] + Σ_{i<j} pairBonus(i, c_i, j, c_j)
/// - 반환: 분절별 선택 인덱스. 입력이 비었으면 `[]`, 분절이 1개면 `[0]`(= 독립 argmax).
/// - 동점 처리: 오도미터 순서로 순회하며 **strict >** 로만 갱신한다. 시작 배치가
///   (0,0,...,0) = 독립 argmax(각 분절의 boosts가 이미 내림차순이므로)이므로 **모든
///   pairBonus가 0이면 결과는 반드시 독립 argmax와 동일**(동일성 불변식 — 테스트로 고정).
/// - `segments.count > HanjaJointSelectionLimits.maxSegments`면 방어적으로 독립 argmax를
///   반환한다(호출자는 애초에 이 경우 부르지 않아야 한다 — 가드는 호출자 쪽).
func selectJointAssignment(
    segments: [HanjaJointSegmentInput],
    pairBonus: (Int, Int, Int, Int) -> Double
) -> [Int] {
    guard !segments.isEmpty else { return [] }
    guard segments.count > 1 else { return [0] }
    guard segments.count <= HanjaJointSelectionLimits.maxSegments else {
        return segments.map { _ in 0 }
    }

    let counts = segments.map(\.boosts.count)
    guard counts.allSatisfy({ $0 > 0 }) else {
        return segments.map { _ in 0 }
    }

    func score(_ assignment: [Int]) -> Double {
        var total = 0.0
        for i in 0..<segments.count {
            total += segments[i].boosts[assignment[i]]
        }
        for i in 0..<segments.count {
            for j in (i + 1)..<segments.count {
                total += pairBonus(i, assignment[i], j, assignment[j])
            }
        }
        return total
    }

    var current = [Int](repeating: 0, count: segments.count)
    var best = current
    var bestScore = score(current)

    while true {
        // Odometer increment: rightmost digit rolls first, carries left.
        var position = segments.count - 1
        while position >= 0 {
            current[position] += 1
            if current[position] < counts[position] { break }
            current[position] = 0
            position -= 1
        }
        if position < 0 { break }

        let candidateScore = score(current)
        if candidateScore > bestScore {
            bestScore = candidateScore
            best = current
        }
    }

    return best
}
