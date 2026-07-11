# hanja-context — 단계 5a/5b 오프라인 데이터 파이프라인

`docs/plans/context-aware-hanja-conversion.md` §7(단계 5) 5a의 Python 절반:
표적 읽기·앵커 단어 인벤토리를 만들고, 한국어 위키백과 코퍼스에서 문맥 신호
후보 문장(병기 / 앵커 공기)만 걸러 낸다. 형태소 분석·카운트 집계는 이 리포의
Swift 수집기(로컬 Kiwi 패키지 러너 — 단계 5a의 나머지 절반)가 이어받는다.

Python 3.14 표준 라이브러리만 사용한다(서드파티 금지 — 특히 `kiwipiepy` 금지,
계획서 §7 5a 작업 1). 대용량 중간 산출물은 woorilee 리포가 아니라
`/Volumes/Workbench/wooriHanjaModel/work/hanja-context/`에 쓴다(해당 리포
`.gitignore`가 `work/`를 무시).

## 재현: 실행 명령

woorilee 리포 루트에서, 아래 순서대로:

```sh
# 1. 표적 읽기 인벤토리 (targets.tsv)
python3 scripts/hanja-context/build_targets.py

# 2. 앵커 단어 인벤토리 (anchors.tsv — targets.tsv 필요)
python3 scripts/hanja-context/build_anchors.py

# 3. 코퍼스 추출·필터링 — 먼저 ~200MB로 처리율 측정
python3 scripts/hanja-context/extract_and_filter.py --limit-bytes 200000000
#    전체 실행 (실측 약 5분, 21~24MB/s; 오래 걸리면 백그라운드로)
python3 scripts/hanja-context/extract_and_filter.py

# 4. Swift 수집기(collector/)로 counts/{anchor,paren,dict}-counts.tsv 생성 후,
#    5b 연관표 산출 (Python, counts/*.tsv만 입력 — 형태소 분석 없음):
python3 scripts/hanja-context/build_association_table.py
```

산출물 위치 (`/Volumes/Workbench/wooriHanjaModel/work/hanja-context/`):

| 경로 | 내용 |
| --- | --- |
| `inventory/targets.tsv` | 표적 읽기 3,008건 — `읽기<TAB>총빈도<TAB>후보:빈도,…` (빈도 내림차순), `#` 헤더에 파라미터·카운트 |
| `inventory/anchors.tsv` | 앵커 39,095행 — `표적읽기<TAB>후보한자<TAB>앵커읽기<TAB>앵커한자<TAB>앵커빈도` |
| `filtered/part-NNNN.txt` | 필터 통과 문장 — `종류<TAB>문장` (종류 ∈ `paren`/`anchor`/`both`), 20만 행마다 파일 교체 |
| `extract-stats.json` | 페이지/문장 카운트, 평가 27계열 게이트 프리뷰 표, thin-signal 플래그 |
| `extract.log` | 진행 로그(5만 페이지마다 처리율·ETA), `START`/`FINISHED` 요약 |
| `DONE` | 전체 패스 무중단 완료 마커(부분 실행에서는 생성 안 됨) |

## 코퍼스 정체 (재현성)

- 파일: `/Volumes/Workbench/wooriHanjaModel/data/kowiki-latest-pages-articles.xml`
  — 한국어 위키백과 `pages-articles` 덤프의 압축 해제본, 6,309,195,011 bytes.
- 덤프 출처: https://dumps.wikimedia.org/kowiki/ (`kowiki-latest-pages-articles.xml.bz2`),
  파일 날짜 2026-06-29.
- 포맷: MediaWiki export-0.11 — **모든 태그가 네임스페이스 한정**
  (`{http://www.mediawiki.org/xml/export-0.11/}page` 등). `dbname` kowiki,
  `generator` MediaWiki 1.47.0-wmf.4.
- 라이선스: CC BY-SA. 산출물은 원문 복원이 불가능한 문장 단위 발췌·통계
  집계이며 출처(한국어 위키백과)를 명기한다. 계획서 §7 "라이선스·재현성" 절
  대로 덤프 버전·URL을 여기와 산출물 헤더에 기록한다.
