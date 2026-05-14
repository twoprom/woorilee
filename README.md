# 우리입력기

`woorilee`는 macOS용 한국어 입력기입니다. 입력 방식은 두벌식 한글 조합을 기본으로 하며, `InputMethodKit` 기반 입력기 프로세스 안에서 한글 조합, 수동 한자 변환, Kiwi 형태소 분석 기반 실시간 한자 변환을 처리합니다.

## 경고

이 프로젝트는 소프트웨어 개발 경험이 없는 사람이 시작했으며, 코드의 상당 부분을 AI가 생성했습니다. 코드 품질이나 안정성에 대한 전문적인 검증을 거치지 않았으므로, 소스 코드를 무조건 신뢰해서는 안 됩니다. 일상적으로 안정적인 한국어 입력기가 필요하다면 macOS 기본 입력기나 검증된 서드파티 입력기를 사용하는 것을 권장합니다. 이 프로젝트는 실험적 성격이 강하며, 예기치 않은 동작이나 버그가 있을 수 있습니다.

## 주요 기능

- 두벌식 한글 조합과 확정
- `InputMethodKit` 클라이언트별 조합 상태 관리
- 수동 한자 변환과 후보 패널
- Kiwi 형태소 분석 기반 실시간 한자 변환
- 사용자 한자 항목과 사용 빈도 기반 후보 랭킹
- macOS 입력 소스 등록을 위한 `Info.plist`/아이콘/로컬라이즈 리소스

## 설치

- GitHub Releases에서 확인하세요. macOS 26.0 이상이 필요합니다. zip 파일 안의 `.app` 번들을 `/Library/Input Methods/` 또는 `~/Library/Input Methods/`로 복사하세요.

## 업데이트

메뉴 막대의 입력 소스 아이콘을 클릭한 뒤 `우리입력기에 관하여`를 선택하면 현재 버전을 확인하고 새 버전으로 업데이트할 수 있습니다.

## 사용법

### 입력기 활성화

1. 시스템 설정 → 키보드 → 입력 소스 → `편집…`으로 이동합니다.
2. 왼쪽 하단의 `+` 버튼을 눌러 입력 소스를 추가합니다.
3. 한국어 목록에서 `두벌式`을 선택하고 추가합니다.
4. 메뉴 막대의 입력 소스 아이콘을 클릭하거나 `Ctrl+Space`로 우리입력기를 선택합니다.
5. 처음 설치한 경우 보안 경고가 나타납니다. 시스템 설정 → 개인정보 보호 및 보안 → `그래도 열기`를 누르세요.

### 한글 입력

일반적인 두벌식 자판 배열로 한글을 입력합니다. 조합 중인 글자는 밑줄이 표시되며, `Space`, `Return`, 화살표 키 등을 누르면 조합이 확정됩니다.

### 한자 변환

- **수동 변환**: 한글을 입력한 뒤 `Opt+Return`을 누르면 한자 후보 패널이 열립니다. 원하는 한자를 선택하면 변환됩니다.
- **실시간 변환**: Kiwi 형태소 분석 기반의 실시간 한자 변환이 활성화되어 있으면, 입력 중 자동으로 한자 후보가 제시됩니다. 메뉴에서 실시간 변환을 켜고 끌 수 있습니다.

## 저장소 구조

| 경로 | 설명 |
| --- | --- |
| `woorilee/` | 앱 타깃의 Swift 소스와 런타임 리소스 |
| `woorilee/main.swift` | 입력기 프로세스 진입점 |
| `woorilee/AppDelegate.swift` | `IMKServer` 초기화와 Hanja/Kiwi 웜업 시작 |
| `woorilee/InputController.swift` | IMK 콜백을 받는 컨트롤러. 조합 상태는 직접 보유하지 않고 세션으로 위임 |
| `woorilee/InputEventPolicy.swift` | 키 이벤트 정규화와 명령 분류 |
| `woorilee/InputCompositionEngine.swift` | marked text, replacement range, commit/update 처리 |
| `woorilee/InputSession.swift` | 클라이언트별 입력 세션, 세션 캐시, 범위 상태 |
| `woorilee/HanjaServiceCoordinator.swift` | 한자 메뉴, 웜업, 후보 패널, 실시간 변환 경로를 조정하는 싱글톤 |
| `woorilee/data/hanja/` | 번들에 포함되는 한자 사전과 빈도 데이터 |
| `woorilee/KiwiModels/` | 앱 번들에 포함되는 Kiwi 모델 리소스 |
| `woorileeTests/` | 입력 정책, 세션, 한자 변환, 저장소 관련 유닛 테스트 |
| `Kiwi/` | 로컬 SwiftPM 의존성으로 연결된 Kiwi 서브모듈 |
| `scripts/` | Kiwi 아티팩트 점검과 입력기 설치 스크립트 |
| `docs/` | 내부 모듈 지도, 런타임 리소스 목록, 리팩터링 검증 체크리스트 |

