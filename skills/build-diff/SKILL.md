---
name: build-diff
description: 빌드 버전 또는 빌드 버전 범위를 입력하면 사내 repo에서 QA 영향 있는 변경점만 추출합니다. 기본값/설정값/show·hide 상태 변경 등 실제 QA 영향 기준으로 분석합니다. "/build-diff", "빌드 변경점 분석", "QA 분석" 요청 시 사용합니다.
argument-hint: "239.0.3 | 239.0.0~239.0.3"
---

# /build-diff — 빌드 변경점 QA 분석

> **실행 환경**: 이 스킬의 bash 명령은 Claude Code Bash 도구 기준으로 작성됐다. Windows에서는 Git Bash 환경에서 실행된다. PowerShell에서 직접 실행하면 동작하지 않는다.

### 임시 파일 경로 (Windows/Mac 호환)

Git Bash의 `/tmp`는 Python에서 접근 불가할 수 있다. 모든 임시 파일은 `$TMPDIR`을 사용한다.
**TMPDIR 초기화는 STEP 0에서 빌드 버전 확정 직후에 실행한다.** 아래 코드 블록은 STEP 0 참고용이다.

```bash
export TMPDIR="$(cygpath -m /tmp 2>/dev/null || echo /tmp)/build-diff"
mkdir -p "$TMPDIR"
```

이후 모든 코드 블록에서 `/tmp/` 대신 `$TMPDIR/`을 사용한다. Python 코드에서도 `$TMPDIR` 환경변수를 참조해야 하므로 반드시 `export`한다.

### Shell 상태 비유지 대응 (Claude Code Bash 도구 특성)

Claude Code의 Bash 도구는 **각 호출마다 새 셸을 시작**한다. `export`한 환경변수(`$TMPDIR`, `$JIRA_AUTH`, `$REPOB` 등)가 다음 호출에서 사라진다.

**해결 패턴**: 초기화 직후 환경변수를 파일에 저장하고, 이후 Bash 블록 첫 줄에서 source한다.

```bash
# 초기화 완료 후 1회 실행 — 환경 파일 저장
cat > "$TMPDIR/_env.sh" <<'ENVEOF'
export TMPDIR="[확정된 TMPDIR 절대경로]"
export PYTHON="[python 경로]"
export JIRA_AUTH="[email:token]"
export JIRA_BASE="[https://domain]"
export REPOB="[repob 바이너리 경로]"
ENVEOF

# 이후 모든 Bash 블록 첫 줄
source "[TMPDIR 절대경로]/_env.sh"
```

> 주의: `_env.sh`에 Jira 토큰이 포함되므로 분석 완료 후 삭제를 권장한다. 단, `$TMPDIR` 자체가 임시 디렉토리이므로 시스템 재부팅 시 자동 정리된다.

### Windows 인코딩 가드 (전체 Python 코드 블록 공통)

Windows 기본 콘솔 인코딩(cp949)에서 한글·특수문자(`\xa0` 등) 출력 시 `UnicodeEncodeError`가 발생한다. **모든 Python `-c` 코드 블록의 첫 줄**에 아래를 삽입한다:

```python
import sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace'); sys.stderr.reconfigure(encoding='utf-8', errors='replace')
```

파일을 `open()`할 때도 `encoding='utf-8', errors='replace'`를 항상 지정한다. 이 규칙은 이후 모든 STEP의 Python 코드에 적용된다. 개별 코드 블록에서 반복 기술하지 않는다.

### Jira API 응답 인코딩 방어 (echo 파이프 금지)

Jira API 응답을 `echo "$RESP" | python -c ...` 패턴으로 파이프하면 Windows cp949 환경에서 한글이 깨진다. **반드시 임시 파일에 저장 후 Python이 파일을 읽도록** 한다:

```bash
# 잘못된 패턴 (사용 금지)
# echo "$RESP" | $PYTHON -c "import json,sys; ..."

# 올바른 패턴
echo "$RESP" > "$TMPDIR/_jira_resp.json"
$PYTHON -c "
import sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace')
import json, os
with open(os.path.join(os.environ['TMPDIR'], '_jira_resp.json'), encoding='utf-8', errors='replace') as f:
    d = json.load(f)
# ... 이후 처리
"
```

이 패턴은 이후 모든 STEP의 Jira/API 응답 처리에 적용된다.

## 도구 확인

```bash
PLUGIN_BASE="${HOME}/.claude/plugins/cache/bagel-marketplace/repob"
LATEST=$(ls "$PLUGIN_BASE" 2>/dev/null | sort -V | tail -1)
if [ -z "$LATEST" ] && ! command -v repob &>/dev/null; then
  echo "❌ 이 스킬은 repob가 필요합니다."
  echo ""
  echo "   Claude Code에서 실행:"
  echo "     /install-plugin repob@bagel-marketplace"
  echo ""
  echo "   설치 후 다시 시도해 주세요."
fi
```

repob가 없으면 위 안내를 출력하고 **중단**한다.

---

## 실행 전 확인

인자가 없으면 `AskUserQuestion`으로 단 한 번 묻는다. options 2개는 **형식 예시 표시 전용**이며, 실제 입력은 반드시 Other(자유 입력)로만 받는다:

```
question: "분석할 빌드 번호를 Other에 직접 입력해 주세요."
options:
  - label: "단일 빌드 예시",  description: "239.0.3  ← Other에 이 형식으로 입력"
  - label: "빌드 범위 예시",  description: "239.0.0~239.0.3  ← Other에 이 형식으로 입력"
```

options 레이블을 **클릭하는 것은 유효 입력이 아니다**. 반드시 Other에 실제 빌드 번호를 직접 입력한 값만 사용한다. 입력값이 `숫자.숫자.숫자` 또는 `숫자.숫자.숫자~숫자.숫자.숫자` 형식이 아니면 같은 질문으로 한 번 더 묻는다.

---

## Jira 인증 설정

인증 정보는 `~/.bagelcode/jira.json`에서 읽는다:

```bash
PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)
JIRA_CONFIG=$(cat ~/.bagelcode/jira.json)
JIRA_DOMAIN=$(echo $JIRA_CONFIG | $PYTHON -c "import json,sys; d=json.load(sys.stdin); print(d['domain'])")
JIRA_EMAIL=$(echo $JIRA_CONFIG | $PYTHON -c "import json,sys; d=json.load(sys.stdin); print(d['email'])")
JIRA_TOKEN=$(echo $JIRA_CONFIG | $PYTHON -c "import json,sys; d=json.load(sys.stdin); print(d['token'])")
JIRA_BOARD=$(echo $JIRA_CONFIG | $PYTHON -c "import json,sys; d=json.load(sys.stdin); print(d['board_id'])")
JIRA_AUTH="$JIRA_EMAIL:$JIRA_TOKEN"
JIRA_BASE="https://$JIRA_DOMAIN"
```

파일이 없으면 아래 안내를 출력하고 **실행을 중단**한다. 토큰을 채팅으로 직접 받지 않는다.

```
~/.bagelcode/jira.json 파일이 없습니다. 아래 형식으로 파일을 생성한 뒤 다시 실행해 주세요:

{
  "domain": "yourcompany.atlassian.net",
  "email": "your.email@company.com",
  "token": "YOUR_JIRA_API_TOKEN",
  "board_id": 1
}

# macOS/Linux
chmod 600 ~/.bagelcode/jira.json

# Windows (PowerShell)
icacls "$HOME\.bagelcode\jira.json" /inheritance:r /grant:r "$($env:USERNAME):(R)"
```

---

## repob 초기화

repob는 bagel-marketplace 플러그인으로 설치된다. 바이너리 경로를 자동 탐지하여 `$REPOB` 변수에 저장한다.

```bash
# 1. bagel-marketplace 플러그인 캐시에서 repob 바이너리 탐지
REPOB=""
PLUGIN_BASE="${HOME}/.claude/plugins/cache/bagel-marketplace/repob"
if [ -d "$PLUGIN_BASE" ]; then
  # 최신 버전 디렉토리 선택 (버전 역순 정렬)
  LATEST_VER=$(ls -1 "$PLUGIN_BASE" | $PYTHON -c "import sys; vs=[v.strip('/') for v in sys.stdin.read().split() if v.strip('/')]; vs.sort(key=lambda v: list(map(int, v.split('.'))), reverse=True); print(vs[0] if vs else '')")
  if [ -n "$LATEST_VER" ]; then
    BIN_DIR="$PLUGIN_BASE/$LATEST_VER/skills/repob/bin"
    # OS별 바이너리 선택
    case "$(uname -s)" in
      MINGW*|MSYS*|CYGWIN*|Windows_NT) REPOB="$BIN_DIR/repob.exe" ;;
      *) REPOB="$BIN_DIR/repob" ;;
    esac
  fi
fi

# 2. PATH에서 fallback 탐색
if [ ! -x "$REPOB" ]; then
  REPOB=$(command -v repob 2>/dev/null || echo "")
fi

# 3. 결과 확인
if [ -x "$REPOB" ]; then
  echo "repob: $($REPOB --version 2>&1)"
else
  echo "WARN: repob 미발견 — gh api fallback 모드로 진행"
  REPOB=""
fi
```