- 단일 소스 원칙: 코퍼스는 위키백과 하나로 시작한다(다변화 금지 — 계획서 §8).

## 형태소 공간 계약 (Swift 수집기·런타임과 일치해야 함)

연관표 피처는 형태소 표면형 공간이므로, 오프라인 수집과 런타임 재랭킹이
정확히 같은 엔진·모델·옵션을 써야 한다(어긋나면 조용히 무력화 — 계획서 §7 5a
작업 1). 계약:

- Kiwi: 로컬 벤더 패키지 `Kiwi/bindings/swift`, 버전 **v0.23.1-3-g93b826f**
- 모델: `woorilee/KiwiModels` (앱이 번들하는 그 디렉터리)
- 분석 옵션: `[.allWithNormalizing, .joinNounPrefix, .joinNounSuffix]`
- topN = 1 (수집기 기준; 런타임 `analyzeClause`는 topN=3에서 최적 분석 선택)
- 내용 형태소 태그: `NNG, NNP, VV, VVI, VA, VAI, MAG, XR`
- 피처 키: `form/TAG` (표면형 + 태그)

`kiwipiepy`는 자체 엔진·자체 배포 모델을 쓰므로 이 계약을 만족하지 못한다 —
사용 금지.

## 인벤토리 파라미터

`build_targets.py` (targets.tsv):

- 표적 = "지배 매핑이 성립하지 않는(모호한)" 읽기. 지배 판정은 런타임
  `buildDominantHanjaMap`(`woorilee/HanjaContextRanker.swift`)과 동일:
  후보가 1개이거나, 디코딩 빈도 1위 ≥ **5**(dominance ratio) × 2위
  (2위 빈도 0이면 지배로 침).
- 빈도: `freq-hanja.txt` raw + `freq-hanjaeo.txt` `% 1_000_000` 디코딩,
  중복 키는 max 병합 — 런타임 `HanjaFrequencyTable`과 동일
  (`hanja_common.py`가 양쪽 로직을 미러링).
- 최소 읽기 길이 **2**, 총 디코딩 빈도 상위 **3,000**개로 절단.
- 평가셋(`eval/hanja-context-eval-set.tsv`) 27계열은 **강제 포함**
  (컷오프 밖 8계열: 정도, 공사, 지방, 시장, 소화, 장관, 선물, 대전 →
  총 3,008 표적).

`build_anchors.py` (anchors.tsv):

- 앵커 조건: (i) 앵커 한자가 후보 한자를 **진부분 문자열**로 포함
  (예: 上水道 ⊃ 水道), (ii) `dominant_map[앵커읽기] == 앵커한자`
  (앵커 자신의 읽기가 비모호), (iii) 디코딩 앵커 단어 빈도 ≥ **1**.
- 39,095행. 스팟체크: 수도 → 水道←30개, 修道←25개, 首都←1개(수도권뿐).

`extract_and_filter.py` (filtered/):

- 단일 스트리밍 패스(`xml.etree.ElementTree.iterparse`, 페이지마다
  `elem.clear()`) — 6.3GB를 메모리에 올리지 않는다. 필터 통과 문장만 쓴다
  (무필터 코퍼스 저장 금지).
- 페이지 필터: `<ns>0</ns>`만, `<redirect>` 있으면 제외.
- 마크업 제거: 중첩 `{{…}}`·`{|…|}` 균형 제거, `<ref>`(쌍/자기닫힘),
  비산문 태그 내용(`<math>`·`<code>`·`<gallery>` 등), 잔여 `<…>` 태그,
  `[[파일:…]]`/`[[분류:…]]`(중첩 포함) 전체 삭제, `[[a|b]]`→`b`/`[[a]]`→`a`,
  인용부호(`'''`/`''`), `==…==` 제목 행, 목록 마커, 표 잔재 행, bare URL,
  `html.unescape`.
