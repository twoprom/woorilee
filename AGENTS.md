# AGENTS.md

이 저장소에서 사소하지 않은 변경을 시작하기 전에 이 파일과 `docs/internal-module-map.md`, `docs/runtime-resource-inventory.md`를 함께 읽는다. 세 문서는 서로 보완하는 기준 문서다.

Sparkle 업데이트 릴리스 작업(빌드 → 서명 → 업로드 → appcast)은 `docs/sparkle-release-workflow.md`를 따른다.

## 프로젝트 개요

- 이 저장소는 macOS용 한국어 입력기 `woorilee` 프로젝트다.
- 앱은 `InputMethodKit` 기반이며, 일반적인 storyboard/nib 앱이 아니라 `woorilee/main.swift`에서 `NSManualApplication`을 직접 띄우는 구조다.
- 한글 조합 엔진은 `LibHangul`을 사용하고, 한자 변환은 번들된 사전(`woorilee/data/hanja/hanja.txt`)과 로컬 벤더링된 `Kiwi` Swift 패키지 + `KiwiModels` 리소스의 형태소 분석을 기반으로 한다.
- `IMKSwift`가 raw `InputMethodKit` API를 감싼다. 직접 `InputMethodKit`을 쓰기보다 `IMKSwift`를 우선하고, 불가피하게 raw IMK로 우회할 때는 이유를 코드 주석에 명시한다.

## 주요 경로

- `woorilee/`: 메인 앱 타깃 소스와 리소스.
- `woorilee/main.swift`: 입력기 앱 진입점. storyboard 기반 실행으로 바꾸지 말 것.
- `woorilee/AppDelegate.swift`: `IMKServer` 초기화와 `HanjaServiceCoordinator.shared`를 통한 Hanja/Kiwi 웜업 트리거.
- `woorilee/Info.plist`: 입력기 등록 정보와 `InputMethodConnectionName`, `InputMethodServerControllerClass` 정의.
- `woorilee/woorilee.entitlements`: 샌드박스와 Mach 등록 관련 권한.
- `woorilee/data/hanja/`: 번들된 한자 사전(`hanja.txt`, `freq-hanja.txt`, `freq-hanjaeo.txt`).
- `woorilee/KiwiModels/`: 앱 번들에 포함되는 Kiwi 모델 리소스.
- `woorilee.xcodeproj/`: Xcode 프로젝트와 SwiftPM 의존성 설정(`IMKSwift`, `LibHangul`, 로컬 `Kiwi`).
- `Kiwi/`: 로컬 Swift 패키지 의존성으로 연결된 서드파티 코드. gitignore 대상이며 명시적 요청 없이는 수정하지 않는다.
- `DerivedData/`, `DerivedDataPlan/`, `.xcode-home/`, `.xcode-swiftpm-modulecache/`: 생성물/캐시. 수정하지 말 것.
- 루트 `KiwiModels/`: 벤더링된 참조용 복사본이며 gitignore 대상이다. 실제 앱 번들은 `woorilee/KiwiModels/`를 사용한다. 두 경로를 혼동하지 말 것.

## 빌드와 검증

- 스킴 확인: `xcodebuild -list -project woorilee.xcodeproj`
- 소스 변경 후 설치 포함 빌드: `WOORILEE_INSTALL_BUILT_INPUT_METHOD=1 xcodebuild -project woorilee.xcodeproj -scheme woorilee -configuration Debug build`
- 유닛 테스트: `xcodebuild -project woorilee.xcodeproj -scheme woorilee -destination 'platform=macOS,arch=arm64' test` (대상 타깃은 `woorileeTests`).
- 단일 테스트 클래스: `xcodebuild -project woorilee.xcodeproj -scheme woorilee -destination 'platform=macOS,arch=arm64' test -only-testing:woorileeTests/InputEventPolicyTests`
- 단일 테스트 메서드: 위 명령의 `-only-testing` 값을 `woorileeTests/InputEventPolicyTests/testPrintableASCIICharacterUsesEventCharacters`처럼 지정한다.
- 스킴의 `Install Built Input Method` 빌드 PostAction은 모든 빌드에서 `scripts/install-built-input-method.sh`를 실행하지만, 설치는 기본적으로 건너뛴다. `WOORILEE_INSTALL_BUILT_INPUT_METHOD=1`일 때만 기존 `woorilee` 프로세스를 종료하고 빌드된 앱을 `/Library/Input Methods/`에 `ditto`하며, 필요하면 `osascript`로 권한 상승을 시도한다.
  - `WOORILEE_SKIP_INSTALL=1` 또는 `WOORILEE_INSTALL_BUILT_INPUT_METHOD=0`은 opt-in이 있어도 설치를 강제로 건너뛴다.
  - 소스 변경 후에는 별도 요청을 기다리지 말고 `WOORILEE_INSTALL_BUILT_INPUT_METHOD=1`로 빌드해 실행 중인 입력기를 갱신한다.
  - 테스트 빌드는 `/Library/Input Methods/`를 건드리지 않도록 설치 환경 변수 없이 실행한다.