이후 모든 repob 명령은 `$REPOB`를 통해 실행한다. `$REPOB`가 비어있으면 gh api fallback 전략으로 대체한다.

---

## STEP 0: 날짜 범위 결정

인자 형식을 판별하여 아래 두 케이스로 분기한다.

### 케이스 A — 빌드 번호 하나 (예: `239.0.3`)
`~` 없음 + `숫자.숫자.숫자` 형식

1. 이전 버전 계산:
   - 마지막 숫자를 1 감소. (예: `239.0.3` → `239.0.2`)
   - 마지막 숫자가 0이고 중간 숫자가 1 이상이면: 중간 숫자를 1 감소, 마지막은 직전 빌드 번호를 Slack `#cvs-build`에서 검색하여 결정한다. (예: `239.1.0` → Slack에서 `239.0` 빌드 중 가장 마지막 번호 검색 → `239.0.5` 등). 검색 실패 시 `AskUserQuestion`으로 직접 입력받는다.
   - **마지막·중간 숫자가 모두 0인 경우 (예: `239.0.0`)**: 스프린트 경계를 자동 추론할 수 없으므로 `AskUserQuestion`으로 시작일을 직접 입력받는다. → 이 경우 3번에서 입력 버전(239.0.0)만 Slack 조회한다.

2. Slack `#cvs-build`(ID: `C4FBFBA0P`) 조회:
   > **`query` 파라미터만 사용한다.** `sort`, `limit`, `include_bots`, `response_format` 등 추가 파라미터는 MCP tool에서 `invalid_arguments`를 유발하므로 **사용하지 않는다.**
   > 검색 결과가 여러 건 반환되므로, **Python으로 결과 중 가장 이른 timestamp를 추출**한다.
   - **일반 케이스**: 이전 버전 + 입력 버전 각각 조회
     - `slack_search_public_and_private`, query: `[이전 버전] in:#cvs-build` → 결과 중 최소 timestamp → 시작일
     - `slack_search_public_and_private`, query: `[입력 버전] in:#cvs-build` → 결과 중 최소 timestamp → 종료일
   - **x.0.0 케이스**: 시작일은 위에서 직접 입력받은 값 사용, 종료일만 Slack 조회
     - `slack_search_public_and_private`, query: `[입력 버전] in:#cvs-build` → 결과 중 최소 timestamp → 종료일
   - **검색 결과에서 최소 timestamp 추출 방법**: Slack MCP 결과는 구조화 데이터가 아닌 **마크다운 텍스트**로 반환된다. 각 결과의 `Time:` 필드에서 날짜·시각을 직접 비교하여 가장 이른 시각을 시작일/종료일로 선택한다. 봇 메시지 텍스트는 비어있을 수 있으므로 `Time:` 필드 기준으로 판단한다. Python 파이프라인이 아닌 **LLM이 텍스트를 읽고 최소값을 판별**하는 방식이다.
   - **검색 실패 시**: `slack_read_channel`은 봇 메시지 텍스트가 비어있어 빌드 버전 확인이 불가하므로 사용하지 않는다. 검색 실패 시 즉시 `AskUserQuestion`으로 날짜 직접 입력 요청.

3. 검색 결과 없으면 `AskUserQuestion`으로 날짜 직접 입력 요청.

4. 분석 대상 repo / 베이스 브랜치 결정:
   - repo: `client`
   - 브랜치용 스프린트 번호: 빌드 번호의 **첫 세그먼트** 사용 (예: `239.0.3` → `239` → `Develop/239/Main`)
   - Jira 스프린트 이름: **첫 두 세그먼트** 사용 (예: `239.0.3` → `239.0`) ← 실제 스프린트명과 일치

### 케이스 B — 빌드 범위 (예: `239.0.0~239.0.3`)
`~` 있음 + 양쪽 모두 `숫자.숫자.숫자` 형식

1. Slack `#cvs-build`(ID: `C4FBFBA0P`)에서 시작·종료 빌드의 최초 등장 시각 검색:
   > **`query` 파라미터만 사용한다.** `sort`, `limit`, `include_bots`, `response_format` 등 추가 파라미터는 사용하지 않는다.
   - `slack_search_public_and_private`, query: `[시작 빌드] in:#cvs-build` → 결과 중 최소 timestamp → 시작일
   - `slack_search_public_and_private`, query: `[종료 빌드] in:#cvs-build` → 결과 중 최소 timestamp → 종료일

2. 검색 결과 없으면 `AskUserQuestion`으로 날짜 직접 입력 요청.

3. 분석 대상 repo / 베이스 브랜치 결정:
   - repo: `client`
   - 시작 빌드와 종료 빌드의 첫 세그먼트가 같으면 그 값을 스프린트 번호로 사용
   - 예: `239.0.0~239.0.3` → `Develop/239/Main`
   - 서로 다르면 `AskUserQuestion`으로 기준 스프린트 또는 명시 브랜치를 직접 묻는다.

4. **Jira fix 버전 매칭 기준 (케이스 B 전용)**:
   - 범위 내 **모든 버전**(예: `239.0.1`, `239.0.2`, `239.0.3`)을 fix 기준으로 본다.
   - 각 버그 댓글에서 범위 내 어느 버전이든 수정 언급이 있으면 수집 대상으로 포함한다.
   - 출력 시 어느 버전에서 수정됐는지 버전별로 구분 표시한다.

---

## 분석 대상
- repo: **client**
- 베이스 브랜치: **[선택된 브랜치]**
- 단일 버전 입력 시: **[입력 버전]** (이전 버전: **[이전 버전]**)
- 빌드 범위 입력 시: **[시작 빌드] ~ [종료 빌드]**
- 날짜 범위: **[시작일] ~ [종료일]**

---