- 문장 분할: 개행 + `(?<=[.!?])\s+`, 공백 정규화 후 **10자 이상** + 한글 포함.
- 채택 조건(하나라도):
  - **병기(paren)**: `한글(漢字)` 패턴 중, 한글 연쇄의 끝 접미사 s
    (len(s)==len(한자열))가 `hanja.txt`에 `(s, 한자열)`로 실재하고 s가
    표적 읽기인 경우만 유효.
  - **앵커(anchor)**: anchors.tsv의 앵커 읽기(중복 제거 34,038종) 중 1개
    이상을 부분 문자열로 포함 — 사전 기반 트라이(시작 위치마다 최장 일치
    후 그 뒤로 전진, flashtext 방식).
- 출력 행: `종류<TAB>문장`, 종류 ∈ `paren` / `anchor` / `both`.

## NIKL 사전 데이터 (보고 전용 — 통합 안 함)

`/Volumes/Workbench/wooriHanjaModel/data/korean-dict-nikl/`(읽기 전용
서브모듈)은 코퍼스(위키백과 단일 소스 원칙, 계획서 §8)에는 통합하지 않는다.
라이선스: NIKL 3사전(표준국어대사전·우리말샘·한국어기초사전)은 2019-03-11부터
CC-BY-SA 2.0 KR — 단, **예문 중 출판물 인용분과 미디어 파일은 오픈소스가
아니며 재배포 불가**(해당 리포 README의 저작권 주의). 쓰더라도 원문 재배포
없는 집계 통계까지만 허용된다. `extract_nikl_defs.py`가 뜻풀이(예문 제외)만
`counts/dict-counts.tsv`로 추출했고, 이 보조 신호는 **사용자 승인**을 받아
아래 5b 연관 점수화의 세 번째 신호(고정밀 직접 라벨)로 참여한다 — 코퍼스가
아니라 사전 뜻풀이 집계이므로 단일 소스 원칙과 무관하다.

## 단계 5b — 연관표 산출 (`build_association_table.py`)

`counts/{anchor,paren,dict}-counts.tsv` + `inventory/targets.tsv`만 입력으로
받는다 — **형태소 분석 없음**(5a에서 이미 `form/TAG` 피처 공간이 고정됨),
순수 카운트 수학, Python 3.14 표준 라이브러리만 사용.

```sh
python3 scripts/hanja-context/build_association_table.py
# 파라미터 override:
python3 scripts/hanja-context/build_association_table.py \
  --paren-weight 20 --dict-weight 20 --min-anchor-survival 5 --alpha 0.5 \
  --top-m 300 --eval-floor-count 30 --max-feature-df-count 662
```

- **4번째 신호 — 연어(collocation)** (`--colloc-counts`/`--colloc-weight`,
  기본 가중치 20): `build_collocation_counts.py`가 krdict 파생어(RelatedForm)
  관계에서 추출한 (읽기,한자,후행 용언 어간) 연어를 플래그 읽기(단계 7)
  한정으로 추가 신호원으로 통합한다. 사전 등재 근거이므로 해당 행만
  ubiquity 필터 면제(예: 고장:故障의 나/VV). 상세는
  `docs/plans/context-aware-hanja-conversion.md` §10 7b.

- 신호 결합: `weighted = anchor + W_paren·paren + W_dict·dict` (기본 20/20).
- 생존 규칙: `anchor_count>=5` OR `paren_count>=1` OR `dict_count>=1` (병기·
  사전 직접 라벨 신호는 앵커의 최소 카운트 5 문턱 면제 — thin 후보 보존).
- 점수: 읽기 내부 대조 스무딩 로그오즈(α=0.5), `score>0`만 유지 — 불용어
  목록 없이 일반 형태소(하/있/되 등)를 자동으로 걸러낸다.
- **선별(selection)은 점수가 아니라 효용** `utility = score × ln(1+가중카운트)`
  기준 상위 M — 순수 점수 선별은 희귀-완벽 피처(수돗물·뱃길)가 흔한-변별
  피처(집·물·서울)를 밀어내는데, 런타임 문맥 형태소는 일상 어휘이므로
  증거량(가중카운트)을 곱해 선별한다. **기록·양자화되는 가중치는 여전히
  순수 대조 점수**(선별 기준만 다름).