더 자세한 내부 경계는 `docs/internal-module-map.md`, 런타임 리소스 목록은 `docs/runtime-resource-inventory.md`, 리팩터링 검증 기준은 `docs/refactor-parity-checklist.md`를 참고하세요.

## 의존성

### 개발 환경

- macOS
- Xcode 26 계열
- Swift 5 모드로 빌드되는 Xcode 프로젝트
- Git LFS
- 로컬 설치 또는 배포 빌드를 위한 Apple Developer Team 설정

공개 프로젝트 파일에는 `DEVELOPMENT_TEAM` 값이 들어 있지 않습니다. 로컬에서 서명된 앱 번들을 빌드하거나 `/Library/Input Methods/`에 설치하려면 Xcode에서 자신의 Team을 설정해야 합니다. CI나 단순 테스트는 코드 서명 없이 실행할 수 있습니다.

현재 앱 타깃의 주요 빌드 설정은 다음과 같습니다.

- 앱 번들 ID: `com.twoprom.inputmethod.woorilee`
- 테스트 번들 ID: `com.twoprom.inputmethod.woorileeTests`
- 앱 표시 이름: `우리입력기`
- 배포 타깃: `macOS 26.0`
- Swift 버전 설정: `5.0`
- 앱 샌드박스와 Hardened Runtime 사용
- `SYMROOT = build`

### SwiftPM 패키지

Xcode 프로젝트는 다음 SwiftPM 의존성을 사용합니다.

| 의존성 | 출처 | 용도 |
| --- | --- | --- |
| `IMKSwift` | `https://github.com/vChewing/IMKSwift.git`, `26.3.7` 이상 27 미만 | raw `InputMethodKit` API를 감싸는 입력기용 Swift 추상화 |
| `LibHangul` | `https://github.com/Meapri/libhangul-swift.git`, `main` 브랜치 | 두벌식 한글 조합 엔진 |
| `Kiwi` | 로컬 경로 `Kiwi/bindings/swift` | 한자 실시간 변환을 위한 한국어 형태소 분석 |

`Package.resolved` 기준 현재 고정 상태는 다음과 같습니다.

- `IMKSwift`: `26.3.7`, revision `be4e776cc0b93bda31ce3904005bf4d94526de19`
- `libhangul-swift`: `main`, revision `d50f34b82deebc3c44a3b0a88ea0849f7230609c`

서드파티 의존성 수정은 마지막 수단입니다. 입력 동작 문제는 먼저 앱 레이어에서 해결하는 것이 이 프로젝트의 기본 원칙입니다.

### Kiwi 서브모듈과 바이너리 아티팩트

`Kiwi/`는 Git 서브모듈이며 `https://github.com/twoprom/Kiwi.git`를 가리킵니다. Xcode 프로젝트는 루트의 `Kiwi` 소스 전체를 직접 빌드하지 않고, `Kiwi/bindings/swift`에 있는 Swift 패키지를 로컬 패키지로 연결합니다.

이 Swift 패키지는 다음 구조를 사용합니다.

- Swift wrapper 타깃: `Kiwi`
- C API binary target: `CKiwi`
- 필수 바이너리: `Kiwi/bindings/swift/Artifacts/CKiwi.xcframework`
- linker 설정: `c++`, `z`

`CKiwi.xcframework`를 `DerivedData`에 수동으로 복사해서 빌드하는 방식은 사용하지 않습니다. 깨끗한 체크아웃에서도 재현 가능해야 하므로 `Kiwi/bindings/swift/Artifacts/CKiwi.xcframework` 위치를 기준으로 준비합니다.

### 런타임 리소스

앱 번들에는 다음 리소스가 포함되어야 합니다.

- `Contents/Resources/main.tiff`
- `Contents/Resources/mainicon.icns`
- `Contents/Resources/data/hanja/hanja.txt`
- `Contents/Resources/data/hanja/freq-hanja.txt`
- `Contents/Resources/data/hanja/freq-hanjaeo.txt`
- `Contents/Resources/KiwiModels/combiningRule.txt`
- `Contents/Resources/KiwiModels/cong.mdl`
- `Contents/Resources/KiwiModels/default.dict`
- `Contents/Resources/KiwiModels/dialect.dict`
- `Contents/Resources/KiwiModels/extract.mdl`
- `Contents/Resources/KiwiModels/multi.dict`
- `Contents/Resources/KiwiModels/nounchr.mdl`
- `Contents/Resources/KiwiModels/sj.morph`
- `Contents/Resources/KiwiModels/typo.dict`
- `Contents/Resources/en.lproj/InfoPlist.strings`
- `Contents/Resources/ko.lproj/InfoPlist.strings`