## 절대 원칙 (이 아래 상세 지시보다 이 원칙이 우선한다)
1. Jira 버그를 코드/문서보다 먼저 수집하라
2. Docs/*.md를 코드보다 먼저 읽어라
3. 커밋 메시지를 신뢰하지 마라. 파일 수가 많으면 반드시 열어봐라
4. 대규모 커밋에서 전체를 다 봤다고 말하지 마라
5. 마지막 출력에 반드시 커버리지 한계를 써라
6. "QA가 놓치면 장애/오탐이 되는 변경"이 우선이다

---

## 목적
지정한 기간 내 빌드 변경사항 중, 단순 리팩토링/라이브러리 갱신/파일 이동을 제외하고 실제 QA 영향이 있는 변경점만 추출하라.

"무엇이 수정되었는가"보다 "QA가 놓치면 실제 장애/오탐으로 이어질 변경이 무엇인가"를 우선순위로 판단하라.

특히 다음과 같은 숨은 변경을 우선 탐지하라:
- 기본값(Default) 변경
- 설정값(Config) 변경
- 표시/비표시(show/hide) 상태 변경
- 활성/비활성(enable/disable) 기본 상태 변경
- 조건문/플래그 기준값 변경
- 문서에는 적혔지만 코드 반영이 누락되었거나 다르게 구현된 케이스
- Jira에 등록된 버그 중 이번 빌드에서 수정된 항목

---

## 분석 순서 (반드시 이 순서를 지켜라)

### STEP 1: Jira 버그 수집 [최우선]
코드/문서보다 먼저 Jira에서 이번 빌드에 수정된 버그를 수집한다.

#### 1-1. 스프린트 ID 조회 [STEP 0 Slack 검색과 동시 실행]
STEP 0의 Slack 검색과 이 단계는 독립적이므로 **동시에 실행**한다.

- **케이스 A (단일 빌드)**: 빌드 번호의 첫 두 세그먼트로 스프린트명 추론 (예: `239.0.2` → `239.0`)
- **케이스 B (빌드 범위)**:
  - 시작·종료 빌드의 첫 두 세그먼트가 같으면 단일 스프린트로 조회 (예: `239.0.0~239.0.3` → `239.0`)
  - **다르면 (예: `239.0.5~240.0.2`)**: 시작 스프린트명(`239.0`)과 종료 스프린트명(`240.0`) 모두 조회하여 두 스프린트 ID를 확보한다. 이후 1-2에서 두 스프린트를 모두 대상으로 Bug 이슈를 수집한다.

```bash
# isLast 기반 페이지네이션 — 스프린트가 발견되거나 마지막 페이지까지 순회
START=0
while true; do
  RESP=$(curl -s -u "$JIRA_AUTH" \
    "$JIRA_BASE/rest/agile/1.0/board/$JIRA_BOARD/sprint?state=active,closed&maxResults=100&startAt=$START")
  echo "$RESP" > "$TMPDIR/_sprint_resp.json"
  RESULT=$($PYTHON -c "
import sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace')
import json, os
with open(os.path.join(os.environ['TMPDIR'], '_sprint_resp.json'), encoding='utf-8', errors='replace') as f:
    data = json.load(f)
vals = data.get('values', [])
for s in vals:
    if '[스프린트 이름]' in s['name']:
        print(s['id'], s['name'])
" 2>/dev/null)
  if [ -n "$RESULT" ]; then echo "$RESULT"; break; fi
  # isLast 확인 — 마지막 페이지면 루프 종료
  IS_LAST=$($PYTHON -c "
import sys, json, os
with open(os.path.join(os.environ['TMPDIR'], '_sprint_resp.json'), encoding='utf-8', errors='replace') as f:
    print(json.load(f).get('isLast', True))
")
  [ "$IS_LAST" = "True" ] && break
  START=$((START + 100))
done
```

루프 내에서 발견 즉시 break하므로 불필요한 API 호출을 최소화한다. `isLast`가 True일 때까지 모든 페이지를 순회하며, 끝까지 없으면 `AskUserQuestion`으로 스프린트명 직접 입력받는다.

#### 1-2. 스프린트 내 [Bug] 이슈 전체 조회
이슈 타입 무관하게 **제목에 `[Bug]`가 포함된 항목**을 수집한다.
(이슈 타입 `버그` + 에픽 하위 `하위 작업` 중 [Bug] 달린 것 모두 포함)

> **JQL `summary ~ "[Bug]"`는 대괄호 이스케이프 문제로 0건을 반환할 수 있다.** 따라서 **전체 이슈 fetch + Python 로컬 필터**를 기본 전략으로 사용한다.

**페이지네이션 필수** — `isLast` 가 `True`가 될 때까지 `nextPageToken`을 이용해 반복 조회한다.

```bash
NEXT_TOKEN=""
while true; do
  PAYLOAD=$($PYTHON -c "
import json, sys, os
body = {'jql': 'sprint = [SPRINT_ID] ORDER BY created DESC', 'maxResults': 100, 'fields': ['summary','status','issuetype','created','updated']}
token = os.environ.get('NEXT_TOKEN','')
if token: body['nextPageToken'] = token
print(json.dumps(body))
" )
  echo "$PAYLOAD" > "$TMPDIR/_jira_payload.json"
  RESP=$(curl -s -u "$JIRA_AUTH" \
    -H "Content-Type: application/json" \
    -X POST "$JIRA_BASE/rest/api/3/search/jql" -d @"$TMPDIR/_jira_payload.json")
  echo "$RESP" > "$TMPDIR/_issue_resp.json"
  $PYTHON -c "
import sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace')
import json, os
with open(os.path.join(os.environ['TMPDIR'], '_issue_resp.json'), encoding='utf-8', errors='replace') as f:
    d = json.load(f)
for i in d.get('issues',[]):
    summary = i['fields']['summary']
    if '[bug]' in summary.lower():
        print(i['id'],'|',i['key'],'|',summary[:80],'|',i['fields']['status']['name'])
"
  IS_LAST=$($PYTHON -c "
import json, os
with open(os.path.join(os.environ['TMPDIR'], '_issue_resp.json'), encoding='utf-8', errors='replace') as f:
    print(json.load(f).get('isLast', True))
")
  [ "$IS_LAST" = "True" ] && break
  NEXT_TOKEN=$($PYTHON -c "
import json, os
with open(os.path.join(os.environ['TMPDIR'], '_issue_resp.json'), encoding='utf-8', errors='replace') as f:
    print(json.load(f).get('nextPageToken',''))
")
  export NEXT_TOKEN
done
```

출력 형식: `내부ID | 이슈키 | 제목 | 상태`. **내부 ID(`id`)는 STEP 1.5 Jira→PR 역추적의 dev-status API에 필수**이므로 반드시 저장한다.

복수 스프린트(케이스 B 범위 교차)인 경우 각 스프린트 ID에 대해 동일하게 실행하고 결과를 합친다.

#### 1-3. 각 이슈 설명 + 댓글에서 fix 버전 추출 [병렬 조회]
수집된 이슈의 설명(description)과 댓글을 **병렬로 조회**한다. 단, Jira rate limit를 고려하여 **동시 요청은 5건 이하**로 제한한다. 5건 응답 후 다음 5건을 보낸다.

**이슈 설명(description) 조회** — 댓글보다 먼저 읽는다. 버그 재현 조건, 수정 범위, 영향 범위가 description에 기술되어 있는 경우가 많다:

> **[ISSUE_KEY]는 placeholder** — 1-2에서 수집한 이슈 키로 치환하여 루프 안에서 호출한다. 동시 요청 5건 이하로 제한하기 위해 `& wait` 배치 패턴을 사용한다 (예시 루프는 아래 댓글 조회 블록 바로 앞 참조).

```bash
# 예시 — 실제 실행 시 [ISSUE_KEY]를 ${ISSUE_KEY}로 치환하여 1-2 결과 루프 안에서 호출
RESP=$(curl -s -u "$JIRA_AUTH" \
  "$JIRA_BASE/rest/api/3/issue/${ISSUE_KEY}?fields=description,summary")
echo "$RESP" > "$TMPDIR/_desc_resp.json"
$PYTHON -c "
import sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace')
import json, os
with open(os.path.join(os.environ['TMPDIR'], '_desc_resp.json'), encoding='utf-8', errors='replace') as f:
    d = json.load(f)
desc = d.get('fields',{}).get('description',{})
# ADF(Atlassian Document Format) → 텍스트 추출
def extract_text(node):
    if isinstance(node, str): return node
    if isinstance(node, dict):
        parts = []
        if 'text' in node: parts.append(node['text'])
        for child in node.get('content', []):
            parts.append(extract_text(child))
        return ' '.join(parts)
    if isinstance(node, list):
        return ' '.join(extract_text(n) for n in node)
    return ''
print(extract_text(desc))
"
```
description에서 추출할 정보: 재현 조건, 수정 방법, 영향 범위, 관련 파일/클래스명 → STEP 3-1 grep 키워드에 추가한다.

**댓글 조회** — 아래 키워드가 포함된 댓글을 찾는다:
- 단일 빌드 입력: 대상 빌드 버전 (예: `239.0.2`, `q239.0.2`)
- 빌드 범위 입력: 범위 내 모든 버전 (예: `239.0.1`, `239.0.2`, `239.0.3`)
- `수정`, `적용`, `확인 가능`, `fix`, `resolved`

**페이지네이션 필수** — 댓글 API는 `total` 기반 offset 방식을 유지한다. `orderBy=created&startAt=0`부터 시작하여 반복 조회한다.

> **[ISSUE_KEY]는 placeholder** — 1-2에서 수집한 이슈 키로 치환하여 외부 루프(이슈별) 안에서 댓글 페이지네이션 루프(내부)를 돌린다.

```bash
# 예시 — 실제 실행 시 [ISSUE_KEY]를 ${ISSUE_KEY}로 치환하여 1-2 결과 루프 안에서 호출
START=0
while true; do
  RESP=$(curl -s -u "$JIRA_AUTH" \
    "$JIRA_BASE/rest/api/3/issue/${ISSUE_KEY}/comment?maxResults=50&startAt=$START&orderBy=created")
  echo "$RESP" > "$TMPDIR/_comment_resp.json"
  eval $($PYTHON -c "
import sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace')
import json, os
with open(os.path.join(os.environ['TMPDIR'], '_comment_resp.json'), encoding='utf-8', errors='replace') as f:
    d = json.load(f)
print(f'TOTAL={d.get(\"total\",0)} FETCHED={len(d.get(\"comments\",[]))}')
")
  START=$((START + FETCHED))
  [ "$START" -ge "$TOTAL" ] && break
done
```

매칭 기준 (댓글을 시간순으로 전체 확인):

**[단일 빌드 판정 규칙]** (케이스 A)
1. 대상 빌드 버전과 수정 관련 키워드가 함께 있는 댓글 → **fix 후보**로 표시
2. fix 후보 이후에 작성된 댓글에서 아래 중 하나가 발견되면 → **fix 확정 취소**
   - "수정 안됐음", "미수정", "재현됨", "다시 수정", "재오픈"
   - 대상 버전보다 높은 버전(예: `239.0.3`)에 "수정" 언급
3. fix 후보 이후 취소 댓글 없이 QA 확인 댓글이 있으면 → **이번 빌드 fix 확정**
4. fix 후보만 있고 QA 확인도 취소도 없으면 → **Pending (QA 미확인)** 으로 표시
- 버전 언급 없거나 다른 버전이면 → 스킵

**[빌드 범위 판정 규칙]** (케이스 B) — 버전별 상태를 개별 추적한다
1. 범위 내 각 버전(예: `239.0.1`, `239.0.2`, `239.0.3`)에 대해 fix 후보를 **버전별로 분리** 추적한다
2. 특정 버전의 fix 후보 이후에 취소 댓글이 나와도, **같은 범위 내 더 높은 버전에서 재수정 언급이 있으면 해당 버전의 fix는 유효**하다
   - 예: `239.0.2 수정 적용` → `수정 안됨` → `239.0.3 수정 적용` → 239.0.2는 미수정, 239.0.3은 fix 후보
3. 각 버전의 최종 상태를 개별 판정한다 (fix 확정 / Pending / fix 취소)
4. 출력 시 **버전별 상태를 구분 표시**한다:
   ```
   [CVS-XXXXX] 제목
   - 239.0.2: fix 취소 (재수정 → 239.0.3)
   - 239.0.3: fix 확정
   ```

#### 1-4. 결과 정리
이번 빌드 또는 빌드 범위 버그 목록을 상태별로 출력:

```
[Jira 수집 버그 목록]
- ✅ fix 확정: [CVS-XXXXX] 제목
  - fix 댓글: "239.0.2 수정 적용됩니다" (작성자, 날짜)
  - QA 확인 댓글: "q239.0.2 수정 확인" (작성자, 날짜)

- ⚠️ fix 취소 (재오픈): [CVS-XXXXX] 제목
  - fix 댓글: "239.0.2 수정 적용됩니다" (작성자, 날짜)
  - 취소 댓글: "수정 안됐음" (작성자, 날짜)
  - 재수정 댓글: "239.0.3에서 수정됩니다" (작성자, 날짜)
  → 이번 빌드(239.0.2)에서는 미수정. 다음 빌드 확인 필요.

- ⏳ Pending (QA 미확인): [CVS-XXXXX] 제목
  - fix 댓글: "239.0.2 수정 적용됩니다" (작성자, 날짜)
  - QA 확인 댓글 없음
```

버그가 없으면:
- 단일 빌드: `이번 스프린트 [Bug] 항목 중 [대상 버전] fix 확인 없음`
- 빌드 범위: `이번 스프린트 [Bug] 항목 중 [범위 내 버전들] fix 확인 없음`

---

### STEP 1.5: GitHub 커밋 + PR 수집 [STEP 1과 동시 실행 가능]

STEP 0에서 확정된 날짜 범위를 기준으로 **커밋과 PR을 모두** 수집한다.
> STEP 1과 동시 실행 시 PR/커밋 키워드 추출은 STEP 1.5 완료 후에만 사용 가능하다. STEP 3-2는 STEP 1.5 완료를 대기한 뒤 실행한다.

> **핵심**: PR 없이 직접 커밋으로만 변경이 들어가는 경우가 빈번하다. PR 수집만으로는 핵심 변경을 놓칠 수 있으므로 **커밋 조회를 1차로, PR을 2차 보완으로** 실행한다.

**조회 전략:**
- **1차 커밋 조회**와 **2차 PR 조회**는 **병렬 실행**한다. 둘 사이에 데이터 의존성이 없으므로 동시에 시작한다.
- 두 조회가 모두 완료된 뒤 **통합 단계**에서 SHA→PR 매핑과 중복 제거를 수행한다.
- Jira→PR 역추적은 STEP 1 완료 후 실행하므로, 1차/2차와 병렬이 아닌 순차 실행이다.

#### 1차: 브랜치 커밋 직접 조회 [필수 — 스킵 금지]

날짜 범위 내 대상 브랜치에 들어간 모든 커밋을 조회한다. Slack에서 얻은 시각(UTC)을 `since`/`until`에 사용한다.

```bash
gh api "repos/bagelcode-cvs/client/commits?sha=[BRANCH]&since=[시작_ISO8601]&until=[종료_ISO8601]&per_page=100" \
  --jq '.[] | "\(.sha[:8]) | \(.commit.author.date) | \(.commit.author.name) | \(.commit.message | split("\n")[0][:100])"'
```

**페이지네이션 필수** — 응답이 정확히 100건이면 다음 페이지가 있다. `page=2`, `page=3`, ... 파라미터를 추가하여 **응답이 100건 미만이 될 때까지 반복 조회**한다. 200건 초과 스프린트도 누락 없이 수집해야 커버리지 수치가 정확하다.

**커밋별 변경 파일 확인** — 각 커밋의 변경 파일 목록과 diff를 확인한다. 단, 아래 커밋은 **자동 스킵**한다:
- `Version up` / `version up` 으로 시작하는 버전업 커밋
- `.meta` 파일만 변경된 커밋

```bash
# 커밋별 변경 파일 + diff 확인 (jq가 아닌 Python 파서 사용 — jq는 patch 내 개행/따옴표에서 깨짐)
gh api "repos/bagelcode-cvs/client/commits/[SHA]" > "$TMPDIR/_commit_detail.json"
$PYTHON -c "
import sys, json, os
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
with open(os.path.join(os.environ['TMPDIR'], '_commit_detail.json'), encoding='utf-8', errors='replace') as f:
    d = json.load(f)
print(f'files: {len(d.get(\"files\",[]))}')
for f in d.get('files',[]):
    print(f'  {f[\"filename\"]} (+{f[\"additions\"]}/-{f[\"deletions\"]})')
    if f.get('patch'): print(f['patch'])
"
```

**Merge 커밋 처리**: merge 커밋(예: `Merge remote-tracking branch 'origin/Develop/238/Main'`)은 대량 파일을 포함할 수 있다. 이 경우:
1. 변경 파일 목록만 먼저 확인한다
2. `.cs` 파일과 설정 파일(`.asset`, `.json`)만 선별하여 diff를 확인한다
3. 프리팹/텍스처/애니메이션 바이너리는 커밋 메시지 기반으로만 기록한다
4. 커버리지 보고에 "merge 커밋 — 주요 파일만 샘플링"으로 명시한다

**커밋 데이터 활용**:
- 커밋 메시지에서 `CVS-\d+` 패턴 추출 → Jira 교차 검증
- 커밋 메시지에서 키워드 추출 → STEP 3 grep 패턴에 추가
- `fix`, `bug`, `hotfix`, `default`, `config`, `enable`, `disable`, `show`, `hide` 등이 커밋 메시지에 있으면 우선순위 높음으로 표시

#### 2차: PR 날짜 기반 조회 (보완)
> 주의: `merged:` 검색은 **날짜(YYYY-MM-DD) 단위**다. 시각(HH:MM)은 사용하지 않는다. STEP 0에서 Slack 시각을 얻더라도 날짜만 추출하여 사용한다.

```bash
gh pr list \
  --repo bagelcode-cvs/client \
  --state merged \
  --search "merged:[시작일]..[종료일]" \
  --json number,title,body,mergedAt,author,labels,baseRefName,mergeCommit \
  --limit 500
```
> `mergeCommit` 필드를 반드시 포함한다. 이후 SHA→PR 매핑에 `mergeCommit.oid`가 필요하며, 별도 gh pr list 재호출 없이 이 결과를 재사용한다.

> `--limit 500`: 스프린트 기간(보통 1~2주) 내 PR이 200건을 초과할 수 있다. 500건까지 조회하고, 결과가 정확히 500건이면 기간을 분할하여 추가 조회한다.

**경계일 후처리 [필수]**: `merged:` 검색은 날짜 단위라 경계일(시작일·종료일)에 무관한 PR이 섞일 수 있다. 조회 후 각 PR의 `mergedAt` 타임스탬프를 STEP 0에서 얻은 실제 시작/종료 시각과 비교한다:
- 시각 범위 안: 정상 포함
- 경계일이지만 시각 범위 밖: **"경계일 PR (시각 범위 밖)"** 으로 분리하여 별도 표시. 분석 본문에 자동 포함하지 않되, 목록은 유지한다

**3차: 베이스 브랜치가 특정된 경우(케이스 A/B), PR 결과를 브랜치로 분류한다**
   - gh CLI의 `--base` 필터는 사용하지 않는다. squash merge 구조에서 실제 귀속 브랜치와 불일치할 수 있기 때문이다.
   - 1차 결과를 `baseRefName` 기준으로 두 그룹으로 나눈다:
     - **[대상 브랜치 일치]**: `baseRefName == [베이스 브랜치]` → 분석 대상 (키워드 추출, Jira 교차검증, grep 반영 모두 이 그룹만)
     - **[브랜치 불일치]**: 다른 브랜치로 머지된 PR → **별도 섹션에만 표시**, 확정 변경·키워드 추출·Jira 교차검증에 자동 포함하지 않는다
   - 대상 브랜치 일치 PR이 0건이더라도 브랜치 불일치 PR을 분석 본문에 끌어올리지 않는다. 결과 정리의 "브랜치 불일치 PR" 섹션에 나열하고 개발팀 확인 권고로만 처리한다

#### Jira → PR 역추적 [STEP 1 완료 후 실행]

STEP 1에서 수집한 버그 이슈에 연결된 PR을 Jira development panel API로 직접 조회한다. GitHub PR 검색에서 누락되는 경우(squash merge, 다른 브랜치 경유 등)를 보완한다.

```bash
# 각 이슈의 dev-status에서 PR 정보 추출 (병렬, 5건씩)
RESP=$(curl -s -u "$JIRA_AUTH" \
  "$JIRA_BASE/rest/dev-status/latest/issue/detail?issueId=[ISSUE_INTERNAL_ID]&applicationType=GitHub&dataType=pullrequest")
echo "$RESP" > "$TMPDIR/_devstatus_resp.json"
$PYTHON -c "
import sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace')
import json, os
with open(os.path.join(os.environ['TMPDIR'], '_devstatus_resp.json'), encoding='utf-8', errors='replace') as f:
    d = json.load(f)
for detail in d.get('detail',[]):
    for pr in detail.get('pullRequests',[]):
        print(pr.get('id',''), '|', pr.get('name',''), '|', pr.get('status',''), '|', pr.get('url',''))
"
```

> dev-status API는 이슈의 **내부 ID** (key가 아님)가 필요하다. STEP 1-2에서 이슈 조회 시 `id` 필드도 함께 저장한다.
> API 실패 시(권한 부족 등) 스킵하고 PR 데이터 활용으로 진행한다. 전체 분석을 중단하지 않는다.

발견된 PR은 STEP 1.5의 PR 목록과 합쳐 중복 제거한다.

#### 커밋 + PR 데이터 통합 활용

1차 커밋 조회와 2차 PR 조회 결과를 아래 절차로 통합한다.

**SHA → PR 매핑 (필수)**:
> 2차 PR 조회에서 이미 `$TMPDIR/_pr_list.json`에 저장한 결과를 재사용한다. **gh pr list를 다시 호출하지 않는다.**

```bash
# 2차에서 저장한 _pr_list.json을 재사용 (재호출 금지)
$PYTHON -c "
import sys, json, os
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
with open(os.path.join(os.environ['TMPDIR'], '_pr_list.json'), encoding='utf-8', errors='replace') as f:
    prs = json.load(f)
for pr in prs:
    mc = pr.get('mergeCommit') or {}
    sha = mc.get('oid','')[:8]
    print(f\"{sha} | PR#{pr['number']} | {pr['title'][:80]}\")
"
```
- `mergeCommit.oid`가 1차 커밋 목록의 SHA와 일치하면 해당 커밋에 PR 정보(제목, 본문, Jira 키)를 보강한다.
- 일치하는 커밋이 있으면 커밋 단독 항목은 제거하고 PR 보강 항목으로 대체한다 (중복 제거).
- SHA 매칭이 안 되는 PR은 squash merge 등으로 SHA가 변경된 경우이므로, Jira 키(`CVS-\d+`) 또는 PR 제목 기반으로 2차 매칭을 시도한다.

수집된 커밋과 PR에서 아래 항목을 추출한다:

1. **Jira 교차 검증**: PR 제목/본문에서 `CVS-\d+` 패턴 추출 + Jira dev-status PR → STEP 1에서 수집한 버그와 매칭
   - Jira에 있고 PR도 있음 → 근거 강화 (Confidence 상향 가능)
   - PR에만 있고 Jira 없음 → **Jira 미등록 변경**으로 별도 표시
   - Jira에만 있고 PR 없음 → repob 코드 확인 필요 (STEP 3에서 우선 탐색)

2. **키워드 추출**: PR 제목/본문에서 클래스명·기능명·설정 키를 뽑아 STEP 3 grep 패턴에 추가

3. **숨은 변경 탐지**: 아래 패턴이 PR 제목/본문에 있으면 우선순위 높음으로 표시
   - `default`, `config`, `flag`, `enable`, `disable`, `show`, `hide`, `초기`, `기본값`, `hotfix`, `임시`

#### 결과 정리

```
[GitHub 커밋 + PR 수집]
■ 브랜치 커밋 (Develop/239/Main)
- 날짜 범위 내 커밋: [N]건
- 분석 대상 커밋 (버전업/meta 제외): [M]건
- Merge 커밋: [K]건 (주요 파일만 샘플링)
  - [SHA 8자리] Merge remote-tracking branch 'origin/Develop/238/Main' — [변경 파일 수]건
- 직접 커밋 상세:
  - [SHA 8자리] [커밋 메시지] — [변경 파일 수]건

■ PR (보완 정보)
- 날짜 범위 내 PR: [N]건
- 대상 브랜치 일치: [K]건
- 브랜치 불일치: [M]건

■ 통합 결과
- Jira 연결 변경: [K]건 (CVS-XXXXX 매칭)
- Jira 미등록 변경: [M]건
- 우선 탐색 키워드: [추출된 키워드 목록]

■ 브랜치 불일치 PR (분석 본문 제외)
- PR #421: Features/2026 q1/payment iam revamp (base: Develop/238/Main) — 개발팀 포함 여부 확인 권고
```

**0건 시 진단 — 두 가지 경우를 반드시 구분한다:**

- **전체 PR 0건** (1차 날짜 조회 자체가 0건): 권한 또는 날짜 범위 문제다.
  1. `--repo bagelcode-cvs/client` 접근 권한 및 날짜 범위를 확인한다.
  2. 해소 안 되면 커버리지 보고에 "PR 수집 불가 — 이유: [원인]"으로 명시하고 진행한다.
  3. `AskUserQuestion` 재입력 요청은 최후 수단이다.

- **대상 브랜치 일치 0건** (전체는 있으나 `baseRefName` 필터 후 0건): 정상 케이스다.
  - 브랜치 불일치 PR을 분석 본문에 끌어올리지 않는다.
  - 커버리지 보고에 "대상 브랜치 일치 PR 없음"으로 명시하고, 브랜치 불일치 PR은 별도 섹션에만 나열한다.

#### Commit-only fast-path [Jira 0건 + 대상 PR 0건일 때]

STEP 1에서 Jira 이슈가 0건이고 STEP 1.5에서 대상 브랜치 일치 PR도 0건이지만, **1차 커밋 조회에서 커밋이 존재하는 경우** 아래 fast-path를 적용한다:

1. **STEP 2 (문서 탐색) 스킵** — Jira/PR이 없으므로 문서 키워드 교차검증 대상이 없다. 커버리지 보고에 "Jira/PR 0건 — 문서 탐색 스킵"으로 명시한다.
2. **STEP 3 진입 시 커밋 기반 키워드만 사용** — 커밋 메시지에서 추출한 클래스명·기능명·설정 키를 grep 패턴으로 사용한다. PR/Jira 키워드는 비어 있으므로 기본 패턴과 커밋 키워드만 조합한다.
3. **STEP 4 (문서-코드 교차 검증) 스킵** — 문서가 없으므로 교차 검증 불가. 커버리지 보고에 명시한다.
4. **STEP 5 이후는 정상 진행** — 커밋 diff 기반으로 핵심 변경 분류, 커버리지 보고, Slack 보고를 수행한다.
5. **커버리지 프레이밍**: "이 빌드는 브랜치 직접 커밋만으로 구성됨 — Jira/PR 교차검증 없이 커밋 diff 기반 분석"으로 명시한다.

> Jira 0건 + PR 0건 + 커밋 0건이면 "분석 대상 변경사항 없음"으로 보고하고 종료한다.

---

### STEP 2: 개발자 작업 문서 탐색 [STEP 3 전에 먼저 완료]
STEP 1 완료 후 문서 탐색을 **먼저 완료**한다. 문서에서 추출한 키워드를 STEP 3 grep 패턴에 반영하기 위해서다.
코드를 보기 전에, 해당 기간에 수정된 문서 파일을 조사한다.

탐색 우선순위:
1. **파일명에 날짜가 포함된 문서** (YYYY-MM-DD, YYYYMMDD 등) — 날짜가 분석 기간 안에 있는 것만
2. 파일명 또는 내용에 빌드 버전(예: `239.0.2`) 또는 스프린트 번호(예: `239`)가 포함된 문서
3. 위 조건 해당 없으면: `CHANGELOG*`, `RELEASE*`, `README*` 최상위 문서만 확인

탐색 대상:
- `Docs/` 하위 전체 (우선순위 1~2 적용)
- 루트의 `CHANGELOG*`, `RELEASE*`, `README*`
- 전체 `.md` 무작위 탐색은 하지 않는다

탐색 방법:
```bash
# repob 사용 가능 시
$REPOB remote glob client [BRANCH] "Docs/**/*.md" --pretty
$REPOB remote read client [BRANCH] "[파일경로]" --pretty