- **eval-27 증거 플로어**: 평가셋 27계열 읽기에 한해, 효용 상위 M 외에도
  `가중카운트 ≥ 30 AND score ≥ ln 2`인 생존 피처를 순위 무관하게 유지
  (`--eval-floor-count`, 0이면 비활성). 어휘가 큰 후보(水道·首都)에서 흔한
  정답 프로브(집·관·나라·정부)가 M 밖으로 밀리는 것을 막는 최소 표적 교정.
  min-score 가드는 대조 미미한 일반 동사(하/있/되)의 재유입 방지용.
- 후보별 상위 M(기본 300)로 프루닝 후 전역 최댓값 기준 1~255 선형 양자화.
  8MB 상한 초과 시 M→200→100, 후보 총가중치<3 드롭, 비-eval27 읽기 총빈도
  오름차순 드롭 순서로 재산출(실측: M=100에서 캡 이하로 수렴, 이후 단계
  불필요 — 상세는 `docs/plans/hanja-context-5b-report.md`).
- **데이터 품질 후속 수정 — ubiquity(IDF식) 필터** (`--max-feature-df-count`,
  기본 662 — 절대 DF 상수, 표적 인벤토리 확장에 실효 컷오프가 느슨해지는
  회귀를 막기 위해 비율(0.039)에서 절대값으로 전환됐다(§10 7b 참고), 0이면
  비활성): 위 within-reading 대조는 형태소 자체가 아니라
  **코퍼스 도메인 편향** 때문에 특정 후보에서만 살아남는 피처(예: 修道
  앵커 문장은 서사체, 水道 앵커 문장은 기술체라서 生존한 나/VV=40)를 잡지
  못한다. 각 피처의 **프로필 문서빈도(profile DF)** — 생존필터 통과 직후,
  프루닝 이전의 (읽기,후보) 프로필 중 그 피처가 등장하는 비율 — 을 계산해
  VV/VA(-I) 태그 피처 중 DF가 문턱을 넘는 것을 전역 배제한다(점수 계산에도
  전혀 참여하지 않음 — 계산된 불용어 목록과 동등). **VV/VA로 범위를 좁힌
  이유**: 실측 DF 분포가 태그 무관 단일 문턱으로는 절대 분리되지 않는다
  — 나라/NNG(6.09%)·정부/NNG(6.00%) 같은 필수 유지 프로브가 감사 대상
  오/VV(6.04%)보다 DF가 높다(집·물·관·서울 등도 마찬가지 대역). 반면
  감사 대상 전부(하·있·되·나·오·보·들, 전부 VV/VA)와 반례로 남아야 하는
  희귀 변별 동사(틀/VV 0.11%·얼/VV 0.45%)는 모두 VV/VA 태그이므로, 그
  태그로만 범위를 좁히면 확실한 문턱(0.039 = 3.9%)이 존재한다. 상세 —
  측정된 DF 분포, 선택 근거, 제거된 피처 예시 — 는
  `docs/plans/hanja-context-5b-report.md` 개정 3.
- 산출물: `woorilee/data/hanja/hanja-context.txt`
  (`읽기:한자:형태소=가중치,형태소=가중치,...`, `/`는 안전 — TAG에 `/` 없어
  Swift 쪽에서 마지막 `/` 기준 split이면 충분; `:`,`,`,`=`,`%`는 퍼센트
  인코딩) + `counts/association-stats.json`.
- 실측(개정 3 — ubiquity 필터 적용 후): M=100 + 플로어 + ubiquity 필터에서
  7,648,546 B (7.29 MiB) / 캡 8 MiB, 수도 교차 후보 스팟체크 9/9 PASS,
  하/있/되/나/오/보 수도 계열에서 전부 부재 확인.
- 5b 게이트 보고: `docs/plans/hanja-context-5b-report.md` (스팟체크·thin
  새니티·크기·재현 명령; 개정 3에 ubiquity 필터 추가).
