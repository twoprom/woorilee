# Sparkle 업데이트 릴리스 워크플로우

이 문서는 `woorilee` 입력기를 Sparkle(2.x)로 배포하는 전체 릴리스 절차를 정리한다.
나중에 AI가 이 문서만 보고 **반자동으로** 릴리스를 수행할 수 있도록 명령·경로·검증 단계를
구체적으로 기록한다.

> **사람이 직접 하는 일은 단 두 가지다:**
> 1. 새 버전 번호(마케팅 버전 / 빌드 번호) 결정
> 2. **릴리스 노트(한국어) 작성**
>
> 그 외 빌드·서명·업로드·appcast 갱신·검증은 이 문서의 절차대로 자동화 가능하다.

---

## 0. 핵심 상수 (machine-readable)

릴리스 자동화에 필요한 고정값. `woorilee/Info.plist`, `woorilee.xcodeproj/project.pbxproj`,
`appcast.xml`에서 도출된 현재 값이다.

| 항목 | 값 | 출처 |
| --- | --- | --- |
| 번들 ID | `com.twoprom.inputmethod.woorilee` | `PRODUCT_BUNDLE_IDENTIFIER` |
| 제품(.app) 이름 | `woorilee.app` | `PRODUCT_NAME = $(TARGET_NAME)` |
| 표시 이름 | `우리입력기` | `CFBundleName` |
| Sparkle 피드 URL | `https://raw.githubusercontent.com/twoprom/woorilee/main/appcast.xml` | `SUFeedURL` |
| Sparkle 공개키(EdDSA) | `Ob4uan3xQfQ9+52MEBSMCyvZIjRnAUBtg0lQGbQxL7Y=` | `SUPublicEDKey` |
| 자동 업데이트 확인 | **꺼짐** (`SUEnableAutomaticChecks = false`) | `Info.plist` |
| appcast 파일 위치 | 저장소 루트 `appcast.xml`, **`main` 브랜치** | 피드 URL이 `main`의 raw를 가리킴 |
| GitHub 저장소 | `https://github.com/twoprom/woorilee` | `git remote origin` |
| 릴리스 태그 형식 | `v{마케팅버전}` (예: `v1.0.4`) | 기존 릴리스 |
| 배포 에셋 이름 | `woorilee.zip` (GitHub Release 첨부) | `appcast.xml` enclosure |
| 에셋 다운로드 URL 형식 | `https://github.com/twoprom/woorilee/releases/download/v{버전}/woorilee.zip` | enclosure url |
| EdDSA 개인키 위치 | 로그인 키체인, 항목 라벨 `Private key for signing Sparkle updates` | `sign_update`가 자동 사용 |
| Sparkle 버전 | 2.9.1 (SPM) | `Package.resolved` |
| 최소 OS | `26.0` (`sparkle:minimumSystemVersion`) | `appcast.xml` |

> 위 상수 중 하나라도 코드에서 바뀌면(예: 피드 URL, 공개키, 번들 ID) **이 표를 먼저 갱신**하라.

### Sparkle CLI 도구 위치

`sign_update`, `generate_appcast`는 Sparkle SPM 아티팩트에 포함되어 있고, 한 번 빌드하면
저장소 로컬 `DerivedData/`에 풀린다. 경로는 환경에 따라 달라질 수 있으므로 다음처럼 탐색한다.

```sh
# 저장소 루트에서 실행
SIGN_UPDATE="$(find DerivedData ~/Library/Developer/Xcode/DerivedData \
  -path '*sparkle*/bin/sign_update' 2>/dev/null | head -1)"
GEN_APPCAST="$(find DerivedData ~/Library/Developer/Xcode/DerivedData \
  -path '*sparkle*/bin/generate_appcast' 2>/dev/null | head -1)"
echo "$SIGN_UPDATE"   # 비어 있으면 먼저 한 번 빌드해서 SPM 아티팩트를 받아라
```

---

## 1. 사전 점검 (자동화가 시작 전에 확인할 것)