# gh api fallback (repob 미사용 시)
# 1. contents API로 Docs 디렉토리 조회 (ref 파라미터로 브랜치 지정)
gh api "repos/bagelcode-cvs/client/contents/Docs?ref=[BRANCH]" \
  --jq '.[].name' 2>&1
# 2. 하위 디렉토리 탐색
gh api "repos/bagelcode-cvs/client/contents/Docs/[하위경로]?ref=[BRANCH]" \
  --jq '.[].name' 2>&1
# 3. 파일 읽기 — base64 디코드는 OS별 분기 (Mac 호환)
CONTENT=$(gh api "repos/bagelcode-cvs/client/contents/Docs/[파일경로]?ref=[BRANCH]" --jq '.content')
echo "$CONTENT" | base64 --decode 2>/dev/null || echo "$CONTENT" | base64 -d 2>/dev/null || $PYTHON -c "import base64,sys; sys.stdout.buffer.write(base64.b64decode(sys.stdin.read()))"
```

문서에서 우선 추출할 정보:
- 의도적으로 변경된 기능/설정
- 기본값(Default) 변경 내역
- 활성화/비활성화된 기능
- 개발자가 "주의", "QA 확인 필요", "임시", "핫픽스", "추가 확인" 등으로 표시한 항목
- known issue, limitation, workaround 성격의 문구

주의: 문서가 없거나 부실한 경우, 그 사실을 명시하고 STEP 3에서 코드 기반 탐색 비중을 높인다.

**STEP 2 완료 후**: 문서에서 추출한 기능명·키워드·PlayerPrefs 키·클래스명 등을 목록으로 정리해 STEP 3-2, 3-3, 3-5 grep 패턴에 추가한다.

---

### STEP 3: 규모 판별 및 코드 탐색

#### 분기 전제
변경 파일 수는 repob shallow clone 환경에서 얻을 수 없다. 따라서 **소규모/대규모 분기는 항상 불가 상태로 간주**하고, 아래 핀포인트 탐색(샘플링 전략)을 기본으로 실행한다. 단, 향후 전체 diff를 얻을 수 있는 경우(예: full clone 지원)에 대비해 분기 기준은 유지한다.

#### [소규모: 파일 100개 미만 — 전체 diff 확보 시만 해당]
전체 diff를 직접 검토한다. 외부 라이브러리/Generated 파일/빌드 산출물은 제외한다.

#### [대규모 또는 diff 불가 (현재 기본 경로)]
아래 핀포인트 탐색을 실행한다.

##### 3-1. Jira 버그 키워드 기반 코드 확인 [grep-first]
STEP 1에서 수집한 버그 제목에서 핵심 명사 키워드를 추출하여 grep으로 먼저 탐색한다.
**query는 grep 결과가 0건이거나, 결과는 있지만 관련성이 낮다고 판단될 때만 fallback으로 실행한다.**

```bash
# repob 사용 가능 시
$REPOB remote grep client [BRANCH] "[키워드1]|[키워드2]" --pretty
# grep 0건이거나 관련성 낮을 때만 query 실행 (느림, 60~300s)
$REPOB remote query client [BRANCH] "[버그 제목] 관련 코드가 어디 있나?" --pretty

