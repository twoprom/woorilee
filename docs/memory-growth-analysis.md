# 장시간 구동 시 메모리 증가 원인 분석 (추정)

> 증상: `woorilee` 입력기 프로세스를 오래 켜두면 RSS(실사용 메모리)가 1 GB 가까이 증가한다.

이 문서는 **정적 코드 분석만으로 세운 가설**이다. 실측(Instruments / `vmmap` / `leaks`)으로 확정하기 전까지는 추정으로 다뤄야 한다. 각 가설마다 "확인 방법"을 같이 적었으니, 먼저 측정으로 범위를 좁힌 뒤 손대는 것을 권한다.

---

## 0. TL;DR

- **단일한 "고전적 누수"라기보다, 반복되는 대형 일시 할당 + macOS `malloc`이 해제한 페이지를 OS에 돌려주지 않는 특성(high-water-mark)** 의 조합일 가능성이 가장 높다. "1 GB까지 늘고 거의 안 줄어든다"는 패턴이 이 시나리오와 일치한다.
- 이 위에 **Kiwi 언어모델의 높은 baseline(~150–400 MB 추정)** 이 깔려 있어 천장 자체가 높다.
- 가장 유력한 증가 동력 후보(우선순위 순):
  1. **실시간 변환 ON일 때, 매 키 입력마다 "조합 중인 문절 전체"를 Kiwi로 재분석** — 디바운스 없음, 입력 길이에 비례하는 일시 할당 폭증. *(단, 실시간 변환은 기본값 OFF)*
  2. **`InputSessionCache`의 weak-to-strong `NSMapTable`** — Apple이 문서에서 경고한 누수 패턴. 사라진 클라이언트의 `InputSession`(+ LibHangul 컨텍스트)이 늦게/안 풀릴 수 있음.
  3. **`usageCountsByKey`를 후보 조회 때마다 전체 재생성** — 힙 churn → 단편화 → RSS 래칫.
  4. **상시 켜진 verbose 로깅** — 직접 누수는 아니지만 hot-path 할당 churn을 키움.
- **가장 먼저 확인할 것:** 메뉴에서 "실시간 변환"이 켜져 있었는지. 켜져 있었다면 1번이 주범일 가능성이 크고, 꺼져 있었다면 2·3번 쪽으로 무게가 옮겨간다.

---

## 1. 측정부터 (추측 금지)

코드를 고치기 전에 아래로 범위를 좁힌다.

```sh
# 현재 입력기 프로세스
pgrep -x woorilee

# 메모리 추이 (phys_footprint 이 핵심 지표)
footprint $(pgrep -x woorilee)

# 영역별 분해: __TEXT/__DATA, MALLOC zone, 익명 매핑, mmap된 모델 파일 등
vmmap --summary $(pgrep -x woorilee)

# 고전적 누수 여부
leaks $(pgrep -x woorilee)

# 힙 내 객체 종류별 카운트/바이트 (어떤 클래스가 쌓이는지)
heap $(pgrep -x woorilee) | head -50
```

판단 기준:

- `leaks`가 깨끗한데 `footprint`가 계속 오른다 → **누수가 아니라 high-water-mark / 단편화**(가설 A·C 쪽).
- `heap`에서 `InputSession` / LibHangul 컨텍스트 / `NSPanel` 류가 클라이언트 수보다 많이 쌓인다 → 가설 B.
- `vmmap`에서 `MALLOC_LARGE` / 익명 영역이 시간에 따라 증가 → 일시 대형 할당의 누적(가설 A·C).
- baseline을 보려면 **실행 직후** 한 번, **실시간 변환 끄고 30분 타이핑 후** 한 번, **켜고 30분 타이핑 후** 한 번 — 세 시점을 비교한다.

정밀 추적이 필요하면 `MallocStackLogging=1`로 띄운 뒤 `malloc_history <pid> -allBySize`, 또는 Instruments의 **Allocations + Leaks + VM Tracker** 템플릿을 사용한다.

