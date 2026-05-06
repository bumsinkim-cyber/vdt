---
name: build-check
description: 빌드 버전을 입력하면 전 빌드 대비 신규 추가 사항과 리버트를 빠르게 확인합니다. 코드 딥다이브 없이 git log + Jira + PR 수준에서 경량 분석합니다. "/build-check", "빌드 체크", "빌드 확인" 요청 시 사용합니다.
argument-hint: "239.0.3 | 239.0.0~239.0.3"
---

# /build-check — 빌드 경량 체크

> **실행 환경**: 이 스킬의 bash 명령은 Claude Code Bash 도구 기준으로 작성됐다. Windows에서는 Git Bash 환경에서 실행된다. PowerShell에서 직접 실행하면 동작하지 않는다.

## 스킬 목적

빌드 출시 시점에 **빠르게** 확인할 두 가지:
1. **신규 추가 사항** — 전 빌드에 없고 이번 빌드에 새로 들어온 티켓·커밋·PR
2. **리버트 감지** — 이번 빌드 범위에서 revert/rollback된 커밋

> 코드 딥다이브(repob grep/query/read)는 하지 않는다. 개별 티켓의 상세 분석이 필요하면 `/ticket-qa`를 사용한다.

---

## 공통 인프라

### 임시 파일 경로 (Windows/Mac 호환)

Git Bash의 `/tmp`는 Python에서 접근 불가할 수 있다. 모든 임시 파일은 `$TMPDIR`을 사용한다.
**TMPDIR 초기화는 STEP 0에서 빌드 버전 확정 직후에 실행한다.**

이후 모든 코드 블록에서 `/tmp/` 대신 `$TMPDIR/`을 사용한다. Python 코드에서도 `$TMPDIR` 환경변수를 참조해야 하므로 반드시 `export`한다.

### Shell 상태 비유지 대응 (Claude Code Bash 도구 특성)

Claude Code의 Bash 도구는 **각 호출마다 새 셸을 시작**한다. `export`한 환경변수가 다음 호출에서 사라진다.

**해결 패턴**: 초기화 직후 런타임 정보를 `run_context.json`에 저장하고, 이후 Bash 블록에서 필요한 키만 읽는다.

### 블록 자립성 원칙 (필독)

이 스킬은 **이전 Bash 블록의 셸 상태를 신뢰하지 않는다.**

- **persist 대상**은 비밀값이 아닌 "재계산 비용이 있거나 이미 결정된 런타임 결과"만 `$TMPDIR/run_context.json`에 저장한다.
- **비밀값(JIRA_AUTH)**은 run_context.json에 넣지 않는다. Jira 호출이 필요한 블록은 매번 `~/.bagelcode/jira.json`에서 email/token을 읽어 조합한다.

### 공통 부트스트랩 (정본)

**적용 범위**: run_context.json이 생성된 이후의 모든 standalone Bash 블록 (STEP 1 이후)에 아래 부트스트랩을 **그대로** 붙인다. STEP 0 내부 블록은 아직 run_context.json이 없으므로 부트스트랩을 사용하지 않는다. 수정/축약/변형하지 않는다.

> **아래 코드 블록은 형식 예시이다 (직접 실행 대상 아님).** `{BUILD_VER}` 등 placeholder를 실제 값으로 치환한 뒤 각 STEP 블록 앞에 삽입한다.

```bash
# ── 공통 부트스트랩 (정본 — 수정 금지) ──
BUILD_VER={확정된 빌드 버전}
export TMPDIR="$(cygpath -m /tmp 2>/dev/null || echo /tmp)/build-check-${BUILD_VER}"
PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)
CTX="$TMPDIR/run_context.json"

[ -f "$CTX" ] || { echo "ERROR: run_context.json not found: $CTX"; exit 1; }
```

그 다음, **해당 블록에 필요한 키만** run_context.json에서 추출한다:

```bash
# 블록별 필요한 키만 추출 (전부 복원하지 않는다)
BRANCH=$($PYTHON -c "import json,sys; print(json.load(open(sys.argv[1], encoding='utf-8'))['branch'])" "$CTX")
START_ISO=$($PYTHON -c "import json,sys; print(json.load(open(sys.argv[1], encoding='utf-8'))['start_iso'])" "$CTX")
END_ISO=$($PYTHON -c "import json,sys; print(json.load(open(sys.argv[1], encoding='utf-8'))['end_iso'])" "$CTX")

# Jira 호출이 필요한 블록만 — 비밀값은 매번 jira.json에서 재구성
JIRA_JSON=$($PYTHON -c "import json,sys; print(json.load(open(sys.argv[1], encoding='utf-8'))['jira_json_path'])" "$CTX")
JIRA_BASE=$($PYTHON -c "import json,sys; print(json.load(open(sys.argv[1], encoding='utf-8'))['jira_base'])" "$CTX")
JIRA_EMAIL=$($PYTHON -c "import json,sys; print(json.load(open(sys.argv[1], encoding='utf-8'))['email'])" "$JIRA_JSON")
JIRA_TOKEN=$($PYTHON -c "import json,sys; print(json.load(open(sys.argv[1], encoding='utf-8'))['token'])" "$JIRA_JSON")
JIRA_AUTH="$JIRA_EMAIL:$JIRA_TOKEN"
```

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

### 코드 블록 실행 규칙 (필독)

1. **블록 분리 금지**: 이 스킬의 각 코드 블록은 **하나의 Bash 호출로 실행**한다. 병렬화·최적화 목적으로 블록을 쪼개거나 재구성하지 않는다.
2. **설계 의도 주석 필독**: 코드 블록 상단에 `> **설계 의도**` 또는 `# ⚠️` 주석이 있으면 반드시 읽고 이해한 뒤 실행한다.

