---
name: ontology-map
description: release-diff의 Evidence 요약 테이블을 입력받아 온톨로지 파일과 매핑해 Feature Module별 cross-cutting 영향을 분석합니다. "/ontology-map", "온톨로지 매핑", "교차 영향 분석" 요청 시 사용합니다.
---

# /ontology-map — Feature Module 교차 영향 분석

## 목적

release-diff가 생성한 **Evidence 요약 테이블**을 온톨로지에 매핑해 두 가지를 도출한다.

1. **직접 변경 범위**: Evidence가 직접 매핑되는 Feature Module
2. **교차 영향 범위**: 여러 티켓이 같은 모듈을 동시에 건드리거나, Secondary 연동으로 함께 확인해야 하는 모듈

---

## 실행 전 확인

인자가 없으면 `AskUserQuestion`으로 한 번 묻는다.

```
question: "release-diff Evidence 요약 테이블을 Other에 붙여넣어 주세요. (또는 릴리스 번호만 입력하면 ontology-map이 직접 release-diff를 참조합니다)"
options:
  - label: "예시",  description: "| CVS-4249 | Story | High | ... |  ← Other에 테이블 전체 붙여넣기"
```

입력값이 순수 숫자이면 해당 릴리스의 release-diff 결과가 현재 대화에 있는지 먼저 확인한다.
없으면 "release-diff를 먼저 실행해 주세요"를 안내하고 중단한다.

---

## 온톨로지 파일 로드

분석 시작 전 온톨로지 파일을 1회 읽는다. 이후 재호출하지 않는다.

**온톨로지 파일 탐색**: 경로를 고정하지 않고 워크스페이스 전체에서 파일명으로 자동 탐색한다.

```bash
find . -name "integrated-qa-impact-ontology-v2.md" 2>/dev/null | head -1
```

탐색 결과가 있으면 해당 경로를 사용한다. 결과가 없으면 아래 안내를 출력하고 중단한다.

```
온톨로지 파일을 찾을 수 없습니다.
파일명 'integrated-qa-impact-ontology-v2.md'을 워크스페이스 어딘가에 배치한 뒤 다시 실행해 주세요.
```

---

## STEP 1: Evidence 파싱

입력받은 Evidence 요약 테이블을 파싱한다. release-diff 3-D가 출력하는 **정확한 형식**은 아래와 같다.

### 기대 입력 형식 (release-diff 3-D 출력과 동일)

```
## Evidence 요약 (온톨로지 매핑용)

| 티켓 | 타입 | 우선순위 | 파일/코드 위치 | 상태 | 기능 키워드 | 비고 |
|------|------|---------|--------------|------|-----------|------|
| CVS-XXXXX | Bug | High | Assets/SlotMaker/SlotManager.cs | Changed | SlotManager, SpinResult | |
| CVS-YYYYY | Story | Medium | src/logic/reward.ts | New | reward, settlement | |
| CVS-ZZZZZ | Task | Low | - | 미확인 | CVS.com, Xsolla, Facebook | ⚠️ 탐색 미완료 |
```

### 컬럼 정의 (7개 고정, `|` 구분 마크다운 테이블)

| # | 컬럼명 | 파싱 용도 | 값 예시 |
|---|--------|---------|--------|
| 1 | 티켓 | 티켓 식별자 — 파싱 기준 키 | `CVS-13255` |
| 2 | 타입 | Bug 우선 처리 판단 | `Bug` / `Story` / `Task` / `Development` |
| 3 | 우선순위 | 매핑 정렬 | `High` / `Medium` / `Low` |
| 4 | 파일/코드 위치 | 1순위 매핑 입력 (경로) | `Assets/Scripts/Slot/SlotManager.cs` 또는 `-` |
| 5 | 상태 | Evidence 확정 여부 | `Changed` / `New` / `Removed` / `Unchanged` / `미확인` |
| 6 | 기능 키워드 | 2순위 매핑 입력 (키워드) | `SlotManager, SpinResult` (쉼표 구분) |
| 7 | 비고 | **파싱 무시** — release-diff 자체 경고 표시 컬럼 | `⚠️ 탐색 미완료` 또는 빈값 |

### 파싱 규칙

- 헤더 행(`| 티켓 | 타입 | ...`)과 구분선(`|------|...`)은 건너뛴다.
- 각 데이터 행을 `|`로 split해 7개 필드를 추출한다. 7개 미만이면 경고 후 건너뛴다.
- 파일/코드 위치가 `-`이면 경로 없음(Light 티켓). 이 경우 **기능 키워드만으로 2순위 매핑**을 시도한다.
- 비고 컬럼은 읽지 않는다.

---

## STEP 2: Feature Module 매핑

온톨로지의 각 Feature Module에 대해 아래 순서로 매핑한다.

### 매핑 우선순위

**1순위 — 파일명 매칭**
Evidence의 파일 경로(또는 파일명)가 온톨로지 `Client Evidence` / `Server Evidence` 목록에 포함되는지 확인한다.