# gh api fallback (repob 미사용 시)
gh search code "[키워드1] OR [키워드2]" --repo bagelcode-cvs/client --json path -L 20
```

**grep hit 파일 필수 읽기** — grep에서 관련 파일이 발견되면 반드시 파일을 열어 실제 코드를 확인한다. grep hit만으로 분석을 끝내지 않는다:

```bash
# repob 사용 가능 시 — 전체 파일 읽기만 지원. 라인 범위(예: :660-690) 문법은 미지원이므로 사용하지 않는다.
$REPOB remote read client [BRANCH] "[grep에서 발견된 파일 경로]" --pretty

# 파일이 너무 크면(1000줄+) gh api fallback으로 특정 라인 범위만 추출한다:
CONTENT=$(gh api "repos/bagelcode-cvs/client/contents/[파일경로]?ref=[BRANCH]" --jq '.content')
echo "$CONTENT" | $PYTHON -c "
import sys, base64
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
data = base64.b64decode(sys.stdin.read())
lines = data.decode('utf-8', errors='replace').split('\n')
for i in range([START_LINE]-1, min([END_LINE], len(lines))):
    print(f'{i+1:05d}| {lines[i]}')
"
```

> **repob remote read vs gh api 선택 기준**: 전체 파일을 볼 때는 repob, 특정 라인 범위만 볼 때는 gh api + Python 슬라이싱을 사용한다.

> **gh api fallback 한계**: `gh search code`는 기본 브랜치만 검색하며 개발 브랜치(`Develop/xxx/Main`)는 대상이 아니다. `gh api contents`로 파일 읽기는 브랜치 지정이 가능하지만, 파일 경로를 사전에 알아야 한다. repob이 가능하면 반드시 repob을 우선 사용한다.

읽을 때 확인할 내용:
- 실제 fix 로직이 구현되었는지 (조건 변경, 값 수정, 새 분기 추가 등)
- 기본값/설정값이 어떻게 바뀌었는지
- description에 기술된 재현 조건과 코드가 일치하는지
- 이 정보를 STEP 5 및 STEP 7 Slack 보고의 "무엇이 바뀌었나" / "변경 영향" / "QA 확인 포인트"에 반영한다

확인 목표:
- 버그와 관련된 코드가 현재 브랜치에 존재하는지
- fix 로직이 구현되어 있는지 (Jira 댓글의 "수정 적용" 주장과 교차 검증)
- **코드 내용을 직접 읽어** "무엇이 바뀌었나", "변경 영향", "QA 확인 포인트"를 도출할 수 있는지

Confidence 기준:
- Jira fix 확정 + 코드 내용 직접 확인 일치 → `High`
- grep hit 있으나 fix 위치 미특정, 또는 Jira만 확인 → `Medium`
- grep 0건 + query로 코드 확인 → `Medium`
- Jira도 코드도 확인 안 됨 → `Low`

> grep hit는 "브랜치에 문자열이 존재한다"는 뜻일 뿐이다. 이번 빌드에서 변경됐거나 버그 fix와 연결된다는 의미가 아니다. 코드 내용을 직접 열어 확인했을 때만 High로 올린다.

##### 3-2, 3-3, 3-5. 설정/초기값/키워드/플래그 탐색 [STEP 2 완료 후 실행]
STEP 2에서 추출한 키워드를 포함해 아래 세 탐색을 실행한다.

**3-2. 코드 토큰 grep** — 기본 패턴 + STEP 2 추출 키워드 + **STEP 1.5 PR 키워드**를 합쳐 단일 호출로 실행한다.
> 주의: generic 토큰(`Initialize`, `SetActive`, `PlayerPrefs` 등)은 노이즈가 있어도 회수율 보장을 위해 fallback이 아닌 기본 탐색에 포함한다.

```bash
# repob 사용 가능 시
$REPOB remote grep client [BRANCH] \
  "isDebug|debugMode|showConsole|isVisible|isEnabled|defaultValue|initialValue|isActive|isHidden|Initialize|SetActive|PlayerPrefs|RemoteConfig|FeatureFlag|[STEP2_키워드들]|[STEP1.5_PR_키워드들]" --pretty