### 파일 루프 패턴 (필독)

> **⚠️ `while read ... done < file` 금지**: `done < file`은 루프 전체의 stdin을 리다이렉트한다.
>
> **정본 패턴**: `mapfile -t ARRAY < file` + `for ITEM in "${ARRAY[@]}"`를 사용한다.
>
> ```bash
> # ✅ 정본 패턴
> mapfile -t ITEMS < "$TMPDIR/targets.txt"
> for ITEM in "${ITEMS[@]}"; do
>   ITEM=$(echo "$ITEM" | tr -d '\r\n')
>   [ -z "$ITEM" ] && continue
>   # ... 처리
> done
>
> # ❌ 금지 패턴
> while IFS= read -r ITEM; do ... done < file
> for ITEM in $(cat file); do ... done
> ```

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
JIRA_JSON="$(cygpath -m "$HOME/.bagelcode/jira.json" 2>/dev/null || echo "$HOME/.bagelcode/jira.json")"

# 파일 존재 및 JSON 유효성 사전 검사
if [ ! -f "$JIRA_JSON" ]; then
  echo "~/.bagelcode/jira.json 파일이 없습니다. 아래 형식으로 파일을 생성한 뒤 다시 실행해 주세요:"
  printf '{\n  "domain": "yourcompany.atlassian.net",\n  "email": "your.email@company.com",\n  "token": "YOUR_JIRA_API_TOKEN",\n  "board_id": 1\n}\n'
  exit 1
fi
if ! $PYTHON -c "import json; json.load(open('$JIRA_JSON', encoding='utf-8', errors='replace'))" 2>/dev/null; then
  echo "~/.bagelcode/jira.json 파일이 손상됐습니다 (JSON 파싱 실패). 파일 내용을 확인해 주세요."
  exit 1
fi

JIRA_DOMAIN=$($PYTHON -c "import json,sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace'); d=json.load(open(sys.argv[1], encoding='utf-8', errors='replace')); print(d['domain'])" "$JIRA_JSON")
JIRA_EMAIL=$($PYTHON -c "import json,sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace'); d=json.load(open(sys.argv[1], encoding='utf-8', errors='replace')); print(d['email'])" "$JIRA_JSON")
JIRA_TOKEN=$($PYTHON -c "import json,sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace'); d=json.load(open(sys.argv[1], encoding='utf-8', errors='replace')); print(d['token'])" "$JIRA_JSON")
JIRA_BOARD=$($PYTHON -c "import json,sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace'); d=json.load(open(sys.argv[1], encoding='utf-8', errors='replace')); print(d['board_id'])" "$JIRA_JSON")
JIRA_AUTH="$JIRA_EMAIL:$JIRA_TOKEN"
JIRA_BASE="https://$JIRA_DOMAIN"
```

파일이 없으면 안내를 출력하고 **실행을 중단**한다. 토큰을 채팅으로 직접 받지 않는다.

---

## STEP 0: 날짜 범위 결정 + 환경 초기화

인자 형식을 판별하여 아래 두 케이스로 분기한다.

### 케이스 A — 빌드 번호 하나 (예: `239.0.3`)
`~` 없음 + `숫자.숫자.숫자` 형식

1. 이전 버전 계산:
   - 마지막 숫자를 1 감소. (예: `239.0.3` → `239.0.2`)
   - 마지막 숫자가 0이고 중간 숫자가 1 이상이면: 중간 숫자를 1 감소, 마지막은 직전 빌드 번호를 Slack `#cvs-build`에서 검색하여 결정한다. 검색 실패 시 `AskUserQuestion`으로 직접 입력받는다.
   - **마지막·중간 숫자가 모두 0인 경우 (예: `239.0.0`)**: 스프린트 경계를 자동 추론할 수 없으므로 `AskUserQuestion`으로 시작일을 직접 입력받는다.

2. Slack `#cvs-build`(ID: `C4FBFBA0P`) 조회:
   > **`query` 파라미터만 사용한다.** `sort`, `limit`, `include_bots`, `response_format` 등 추가 파라미터는 MCP tool에서 `invalid_arguments`를 유발하므로 **사용하지 않는다.**
   > 검색 결과가 여러 건 반환되므로, **Python으로 결과 중 가장 이른 timestamp를 추출**한다.
   - **일반 케이스**: 이전 버전 + 입력 버전 각각 조회
     - `slack_search_public_and_private`, query: `[이전 버전] in:#cvs-build` → 결과 중 최소 timestamp → 시작일
     - `slack_search_public_and_private`, query: `[입력 버전] in:#cvs-build` → 결과 중 최소 timestamp → 종료일
   - **x.0.0 케이스**: 시작일은 위에서 직접 입력받은 값 사용, 종료일만 Slack 조회
   - **검색 결과에서 최소 timestamp 추출 방법**: Slack MCP 결과는 구조화 데이터가 아닌 **마크다운 텍스트**로 반환된다. 각 결과의 `Time:` 필드에서 날짜·시각을 직접 비교하여 가장 이른 시각을 시작일/종료일로 선택한다. **LLM이 텍스트를 읽고 최소값을 판별**하는 방식이다.
   - **검색 실패 시**: `slack_read_channel`은 봇 메시지 텍스트가 비어있어 빌드 버전 확인이 불가하므로 사용하지 않는다. 검색 실패 시 즉시 `AskUserQuestion`으로 날짜 직접 입력 요청.