```
예) Evidence 파일: SlotManager.cs
    온톨로지 Client Evidence에 SlotManager.cs 있음 → Direct Match
```

**2순위 — 키워드 매칭**
파일 경로가 없거나(미확인) 파일명 매칭이 없으면, 기능 키워드를 온톨로지 `Risk Keywords` / Feature Module 이름과 비교한다.
> **Light 티켓**(파일/코드 위치가 `-`)은 1순위를 건너뛰고 **바로 2순위 키워드 매칭**으로 진입한다.

```
예) 키워드: "Xsolla", "결제"
    온톨로지 결제 모듈 Risk Keywords에 매칭 → Secondary Match
```

**3순위 — 미매핑**
파일명도, 키워드도 매칭되지 않으면 "미매핑" 사실로 분리한다.

### 매핑 등급

매핑 등급은 **Evidence가 모듈에 얼마나 직접 연결됐는가**를 나타낸다.

| 등급 | 기준 |
|------|------|
| **Direct Match** | 파일명이 온톨로지 Evidence와 정확히 일치 |
| **Secondary Match** | 키워드 매칭 또는 연동 흐름(보상·팝업·라우팅)으로 간접 연결 |
| **Review Required** | 매핑 근거 약함, 수동 확인 필요 |

### Global 플래그

Global은 매핑 등급과 **독립된 별도 플래그**다. 매핑 등급과 병기한다.

| 플래그 | 부여 조건 |
|--------|----------|
| **🌐 Global** | 아래 **두 조건을 모두** 충족할 때만 부여: ① 해당 모듈이 온톨로지에서 `Core System` / `0️⃣` 태그를 가짐 ② 해당 모듈이 이미 Direct Match 또는 Secondary Match로 매핑 확정됨 |

병기 예시: `Direct Match 🌐 Global`, `Secondary Match 🌐 Global`

> **매핑 안 된 Core System 모듈에는 Global을 붙이지 않는다.** 매핑된 모듈만 출력하는 원칙과 일치한다. PopupManager.cs, AssetBundle 로더, 씬 전환 로직, 인증 흐름 등 전 기능 공용 컴포넌트가 이 플래그를 받는다.

### Confidence 루브릭

| Confidence | 조건 |
|-----------|------|
| **High** | Direct Match + Evidence 상태가 Changed/New/Removed로 확정됨 |
| **Medium** | Secondary Match (키워드 매칭), 또는 Direct Match이나 Evidence 상태가 미확인 |
| **Low** | Review Required, 또는 키워드 매칭이 1개이고 파일 근거 없음 |

---

## STEP 3: 교차 영향 탐지

여러 티켓이 같은 Feature Module에 매핑됐을 때 교차 영향을 탐지한다.

**탐지 조건**:
- 2개 이상의 티켓이 동일 Feature Module에 Direct/Secondary Match
- 한 티켓의 변경이 다른 티켓 기능의 `QA Observable Outputs`에 영향을 줄 수 있는 경우

**특히 주의할 공용 허브**:
- 보상 지급 흐름 (`logic_reward.ts`, `RewardManager.cs`)
- 팝업 관리 (`PopupManager.cs`, 팝업 스택)
- 라우팅 / 씬 전환
- 서버-클라이언트 인터페이스 (API 응답 구조 변경)
- 설정값 / Feature Flag (`isEnabled`, `defaultValue`, `RemoteConfig`)

---

## STEP 4: 출력

### 온톨로지 매핑 결과

매핑된 Feature Module별로 출력한다. 매핑 없는 모듈은 출력하지 않는다.

```
## 온톨로지 매핑 결과

### [Feature Module 이름]
- 매핑 등급: Direct Match / Secondary Match / Review Required
  (🌐 Global은 Direct Match 또는 Secondary Match에만 병기 가능. Review Required에는 부여하지 않음)
- Confidence: High / Medium / Low
- 근거:
- 관련 티켓:
  - [CVS-XXXXX] 파일/코드 위치 (Changed / New / Removed / 미확인)
- QA Observable Outputs:
  - (온톨로지에서 해당 모듈의 QA Observable Outputs 인용)
- Key Asserts:
  - (온톨로지에서 해당 모듈의 Key Asserts 인용)
- Risk Keywords 매칭: (Evidence와 겹친 키워드)
```

### 교차 영향 범위

여러 티켓이 같은 모듈을 건드리는 경우만 출력한다.

```
## 교차 영향 범위

### [Feature Module 이름] — [티켓 수]개 티켓 동시 변경
- 티켓: CVS-XXXXX, CVS-YYYYY
- 리스크: (두 변경이 충돌하거나 연동 흐름에서 겹칠 수 있는 시나리오)
- 추가 확인 포인트:
  1. ...
  2. ...
```

### 미매핑 사실

어느 Feature Module에도 매핑되지 않은 Evidence를 정리한다.

```
## 미매핑 사실
- [CVS-XXXXX] 키워드: [...] → 온톨로지에 해당 모듈 없음 (신규 기능 또는 온톨로지 업데이트 필요)
```