# gh api fallback — 키워드를 개별 검색으로 분리 (gh search code는 OR 미지원)
for KEYWORD in "[STEP2_키워드들]" "[STEP1.5_PR_키워드들]" "PlayerPrefs" "RemoteConfig" "FeatureFlag"; do
  gh search code "$KEYWORD" --repo bagelcode-cvs/client --json path -L 10
done
```

**3-3. 설정 파일 전용 탐색 [필수 — 스킵 금지]** — ScriptableObject(.asset), JSON, YAML 설정 파일은 위 토큰 없이도 default/config 변경이 들어갈 수 있다. 반드시 실행한다.

> **주의**: 하드코딩된 디렉토리(예: `Assets/Meta/Settings`)가 실제 repo에 존재하지 않을 수 있다. 먼저 1단계 디렉토리 탐색으로 실제 설정 파일 위치를 확인한 후 glob한다.

```bash
# repob 사용 가능 시 — 2단계 접근
# > 주의: repob remote grep은 `--glob` 플래그를 지원하지 않는다. 파일 확장자 필터링은 불가하므로 패턴으로 대체한다.
# 1단계: 설정성 키워드로 grep (파일 확장자 필터 없이 — 결과에서 .cs/.asset/.json 등을 수동 분류)
$REPOB remote grep client [BRANCH] "EnvironmentSettings|RemoteConfig|FeatureFlag|ApplicationSettings" --pretty 2>/dev/null | head -30
# 2단계: STEP 1.5 커밋에서 변경된 설정 파일 경로를 직접 읽기 (커밋 diff에서 .asset/.json 파일 경로 추출 후)
# 커밋 diff 분석에서 이미 발견된 설정 파일(.asset, .json)이 있으면 그 경로를 바로 $REPOB remote read로 확인한다.
# 이 방식이 glob 탐색보다 정확하고 빠르다 — 실제 변경된 파일만 조회하기 때문이다.