3. 검색 결과 없으면 `AskUserQuestion`으로 날짜 직접 입력 요청.

4. 분석 대상 repo / 베이스 브랜치 결정:
   - repo: `client`
   - 브랜치용 스프린트 번호: 빌드 번호의 **첫 세그먼트** 사용 (예: `239.0.3` → `239` → `Develop/239/Main`)
   - Jira 스프린트 이름: **첫 두 세그먼트** 사용 (예: `239.0.3` → `239.0`)

### 케이스 B — 빌드 범위 (예: `239.0.0~239.0.3`)
`~` 있음 + 양쪽 모두 `숫자.숫자.숫자` 형식

1. Slack `#cvs-build`(ID: `C4FBFBA0P`)에서 시작·종료 빌드의 최초 등장 시각 검색:
   > **`query` 파라미터만 사용한다.**
   - `slack_search_public_and_private`, query: `[시작 빌드] in:#cvs-build` → 결과 중 최소 timestamp → 시작일
   - `slack_search_public_and_private`, query: `[종료 빌드] in:#cvs-build` → 결과 중 최소 timestamp → 종료일

2. 검색 결과 없으면 `AskUserQuestion`으로 날짜 직접 입력 요청.

3. 분석 대상 repo / 베이스 브랜치 결정:
   - repo: `client`
   - 시작 빌드와 종료 빌드의 첫 세그먼트가 같으면 그 값을 스프린트 번호로 사용
   - 서로 다르면 `AskUserQuestion`으로 기준 스프린트를 직접 묻는다.

### TMPDIR 초기화 + run_context.json 생성

빌드 버전과 날짜 범위가 확정되면 즉시 실행한다:

```bash
BUILD_VER={확정된 빌드 버전 또는 범위}
export TMPDIR="$(cygpath -m /tmp 2>/dev/null || echo /tmp)/build-check-${BUILD_VER}"
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"
```

run_context.json 저장:

```bash
$PYTHON -c "
import json, sys, os
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
ctx = {
    'build_ver': '[빌드 버전]',
    'prev_ver': '[이전 빌드 버전]',
    'branch': '[Develop/NNN/Main]',
    'sprint_name': '[NNN.N]',
    'start_iso': '[시작 ISO8601]',
    'end_iso': '[종료 ISO8601]',
    'start_date': '[YYYY-MM-DD]',
    'end_date': '[YYYY-MM-DD]',
    'jira_json_path': '$JIRA_JSON',
    'jira_base': '$JIRA_BASE',
    'jira_board': $JIRA_BOARD
}
with open(os.path.join(os.environ['TMPDIR'], 'run_context.json'), 'w', encoding='utf-8') as f:
    json.dump(ctx, f, ensure_ascii=False, indent=2)
print('run_context.json saved')
"
```

### run_context.json 스키마

| 키 | 필수 | 설명 |
|---|---|---|
| `build_ver` | O | 분석 대상 빌드 버전 (예: 239.0.3) |
| `prev_ver` | O | 이전 빌드 버전 (예: 239.0.2) |
| `branch` | O | 대상 브랜치 (예: Develop/239/Main) |
| `sprint_name` | O | Jira 스프린트 이름 (예: 239.0) |
| `start_iso` | O | 시작 시각 ISO8601 |
| `end_iso` | O | 종료 시각 ISO8601 |
| `start_date` | O | 시작 날짜 YYYY-MM-DD |
| `end_date` | O | 종료 날짜 YYYY-MM-DD |
| `jira_json_path` | O | ~/.bagelcode/jira.json 절대 경로 |
| `jira_base` | O | https://{domain} |
| `jira_board` | O | Jira board ID |

**제외 항목**: `jira_auth`, `email`, `token` — 비밀값은 저장하지 않는다.

---

## STEP 1: 신규 추가 사항 수집

**목적**: 전 빌드 이후 ~ 이번 빌드까지 새로 들어온 커밋·PR·티켓 목록을 수집한다.

> STEP 1-1(커밋 조회)과 STEP 1-2(PR 조회)는 독립적이므로 **병렬 실행**한다.

### 1-1. 브랜치 커밋 조회

날짜 범위 내 대상 브랜치에 들어간 모든 커밋을 조회한다. Slack에서 얻은 시각(UTC)을 `since`/`until`에 사용한다.

```bash
# ── 부트스트랩 (생략 — 공통 부트스트랩 삽입) ──

PAGE=1
> "$TMPDIR/commits_raw.txt"
while true; do
  RESP=$(gh api "repos/bagelcode-cvs/client/commits?sha=${BRANCH}&since=${START_ISO}&until=${END_ISO}&per_page=100&page=${PAGE}" 2>/dev/null)
  echo "$RESP" > "$TMPDIR/_commits_page.json"
  COUNT=$($PYTHON -c "
import sys, json
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
with open('$TMPDIR/_commits_page.json', encoding='utf-8', errors='replace') as f:
    commits = json.load(f)
for c in commits:
    sha = c['sha'][:8]
    date = c['commit']['author']['date']
    author = c['commit']['author']['name']
    msg = c['commit']['message'].split('\n')[0][:120]
    print(f'{sha}|{date}|{author}|{msg}')
print(f'__COUNT__={len(commits)}', file=sys.stderr)
" >> "$TMPDIR/commits_raw.txt" 2>"$TMPDIR/_count.txt")
  THIS_COUNT=$($PYTHON -c "
import re
with open('$TMPDIR/_count.txt', encoding='utf-8', errors='replace') as f:
    m = re.search(r'__COUNT__=(\d+)', f.read())
    print(m.group(1) if m else '0')
")
  [ "$THIS_COUNT" -lt 100 ] && break
  PAGE=$((PAGE + 1))
done
```