### 추가 QA 체크리스트 항목

온톨로지 매핑으로 발견된 항목 중 아래 조건에 따라 출력 범위를 결정한다.

**현재 대화에 release-diff 체크리스트가 있는 경우**: release-diff 체크리스트와 중복되는 항목은 제외한다. 진짜 추가 발견분만 출력한다.

**release-diff 결과가 없거나 Evidence 테이블만 입력된 경우**: 중복 판단을 할 수 없으므로 온톨로지 매핑으로 도출된 모든 확인 항목을 출력한다. 헤더에 "※ release-diff 체크리스트 없음 — 전체 항목 출력" 을 명시한다.

```
## 온톨로지 기반 추가 확인 항목
※ (release-diff 체크리스트와 비교 후 추가분만 / 또는 전체 출력 중 하나를 명시)

[ ] [Feature Module] — 추가 확인 포인트 — 근거: Secondary Match / 교차 영향
[ ] ...
```

---

## STEP 5: Slack 보고 [선택 실행]

> **Slack 전송 범위**: 매핑 결과·교차 영향 상세는 release-diff 보고와 대부분 중복되므로 Slack에는 보내지 않는다. **온톨로지 기반 추가 확인 항목만** 전송한다. 매핑 상세는 대화 내 STEP 4 출력으로 확인한다.

STEP 4 결과를 대화에 먼저 출력한다. 추가 확인 항목이 0건이면 "추가 확인 항목 없음 — Slack 전송 생략"을 출력하고 STEP 5를 스킵한다.

추가 확인 항목이 1건 이상이어도 Slack 전송은 기본적으로 생략하고, 사용자가 Slack 전달을 명시적으로 요청한 경우에만 진행한다.

사용자가 Slack 전달을 요청한 경우 `#qa-ai-report` 채널(ID: `C0AQTSRRFHC`)에 **1개 메시지 + 스레드** 형식으로 전송한다.

#### 형식 규칙
- Slack Block Kit은 사용하지 않는다. 일반 텍스트(`mrkdwn`)로 전송한다
- **이모지 최소화**: 불필요한 이모지를 넣지 않는다. 텍스트 위주로 작성한다

#### 5-1. 부모 메시지

릴리스 번호를 포함해 release-diff 메시지와 맥락을 연결한다.

```
_릴리스 {RELEASE}_
*ontology-map 추가 확인 항목* [N]건
매핑 모듈 [N] | 교차 영향 [N] | 미매핑 [N]
```

#### 5-2. 스레드 답글 (부모 메시지의 `thread_ts` 사용)

항목을 **Blocker / 추가 확인 / 교차 영향** 3단으로 분리한다. 해당 단이 0건이면 생략한다.
각 항목은 **3줄 구성**: 확인 포인트 + "확인:" 한 줄 요약 + 이탤릭 근거.

"확인:" 줄은 온톨로지 QA Observable Outputs / Key Asserts에서 테스터 동작 수준으로 한 줄 요약한다. 해당 모듈의 QA Observable Outputs / Key Asserts가 없으면 "확인:" 줄을 생략한다.

```
*Blocker — Core System*
[ ] 확인 포인트 제목
    확인: 테스터 동작 수준 한 줄 요약 (QA Observable Outputs / Key Asserts 기반)
    _파일명 상태 — 매핑 등급_

*추가 확인*
[ ] 확인 포인트 제목
    확인: 테스터 동작 수준 한 줄 요약
    _파일명 상태 — 매핑 등급_

*교차 영향*
[ ] 확인 포인트 제목
    확인: 테스터 동작 수준 한 줄 요약
    _관련 티켓 — 교차_
```

미매핑이 1건 이상이면 스레드 끝에 추가한다. 0건이면 생략한다.

```
미매핑 [N]건:
- [CVS-XXXXX] 키워드: [...] — 온톨로지에 해당 모듈 없음
```

#### 5-3. 실패 처리

전송 실패 시: 1회 재시도한다. 재시도도 실패하면 "Slack 전송 실패"를 대화에 출력하고 종료한다.

---

## 절대 원칙

1. Evidence 없는 Feature Module은 "영향 없음"으로 단정하지 않는다. 매핑 시도 결과를 명시한다.
2. 파일명 매칭이 없어도 키워드 매칭으로 Secondary Match가 가능하다. 2순위 매핑을 건너뛰지 않는다.
3. 미매핑 사실은 "온톨로지가 최신이 아닐 수 있음"을 명시한다. 신규 기능은 온톨로지 업데이트가 필요하다.
4. 교차 영향은 "가능성"이다. 확정처럼 쓰지 않는다.

## 금지 사항

- 온톨로지 전체 모듈을 나열하지 마라. 매핑된 모듈만 출력한다.
- Evidence 없이 "이 모듈도 확인하면 좋다"는 식의 추측성 확장을 하지 마라.
- release-diff가 이미 체크리스트에 포함한 항목을 다시 나열하지 마라.