# gh api fallback — 동적 탐색: Assets 하위 디렉토리 목록을 먼저 가져온 뒤 설정성 디렉토리를 탐색한다
# 1단계: Assets 하위 디렉토리 목록 확보
DIRS=$(gh api "repos/bagelcode-cvs/client/contents/Assets?ref=[BRANCH]" \
  --jq '.[] | select(.type=="dir") | .path' 2>/dev/null || true)
# 2단계: 이름에 config/setting/data/resource/environment/fsm 등이 포함된 디렉토리에서 설정 파일 탐색
# 주의: .path를 출력해야 이후 파일 읽기에서 경로를 사용할 수 있다 (.name만 출력하면 경로가 끊김)
echo "$DIRS" | while read -r DIR; do
  case "$(echo "$DIR" | tr '[:upper:]' '[:lower:]')" in
    *config*|*setting*|*data*|*resource*|*streaming*|*environment*|*fsm*|*meta*)
      gh api "repos/bagelcode-cvs/client/contents/$DIR?ref=[BRANCH]" \
        --jq '.[] | select(.name | test("\\.(asset|json|ya?ml)$")) | .path' 2>/dev/null || true
      ;;
  esac
done
# 3단계: 발견된 .path 목록으로 이후 파일 읽기를 수행한다
# 예: gh api "repos/bagelcode-cvs/client/contents/[PATH]?ref=[BRANCH]" --jq '.content' | base64 -d
```

> glob/grep 결과가 0건이면 **"3-3 탐색 완료 — 설정 파일 매칭 없음"**으로 명시하고 넘어간다. 404나 빈 결과를 에러로 취급하지 않는다.

결과 중 아래 기준에 해당하는 파일을 우선 열어본다:
- STEP 1.5 PR 키워드 또는 STEP 2 문서 키워드와 파일명이 일치하는 것
- `config`, `setting`, `default`, `data` 등 설정성 명칭을 포함하는 것
- 파일명에 날짜가 있으면 추가 참고로만 활용 (날짜 없는 파일도 반드시 포함)

**열어볼 파일이 없다면**: "3-3 탐색 완료 — 키워드 매칭 파일 없음"으로 명시하고 넘어간다. 결과를 출력하지 않고 넘어가는 것은 허용하지 않는다.

확인 항목:
- default/initial 값, true/false 기본값, enum 기본 선택값 변경
- 부정문 추가/삭제, AND/OR 변경, early return 조건 변경
- enable/disable, show/hide 토글 기본 상태 변경
- ScriptableObject/JSON 설정 파일 내 숫자·플래그 기본값 변경

> **주의 — temporal anchor**: 3-3 결과는 브랜치 현재 상태를 보는 것이다. grep/glob hit는 "이번 빌드에서 변경됐다"는 의미가 아니다. STEP 1.5 PR, STEP 2 문서, Jira 근거 중 하나와 연결될 때만 STEP 5 확정 항목으로 올린다. 근거 없으면 "추가 확인 권고 (Low)" 이하로 표시한다.

##### 3-5. UI/매니저/초기화 경로 우선 확인 [필수 — 스킵 금지]
아래 키워드로 grep을 실행한다. 결과가 없어도 "3-5 탐색 완료 — 해당 패턴 없음"으로 명시해야 한다:

```bash
# repob 사용 가능 시
$REPOB remote grep client [BRANCH] \
  "Manager.*Awake|Manager.*Start|Bootstrap|GameBootstrap|SceneLoader|OnSceneLoaded|DebugMenu|AdminMenu|GMTool|DevConsole|DevEditor" --pretty

# gh api fallback — 키워드를 개별 검색으로 분리
for KEYWORD in "GameBootstrap" "SceneLoader" "DebugMenu" "AdminMenu" "GMTool" "DevConsole" "DevEditor"; do
  gh search code "$KEYWORD" --repo bagelcode-cvs/client --json path -L 10
done
```

확인 대상:
- UI 표시 제어 코드, Manager 계열 클래스의 초기화
- 앱/게임 시작 시 초기화되는 bootstrap 경로
- scene load 직후 실행되는 로직
- debug menu / admin menu / GM tool / console 진입 경로

> **주의 — temporal anchor**: 3-5도 동일하다. hit가 있어도 STEP 1.5 PR, STEP 2 문서, Jira 근거 없이 확정 항목으로 올리지 않는다. 근거 없으면 "추가 확인 권고 (Low)" 이하로 표시한다.

---

### STEP 4: 문서-코드 교차 검증
STEP 2의 문서 내용과 실제 코드 변경을 연결하여 확인한다.

각 항목마다 확인:
- 문서에 적힌 변경 의도
- 실제 반영된 코드 위치
- 문서와 구현이 일치하는지 여부
- 불일치 시 QA 리스크

우선 보고:
- 문서에는 "기본 OFF"인데 코드상 기본 ON인 경우
- 문서에는 "임시 비활성화"인데 실제로는 조건이 살아있는 경우
- 문서에는 "QA 확인 필요"라고 썼지만 관련 코드 수정이 누락된 경우

---

### STEP 5: 핵심 변경 분류 및 QA 목록 작성
STEP 1~4 결과를 통합하여 분류한다.
단순 리팩토링 / 라이브러리 업데이트 / 파일 이동 / 네이밍 정리 / 포맷 수정은 제외한다.

각 항목은 아래 형식으로 작성:

---
**[변경 유형: Bug Fix (Jira 버그 전용) / Behavior / Config / Flag / Doc Mismatch]**
> Bug Fix는 STEP 1에서 수집한 Jira 버그에만 부여한다. Jira 미등록 버그성 변경은 Behavior 또는 Config로 분류하고, STEP 7에서는 7-3(핵심 변경)으로 보낸다.
- **무엇이 바뀌었나**:
- **기존 → 변경 후**:
- **변경 영향**: 실제 사용자/QA 관점에서 무엇이 달라지는가
- **근거**: Jira 티켓 / 문서 경로 / 코드 위치
- **QA 확인 포인트**: 반드시 확인해야 할 테스트 포인트
- **우선순위**: 높음 / 중간 / 낮음
- **Confidence**: High (Jira+코드 일치) / Medium (Jira만 or 코드만) / Low
---

우선순위 기준:
- 기본값 변경 / 노출·비노출 변경 / enable·disable 변경 / 버그픽스: **높음**
- 설정 변경이나 기능 체감 영향이 낮은 경우: **중간**
- 문서 불일치이나 실제 영향이 불명확한 경우: **중간 또는 낮음**

---

### STEP 6: 분석 커버리지 정직 보고 [필수]

```
[분석 커버리지]
- Jira 수집: 스프린트 [N] [Bug] 항목 [M]건 / 이번 빌드 fix 확인 [K]건
- 브랜치 커밋 수집: 날짜 범위 내 [N]건 / 분석 대상 [M]건 / Merge 커밋 [K]건
- GitHub PR 수집: 대상 브랜치 일치 [N]건 / 브랜치 불일치 [M]건 / Jira 미등록 [K]건
- STEP 3-3 설정 파일 탐색: 실행 완료 — 키워드 매칭 [N]건 / 해당 없음
- STEP 3-5 초기화 경로 탐색: 실행 완료 — 해당 패턴 [N]건 / 해당 없음
- 완전히 확인한 영역:
- 샘플링만 한 영역:
- 확인하지 못한 영역:
- 제외한 영역:
- 추가 조사 권고:
```

- Jira에서 버전 언급 없는 버그는 커버리지 밖임을 명시하라.
- repob 사용 불가하여 gh api fallback으로 진행한 경우, 개발 브랜치 grep/glob 제한을 명시하라.
- repob remote grep이 0건을 반환했지만 커밋 diff에서 관련 코드가 확인된 경우, "repob grep 0건 — 인덱싱 미적용 또는 브랜치 미반영 가능성, 커밋 diff 직접 확인으로 대체"로 명시하라. repob 0건 = 코드 없음으로 단정하지 마라.
- repob shallow clone으로 diff 확인 불가한 경우 솔직히 적어라.
- AI가 "전부 다 봤다"는 인상을 주지 마라.

### 분석 결과 파일 저장 [STEP 6 출력 직후 실행]

STEP 5~6의 대화 출력 내용을 `$TMPDIR/analysis_output.md`에 **Write 도구로** 저장한다. 컨텍스트 윈도우가 압축되어도 STEP 7 Slack 전송 시 이 파일을 읽어 메시지를 구성할 수 있다.

> `$TMPDIR`은 스킬 상단 "임시 파일 경로" 섹션에서 초기화된 값을 사용한다. bash에서 `echo $TMPDIR`로 절대경로를 확인한 뒤 Write 도구의 `file_path`에 전달한다.

저장 절차:
1. `echo "$TMPDIR/analysis_output.md"` 로 절대 경로를 확인한다
2. `ls "$TMPDIR/analysis_output.md"` 로 기존 파일 존재 여부를 확인한다
   - **파일이 이미 존재하면**: **Read 도구**로 먼저 읽은 뒤 **Edit 도구**로 전체 내용을 교체한다 (Write 도구는 미읽은 파일에 사용 불가)
   - **파일이 없으면**: **Write 도구**로 새로 생성한다
3. 저장 직후 `ls -la "$TMPDIR/analysis_output.md"` 로 파일 생성/갱신을 확인한다

> STEP 7 시작 시 컨텍스트가 부족하면 **Read 도구**로 위 경로의 `analysis_output.md`를 읽어 Slack 메시지를 구성한다.

---

### STEP 7: Slack 보고 [사용자 승인 후 실행]

STEP 5~6 결과를 대화에 먼저 출력한 뒤, `AskUserQuestion`으로 Slack 전송 여부를 묻는다:

```
question: "분석 결과를 #qa-ai-report 채널에 전송할까요?"
options:
  - label: "전송",  description: "#qa-ai-report 채널에 항목별 메시지 + 스레드로 전송"
  - label: "전송 안 함",  description: "전송하지 않고 종료"