**자동 스킵 대상** — 아래 커밋은 집계에서 제외한다:
- `Version up` / `version up`으로 시작하는 버전업 커밋
- `.meta` 파일만 변경된 커밋

```bash
# ── 부트스트랩 (생략) ──

# 버전업/meta-only 커밋 필터링
$PYTHON -c "
import sys, re
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
with open('$TMPDIR/commits_raw.txt', encoding='utf-8', errors='replace') as f:
    lines = f.readlines()
filtered = []
for line in lines:
    line = line.strip()
    if not line: continue
    parts = line.split('|', 3)
    if len(parts) < 4: continue
    msg = parts[3].lower()
    if msg.startswith('version up'): continue
    filtered.append(line)
with open('$TMPDIR/commits_filtered.txt', 'w', encoding='utf-8') as f:
    f.write('\n'.join(filtered))
print(f'전체 커밋: {len(lines)}건 / 필터 후: {len(filtered)}건')
"
```

### 1-2. PR 날짜 기반 조회 [1-1과 병렬 실행]

> 주의: `merged:` 검색은 **날짜(YYYY-MM-DD) 단위**다. 시각(HH:MM)은 사용하지 않는다.

```bash
# ── 부트스트랩 (생략) ──

gh pr list \
  --repo bagelcode-cvs/client \
  --state merged \
  --search "merged:${START_DATE}..${END_DATE}" \
  --json number,title,body,mergedAt,author,baseRefName,mergeCommit \
  --limit 500 > "$TMPDIR/pr_list.json"

# 대상 브랜치 필터 + Jira 키 추출
$PYTHON -c "
import sys, json, re
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
with open('$TMPDIR/pr_list.json', encoding='utf-8', errors='replace') as f:
    prs = json.load(f)
matched = []
unmatched = []
for pr in prs:
    base = pr.get('baseRefName', '')
    if base == '${BRANCH}':
        matched.append(pr)
    else:
        unmatched.append(pr)

# 대상 브랜치 일치 PR 저장
with open('$TMPDIR/pr_matched.json', 'w', encoding='utf-8') as f:
    json.dump(matched, f, ensure_ascii=False, indent=2)

# Jira 키 추출
jira_keys = set()
for pr in matched:
    title = pr.get('title', '')
    body = pr.get('body', '') or ''
    keys = re.findall(r'CVS-\d+', title + ' ' + body)
    jira_keys.update(keys)
with open('$TMPDIR/jira_keys_from_pr.txt', 'w', encoding='utf-8') as f:
    f.write('\n'.join(sorted(jira_keys)))

print(f'PR 전체: {len(prs)}건 / 대상 브랜치 일치: {len(matched)}건 / 브랜치 불일치: {len(unmatched)}건')
print(f'Jira 키 추출: {len(jira_keys)}건')
"
```

**경계일 후처리 [필수]**: `merged:` 검색은 날짜 단위라 경계일에 무관한 PR이 섞일 수 있다. 조회 후 각 PR의 `mergedAt` 타임스탬프를 실제 시작/종료 시각과 비교한다:
- 시각 범위 안: 정상 포함
- 경계일이지만 시각 범위 밖: **"경계일 PR (시각 범위 밖)"** 으로 분리하여 별도 표시

### 1-3. 커밋 + PR 통합 및 Jira 티켓 제목 수집

1-1, 1-2 완료 후 실행한다.

```bash
# ── 부트스트랩 (생략) ──

# SHA → PR 매핑
$PYTHON -c "
import sys, json
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

with open('$TMPDIR/pr_matched.json', encoding='utf-8', errors='replace') as f:
    prs = json.load(f)
with open('$TMPDIR/commits_filtered.txt', encoding='utf-8', errors='replace') as f:
    commits = [l.strip() for l in f if l.strip()]

# PR의 mergeCommit SHA → PR 매핑 테이블
sha_to_pr = {}
for pr in prs:
    mc = pr.get('mergeCommit') or {}
    sha = mc.get('oid', '')[:8]
    if sha:
        sha_to_pr[sha] = pr

# 통합: 커밋에 PR 정보 보강
results = []
matched_shas = set()
for line in commits:
    parts = line.split('|', 3)
    sha = parts[0]
    if sha in sha_to_pr:
        pr = sha_to_pr[sha]
        results.append({'type': 'pr', 'sha': sha, 'pr_num': pr['number'], 'title': pr['title'], 'date': parts[1], 'author': parts[2]})
        matched_shas.add(sha)
    else:
        results.append({'type': 'commit', 'sha': sha, 'msg': parts[3] if len(parts)>3 else '', 'date': parts[1], 'author': parts[2]})

# PR만 있고 커밋 매칭 안 된 것 추가
for pr in prs:
    mc = pr.get('mergeCommit') or {}
    sha = mc.get('oid', '')[:8]
    if sha and sha not in matched_shas:
        results.append({'type': 'pr', 'sha': sha, 'pr_num': pr['number'], 'title': pr['title'], 'date': pr.get('mergedAt',''), 'author': pr.get('author',{}).get('login','')})

with open('$TMPDIR/integrated.json', 'w', encoding='utf-8') as f:
    json.dump(results, f, ensure_ascii=False, indent=2)
print(f'통합 결과: {len(results)}건 (PR 매칭: {len(matched_shas)}건)')
"
```