`woorilee/KiwiModels/*`는 Git LFS로 관리되는 실제 앱 번들용 모델입니다. 루트의 `KiwiModels/`는 참조용 또는 로컬 작업용 경로이며 앱 타깃의 실제 리소스 경로가 아닙니다.

## 처음 설정하기

처음 clone할 때는 Kiwi 서브모듈까지 함께 받아야 합니다.

```sh
git clone --recurse-submodules <repository-url>
cd open-woorilee
git lfs pull
git -C Kiwi lfs pull
scripts/prepare-kiwi-artifacts.sh
```

이미 서브모듈 없이 clone했다면 다음 명령으로 서브모듈과 LFS 아티팩트를 준비합니다.

```sh
git submodule update --init --recursive
git lfs pull
git -C Kiwi lfs pull
scripts/prepare-kiwi-artifacts.sh
```

`scripts/prepare-kiwi-artifacts.sh`는 다음을 확인합니다.

- `Kiwi/bindings/swift/Artifacts/CKiwi.xcframework` 존재 여부
- `woorilee/KiwiModels/` 아래 필수 모델 파일 존재 여부

루트에 `Kiwi.xcframework`가 있다면 스크립트가 `Kiwi/bindings/swift/scripts/prepare-ckiwi-xcframework.sh`를 호출해 `CKiwi.xcframework`로 변환할 수 있습니다. 더 자세한 Kiwi 아티팩트 준비 절차는 `docs/kiwi-artifacts.md`를 참고하세요.

## 빌드

스킴과 타깃 확인:

```sh
xcodebuild -list -project woorilee.xcodeproj
```

Debug 빌드:

```sh
xcodebuild -project woorilee.xcodeproj \
  -scheme woorilee \
  -configuration Debug \
  build
```

기본 빌드 산출물은 `build/Debug/woorilee.app`에 생성됩니다.

## 테스트

전체 유닛 테스트:

```sh
xcodebuild -project woorilee.xcodeproj \
  -scheme woorilee \
  -destination 'platform=macOS,arch=arm64' \
  test
```

특정 테스트 클래스:

```sh
xcodebuild -project woorilee.xcodeproj \
  -scheme woorilee \
  -destination 'platform=macOS,arch=arm64' \
  test \
  -only-testing:woorileeTests/InputEventPolicyTests
```

특정 테스트 메서드:

```sh
xcodebuild -project woorilee.xcodeproj \
  -scheme woorilee \
  -destination 'platform=macOS,arch=arm64' \
  test \
  -only-testing:woorileeTests/InputEventPolicyTests/testPrintableASCIICharacterUsesEventCharacters
```

입력 로직을 바꿨다면 빌드와 테스트 외에도 실제 호스트 앱에서 다음 동작을 확인해야 합니다.

- 한글 조합과 확정
- `Backspace`, `Space`, `Return`, `Escape`, `Tab`
- 화살표와 이동 명령이 조합 중 텍스트를 올바르게 확정하는지
- 선택 영역 위에 입력할 때 기존 선택을 정확히 대체하는지
- `markedRange`와 `replacementRange`가 Safari, TextEdit, Terminal 등에서 깨지지 않는지

## 로컬 설치

`woorilee.xcscheme`에는 빌드 후 `scripts/install-built-input-method.sh`를 실행하는 post-action이 있습니다. 다만 현재 스크립트는 기본값으로 설치를 건너뜁니다. 빌드 산출물을 `/Library/Input Methods/`에 설치하려면 명시적으로 opt-in해야 합니다.

```sh
WOORILEE_INSTALL_BUILT_INPUT_METHOD=1 xcodebuild -project woorilee.xcodeproj \
  -scheme woorilee \
  -configuration Debug \
  build
```

설치 스크립트는 다음 순서로 동작합니다.

1. 실행 중인 `woorilee` 프로세스를 `killall`로 종료
2. 기존 `/Library/Input Methods/woorilee.app` 제거
3. 빌드된 `.app` 번들을 `ditto`로 복사
4. 권한이 부족하면 `osascript`로 관리자 권한을 요청

설치를 명시적으로 막으려면 다음 중 하나를 사용합니다.

