# AGENTS.md

## 프로젝트 개요

- 이 저장소는 macOS용 한국어 입력기 `woorilee` 프로젝트다.
- 앱은 `InputMethodKit` 기반이며, 일반적인 storyboard/nib 앱이 아니라 `woorilee/main.swift`에서 `NSManualApplication`을 직접 띄우는 구조다.
- 한글 조합 엔진은 `LibHangul`을 사용하고, 한자 변환은 번들된 사전(`woorilee/data/hanja/hanja.txt`)과 로컬 벤더링된 `Kiwi` Swift 패키지 + `KiwiModels` 리소스의 형태소 분석을 기반으로 한다.
- 입력 처리는 한 파일에 모여 있지 않고 다음 경계로 나뉘어 있다 — `InputController`(IMK 디스패치), `InputEventPolicy`(키 정규화), `InputCompositionEngine`(marked/replacement 처리), `InputSession`(클라이언트별 상태와 캐시). 자세한 구조는 `docs/internal-module-map.md`를 참고한다.

## 주요 경로

- `woorilee/`: 메인 앱 타깃 소스와 리소스.
- `woorilee/main.swift`: 입력기 앱 진입점. storyboard 기반 실행으로 바꾸지 말 것.
- `woorilee/AppDelegate.swift`: `IMKServer` 초기화와 `HanjaServiceCoordinator.shared`를 통한 Hanja/Kiwi 웜업 트리거.
- `woorilee/InputController.swift`: IMK가 클라이언트마다 생성하는 컨트롤러. 조합 상태는 직접 보유하지 않고 `InputSessionCache`를 통해 `InputSession`으로 위임한다.
- `woorilee/InputEventPolicy.swift`, `woorilee/InputCompositionEngine.swift`, `woorilee/InputSession.swift`: 키 정규화, marked/replacement 범위, 세션/캐시 상태를 각각 담당.
- `woorilee/HanjaServiceCoordinator.swift`: 한자 메뉴, 웜업 패널, 수동 후보 패널, 실시간 변환 경로를 묶는 `@MainActor` 싱글톤. 자세한 모듈 경계는 `docs/internal-module-map.md`.
- 실시간 변환 모드에서는 일본어 IME식 문절 신축을 지원한다: `Shift+←/→`로 포커스 분절의 오른쪽 경계를 한 글자씩 줄이거나 늘린다. 경계 오버레이(`RealtimeClauseState.manualBoundaries`)는 재분석이 존중하며(Kiwi 대신 `KiwiAnalysisService.makeManualSegments` 사용), 글자 입력·Backspace·Space 등 소스 편집 시 폐기되어 Kiwi 자동 분절로 복귀한다.
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
- 기본 빌드: `xcodebuild -project woorilee.xcodeproj -scheme woorilee -configuration Debug build`
- 유닛 테스트: `xcodebuild -project woorilee.xcodeproj -scheme woorilee -destination 'platform=macOS,arch=arm64' test` (대상 타깃은 `woorileeTests`).
- 빌드 단계에서 `scripts/install-built-input-method.sh`가 자동 실행되어 `killall woorilee` 후 빌드된 `woorilee.app`을 `/Library/Input Methods/`로 `ditto`한다. 필요 시 `osascript`로 권한 상승을 시도한다.
  - 끄려면 `WOORILEE_SKIP_INSTALL=1` 또는 `WOORILEE_INSTALL_BUILT_INPUT_METHOD=0`. 평소 개발에서는 끄지 않는다.
- 수동 설치 시에도 앱 번들 복사는 `cp -R`보다 `ditto`를 우선 사용하고, 먼저 `killall woorilee`로 기존 프로세스를 내려야 macOS가 새 번들을 인식한다.
- 입력 로직을 바꿨다면 최소한 다음 동작을 확인한다.
  - 한글 조합/확정이 정상 동작하는지
  - `Backspace`, `Space`, `Return`, `Escape`, `Tab` 처리에 회귀가 없는지
  - 화살표/이동 명령 시 조합 중 텍스트가 남지 않고 적절히 확정되는지
  - `markedRange`와 `replacementRange`가 깨지지 않는지 (Safari/TextEdit/Terminal 등 호스트별 차이 주의)

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