**Jira 티켓 제목 + 타입 일괄 조회** — PR/커밋에서 추출한 Jira 키의 제목·타입·내부ID를 가져온다.

```bash
# ── 부트스트랩 (생략) ──

# 커밋 메시지에서도 CVS-\d+ 추출하여 합침
$PYTHON -c "
import sys, re
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
keys = set()
# PR에서 추출한 키
with open('$TMPDIR/jira_keys_from_pr.txt', encoding='utf-8', errors='replace') as f:
    for line in f:
        k = line.strip()
        if k: keys.add(k)
# 커밋 메시지에서 추출
with open('$TMPDIR/commits_filtered.txt', encoding='utf-8', errors='replace') as f:
    for line in f:
        found = re.findall(r'CVS-\d+', line)
        keys.update(found)
with open('$TMPDIR/all_jira_keys.txt', 'w', encoding='utf-8') as f:
    f.write('\n'.join(sorted(keys)))
print(f'Jira 키 합계: {len(keys)}건')
" 

# Jira 제목 일괄 조회 (5건씩 병렬 — 개별 파일에 저장 후 합침)
mapfile -t KEYS < "$TMPDIR/all_jira_keys.txt"
_JOB_COUNT=0
for KEY in "${KEYS[@]}"; do
  KEY=$(echo "$KEY" | tr -d '\r\n')
  [ -z "$KEY" ] && continue
  (
    RESP=$(curl -s -u "$JIRA_AUTH" "$JIRA_BASE/rest/api/2/issue/${KEY}?fields=summary,issuetype,status")
    echo "$RESP" > "$TMPDIR/_jira_${KEY}.json"
  ) &
  _JOB_COUNT=$((_JOB_COUNT + 1))
  if [ "$_JOB_COUNT" -ge 5 ]; then wait; _JOB_COUNT=0; fi
done
wait

# 병렬 완료 후 개별 JSON → jira_titles.txt 합침 (동시 쓰기 방지)
$PYTHON -c "
import sys, json, os, re
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
tmpdir = os.environ.get('TMPDIR', '')
with open(os.path.join(tmpdir, 'all_jira_keys.txt'), encoding='utf-8', errors='replace') as f:
    keys = [l.strip() for l in f if l.strip()]
lines = []
for key in keys:
    fpath = os.path.join(tmpdir, f'_jira_{key}.json')
    if not os.path.exists(fpath): continue
    with open(fpath, encoding='utf-8', errors='replace') as jf:
        d = json.load(jf)
    summary = d.get('fields',{}).get('summary','')
    itype = d.get('fields',{}).get('issuetype',{}).get('name','')
    internal_id = d.get('id','')
    lines.append(f'{key}|{itype}|{summary}|{internal_id}')
with open(os.path.join(tmpdir, 'jira_titles.txt'), 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines) + '\n')
print(f'Jira 제목 합침: {len(lines)}건')
"
```

### 1-4. Bug 티켓 댓글 순회 — fix 상태 판정

Jira 제목 조회에서 `[Bug]`가 포함된 티켓만 대상으로 댓글을 순회하여 fix 상태를 판정한다. Bug가 아닌 티켓은 스킵한다.

> 댓글 조회는 **5건씩 병렬**로 실행한다. Jira rate limit를 고려하여 동시 요청은 5건 이하로 제한한다.

```bash
# ── 부트스트랩 (생략) ──

# Bug 티켓만 추출
$PYTHON -c "
import sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
with open('$TMPDIR/jira_titles.txt', encoding='utf-8', errors='replace') as f:
    for line in f:
        line = line.strip()
        if not line: continue
        parts = line.split('|', 3)
        if len(parts) >= 4 and '[bug]' in parts[2].lower():
            print(f'{parts[0]}|{parts[3]}')  # key|internal_id
" > "$TMPDIR/bug_keys.txt"

BUG_COUNT=$(wc -l < "$TMPDIR/bug_keys.txt" | tr -d ' ')
echo "Bug 티켓: ${BUG_COUNT}건"

if [ "$BUG_COUNT" -eq 0 ]; then
  echo "{}" > "$TMPDIR/bug_fix_status.json"
  exit 0
fi

# 댓글 조회 (5건씩 병렬)
mapfile -t BUG_LINES < "$TMPDIR/bug_keys.txt"
_JOB_COUNT=0
for BUG_LINE in "${BUG_LINES[@]}"; do
  BUG_LINE=$(echo "$BUG_LINE" | tr -d '\r\n')
  [ -z "$BUG_LINE" ] && continue
  BUG_KEY=$(echo "$BUG_LINE" | cut -d'|' -f1)
  (
    # 댓글 전체 수집 (페이지네이션)
    START=0
    > "$TMPDIR/_comments_${BUG_KEY}.json"
    echo "[" > "$TMPDIR/_comments_${BUG_KEY}.json"
    FIRST=1
    while true; do
      RESP=$(curl -s -u "$JIRA_AUTH" \
        "$JIRA_BASE/rest/api/3/issue/${BUG_KEY}/comment?maxResults=50&startAt=${START}&orderBy=created")
      echo "$RESP" > "$TMPDIR/_comment_page_${BUG_KEY}.json"
      $PYTHON -c "
import sys, json
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
with open('$TMPDIR/_comment_page_${BUG_KEY}.json', encoding='utf-8', errors='replace') as f:
    d = json.load(f)
comments = d.get('comments', [])
total = d.get('total', 0)
fetched = len(comments)
# ADF → 텍스트 추출
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
for c in comments:
    body_text = extract_text(c.get('body', ''))
    author = c.get('author', {}).get('displayName', '')
    created = c.get('created', '')[:10]
    print(json.dumps({'body': body_text, 'author': author, 'created': created}, ensure_ascii=False))
print(f'__TOTAL__={total}', file=sys.stderr)
print(f'__FETCHED__={fetched}', file=sys.stderr)
" >> "$TMPDIR/_comments_text_${BUG_KEY}.txt" 2>"$TMPDIR/_cpag_${BUG_KEY}.txt"
      TOTAL=$($PYTHON -c "
import re
with open('$TMPDIR/_cpag_${BUG_KEY}.txt', encoding='utf-8', errors='replace') as f:
    t = f.read()
m = re.search(r'__TOTAL__=(\d+)', t)
print(m.group(1) if m else '0')
")
      FETCHED=$($PYTHON -c "
import re
with open('$TMPDIR/_cpag_${BUG_KEY}.txt', encoding='utf-8', errors='replace') as f:
    t = f.read()
m = re.search(r'__FETCHED__=(\d+)', t)
print(m.group(1) if m else '0')
")
      START=$((START + FETCHED))
      [ "$START" -ge "$TOTAL" ] && break
    done
  ) &
  _JOB_COUNT=$((_JOB_COUNT + 1))
  if [ "$_JOB_COUNT" -ge 5 ]; then wait; _JOB_COUNT=0; fi
done
wait
echo "Bug 댓글 수집 완료"
```