---

## 2. 높은 Baseline: Kiwi / 漢字 모델 (증가가 아니라 천장)

앱은 시작 시 **무조건** Kiwi와 漢字 사전을 warm-up 한다 ([AppDelegate.swift:54](../woorilee/AppDelegate.swift), [KiwiAnalysisService.swift:42](../woorilee/KiwiAnalysisService.swift)). 번들된 모델 파일 크기:

| 파일 | 크기 |
|---|---|
| `KiwiModels/cong.mdl` | **~75 MB** |
| `KiwiModels/multi.dict` | ~12 MB |
| `KiwiModels/nounchr.mdl` | ~9.7 MB |
| `KiwiModels/sj.morph` | ~8.5 MB |
| `KiwiModels/default.dict` | ~3.1 MB |
| `data/hanja/hanja.txt` | ~6.5 MB |
| `data/hanja/freq-hanjaeo.txt` | ~3.9 MB |
| 합계(주요) | **~120 MB (디스크)** |

C++ Kiwi 분석기가 이 모델들을 메모리로 올리면(역인덱스·트라이·LM 등 자료구조로 전개되며 보통 디스크 크기보다 커진다) **상주 메모리 baseline이 수백 MB**가 될 수 있다. 또한 `HanjaFrequencyTable`은 `[String: Int]`에 `reserveCapacity(256_000)`로 빈도표를 통째로 적재한다 ([HanjaDictionaryService.swift:18](../woorilee/HanjaDictionaryService.swift)).

→ 이건 **시간이 지나며 늘어나는 양이 아니라 고정 천장**이다. 다만 "왜 1 GB 같은 큰 수가 나오나"의 절반은 이 baseline이 설명한다. `vmmap`에서 모델 파일이 mmap으로 잡혀 있는지(파일 백업, 압력 시 회수 가능) vs 익명 힙에 복사되었는지(회수 불가)를 확인하면 천장 성격을 알 수 있다.

---

## 3. 의심 원인 (우선순위 순)

### A. 실시간 변환: 매 키 입력마다 문절 전체를 Kiwi로 재분석 — 디바운스 없음 ⚠️ (실시간 ON일 때 1순위)

실시간 변환 모드에서는 키가 들어올 때마다 화면 갱신 경로가 `updateRealtimeDisplay() → updateRealtimeAnalysis()`를 타고 ([InputCompositionEngine.swift:178](../woorilee/InputCompositionEngine.swift)), 매번 **조합 중인 문절 소스 전체**를 다시 분석한다:

```swift
// InputCompositionEngine.swift:224
private func updateRealtimeAnalysis() {
    let state = session.realtimeClauseState
    let sourceText = state.rawClauseText + state.tailPreedit   // 문절이 커질수록 통째로 커짐
    ...
    segments = analyzeRealtimeClause(sourceText)               // 매 키 입력마다 호출
}
```

`analyzeRealtimeClause` → `kiwi.analyze(clause, topN: 3, …)` ([KiwiAnalysisService.swift:89](../woorilee/KiwiAnalysisService.swift)). 즉 한 글자 칠 때마다 `topN=3`짜리 형태소 분석을 **점점 길어지는 입력 전체에 대해** 다시 돌린다. 디바운스/증분 분석이 없다.

- Swift 바인딩 자체는 결과를 `defer { kiwi_res_close(result) }`로 잘 해제한다 ([Kiwi.swift:58](../Kiwi/bindings/swift/Sources/Kiwi/Kiwi.swift)) — 즉 **명시적 Swift 레벨 누수는 아니다.**
- 그러나 C++ Kiwi 분석기는 내부적으로 작업용 아레나/경로 평가 버퍼를 잡으며, 이런 버퍼는 보통 **"본 적 있는 최대 입력 크기"에 맞춰 커진 뒤 줄지 않는다.** 게다가 macOS `malloc`은 큰 블록을 해제해도 OS에 잘 돌려주지 않는다.
- 결과: 긴 문절을 몇 번 조합하면 RSS가 한 번 점프하고 **그 수준에서 안 내려온다.** 장시간 사용으로 이 점프가 누적되면 천장이 계속 올라간다.