```sh
WOORILEE_SKIP_INSTALL=1 xcodebuild -project woorilee.xcodeproj -scheme woorilee build
WOORILEE_INSTALL_BUILT_INPUT_METHOD=0 xcodebuild -project woorilee.xcodeproj -scheme woorilee build
```

앱 번들 복사는 `cp -R`보다 `ditto`를 우선합니다. macOS 입력기는 실행 중인 번들이 교체되면 새 번들을 바로 인식하지 못할 수 있으므로 수동 설치를 하더라도 먼저 `killall woorilee`를 실행하세요.

## 런타임 구조

실행 흐름은 다음과 같습니다.

1. `woorilee/main.swift`가 `NSManualApplication.shared` 실행
2. `AppDelegate.applicationDidFinishLaunching`에서 `IMKServer` 생성
3. `Info.plist`의 `InputMethodConnectionName`과 `InputMethodServerControllerClass`를 통해 IMK가 `InputController` 생성
4. `InputController`가 IMK 이벤트를 받아 세션과 서비스로 위임
5. `InputSession`과 `InputCompositionEngine`이 marked text, replacement range, commit을 처리
6. `HanjaServiceCoordinator`가 한자 메뉴, 후보 패널, Kiwi/Hanja 웜업, 실시간 변환을 조정

`InputMethodConnectionName` 값과 `AppDelegate.swift`의 `IMKServer(name:...)` 인자는 항상 일치해야 합니다. `InputMethodServerControllerClass`는 `InputController`를 가리켜야 합니다.

`InputController`, `AppDelegate`, `InputSession`, `HanjaServiceCoordinator`는 메인 액터 전제 코드입니다. Kiwi/Hanja 웜업과 사용 통계 파일 I/O 같은 작업은 백그라운드에서 실행한 뒤 `@MainActor` 경로로 돌아오는 기존 패턴을 유지해야 합니다.

## 한자 변환 데이터

한자 변환은 세 종류의 데이터를 함께 사용합니다.

- 번들 사전: `woorilee/data/hanja/hanja.txt`
- 빈도 사전: `woorilee/data/hanja/freq-hanja.txt`, `woorilee/data/hanja/freq-hanjaeo.txt`
- 사용자 데이터: Application Support 아래의 사용자 한자 항목과 사용 빈도 JSON

런타임 경로와 파일명은 `woorilee/AppRuntimePaths.swift`에 모여 있습니다. 후보 랭킹에 쓰이는 Codable 모델은 `woorilee/HanjaPersonalizationModels.swift`, 사용 빈도 저장소는 `woorilee/HanjaUsageStore.swift`, 사용자 사전 저장소는 `woorilee/UserHanjaStore.swift`가 담당합니다.

## 작업 원칙

- 입력기 실행 흐름을 일반 AppKit 앱 구조로 바꾸지 않습니다.
- 새 IMK 코드는 가능하면 `IMKSwift` 추상화를 먼저 사용합니다.
- raw `InputMethodKit` 호출이 필요하면 왜 우회가 필요한지 코드나 설명에 남깁니다.
- `InputController`에 조합 상태를 새로 저장하지 않습니다. 상태는 `InputSessionCache`와 `InputSession` 경계에 둡니다.
- `insertText`, `setMarkedText`, `unmarkText`, `selectedRange`, `markedRange` 관련 변경은 아주 좁게 유지합니다.
- `Kiwi`, `IMKSwift`, `LibHangul` 자체 수정은 마지막 수단입니다.
- `DerivedData/`, `DerivedDataPlan/`, `.xcode-home/`, `.xcode-swiftpm-modulecache/`는 생성물/캐시이므로 수정하지 않습니다.

작업 트리가 Xcode 생성물로 지저분해질 수 있으므로 상태 확인은 필요한 경로로 좁히는 편이 좋습니다.

```sh
git status --short -- AGENTS.md CLAUDE.md README.md woorilee woorilee.xcodeproj docs scripts
git diff -- README.md woorilee woorilee.xcodeproj docs scripts
```

## 참고 문서

- `AGENTS.md`: 이 저장소에서 코딩 에이전트가 지켜야 할 한국어 작업 지침
- `CLAUDE.md`: 영어로 정리된 빠른 온보딩 문서
- `docs/internal-module-map.md`: 현재 입력기 런타임 모듈 경계
- `docs/runtime-resource-inventory.md`: 번들 리소스와 설치 동작의 기준
- `docs/refactor-parity-checklist.md`: 구조 변경 후 유지해야 하는 빌드/리소스/IME 동작 체크리스트
- `docs/kiwi-artifacts.md`: Kiwi 서브모듈과 `CKiwi.xcframework` 준비 절차