**fix 상태 판정** — 빌드 버전 기반으로 댓글을 시간순 확인한다.

```bash
# ── 부트스트랩 (생략) ──

BUILD_VER=$($PYTHON -c "import json,sys; print(json.load(open(sys.argv[1], encoding='utf-8'))['build_ver'])" "$CTX")

$PYTHON -c "
import sys, json, re, os, glob
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

build_ver = '${BUILD_VER}'
# 빌드 범위인 경우 모든 버전을 매칭 대상으로
# 예: 239.0.0~239.0.3 → [239.0.0, 239.0.1, 239.0.2, 239.0.3]
if '~' in build_ver:
    start_v, end_v = build_ver.split('~')
    sp = start_v.split('.')
    ep = end_v.split('.')
    versions = []
    for patch in range(int(sp[2]), int(ep[2]) + 1):
        versions.append(f'{sp[0]}.{sp[1]}.{patch}')
else:
    versions = [build_ver]

ver_pattern = '|'.join(re.escape(v) for v in versions)

bug_status = {}
tmpdir = os.environ['TMPDIR']

# Bug 키 목록 로드
with open(os.path.join(tmpdir, 'bug_keys.txt'), encoding='utf-8', errors='replace') as f:
    bug_keys = [line.strip().split('|')[0] for line in f if line.strip()]

for key in bug_keys:
    comments_file = os.path.join(tmpdir, f'_comments_text_{key}.txt')
    if not os.path.exists(comments_file):
        bug_status[key] = {'status': 'unknown', 'detail': '댓글 수집 실패'}
        continue

    comments = []
    with open(comments_file, encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                comments.append(json.loads(line))
            except:
                continue

    fix_comment = None
    cancel_comment = None
    qa_comment = None

    for c in comments:
        body = c['body']
        # 버전 매칭 확인
        has_ver = bool(re.search(ver_pattern, body))
        # fix 키워드
        fix_keywords = bool(re.search(r'수정|적용|fix|resolved|확인\s*가능', body, re.IGNORECASE))
        # 취소 키워드
        cancel_keywords = bool(re.search(r'수정\s*안\s*됐|미수정|재현됨|다시\s*수정|재오픈|not\s*fixed', body, re.IGNORECASE))
        # QA 확인 키워드
        qa_keywords = bool(re.search(r'q\d+\.\d+\.\d+|QA\s*확인|테스트\s*완료|확인\s*완료', body, re.IGNORECASE))

        if has_ver and fix_keywords and not cancel_keywords:
            fix_comment = c
        if cancel_keywords:
            cancel_comment = c
        if qa_keywords and has_ver:
            qa_comment = c

    def fmt(c):
        return f"{c['body'][:80]} ({c['author']}, {c['created']})"

    if fix_comment and qa_comment and not cancel_comment:
        bug_status[key] = {
            'status': 'fix_confirmed',
            'fix': fmt(fix_comment),
            'qa': fmt(qa_comment)
        }
    elif fix_comment and cancel_comment:
        bug_status[key] = {
            'status': 'fix_cancelled',
            'fix': fmt(fix_comment),
            'cancel': fmt(cancel_comment)
        }
    elif fix_comment:
        bug_status[key] = {
            'status': 'pending',
            'fix': fmt(fix_comment)
        }
    else:
        bug_status[key] = {'status': 'no_mention', 'detail': '빌드 버전 언급 없음'}

with open(os.path.join(tmpdir, 'bug_fix_status.json'), 'w', encoding='utf-8') as f:
    json.dump(bug_status, f, ensure_ascii=False, indent=2)

# 요약
confirmed = sum(1 for v in bug_status.values() if v['status'] == 'fix_confirmed')
pending = sum(1 for v in bug_status.values() if v['status'] == 'pending')
cancelled = sum(1 for v in bug_status.values() if v['status'] == 'fix_cancelled')
no_mention = sum(1 for v in bug_status.values() if v['status'] == 'no_mention')
print(f'Bug fix 판정: fix 확정 {confirmed}건 / Pending {pending}건 / fix 취소 {cancelled}건 / 버전 미언급 {no_mention}건')
"
```