- 수동 설치 시에도 앱 번들 복사는 `cp -R`보다 `ditto`를 우선 사용하고, 먼저 `killall woorilee`로 기존 프로세스를 내려야 macOS가 새 번들을 인식한다.
- UI 테스트 타깃은 없다.
- 입력 로직을 바꿨다면 최소한 다음 동작을 확인한다.
  - 한글 조합/확정이 정상 동작하는지
  - `Backspace`, `Space`, `Return`, `Escape`, `Tab` 처리에 회귀가 없는지
  - 화살표/이동 명령 시 조합 중 텍스트가 남지 않고 적절히 확정되는지
  - `markedRange`와 `replacementRange`가 깨지지 않는지 (Safari/TextEdit/Terminal 등 호스트별 차이 주의)

## 아키텍처

실행 경로는 `main.swift` → `NSManualApplication`(`AppDelegate.swift`에 정의) → `AppDelegate.applicationDidFinishLaunching` 순서다. `AppDelegate`는 `Info.plist`의 `InputMethodConnectionName`으로 `IMKServer`를 생성하고 `HanjaServiceCoordinator.shared`를 통해 Hanja/Kiwi 웜업을 시작한다.

`Info.plist` 연결 정보는 이름을 바꿀 때 반드시 함께 맞춘다.

- `InputMethodConnectionName` ↔ `AppDelegate`에서 `IMKServer`에 전달하는 `name:` 인자.
- `InputMethodServerControllerClass` ↔ IMK가 클라이언트마다 생성하는 `IMKInputSessionController` 하위 클래스인 `InputController`.

입력기 런타임은 의도적으로 다음 경계로 분리되어 있다. 자세한 내용은 `docs/internal-module-map.md`를 참고하고, 이 책임을 `InputController` 하나로 다시 합치지 않는다.

- `woorilee/InputController.swift`: `handle(_:client:)`, 메뉴 연결, 아래 헬퍼로의 디스패치만 담당하는 IMK 경계 오케스트레이션.
- `woorilee/InputEventPolicy.swift`: 출력 가능한 ASCII 추출, 두벌식 Shift 매핑, 이동/selector 분류 등 상태 없는 키 이벤트 정규화. 유닛 테스트 가능한 순수 로직으로 유지한다.
- `woorilee/InputCompositionEngine.swift`: marked text와 replacement range bookkeeping, `IMKTextInput` 호출을 감싼 확정/갱신 헬퍼.
- `woorilee/InputSession.swift`: 클라이언트별 `InputSession`, `InputSessionCache`, `InputRangeState`. IMK는 컨트롤러 인스턴스를 여러 클라이언트에 재사용할 수 있으므로 조합 상태를 `InputController` 자체에 저장하지 않는다.
- `woorilee/HanjaServiceCoordinator.swift`: 한자 메뉴, 웜업 패널, 수동 후보 패널, Kiwi 기반 실시간 변환을 묶는 싱글톤. `realtimeConversionPhaseUnlocked`(현재 `true`)는 실시간 경로 kill switch이며, `isRealtimeAvailable`은 Kiwi와 한자 사전이 모두 `ready`여야 참이다.
- `woorilee/HanjaConversionModels.swift`: `CompositionMode`(`hangul` / `manualHanja` / `realtimeHanja`), `SegmentLockKey` 등 coordinator/session/test가 공유하는 값 타입. `RealtimeClauseState`의 `manualBoundaries`와 `focusedSpanStart`는 실시간 모드에서 `Shift+←/→` 문절 신축을 지원한다. 수동 경계가 있으면 재분석은 Kiwi를 다시 실행하지 않고 `KiwiAnalysisService.makeManualSegments`를 사용하며, 글자 입력·Backspace·Space 등 소스 편집 시 경계를 버린다.
- `woorilee/ManualHanjaModels.swift`, `woorilee/ManualHanjaPanelAnchorResolver.swift`: 수동 한자 패널의 target/notice/content 값 타입과 호스트 앱별 caret rect 탐색 로직.
- `woorilee/CandidatePanelOriginCalculator.swift`: caret rect를 후보 패널 원점으로 바꾸는 순수 배치 계산. caret 아래 배치, 공간 부족 시 위로 반전, visible frame 내부 제한을 담당하며 상태 없이 유닛 테스트한다.
- `woorilee/NumericHanjaCandidateGenerator.swift`: 숫자 입력을 자릿수별/수량 단위별 한자와 한글 후보로 만드는 상태 없는 생성기.

지원 서비스는 각각 `uninitialized` / `loading` / `ready` / `unavailable(reason)` 상태 enum을 소유한다.