```sh
# (a) 작업 트리가 깨끗한가
git -C /Volumes/Workbench/woorilee status --short -- woorilee woorilee.xcodeproj appcast.xml

# (b) gh CLI 인증 여부
gh auth status

# (c) EdDSA 개인키가 키체인에 있는가 (있으면 attributes 출력)
security find-generic-password -l "Private key for signing Sparkle updates" >/dev/null 2>&1 \
  && echo "signing key: OK" || echo "signing key: MISSING (릴리스 중단)"

# (d) Sparkle 도구가 풀려 있는가 (없으면 1회 빌드 필요)
test -n "$SIGN_UPDATE" && echo "sign_update: $SIGN_UPDATE" || echo "sign_update: 빌드 후 재탐색"
```

전제:

- 릴리스는 **`main` 브랜치 기준**으로 한다. appcast 피드가 `main`의 raw를 읽기 때문이다.
  개발은 `develop`에서 하므로, 배포할 코드는 먼저 `main`에 병합되어 있어야 한다.
- 위 (a)~(d) 중 하나라도 실패하면 진행을 멈추고 사람에게 보고한다.

---

## 2. 사람 입력값 수집

릴리스를 시작하기 전에 사람에게 다음을 받는다.

1. **마케팅 버전** — `CFBundleShortVersionString`. 예: `1.0.4` (사용자에게 보이는 버전, SemVer)
2. **빌드 번호** — `CFBundleVersion` / `sparkle:version`. **단조 증가하는 정수**. 현재 `105` → 다음 `106`.
   Sparkle는 이 정수로 신/구를 비교하므로 **반드시 이전보다 커야 한다.**
3. **릴리스 노트(한국어)** — 사람이 작성. appcast `<item>`의 `<description>`에 HTML/CDATA로 들어간다.
   예시 형식:
   ```html
   <h3>1.0.4</h3>
   <ul>
     <li>형태소 경계 조정(Shift+←/→) 안정화</li>
     <li>후보창 위치 계산 개선</li>
   </ul>
   ```

아래 절차에서는 예시로 `MARKETING=1.0.4`, `BUILD=106`을 사용한다. 실제 값으로 치환할 것.

```sh
MARKETING=1.0.4
BUILD=106
TAG="v${MARKETING}"
```

---

## 3. 버전 번호 올리기

`woorilee.xcodeproj/project.pbxproj`에서 **앱 타깃**의 Debug/Release 두 구성 모두에
`MARKETING_VERSION`과 `CURRENT_PROJECT_VERSION`이 각각 2번씩 나온다(테스트 타깃 값은 건드리지 않는다).

현재 값 확인:

```sh
grep -nE 'MARKETING_VERSION|CURRENT_PROJECT_VERSION' woorilee.xcodeproj/project.pbxproj
```

앱 타깃의 4줄(MARKETING ×2, CURRENT_PROJECT ×2)을 새 값으로 수정한다. 테스트 타깃은
`MARKETING_VERSION = 1.0; CURRENT_PROJECT_VERSION = 1;`로 별도이므로 **변경 금지**.
앱 타깃만 바꾸려면 현재 값(`1.0.3` / `105`)을 기준으로 치환하는 것이 안전하다.

```sh
# 앱 타깃의 기존 값(1.0.3 / 105)만 정확히 치환 (테스트 타깃은 1.0 / 1 이라 영향 없음)
sed -i '' "s/MARKETING_VERSION = 1\.0\.3;/MARKETING_VERSION = ${MARKETING};/g" woorilee.xcodeproj/project.pbxproj
sed -i '' "s/CURRENT_PROJECT_VERSION = 105;/CURRENT_PROJECT_VERSION = ${BUILD};/g" woorilee.xcodeproj/project.pbxproj

# 검증: 앱 타깃 두 구성에 새 값이 들어갔는지
grep -nE "MARKETING_VERSION = ${MARKETING};|CURRENT_PROJECT_VERSION = ${BUILD};" woorilee.xcodeproj/project.pbxproj
```