```

"전송 안 함" 선택 시 STEP 7을 스킵하고 종료한다.
"전송" 선택 시 아래 형식으로 `#qa-ai-report` 채널(ID: `C0AQTSRRFHC`)에 **항목별 개별 메시지 + 스레드** 형식으로 전송한다.

> **핵심 구조**: 하나의 메인 메시지에 모든 항목을 나열하는 것이 아니라, **항목마다 별도 메시지를 보내고 각 메시지에 상세 스레드를 단다.**

#### 형식 규칙 (전체 공통)
- Slack Block Kit은 사용하지 않는다. 일반 텍스트(`mrkdwn`)로 전송한다
- **이모지 최소화**: 불필요한 이모지를 넣지 않는다. 텍스트 위주로 작성한다. 이모지는 버그 상태 구분(fix 확정/Pending/fix 취소) 등 의미 전달에 필수적인 경우에만 사용한다
- 이탤릭(`_텍스트_`)은 Slack에서 사용 가능하며, 버전·제목 강조에 활용한다

#### 7-1. 타이틀 메시지 전송

첫 번째 메시지로 분석 개요를 보낸다. 이 메시지에는 스레드를 달지 않는다:

```
_build-diff [빌드 버전] 분석 결과_
날짜: [시작일] ~ [종료일] | [repo] / [베이스 브랜치]
```

#### 7-2. 버그 티켓별 메시지 + 스레드

각 버그 티켓마다 **별도 메시지**를 보내고, 해당 메시지에 **스레드로 상세 정보**를 단다.

**부모 메시지** (채널에 노출) — Jira 링크 + 상태를 포함해 채널에서 바로 식별 가능하게 한다:
```
_[빌드 버전]_
*[CVS-XXXXX]* [Bug] 버그 제목 | fix 확정
{JIRA_BASE}/browse/CVS-XXXXX
```
상태 표기: `fix 확정` / `Pending` / `fix 취소 (재오픈)`

**스레드 답글** (부모 메시지의 `thread_ts` 사용) — 테스터용 정보만. 관련 파일/근거는 7-4 분석 요약으로 분리:
```
_[CVS-XXXXX]_ — [Bug] 버그 제목
fix 댓글: "[댓글 내용]" (작성자, 날짜)
QA 확인: "[확인 내용]" (작성자, 날짜)
상태: fix 확정 / Pending / fix 취소 (재오픈)

무엇이 바뀌었나:
- [STEP 3-1에서 코드를 읽어 확인한 실제 변경 내용]
- 기존: [이전 동작/값]
- 변경: [현재 동작/값]

변경 영향:
- [사용자/QA 관점에서 달라지는 점]

QA 확인 포인트:
1. [확인 항목 1]
2. [확인 항목 2]
```

> `관련 파일: [파일 경로:라인번호]`는 7-4 분석 요약으로 이동했다. 테스터에게 코드 경로는 불필요.

필수 조건:
- "무엇이 바뀌었나", "변경 영향", "QA 확인 포인트"는 **STEP 3-1에서 `$REPOB remote read` (또는 gh api fallback)로 실제 코드를 읽은 결과**를 기반으로 작성한다
- 코드를 읽지 않고 Jira 제목만으로 추정한 내용을 쓰지 않는다
- STEP 3-1에서 코드 확인이 안 된 경우 "⚠️ 코드 미확인 — Jira 정보 기반"을 명시한다

#### 7-3. 핵심 변경별 메시지 + 스레드

STEP 5의 핵심 변경 항목마다 **별도 메시지**를 보내고, 해당 메시지에 **스레드로 코드 분석 상세**를 단다.

> **7-3은 Jira 버그가 아닌 핵심 변경만 다룬다.** Jira 버그(Bug Fix)는 7-2에서 전용으로 처리하므로 7-3에 중복 포함하지 않는다.

**부모 메시지** (채널에 노출):
```
_[빌드 버전]_
[변경 제목] | [변경 유형: Behavior / Config / Flag / Doc Mismatch] | 우선순위: [높음/중간/낮음]
```

**스레드 답글** (부모 메시지의 `thread_ts` 사용) — 테스터용 정보만. 근거는 7-4 분석 요약으로 분리:
```
_[변경 제목]_
변경 유형: [Behavior / Config / Flag / Doc Mismatch]
기존 → 변경 후: [기존 동작/값] → [변경 동작/값]
영향: [사용자/QA 관점에서 달라지는 점]
QA 확인 포인트:
1. [확인 항목 1]
2. [확인 항목 2]
3. [확인 항목 3]
```

> `근거: [문서 경로] + [코드 파일:라인번호]`는 7-4 분석 요약으로 이동했다.

필수 조건:
- "기존 → 변경 후", "영향", "QA 확인 포인트"는 **STEP 3~4에서 실제 코드를 읽은 결과** (3-1 `$REPOB remote read` (또는 gh api fallback), 3-3 설정 파일 확인, 3-5 초기화 경로 확인, STEP 4 문서-코드 교차 검증 등)를 기반으로 작성한다
- 코드를 읽지 않고 추정한 내용을 쓰지 않는다
- 코드 확인이 안 된 경우 스레드 첫 줄에 "코드 미확인 — 문서/Jira 정보 기반"을 명시한다

#### 7-4. 분석 요약 (근거 + 커버리지)

7-2/7-3 스레드에서 분리한 근거·코드 위치·Confidence와 커버리지 보고를 한 곳에 모아 보낸다.

**부모 메시지**:
```
_[빌드 버전]_
*분석 요약* -- 근거 및 커버리지
```

**스레드 답글** — 항목별 근거 + 커버리지 통합:
```
*항목별 근거*

• [CVS-XXXXX] [Bug] 버그 제목
  코드: [파일경로:라인] | Confidence: High
• [변경 제목] [Behavior]
  근거: [문서 경로] + [코드 파일:라인] | Confidence: Medium
• [변경 제목] [Config]
  근거: ⚠️ 코드 미확인 — Jira 정보 기반 | Confidence: Low

*분석 커버리지*
Jira 수집: [Bug] [M]건 / fix 확인 [K]건
GitHub PR: 대상 [N]건 / Jira 미등록 [K]건
확인한 영역: [...]
확인 못한 영역: [...]
추가 조사 권고: [...]
```

> 5000자 초과 시: 항목별 근거(답글1) + 커버리지(답글2)로 분리한다.
> 버그 항목이 0건이면 근거 섹션에 핵심 변경 항목만 나열한다.

#### 7-5. 전송 순서 및 실패 처리

**전송 순서**: 7-1 타이틀 → 7-2 버그 (우선순위 높은 순) → 7-3 핵심 변경 → 7-4 분석 요약
모든 메시지는 **순차 전송**한다. 병렬 전송 시 Slack에서 메시지 순서가 보장되지 않는다.
각 부모 메시지 전송 후 `thread_ts`를 받아 즉시 스레드를 단다. 다음 항목으로 넘어간다.

**실패 처리**:
- Slack 전송 실패(`invalid_blocks`, 권한 오류 등) 시 메시지를 간소화하여 1회 재시도한다
- 재시도도 실패하면 "Slack 전송 실패 — [에러 메시지]"를 대화에 출력하고 스킵한다. 전송 실패가 전체 분석을 중단시키지 않는다

---

## 금지 사항
- 단순 diff 요약으로 끝내지 마라.
- "변경 많음", "여러 파일 수정됨" 같은 추상적 표현으로 뭉개지 마라.
- 커밋 메시지만 보고 의미를 추정하지 마라.
- 증거 없이 "문제 없음"이라고 결론내리지 마라.
- 대규모 커밋에서 전체를 다 본 것처럼 말하지 마라.
- Jira 댓글 없이 버그픽스 여부를 단정하지 마라.