- `woorilee/KiwiAnalysisService.swift`: Kiwi 형태소 분석기 백그라운드 웜업.
- `woorilee/HanjaDictionaryService.swift`: 번들된 한자 테이블 로딩.
- `woorilee/HanjaUsageStore.swift`, `woorilee/UserHanjaStore.swift`: 후보 순위에 쓰는 사용 통계와 사용자 정의 항목. 공유 Codable 타입은 `woorilee/HanjaPersonalizationModels.swift`, Application Support와 번들 리소스 경로는 `woorilee/AppRuntimePaths.swift`에 모여 있다.
- `woorilee/HanjaSettingsStore.swift`: 실시간 변환 토글, 숫자 후보 선택 후 자동 이동 등 메뉴 설정.
- `woorilee/HanjaWarmUpPanelController.swift`, `woorilee/HanjaCandidatePanelController.swift`: 활성화되지 않는 웜업/후보 패널. `woorilee/HanjaCandidatePanelView.swift`는 후보 패널에 호스팅되는 SwiftUI 뷰다.
- `woorilee/AboutWindowController.swift`: About 패널과 자동 업데이트용 Sparkle `SPUStandardUpdaterController` 소유.
- `woorilee/HanjaUserDictionaryWindowController.swift`, `woorilee/HanjaUserDictionaryView.swift`: `UserHanjaStore` 기반 사용자 한자 사전 편집기.

## 리소스와 의존성

- 앱 번들 리소스는 `woorilee/` 아래에 있다. `data/hanja/{hanja.txt,freq-hanja.txt,freq-hanjaeo.txt}`, `KiwiModels/*`, `main.tiff`, `mainicon.icon`, `*.lproj/InfoPlist.strings`가 포함된다. 프로젝트 파일 변경 후에는 기준 목록인 `docs/refactor-parity-checklist.md`를 확인한다.
- `mainicon.icon`은 빌드 시 `mainicon.icns`로 컴파일되는 Icon Composer 번들이다.
- SwiftPM 의존성은 Xcode 프로젝트가 해석하는 `IMKSwift`, `LibHangul`, `Sparkle`과 `Kiwi/bindings/swift`의 로컬 경로 `Kiwi` 패키지다. Sparkle은 자동 업데이트를 위해 `AboutWindowController`에서만 사용한다.
- 루트의 `Kiwi/`와 `KiwiModels/`는 gitignore된 벤더링 복사본이고, 실제 앱 번들 리소스는 `woorilee/KiwiModels/`에 있다.
- 생성/캐시 경로인 `DerivedData/`, `DerivedDataPlan/`, `.xcode-home/`, `.xcode-swiftpm-modulecache/`는 수정하지 않는다.

## 수정 원칙

- `InputMethodConnectionName` 값과 `AppDelegate.swift`의 `IMKServer` 초기화 로직은 항상 일치해야 한다.
- `InputMethodKit` API를 직접 호출하는 새 코드는 가능한 한 피하고, 먼저 `IMKSwift`가 제공하는 타입과 추상화를 통해 구현한다.
- 입력기 관련 동작을 추가하거나 수정할 때는 raw `InputMethodKit` 사용보다 기존 `IMKSwift` 사용 패턴과 일관성을 우선한다.
- `IMKSwift`로 해결되지 않는 경우에만 직접 `InputMethodKit` 사용을 검토하고, 그 경우 왜 우회가 필요한지 코드와 설명에 분명히 남긴다.
- `InputController`, `AppDelegate`, `InputSession`, `HanjaServiceCoordinator`는 메인 액터 전제 코드다. 동시성 변경 시 이 전제를 깨지 말 것. Kiwi/Hanja 웜업, 사용 통계 파일 I/O 등 백그라운드 작업은 off-main에서 실행한 뒤 `@MainActor` 콜백으로 합류시키는 기존 패턴을 따른다.
- 입력기 특성상 `insertText`, `setMarkedText`, `unmarkText`, `selectedRange`, `markedRange` 상호작용이 매우 민감하다. 단순 리팩터링도 동작 회귀를 만들 수 있으니 범위를 좁혀 수정한다.
- 키 매핑이나 조합 상태를 건드릴 때는 조합 중 문자열, 즉시 확정 문자열, 세션 캐시 수명주기를 함께 본다.
- 입력기 실행 흐름을 일반 AppKit 앱처럼 바꾸지 말 것. storyboard/nib 도입은 이 프로젝트 구조와 맞지 않는다.
- 서드파티 의존성(`Kiwi`, `IMKSwift`, `LibHangul`) 수정은 마지막 수단으로 두고, 먼저 앱 레이어에서 해결 가능한지 본다.

## 작업 범위 관리

- 이 저장소는 `DerivedData` 변경으로 작업 트리가 쉽게 지저분해진다. 상태 확인 시에는 필요한 경로만 좁혀서 본다.
- 추천 범위:
  - `git status --short -- AGENTS.md woorilee woorilee.xcodeproj`
  - `git diff -- woorilee woorilee.xcodeproj AGENTS.md`
- 사용자가 만든 기존 변경은 되돌리지 말 것. 특히 `woorilee/InputController.swift`는 자주 작업되는 파일이므로 덮어쓰지 않게 주의한다.

## Apple 프레임워크 정보

- Apple 프레임워크나 API 동작을 확인해야 할 때는 `sosumi-mcp`를 사용한다.
- 특히 `AppKit`, `InputMethodKit`, 텍스트 입력 시스템 관련 문서는 추측하지 말고 먼저 확인한다.

# Guidelines

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.