> 치환 후 반드시 `grep`으로 **정확히 2개씩** 바뀌었는지 확인한다. 다음 릴리스를 위해
> 위 `sed`의 "기존 값"은 매번 직전 릴리스 버전으로 바꿔야 함을 기억할 것.

---

## 4. 릴리스 빌드 (Release 구성)

배포용은 **Release 구성**으로 빌드한다. 로컬 입력기를 건드리지 않도록
`WOORILEE_INSTALL_BUILT_INPUT_METHOD`는 **설정하지 않는다**(설치 PostAction은 기본적으로 skip).
이것은 개발 빌드 규칙(항상 install opt-in)과 다른, 릴리스 빌드의 의도된 예외다.
`WOORILEE_SKIP_INSTALL=1` / `...=0`은 여전히 쓰지 않는다.

```sh
# 깨끗한 산출물 위치를 위해 전용 derivedDataPath 사용
xcodebuild -project woorilee.xcodeproj -scheme woorilee \
  -configuration Release -derivedDataPath build clean build

APP="build/Build/Products/Release/woorilee.app"
test -d "$APP" && echo "built: $APP" || { echo "빌드 실패"; exit 1; }
```

빌드 검증:

```sh
# 번들 버전이 의도대로 박혔는지
/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist"  # = $MARKETING
/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist"             # = $BUILD

# 코드 서명이 유효한지 (현재는 Apple Development 서명 — 6장 한계 참조)
codesign --verify --deep --strict --verbose=2 "$APP"
```

---

## 5. 배포용 zip 생성

Sparkle 압축본은 반드시 `ditto`로 만들어 번들 구조·심볼릭링크·서명을 보존한다.
`zip` 명령은 쓰지 말 것(서명 깨짐).

```sh
ditto -c -k --sequesterRsrc --keepParent "$APP" build/woorilee.zip
ls -l build/woorilee.zip
```

---

## 6. EdDSA 서명 (sign_update)

`sign_update`는 키체인에서 개인키를 자동으로 읽는다. 출력된
`sparkle:edSignature`와 `length`를 그대로 appcast enclosure에 넣는다.

```sh
"$SIGN_UPDATE" build/woorilee.zip
# 출력 예:
#   sparkle:edSignature="....=" length="100437143"
```

이 값을 변수로 잡아두면 appcast 작성이 쉽다(파싱 예):

```sh
SIGN_OUT="$("$SIGN_UPDATE" build/woorilee.zip)"
ED_SIG="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$SIGN_OUT")"
LENGTH="$(sed -n 's/.*length="\([^"]*\)".*/\1/p'  <<<"$SIGN_OUT")"
echo "edSignature=$ED_SIG"; echo "length=$LENGTH"
```

---

## 7. GitHub Release 생성 및 에셋 업로드

appcast의 enclosure URL이 가리키는 곳이므로 **appcast를 push하기 전에 먼저** 릴리스를 만든다.
릴리스 노트는 2장에서 사람이 작성한 내용을 파일로 넘긴다.

```sh
# 릴리스 노트(GitHub Release 본문용) — 사람이 작성한 텍스트
NOTES_FILE=build/release-notes-${MARKETING}.md   # 사람이 채운 파일

gh release create "$TAG" build/woorilee.zip \
  --repo twoprom/woorilee \
  --title "$TAG" \
  --notes-file "$NOTES_FILE"

# 업로드 검증: 다운로드 URL이 200이고 크기가 length와 일치하는지
URL="https://github.com/twoprom/woorilee/releases/download/${TAG}/woorilee.zip"
curl -sIL "$URL" | grep -iE "HTTP/|content-length"
```

> 첫 정식 릴리스가 아니라 사전 공개라면 `--prerelease`를 붙인다(기존 1.0.1/1.0.2가 prerelease였다).
> Sparkle 사용자에게 노출하려면 정식(latest) 릴리스로 두는 것이 일반적이다.

---

## 8. appcast.xml 갱신