**판정 규칙:**
1. 대상 빌드 버전 + 수정 관련 키워드가 함께 있는 댓글 → **fix 후보**
2. fix 후보 이후 취소 키워드(`수정 안됐음`, `미수정`, `재현됨`, `재오픈`) 발견 → **fix 취소**
3. fix 후보 + QA 확인 댓글 + 취소 없음 → **fix 확정**
4. fix 후보만 있고 QA 확인도 취소도 없음 → **Pending (QA 미확인)**
5. 버전 언급 없음 → **버전 미언급** (이번 빌드 대상 아닐 수 있음)

### 1-5. 신규 추가 사항 결과 정리

Bug 티켓은 fix 상태를 함께 표시한다.

```bash
# ── 부트스트랩 (생략) ──

$PYTHON -c "
import sys, json, re
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

# 데이터 로드
with open('$TMPDIR/integrated.json', encoding='utf-8', errors='replace') as f:
    items = json.load(f)

jira_titles = {}
with open('$TMPDIR/jira_titles.txt', encoding='utf-8', errors='replace') as f:
    for line in f:
        line = line.strip()
        if not line: continue
        parts = line.split('|', 3)
        if len(parts) >= 3:
            jira_titles[parts[0]] = {'type': parts[1], 'summary': parts[2]}

# Bug fix 상태 로드
bug_status = {}
try:
    with open('$TMPDIR/bug_fix_status.json', encoding='utf-8', errors='replace') as f:
        bug_status = json.load(f)
except:
    pass

STATUS_LABELS = {
    'fix_confirmed': 'fix 확정',
    'pending': 'Pending',
    'fix_cancelled': 'fix 취소',
    'no_mention': '버전 미언급',
    'unknown': '확인 불가'
}

# 티켓 기반으로 그룹핑
ticket_items = {}   # key → [items]
no_ticket_items = []

for item in items:
    text = item.get('title', '') or item.get('msg', '')
    keys = re.findall(r'CVS-\d+', text)
    if keys:
        for k in keys:
            ticket_items.setdefault(k, []).append(item)
    else:
        no_ticket_items.append(item)

# Bug 티켓과 일반 티켓 분리
bug_tickets = {}
normal_tickets = {}
for key, sub_items in ticket_items.items():
    info = jira_titles.get(key, {})
    if '[bug]' in info.get('summary', '').lower():
        bug_tickets[key] = sub_items
    else:
        normal_tickets[key] = sub_items

# 출력
print('[신규 추가 사항]')
print(f'커밋 {len([i for i in items if i[\"type\"]==\"commit\"])}건 / PR {len([i for i in items if i[\"type\"]==\"pr\"])}건 / 티켓 {len(ticket_items)}건 (Bug {len(bug_tickets)}건)')
print()

# Bug 티켓 (fix 상태 포함)
if bug_tickets:
    print('■ Bug 티켓')
    for key in sorted(bug_tickets.keys()):
        info = jira_titles.get(key, {})
        summary = info.get('summary', '')
        sub_items = bug_tickets[key]
        pr_nums = [str(i['pr_num']) for i in sub_items if i['type'] == 'pr']
        pr_str = ', '.join(f'PR #{n}' for n in pr_nums) if pr_nums else '직접 커밋'

        bs = bug_status.get(key, {})
        status_str = STATUS_LABELS.get(bs.get('status', 'unknown'), '확인 불가')
        status_icon = {'fix_confirmed': 'v', 'pending': '?', 'fix_cancelled': 'x', 'no_mention': '-'}.get(bs.get('status',''), '?')
        print(f'- [{status_icon}] {key}: {summary} ({pr_str}) — {status_str}')

        # fix/QA 댓글 요약
        if bs.get('fix'):
            print(f'    fix: {bs[\"fix\"]}')
        if bs.get('qa'):
            print(f'    QA: {bs[\"qa\"]}')
        if bs.get('cancel'):
            print(f'    취소: {bs[\"cancel\"]}')
    print()

# 일반 티켓
if normal_tickets:
    print('■ 일반 티켓')
    for key in sorted(normal_tickets.keys()):
        info = jira_titles.get(key, {})
        itype = info.get('type', '')
        summary = info.get('summary', '')
        sub_items = normal_tickets[key]
        pr_nums = [str(i['pr_num']) for i in sub_items if i['type'] == 'pr']
        pr_str = ', '.join(f'PR #{n}' for n in pr_nums) if pr_nums else '직접 커밋'
        type_tag = f'[{itype}] ' if itype else ''
        print(f'- {key}: {type_tag}{summary} ({pr_str})')
    print()

if no_ticket_items:
    print('■ Jira 미등록 변경')
    for item in no_ticket_items:
        if item['type'] == 'pr':
            print(f'- PR #{item[\"pr_num\"]}: {item[\"title\"]}')
        else:
            print(f'- 커밋 {item[\"sha\"]}: {item[\"msg\"]}')
" | tee "$TMPDIR/step1_output.txt"
```

---

## STEP 2: 리버트 감지

**목적**: 이번 빌드 범위에서 revert/rollback된 커밋을 감지한다.

### 2-1. 리버트 커밋 감지

커밋 메시지에서 `Revert`, `revert`, `rollback` 패턴을 탐지한다.