**중요:** 실시간 변환은 **기본값 OFF**다 ([HanjaSettingsStore.swift:21](../woorilee/HanjaSettingsStore.swift) — `default: false`). 따라서 이 가설은 *사용자가 메뉴에서 켰을 때만* 성립한다. 켜두고 오래 썼다면 가장 유력한 주범.

**확인:** 실시간 변환을 끄고 동일 시간 사용했을 때 증가가 멈추는지 비교. Instruments Allocations에서 `kiwi_analyze` 콜스택의 persistent 바이트가 누적되는지 확인.

**완화 방향(참고):** 분석을 디바운스(예: 마지막 입력 후 N ms)하거나, 문절 길이 상한을 두거나, 증분 분석으로 전환. (이 문서 범위는 진단까지이며 수정은 별도.)

---

### B. `InputSessionCache`의 weak-to-strong `NSMapTable` 누수 패턴 ⚠️

```swift
// InputSession.swift:135
private static let cache = NSMapTable<AnyObject, InputSession>(
    keyOptions: [.weakMemory, .objectPointerPersonality],  // key = IMK client (weak)
    valueOptions: [.strongMemory]                           // value = InputSession (strong)
)
```

이건 **weak 키 + strong 값** 조합인데, Apple의 `NSMapTable.h` 헤더가 명시적으로 경고하는 구성이다: *weak 키가 회수돼도 그에 대응하는 strong 값은 즉시 제거되지 않고, 맵 테이블이 다음에 조작될 때까지(때로는 그 이상) 살아남는다.*

- 각 IMK 클라이언트(텍스트 필드/앱 단위 프록시)마다 `InputSession` 하나가 생기고, 그 안에 LibHangul thread-safe 입력 컨텍스트(C 자원)가 매달려 있다 ([InputSession.swift:156](../woorilee/InputSession.swift)).
- 앱/문서/텍스트필드를 많이 옮겨다니며 오래 쓰면 죽은 클라이언트의 `InputSession`이 늦게/안 풀리며 쌓일 수 있다.
- 개별 세션은 작아서 **단독으로 1 GB를 만들지는 못한다.** 하지만 누적성 증가의 한 축이고, "오래 켜둘수록"이라는 증상과 방향이 맞는다. 또한 `heap`/`leaks`로 가장 깔끔하게 확정 가능한 항목이다.

**확인:** `heap <pid> | grep -i InputSession` 카운트가 실제 활성 텍스트필드 수보다 단조 증가하는지. 앱을 여럿 열고 닫기를 반복한 뒤 측정.

---

### C. `usageCountsByKey` 전체 재생성 — 조회마다 딕셔너리 복제 (힙 churn)

漢字 후보를 뽑을 때마다 사용량 전체를 새 딕셔너리로 만든다:

```swift
// HanjaUsageStore.swift:46
var usageCountsByKey: [HanjaCandidateKey: Int] {
    recordsByKey.reduce(into: [:]) { ... }   // 매 호출마다 전체 복제
}

// HanjaDictionaryService.swift:211 — 후보 조회 경로에서 매번 호출
let usageCounts = usageStore?.usageCountsByKey ?? [:]
```

- `recordsByKey`는 사용자가 선택한 (독음, 값) 쌍마다 누적된다. 어휘 규모라 **상한 자체는 작지만(수천~수만 항목)**, 그 전체를 후보 조회 때마다 새로 복제한다.
- 실시간 변환 ON이면 **키 입력당 × 문절 내 분절당** 조회가 일어나 복제 빈도가 폭증한다(가설 A와 곱해진다).
- 직접 누수는 아니지만, 반복되는 중간 크기 일시 할당은 **힙 단편화**를 키워 RSS가 baseline으로 못 돌아오게 만든다.