`appcast.xml` 최상단(`<channel>` 바로 아래)에 새 `<item>`을 **추가**한다(기존 항목은 보존).
`pubDate`는 RFC 822 형식, 타임존은 `+0900`.

새 item 템플릿:

```xml
        <item>
            <title>1.0.4</title>
            <pubDate>Sat, 27 Jun 2026 21:00:00 +0900</pubDate>
            <sparkle:version>106</sparkle:version>
            <sparkle:shortVersionString>1.0.4</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
            <description><![CDATA[
                <!-- 사람이 작성한 릴리스 노트(HTML) -->
                <h3>1.0.4</h3>
                <ul>
                  <li>...</li>
                </ul>
            ]]></description>
            <enclosure
                url="https://github.com/twoprom/woorilee/releases/download/v1.0.4/woorilee.zip"
                length="여기에 sign_update의 length"
                type="application/octet-stream"
                sparkle:edSignature="여기에 sign_update의 edSignature"/>
        </item>
```

자동화 시 채워야 할 값:
- `title` / `sparkle:shortVersionString` ← `$MARKETING`
- `sparkle:version` ← `$BUILD`
- `pubDate` ← `date "+%a, %d %b %Y %H:%M:%S +0900"`
- `enclosure url` ← `$URL`
- `length` ← `$LENGTH`, `sparkle:edSignature` ← `$ED_SIG`
- `<description>` ← 사람이 작성한 릴리스 노트(HTML)

> **대안: `generate_appcast`** — Sparkle은 아카이브 디렉터리에서 appcast를 자동 생성·서명하는
> `generate_appcast`도 제공한다. 단 이 프로젝트는 enclosure가 GitHub Release URL을 가리키므로
> `--download-url-prefix`로 접두사를 지정해야 하고 릴리스 노트 연동 방식이 달라진다.
> 현재는 항목 수가 적고 결정적(deterministic)이라 **수동 편집 방식**을 표준으로 둔다.
> `generate_appcast`로 전환하려면 별도 검증 후 이 문서를 갱신할 것.

appcast 검증(로컬):

```sh
xmllint --noout appcast.xml && echo "appcast XML: OK"
grep -c "<item>" appcast.xml   # 항목 수가 1 늘었는지
```

---

## 9. 커밋·태그·push (`main` 기준)

피드는 `main`의 raw를 읽으므로 **버전 범프와 appcast는 `main`에 올라가야** 사용자에게 보인다.

```sh
# main에서 작업 중이라고 가정 (아니면 먼저 develop→main 병합)
git add woorilee.xcodeproj/project.pbxproj appcast.xml
git commit -m "release: ${MARKETING} (build ${BUILD})

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
git push origin main
```

태그는 보통 `gh release create`가 자동 생성한다(7장). 별도로 커밋에 태그를 맞추고 싶다면:

```sh
git tag -f "$TAG" && git push -f origin "$TAG"   # 릴리스 커밋을 정확히 가리키게 할 때만
```

(선택) 로컬 보관 관례 — 기존에 `releases/{버전}/`에 산출물을 보관해 왔다.

```sh
mkdir -p "releases/${MARKETING}"
cp build/woorilee.zip "releases/${MARKETING}/woorilee.zip"
```
> `releases/`는 용량이 크다. 저장소에 커밋할지 여부는 `.gitignore` 정책에 따른다(현재 추적 중이면
> 관례 유지, 아니면 로컬 보관만).

---

## 10. 최종 검증 (사용자 관점)

```sh
# (a) 피드가 새 버전을 노출하는가 (raw가 갱신 반영까지 수십 초~수 분 지연될 수 있음)
curl -sL "https://raw.githubusercontent.com/twoprom/woorilee/main/appcast.xml" \
  | grep -E "<sparkle:version>|shortVersionString"

# (b) enclosure가 실제 내려받기 가능한가 + 크기 일치
curl -sIL "$URL" | grep -iE "HTTP/|content-length"   # content-length == $LENGTH
```