```bash
# ── 부트스트랩 (생략) ──

$PYTHON -c "
import sys, re
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
with open('$TMPDIR/commits_raw.txt', encoding='utf-8', errors='replace') as f:
    lines = f.readlines()
reverts = []
for line in lines:
    line = line.strip()
    if not line: continue
    parts = line.split('|', 3)
    if len(parts) < 4: continue
    msg = parts[3]
    if re.search(r'\b(revert|rollback)\b', msg, re.IGNORECASE):
        reverts.append({'sha': parts[0], 'date': parts[1], 'author': parts[2], 'msg': msg})

        # Revert 대상 추출 시도 — 'Revert \"원본 메시지\"' 패턴
        m = re.search(r'[Rr]evert\s+\"(.+?)\"', msg)
        if m:
            reverts[-1]['original_msg'] = m.group(1)

with open('$TMPDIR/reverts.json', 'w', encoding='utf-8') as f:
    import json
    json.dump(reverts, f, ensure_ascii=False, indent=2)
print(f'리버트/롤백 커밋: {len(reverts)}건')
" | tee "$TMPDIR/step2_reverts.txt"
```

### 2-2. 리버트 결과 정리

```bash
# ── 부트스트랩 (생략) ──

$PYTHON -c "
import sys, json
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

with open('$TMPDIR/reverts.json', encoding='utf-8', errors='replace') as f:
    reverts = json.load(f)

print('[리버트 감지]')
print()

if reverts:
    print(f'■ 리버트/롤백 커밋: {len(reverts)}건')
    for r in reverts:
        original = r.get('original_msg', '')
        if original:
            print(f'  - Revert \"{original}\" — 커밋 {r[\"sha\"]} ({r[\"author\"]}, {r[\"date\"][:10]})')
        else:
            print(f'  - {r[\"msg\"]} — 커밋 {r[\"sha\"]} ({r[\"author\"]}, {r[\"date\"][:10]})')
else:
    print('■ 리버트/롤백 커밋: 없음')
" | tee "$TMPDIR/step2_output.txt"
```

---

## STEP 3: 결과 출력 + Slack 전송

### 3-1. 콘솔 출력 및 파일 저장

STEP 1~2 결과를 통합하여 콘솔에 출력하고 파일로 저장한다.

```bash
# ── 부트스트랩 (생략) ──

# 결과 통합
$PYTHON -c "
import sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

header = f'''_build-check ${BUILD_VER} 결과_
날짜: ${START_DATE} ~ ${END_DATE} | client / ${BRANCH}
---
'''

with open('$TMPDIR/step1_output.txt', encoding='utf-8', errors='replace') as f:
    step1 = f.read()
with open('$TMPDIR/step2_output.txt', encoding='utf-8', errors='replace') as f:
    step2 = f.read()

output = header + '\n' + step1 + '\n\n' + step2
print(output)

with open('$TMPDIR/analysis_output.md', 'w', encoding='utf-8') as f:
    f.write(output)
"
```

### 3-2. Slack 전송 [사용자 승인 후 실행]

결과를 대화에 출력한 뒤, `AskUserQuestion`으로 Slack 전송 여부를 묻는다:

```
question: "분석 결과를 #qa-ai-report 채널에 전송할까요?"
options:
  - label: "전송",  description: "#qa-ai-report 채널에 전송"
  - label: "전송 안 함",  description: "전송하지 않고 종료"
```

"전송 안 함" 선택 시 종료한다.
"전송" 선택 시 아래 형식으로 `#qa-ai-report` 채널(ID: `C0AQTSRRFHC`)에 전송한다.

#### 형식 규칙 (전체 공통)
- Slack Block Kit은 사용하지 않는다. 일반 텍스트(`mrkdwn`)로 전송한다
- **이모지 최소화**: 불필요한 이모지를 넣지 않는다. 텍스트 위주로 작성한다
- 이탤릭(`_텍스트_`)은 Slack에서 사용 가능하며, 버전·제목 강조에 활용한다

#### 메시지 1: 타이틀 + 신규 추가 사항

```
_build-check [빌드 버전]_
날짜: [시작일] ~ [종료일] | client / [브랜치]

*신규 추가 사항* — 커밋 [N]건 / PR [M]건 / 티켓 [K]건

- CVS-12345: [타입] 제목 (PR #401)
- CVS-12346: [타입] 제목 (PR #405)
...
```

> 5000자 초과 시 티켓 목록을 스레드로 분리한다 (부모: 타이틀 + 요약 수치, 스레드: 상세 목록).

#### 메시지 2: 리버트 (해당 시에만)

리버트가 0건이면 이 메시지를 보내지 않는다.

```
_build-check [빌드 버전]_
*리버트 감지*

■ 리버트: [N]건
- Revert "원본 커밋 메시지" — 커밋 abc1234
```

#### 전송 순서 및 실패 처리

**전송 순서**: 메시지 1 → 메시지 2 순차 전송. 병렬 전송 시 Slack에서 메시지 순서가 보장되지 않는다.

**실패 처리**:
- Slack 전송 실패 시 메시지를 간소화하여 1회 재시도한다
- 재시도도 실패하면 "Slack 전송 실패 — [에러 메시지]"를 대화에 출력하고 종료한다

---

## 금지 사항
- 코드 내용을 읽거나 분석하지 마라 (repob grep/query/read 사용 금지)
- 커밋 메시지만 보고 변경의 영향을 추정하지 마라 — 이 스킬은 "무엇이 들어왔나"만 보고한다
- "QA 확인 포인트", "테스트 방법" 등 ticket-qa 영역의 분석을 하지 마라
- Jira 댓글 순회는 Bug 티켓의 fix 판정 용도로만 수행한다 — Bug가 아닌 티켓의 댓글은 순회하지 마라