**확인:** Instruments Allocations의 transient 할당에서 `Dictionary`/`HanjaCandidateKey` 폭이 큰지. `recordsByKey.count`가 비정상적으로 큰지(중복 키 누적 여부).

---

### D. 상시 켜진 verbose 로깅

- `debugLoggingEnabled = true`로 하드코딩 ([InputController.swift:32](../woorilee/InputController.swift)), `debugLog`가 hot-path 곳곳에서 호출됨 ([InputController.swift:1419](../woorilee/InputController.swift)).
- `handle`/`inputText`/`didCommand`마다 `inputLogger.info(...)`가 입력 문자열을 보간해 찍는다 ([InputController.swift:84,105,120,433](../woorilee/InputController.swift)).
- OSLog 저장소는 **프로세스 밖** 링버퍼라 이 자체가 RSS를 1 GB로 만들지는 않는다. 하지만 매 키 입력마다 `OSLogMessage` 보간으로 일시 객체를 만들어 **할당 churn에 기여**하고, 진단 시 노이즈를 키운다.

**확인:** 릴리스 빌드에서 `debugLoggingEnabled`/`inputLogger.debug` 비용을 끄고 차이를 본다. (기능 영향 없음 — 진단/완화 모두 안전.)

---

### E. 가능성 낮은(하지만 배제 못 한) 후보

- **IMK 컨트롤러 인스턴스 누적:** IMK는 클라이언트마다 `InputController`를 만든다. 프레임워크가 이를 제때 해제하지 않는 사례가 알려져 있으나, 이 코드만으로는 확정 불가. `heap`에서 `InputController` 카운트로 확인.
- **패널/SwiftUI 호스팅:** 후보 패널은 싱글턴 + `NSHostingView` 재사용이라 구조상 누수 가능성은 낮다 ([HanjaCandidatePanelController.swift:95](../woorilee/HanjaCandidatePanelController.swift)). `selectionHandler`도 `hide()`에서 nil 처리됨. 다만 SwiftUI/`NSHostingView`가 갱신마다 내부 캐시를 늘리는지는 측정으로만 확인 가능.
- **Sparkle 자동 업데이트:** `AboutWindowController`가 `SPUStandardUpdaterController`를 시작 시 생성하지만([AboutWindowController.swift:14](../woorilee/AboutWindowController.swift)), 주기적 체크는 가볍고 1 GB 증가의 설명으론 약하다.

---

## 4. 종합 가설

> **천장이 높은 이유**는 Kiwi 언어모델 baseline(가설 2장, 수백 MB 추정)이고,
> **시간이 갈수록 더 오르는 이유**는 — 실시간 변환을 켰다면 (A) 매 키 입력 전 문절 재분석이 만드는 대형 일시 할당이 `malloc` high-water-mark로 굳는 것, 끄고 썼다면 (B) 세션 맵 누적 + (C) 사용량 딕셔너리 churn에 의한 단편화가 주된 동력 —
> 으로 추정한다. 셋 다 "해제했는데 RSS가 안 줄어든다"는 동일한 관측으로 수렴하며, `leaks`만으로는 (B)를 제외하면 잘 안 잡힌다.

## 5. 권장 다음 단계

1. **실시간 변환 ON/OFF 두 조건**에서 `footprint`를 30분 간격으로 비교 → 가설 A의 비중을 즉시 가른다.
2. `leaks` + `heap | grep InputSession`으로 가설 B를 확정/배제.
3. `vmmap --summary`로 baseline(모델 mmap vs 익명 힙)과 증가 영역(MALLOC zone)을 분리.
4. 위 결과로 주범이 좁혀지면 그때 해당 항목만 손본다(디바운스/맵테이블 교체/딕셔너리 캐싱/로깅 게이트). **측정 전 선제 수정은 지양.**

---

*작성: 정적 분석 기반 추정. 실측으로 갱신 필요.*