앱에서의 확인: `우리입력기`는 **자동 업데이트 확인이 꺼져 있다**(`SUEnableAutomaticChecks=false`).
사용자는 **About 패널 → "업데이트 확인…"** 버튼([AboutWindowController.swift](../woorilee/AboutWindowController.swift))을
눌러야 갱신을 본다. 릴리스 직후 직접 눌러 새 버전 감지/다운로드/설치가 동작하는지 확인하는 것을 권장한다.

---

## 11. 서명·공증(notarization) 한계 — **중요**

> ⚠️ 현재 이 환경에는 **Developer ID Application 인증서가 없고**, 코드 서명 ID는
> `Apple Development` 하나뿐이다(`security find-identity -v -p codesigning` 기준).
> 따라서 빌드 산출물은 **Developer ID 서명이 아니며, Apple 공증(notarization)도 되어 있지 않다.**

함의:

- 다른 Mac에서 새로 내려받은 `.app`은 Gatekeeper/격리(quarantine) 때문에 차단되거나
  경고가 뜰 수 있다. 사용자가 수동으로 허용해야 할 수 있다.
- 정식 외부 배포 품질을 갖추려면 다음이 필요하다(현재 미구성):
  1. **Developer ID Application** 인증서 발급·설치
  2. Release 빌드를 Developer ID로 서명 (Hardened Runtime은 이미 `YES`)
  3. `xcrun notarytool submit build/woorilee.zip --keychain-profile <프로필> --wait`로 공증
  4. `xcrun stapler staple "$APP"` 후 다시 zip → 6장(sign_update)부터 재수행
- 위 4단계를 도입하려면 인증서·notarytool 키체인 프로필 같은 **환경 비밀값**이 필요하므로,
  AI가 임의로 진행하지 말고 **사람에게 자격 증명 구비 여부를 먼저 확인**한다.

이 한계가 해소(Developer ID + 공증 도입)되면 4~6장 사이에 공증 단계를 끼워 넣고 이 절을 갱신할 것.

---

## 12. 롤백 / 실수 복구

- **appcast만 잘못 올림**: `appcast.xml`에서 문제 item 제거 후 다시 commit/push. 사용자는
  최신 `sparkle:version`만 보므로, 직전 정상 버전 item이 최상위가 되도록 되돌린다.
- **잘못된 zip 업로드**: `gh release delete-asset "$TAG" woorilee.zip` 후 올바른 zip 재업로드.
  단 enclosure `length`/서명이 바뀌므로 appcast도 함께 갱신해야 한다.
- **릴리스 자체 취소**: `gh release delete "$TAG" --cleanup-tag` 후 appcast item 제거.
- **버전 번호를 잘못 올림**: pbxproj 되돌리고 재빌드. 이미 공개된 빌드 번호는 재사용 금지
  (Sparkle 비교가 깨진다) — 더 큰 번호로 새로 낸다.

---

## 13. AI 자동화 체크리스트 (요약)

```
[ ] 1. 사전 점검: 깨끗한 트리 / gh 인증 / 키체인 서명키 / sign_update 경로  (§1)
[ ] 2. 사람 입력 확보: MARKETING, BUILD(이전보다 큰 정수), 릴리스 노트(HTML)  (§2)
[ ] 3. pbxproj 버전 범프 — 앱 타깃 4줄, 테스트 타깃 제외, grep 검증  (§3)
[ ] 4. Release 빌드 (install opt-in 없이) + 번들 버전/서명 검증  (§4)
[ ] 5. ditto로 woorilee.zip 생성  (§5)
[ ] 6. sign_update → edSignature, length 확보  (§6)
[ ] 7. gh release create + zip 업로드, 다운로드 URL 200 확인  (§7)
[ ] 8. appcast.xml에 새 <item> 추가 + xmllint 검증  (§8)
[ ] 9. main에 commit & push (버전 범프 + appcast)  (§9)
[ ] 10. raw 피드/enclosure 최종 검증, About 패널에서 업데이트 확인  (§10)
[ ] 11. (해당 시) 공증 한계 사람에게 고지  (§11)
```
