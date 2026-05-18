---
name: release-diff
description: 릴리스 번호를 입력하면 Jira 프로젝트의 fixVersion 기준으로 해당 릴리스 티켓을 읽고, client+server repo에서 테스트 방법과 영향 범위를 분석한 뒤 최종 QA 체크리스트와 Evidence 요약을 만들어 줍니다. 온톨로지 매핑은 /ontology-map 스킬로 분리됐습니다. "/release-diff", "릴리스 분석", "241 릴리스 QA" 요청 시 사용합니다.
---

# /release-diff — 릴리스 QA 영향 분석

> **실행 환경**: 이 스킬의 bash 명령은 Claude Code Bash 도구 기준으로 작성됐다. Windows에서는 Git Bash 환경에서 실행된다. PowerShell에서 직접 실행하면 동작하지 않는다.

### 임시 파일 경로 (Windows 호환)

Git Bash의 `/tmp`는 Python에서 접근 불가할 수 있다. 모든 임시 파일은 `$TMPDIR`을 사용한다.
**TMPDIR 초기화는 STEP 0에서 RELEASE 변수 확정 직후에 실행한다.** 아래 코드 블록은 STEP 0 참고용이다.

이후 모든 코드 블록에서 `/tmp/` 대신 `$TMPDIR/`을 사용한다. Python 코드에서도 `$TMPDIR` 환경변수를 참조해야 하므로 반드시 `export`한다.

### Windows 인코딩 가드 (전체 Python 코드 블록 공통)

Windows 기본 콘솔 인코딩(cp949)에서 한글·특수문자(`\xa0` 등) 출력 시 `UnicodeEncodeError`가 발생한다. **모든 Python `-c` 코드 블록의 첫 줄**에 아래를 삽입한다:

```python
import sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace'); sys.stderr.reconfigure(encoding='utf-8', errors='replace')
```

파일을 `open()`할 때도 `encoding='utf-8', errors='replace'`를 항상 지정한다. 이 규칙은 이후 모든 STEP의 Python 코드에 적용된다. 개별 코드 블록에서 반복 기술하지 않는다.

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

인자가 없으면 `AskUserQuestion`으로 한 번 묻는다.

```
question: "분석할 릴리스 번호를 Other에 직접 입력해 주세요."
options:
  - label: "예시",  description: "241  ← Other에 이 형식으로 입력 (Jira fixVersion 241.0에 매핑됨)"
```

입력값이 순수 숫자가 아니면 같은 질문으로 한 번 더 묻는다.

---

## Jira 인증 설정

인증 정보는 `~/.bagelcode/jira.json`에서 읽는다.

```bash
PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)
JIRA_JSON="$(cygpath -m "$HOME/.bagelcode/jira.json" 2>/dev/null || echo "$HOME/.bagelcode/jira.json")"
JIRA_DOMAIN=$($PYTHON -c "import json,sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace'); d=json.load(open(sys.argv[1], encoding='utf-8', errors='replace')); print(d['domain'])" "$JIRA_JSON")
JIRA_EMAIL=$($PYTHON -c "import json,sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace'); d=json.load(open(sys.argv[1], encoding='utf-8', errors='replace')); print(d['email'])" "$JIRA_JSON")
JIRA_TOKEN=$($PYTHON -c "import json,sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace'); d=json.load(open(sys.argv[1], encoding='utf-8', errors='replace')); print(d['token'])" "$JIRA_JSON")
JIRA_PROJECT=$($PYTHON -c "import json,sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace'); d=json.load(open(sys.argv[1], encoding='utf-8', errors='replace')); print(d.get('project_key', 'CVS'))" "$JIRA_JSON")
JIRA_AUTH="$JIRA_EMAIL:$JIRA_TOKEN"
JIRA_BASE="https://$JIRA_DOMAIN"
```

`project_key`가 없으면 기본값 `CVS`를 사용한다. 다른 프로젝트를 분석할 때만 jira.json에 명시한다.

파일이 없으면 아래 안내를 출력하고 **실행을 중단**한다.

```
~/.bagelcode/jira.json 파일이 없습니다. 아래 형식으로 파일을 생성한 뒤 다시 실행해 주세요:

{
  "domain": "yourcompany.atlassian.net",
  "email": "your.email@company.com",
  "token": "YOUR_JIRA_API_TOKEN",
  "project_key": "CVS"
}
```

---

## repob 초기화

`repob`는 bagel-marketplace 플러그인 또는 PATH에서 찾은 실행 파일을 `$REPOB` 변수로 고정한 뒤 사용한다. 이 스킬 안에서는 `$REPOB remote ...`를 직접 호출하지 말고, 아래 초기화 후 **모든 명령을 `$REPOB remote ...` 형태로 실행한다.**

```bash
# 1. bagel-marketplace 플러그인 캐시에서 repob 바이너리 탐지
REPOB=""
PLUGIN_BASE="${HOME}/.claude/plugins/cache/bagel-marketplace/repob"
if [ -d "$PLUGIN_BASE" ]; then
  LATEST_VER=$(ls -1 "$PLUGIN_BASE" | $PYTHON -c "import sys; vs=[v.strip('/') for v in sys.stdin.read().split() if v.strip('/')]; vs.sort(key=lambda v: list(map(int, v.split('.'))), reverse=True); print(vs[0] if vs else '')")
  if [ -n "$LATEST_VER" ]; then
    BIN_DIR="$PLUGIN_BASE/$LATEST_VER/skills/repob/bin"
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

# 3. 결과 확인 — repob는 필수 의존성 (fallback 없음)
if [ -x "$REPOB" ]; then
  echo "repob: $($REPOB --version 2>&1)"
else
  echo "ERROR: repob 미발견 — cross-branch 비교 불가. 스킬 실행을 중단합니다."
  echo "bagel-marketplace 플러그인 설치 또는 PATH에 repob 추가 후 재실행하세요."
  exit 1
fi
```

## STEP 0: 브랜치 결정

릴리스 번호만으로 브랜치를 결정한다. Slack 검색, 날짜 범위, 빌드 번호는 사용하지 않는다.

RELEASE와 PREV를 최초 1회 설정한다. 이후 모든 glob/grep/read 명령은 이 변수를 사용한다.

```bash
RELEASE={입력받은 릴리스 번호}     # 예: 241
PREV=$((RELEASE - 1))              # 예: 240
export RELEASE PREV                # Sub-Bug 분류 Python(STEP 1-3)이 os.environ['RELEASE'] 사용

# TMPDIR 초기화 — RELEASE 확정 직후, 다른 STEP보다 먼저 실행
# cygpath -m: forward-slash Windows 경로 (C:/Users/...) — Python 백슬래시 escape 문제 방지
export TMPDIR="$(cygpath -m /tmp 2>/dev/null || echo /tmp)/release${RELEASE}"
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"
```

| repo | 현재 브랜치 (HEAD) | 이전 브랜치 (BASE) |
|------|-------------------|-------------------|
| client | `Develop/${RELEASE}/Main` | `Develop/${PREV}/Main` |
| server | `${RELEASE}.0/Main` | `${PREV}.0/Main` |

예) 릴리스 241 → HEAD: `Develop/241/Main` / BASE: `Develop/240/Main`

---

## STEP 1: Jira 릴리스 티켓 수집

### 1-1. 릴리스(fixVersion) 확인

릴리스 이름은 `{RELEASE}.0` 형식 (예: `241.0`).
Jira의 **release-report-all-issues 탭**과 동일한 결과를 얻기 위해, `project={JIRA_PROJECT} AND fixVersion="{RELEASE}.0"` JQL로 직접 조회한다.

먼저 해당 fixVersion이 프로젝트에 실제로 존재하는지 확인한다 (오타 방지).

```bash
# fetch 실패 가시화 — fetch_failed.txt 1회 초기화 (versions fetch 직전, 이후 재초기화 금지)
> "$TMPDIR/fetch_failed.txt"

# 프로젝트의 모든 버전 조회 (페이지네이션 없음 — 단순 배열 반환)
HTTP_CODE=$(curl -s --connect-timeout 5 --max-time 45 --retry 2 --retry-delay 2 \
  -o "$TMPDIR/_versions.json" -w '%{http_code}' -u "$JIRA_AUTH" \
  "$JIRA_BASE/rest/api/3/project/$JIRA_PROJECT/versions")
if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
  echo "ERROR: versions fetch failed (HTTP $HTTP_CODE) — fixVersion 검증 불가, 스킬 중단" >&2
  printf '%s\t%s\t%s\t%s\n' "critical" "versions" "-" "$HTTP_CODE" >> "$TMPDIR/fetch_failed.txt"
  exit 1
fi

VERSION_INFO=$($PYTHON -c "
import sys, json
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
sys.stderr.reconfigure(encoding='utf-8', errors='replace')
target = '${RELEASE}.0'
try:
    versions = json.load(open('$TMPDIR/_versions.json', encoding='utf-8', errors='replace'))
except (json.JSONDecodeError, ValueError):
    print('PARSE_ERROR', file=sys.stderr); exit(1)

# 1차: exact match
for v in versions:
    if v.get('name') == target:
        print(f\"{v['id']}\t{v['name']}\t{v.get('released', False)}\")
        exit(0)

# 2차: substring match
matches = [v for v in versions if target in v.get('name', '')]
if len(matches) > 1:
    print('AMBIGUOUS', file=sys.stderr)
    for m in matches: print(f\"  {m['id']} {m['name']}\", file=sys.stderr)
    exit(1)
for m in matches:
    print(f\"{m['id']}\t{m['name']}\t{m.get('released', False)}\")
")

if [ -z "$VERSION_INFO" ]; then
  echo "ERROR: 프로젝트 $JIRA_PROJECT 에서 fixVersion '${RELEASE}.0' 미발견 — 릴리스명 또는 project_key 확인 필요" >&2
  # AskUserQuestion으로 정확한 릴리스명 재입력
fi

VERSION_ID=$(echo "$VERSION_INFO" | awk -F'\t' '{print $1}')
VERSION_NAME=$(echo "$VERSION_INFO" | awk -F'\t' '{print $2}')
# Sub-Bug fixVersion 분기 정책에서 사용 (Python 환경변수로 전달)
export VERSION_NAME VERSION_ID
echo "release-diff target: project=$JIRA_PROJECT fixVersion=$VERSION_NAME (id=$VERSION_ID)"
```

탐색 결과가 없거나 AMBIGUOUS이면 `AskUserQuestion`으로 정확한 릴리스명을 입력받는다.

### 1-2. 상위 티켓 전체 조회 (fixVersion 기준, 하위 작업 제외)

하위 작업(Sub-task)은 QA 분석 대상에서 제외한다. Story, Task, Bug, Epic, Development 등 모든 상위 티켓을 수집한다.

**이슈 상태 해석**: `Need Review` = 개발팀 완료 사인. QA 분석 대상에 포함한다. 미구현 상태가 아니다.

> **API**: REST search API(`/rest/api/3/search/jql`) **단일 호출**. JQL은 `project={JIRA_PROJECT} AND fixVersion="{RELEASE}.0" ORDER BY created ASC`. release-report-all-issues 탭과 동일한 결과를 얻기 위해 fixVersion 기반으로 조회한다.

**Windows 인코딩 안전 패턴**: REST 응답을 Bash 파이프(`echo "$RESP" | python`)로 처리하면 Windows cp949 인코딩 문제로 한글이 깨진다. **반드시 curl → 파일 저장 → Python 파일 읽기 패턴**을 사용한다.

```bash
# JQL: project=X AND fixVersion="241.0" ORDER BY created ASC
# URL 인코딩: 공백 %20, 따옴표 %22, = 그대로
JQL="project=${JIRA_PROJECT}%20AND%20fixVersion=%22${VERSION_NAME}%22%20ORDER%20BY%20created%20ASC"

# /rest/api/3/search/jql은 cursor 기반 페이지네이션 — total/startAt 미지원.
# nextPageToken으로 다음 페이지 요청, isLast=true면 종료.
PAGE_TOKEN=""
PAGE_NUM=0
while true; do
  if [ -z "$PAGE_TOKEN" ]; then
    URL="$JIRA_BASE/rest/api/3/search/jql?jql=${JQL}&maxResults=50&fields=summary,description,issuetype,status,priority,assignee,subtasks,fixVersions"
  else
    URL="$JIRA_BASE/rest/api/3/search/jql?jql=${JQL}&maxResults=50&nextPageToken=${PAGE_TOKEN}&fields=summary,description,issuetype,status,priority,assignee,subtasks,fixVersions"
  fi
  HTTP_CODE=$(curl -s --connect-timeout 5 --max-time 45 --retry 2 --retry-delay 2 -o "$TMPDIR/page_${PAGE_NUM}.json" -w '%{http_code}' -u "$JIRA_AUTH" "$URL")
  if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
    echo "ERROR: Jira search HTTP $HTTP_CODE — JQL 또는 권한 확인 필요" >&2
    printf '%s\t%s\t%s\t%s\n' "critical" "search" "page_${PAGE_NUM}" "$HTTP_CODE" >> "$TMPDIR/fetch_failed.txt"
    break
  fi

  # Python에서 파일 직접 읽기 (파이프 없음 — 인코딩 문제 방지)
  PAGE_OUT=$($PYTHON -c "
import sys, json
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
sys.stderr.reconfigure(encoding='utf-8', errors='replace')
try:
    d = json.load(open('$TMPDIR/page_${PAGE_NUM}.json', encoding='utf-8', errors='replace'))
except (json.JSONDecodeError, ValueError):
    print('__META__ True ')
    exit(0)
issues = d.get('issues', [])
is_last = d.get('isLast', True)
next_token = d.get('nextPageToken', '')
for i in issues:
    itype = i['fields']['issuetype']['name']
    if itype in ['하위 작업', 'Sub-task', 'Subtask']:
        continue
    key = i['key']
    summary = i['fields']['summary']
    status = i['fields']['status']['name']
    priority = (i['fields'].get('priority') or {}).get('name', '-')
    assignee = (i['fields'].get('assignee') or {}).get('displayName', '미배정')
    subtask_count = len(i['fields'].get('subtasks', []))
    internal_id = i['id']
    print(f'{key}|{itype}|{status}|{priority}|{assignee}|{subtask_count}서브|{summary}|{internal_id}')
    for sub in i['fields'].get('subtasks', []):
        print(f'SUBTASK_KEY:{key}:{sub[\"key\"]}')
print(f'__META__ {is_last} {next_token}')
")

  # 이슈 라인은 stdout 출력 + all_issues.txt에 누적 저장
  # SUBTASK_KEY: 라인은 all_subtask_keys.txt로 분리
  echo "$PAGE_OUT" | grep -v '^__META__' | grep -v '^SUBTASK_KEY:' >> "$TMPDIR/all_issues.txt"
  echo "$PAGE_OUT" | grep '^SUBTASK_KEY:' >> "$TMPDIR/all_subtask_keys.txt"
  echo "$PAGE_OUT" | grep -v '^__META__'
  IS_LAST=$(echo "$PAGE_OUT" | grep '^__META__' | awk '{print $2}')
  PAGE_TOKEN=$(echo "$PAGE_OUT" | grep '^__META__' | awk '{print $3}')
  # 종료 조건: isLast=True 또는 nextPageToken 비어있음 (안전망)
  [ "$IS_LAST" = "True" ] && break
  [ -z "$PAGE_TOKEN" ] && break
  PAGE_NUM=$((PAGE_NUM + 1))
done

# 페이지네이션 완료 후 issue_ids.tsv 생성 (8번째 필드 = internal ID)
# 형식: 이슈키 \t 내부ID — STEP 1.5-E dev-status API 호출에 사용
awk -F'|' '{print $1"\t"$8}' "$TMPDIR/all_issues.txt" > "$TMPDIR/issue_ids.tsv"
echo "수집 완료: 상위 $(wc -l < $TMPDIR/all_issues.txt)건 / 하위 $(wc -l < $TMPDIR/all_subtask_keys.txt)건"
```

수집 결과가 0건이면 fixVersion 이름·project_key·권한을 재확인하고 `AskUserQuestion`으로 수동 입력을 받는다.

> **출력 파일** (이후 STEP에서 사용):
> - `$TMPDIR/all_issues.txt` — 상위 티켓 목록 (`키|타입|상태|우선순위|담당|N서브|제목|내부ID` 8필드 pipe-separated)
> - `$TMPDIR/all_subtask_keys.txt` — 하위 작업 매핑 (`SUBTASK_KEY:상위키:하위키` 줄당 1건)
> - `$TMPDIR/issue_ids.tsv` — 상위 티켓 internal ID (`키\t내부ID` tab-separated)

### 1-3. 각 티켓 상세 수집

각 티켓에서 아래 정보를 수집한다.

**기본 정보**: 이슈 키, 제목, 설명, 이슈 타입, 우선순위, 상태, 담당자

**코멘트**: 테스트 관련 키워드 포함 여부 확인 (`테스트`, `QA`, `확인 필요`, `시나리오`, `TC`, `test`, `verify`)

> **병렬 실행 필수 — 상위 티켓 + 하위 작업을 한 Bash 블록에서 동시 실행**: 상위 티켓(issue + remotelink)과 하위 작업(subtask description)을 순차 wait로 나누지 않는다. 하위 작업 키 목록은 1-2에서 이미 수집됐으므로, 상위·하위를 모두 한 번에 `&` + `wait`로 실행해 wait 1회로 끝낸다.

```bash
# 도구 timeout 시 background curl 좀비 방지 — 부모 셸 종료 시 자식 일괄 정리
trap 'kill $(jobs -p) 2>/dev/null; wait 2>/dev/null' EXIT INT TERM

# 이전 실행 잔재 방지 — tsv 파일 초기화
> $TMPDIR/spec_links.tsv
> $TMPDIR/subtask_keywords.tsv

# 상위 티켓 상세·링크 조회 함수
fetch_issue() {
  KEY=$1
  HTTP_CODE=$(curl -s --connect-timeout 5 --max-time 45 --retry 2 --retry-delay 2 -o $TMPDIR/issue_${KEY}.json -w '%{http_code}' -u "$JIRA_AUTH" \
    "$JIRA_BASE/rest/api/3/issue/$KEY?fields=summary,description,issuetype,status,priority,assignee,comment")
  if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
    echo "WARN: issue $KEY fetch failed (HTTP $HTTP_CODE)" >&2
    printf '%s\t%s\t%s\t%s\n' "critical" "issue" "$KEY" "$HTTP_CODE" >> "$TMPDIR/fetch_failed.txt"
    echo '{}' > $TMPDIR/issue_${KEY}.json
  fi
  HTTP_CODE=$(curl -s --connect-timeout 5 --max-time 45 --retry 2 --retry-delay 2 -o $TMPDIR/remotelink_${KEY}.json -w '%{http_code}' -u "$JIRA_AUTH" \
    "$JIRA_BASE/rest/api/3/issue/$KEY/remotelink")
  if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
    echo "WARN: remotelink $KEY fetch failed (HTTP $HTTP_CODE)" >&2
    printf '%s\t%s\t%s\t%s\n' "partial" "remotelink" "$KEY" "$HTTP_CODE" >> "$TMPDIR/fetch_failed.txt"
    echo '[]' > $TMPDIR/remotelink_${KEY}.json
  fi
}

# 하위 작업 fetch 함수 — curl만 (파싱은 wait 후 단일 Python으로 일괄)
# 안티패턴 회피: subtask마다 inline `$PYTHON -c` 호출하면 N회 인터프리터 cold start로
# Bash 2분 timeout에 걸려 harness 자동 background 전환 → `&` 자식 프로세스 손실 위험.
fetch_subtask() {
  KEY=$1
  # 필드 보강: 3-tier sub-bug 정책에 모두 필요
  #   issuetype: 하위 버그/하위 작업 분류
  #   priority: High/Highest 개별 승격 판정
  #   status: 미해결(open) sub-bug 경고 판정
  #   fixVersions: 부모와 다른 릴리스인 sub-bug 회귀 대상 제외 판정
  HTTP_CODE=$(curl -s --connect-timeout 5 --max-time 45 --retry 2 --retry-delay 2 -o "$TMPDIR/subtask_detail_${KEY}.json" -w '%{http_code}' -u "$JIRA_AUTH" \
    "$JIRA_BASE/rest/api/3/issue/$KEY?fields=summary,description,issuetype,priority,status,fixVersions")
  if [ "$HTTP_CODE" -lt 200 ] 2>/dev/null || [ "$HTTP_CODE" -ge 300 ] 2>/dev/null; then
    echo "WARN: subtask $KEY fetch failed (HTTP $HTTP_CODE)" >&2
    printf '%s\t%s\t%s\t%s\n' "partial" "subtask" "$KEY" "$HTTP_CODE" >> "$TMPDIR/fetch_failed.txt"
  fi
}

# 상위 티켓 + 하위 작업 모두 한 번에 병렬 실행 → wait 1회
# 입력: 1-2에서 생성한 all_issues.txt (상위), all_subtask_keys.txt (하위 SUBTASK_KEY:상위:하위 형식)

# 상위 6건 — 직접 push 워크플로우라 수가 적음, 한 번에 병렬
while IFS='|' read -r KEY _; do
  [ -z "$KEY" ] && continue
  fetch_issue "$KEY" &
done < "$TMPDIR/all_issues.txt"

# 하위 작업 — 5건 batch wait로 쪼개기 (66건처럼 많을 때 timeout 방지)
BATCH=0
while IFS=: read -r _ PARENT SUBKEY; do
  [ -z "$SUBKEY" ] && continue
  fetch_subtask "$SUBKEY" &
  BATCH=$((BATCH + 1))
  if [ $((BATCH % 5)) -eq 0 ]; then wait; fi
done < "$TMPDIR/all_subtask_keys.txt"
wait

# wait 완료 후 — 단일 Python 1회로 모든 subtask JSON 일괄 파싱
# (개별 `$PYTHON -c` 호출 N회 대신 heredoc 1회 — Python cold start 1번)
$PYTHON <<'PYEOF'
import json, os, glob
TMPDIR = os.environ['TMPDIR']

def extract_text(node):
    if not node or not isinstance(node, dict): return ''
    if node.get('type') == 'text': return node.get('text','')
    return ''.join(extract_text(c) for c in node.get('content', []))

lines = []
for f in sorted(glob.glob(f'{TMPDIR}/subtask_detail_*.json')):
    key = os.path.basename(f).replace('subtask_detail_', '').replace('.json', '')
    try:
        d = json.load(open(f, encoding='utf-8', errors='replace'))
    except Exception:
        continue
    fl = d.get('fields', {})
    summary = (fl.get('summary') or '').replace('\xa0', ' ').replace('\t', ' ').replace('\n', ' ')
    desc = extract_text(fl.get('description') or {}).strip().replace('\xa0', ' ').replace('\t', ' ').replace('\n', ' ')
    lines.append(f'{key}\t{summary}\t{desc[:800]}')

with open(f'{TMPDIR}/subtask_keywords.tsv', 'w', encoding='utf-8') as fp:
    fp.write('\n'.join(lines) + ('\n' if lines else ''))
print(f'subtask_keywords.tsv: {len(lines)}건')
PYEOF
```

> **금지 사항**: subtask·devstatus·remotelink 같이 N건 데이터를 처리할 때 `for KEY in ...; do $PYTHON -c "..." & done` 패턴은 사용하지 않는다. curl만 병렬로 받고, 파싱은 wait 후 `$PYTHON <<'PYEOF'` heredoc 1회 + `glob.glob`으로 일괄 처리한다. (이 원칙은 1.5-C2, 1.5-E, 2-3 정규화 등 다른 단계에도 동일하게 적용)

remotelink에서 아래 두 종류를 추출해 `$TMPDIR/spec_links.tsv`에 누적 기록한다. (STEP 2-4 트리아지, STEP 3-C, STEP 5에서 사용)

- **Confluence URL** (`atlassian.net/wiki`): 페이지 ID 추출 → STEP 3-C에서 본문 read
- **외부 기획서 URL** (`docs.google.com`, `drive.google.com`, `slides.google.com`, 기타 외부 링크): URL 그대로 보관, STEP 3-C에서 "기획서 미확인"으로 처리하되 URL 명시

**TSV 형식** (6컬럼, 탭 구분):
```
{티켓키}\t{타입}\t{URL}\t{페이지ID}\t{제목}\t{redirect 상태}
```
- `redirect 상태`: 초기값 빈문자열. 트리아지(2-4) 직전 조기 판정에서 `redirect` 또는 `normal`로 갱신

```bash
# 모든 티켓의 remotelink를 Python 1회로 일괄 파싱 (fetch_issue wait 완료 후)
$PYTHON -c "
import sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace'); sys.stderr.reconfigure(encoding='utf-8', errors='replace')
import json, glob, re, os

out = []
for f in sorted(glob.glob('$TMPDIR/remotelink_*.json')):
    key = os.path.basename(f).replace('remotelink_','').replace('.json','')
    try:
        links = json.load(open(f, encoding='utf-8', errors='replace'))
    except (json.JSONDecodeError, ValueError):
        import sys
        print(f'WARN: {key} remotelink JSON invalid', file=sys.stderr)
        continue
    for lk in (links if isinstance(links, list) else []):
        url = (lk.get('object') or {}).get('url', '')
        title = (lk.get('object') or {}).get('title', '')
        if not url:
            continue
        if 'atlassian.net/wiki' in url:
            m = re.search(r'/pages/(\d+)', url) or re.search(r'pageId=(\d+)', url)
            page_id = m.group(1) if m else ''
            out.append(f'{key}\tconfluence\t{url}\t{page_id}\t{title}')
        elif any(d in url for d in ['docs.google.com', 'drive.google.com', 'slides.google.com']):
            out.append(f'{key}\tgoogle\t{url}\t\t{title}')
        elif url.startswith('http') and 'jira' not in url:
            out.append(f'{key}\texternal\t{url}\t\t{title}')

with open('$TMPDIR/spec_links.tsv', 'a', encoding='utf-8') as fp:
    fp.write('\n'.join(out) + '\n' if out else '')
" 2>/dev/null
```

#### 하위 작업·하위 버그 처리 정책 (3-tier)

**기본 원칙**: QA 분석 단위는 **상위 티켓**. 하위 작업/하위 버그는 부모 티켓 분석에 통합되어 처리한다.

| 분류 | 처리 | 출력 |
|------|------|------|
| **상위 티켓** (Story/Bug/Task/새 기능/개선/Development) | 개별 분석 | 테스트 방법 + 영향 범위 + 기획서 비교 (현재 동작) |
| **하위 작업** (Sub-task: 서버/클라/TA/사운드 등) | 키워드 풀로만 활용 | 부모의 grep 키워드 추출용. 별도 출력 없음 |
| **하위 버그** (Sub-Bug: priority 무관) | 부모의 "회귀 확인" 통합 표기 | 부모 분석 안에 N건 카운트 + 키워드 묶음 |
| **하위 버그 (High/Highest priority)** | 개별 체크리스트 항목으로 승격 | 부모와 별개로 STEP 4에 항목 추가 |

**왜 이렇게**:
- 하위 버그가 50건 넘는 부모 티켓(예: 대규모 리뱀프 작업) 개별 검증은 비현실적이고 의미 단위가 흐려짐
- 그러나 fix 0건 vs 30건은 **회귀 위험도가 다름** — 개수·키워드 묶음으로 표시
- High/Highest priority는 critical fix이므로 개별 회귀 검증 가치 있음

**의도된 정책 분기**:
- 부모가 Need Review/완료 + 하위 버그 일부 still **open** → STEP 5 커버리지에 `⚠️ 부모 [KEY]: 미해결 sub-bug N건 — 본 릴리스 미반영` 경고
- 하위 버그 fixVersion이 부모와 다른 릴리스(예: 부모 241, sub-bug 240) → 본 릴리스 분석에서는 **카운트만**, 회귀 확인 대상 제외 (이전 릴리스에서 처리됨)

#### 하위 작업 설명 수집 (1-3 코드 블록 내 동시 실행 — 키워드 풀 + sub-bug 카운트 목적)

위 1-3 코드 블록에서 `fetch_issue`와 함께 `&` + `wait`로 동시 실행된다. 별도 wait 없음.

1-2에서 수집한 `SUBTASK_KEY:상위키:하위키` 목록의 하위 키를 사용한다. **목적**:
1. 하위 작업 (Sub-task): 배치 grep 키워드 풀 확장. "CVS.com"처럼 상위 티켓 제목이 추상적인 경우 실제 구현 키워드("Xsolla", "Facebook", "BrowserResize" 등)는 하위 작업 설명에만 있다.
2. 하위 버그 (Sub-Bug): 부모별 카운트 + priority 분류 → STEP 3 분석에 "수정된 sub-bug N건 (High N건 별도, 그 외 그룹화)" 통합

수집한 하위 작업 설명에서 **기술 키워드**(SDK명, 클래스명, API명, 기능명)를 추출해 STEP 2-3 배치 grep 키워드 풀에 추가한다.

**Sub-Bug 분류 (하위 작업 fetch 직후 실행)**:

```bash
# 1-3 fetch 완료 후 — 하위 작업 중 issuetype=Bug/하위 버그/Sub-Bug 분류
# 입력: subtask_detail_*.json (issuetype/priority/status/fixVersions 포함 — fetch_subtask가 미리 가져옴)
# 출력: sub_bugs.json — 부모별 sub-bug list
$PYTHON <<'PYEOF'
import json, os, glob
TMPDIR = os.environ['TMPDIR']
RELEASE_NAME = os.environ.get('VERSION_NAME', '')  # 본 릴리스 fixVersion 이름 (예: '241.0 QA')
RELEASE_NUM = os.environ.get('RELEASE', '')        # 본 릴리스 숫자 (예: '241')

bug_types = {'하위 버그', 'Sub-Bug', 'Sub-bug', '버그', 'Bug'}
high_priorities = {'High', 'Highest', '높음', '매우 높음'}
done_statuses = {'완료', 'Done', 'Closed', 'Need Review', 'Resolved'}

def matches_release(fix_versions, release_name, release_num):
    """sub-bug fixVersions가 본 릴리스와 동일한지 판정.
    - 1차: name 정확히 일치
    - 2차: 숫자 prefix 매칭 (예: '241'이 fixVersion 이름에 포함)
    - fixVersions 비어있으면 '미지정' (회귀 대상에 포함 — 보수적)
    """
    if not fix_versions:
        return None  # 미지정 = 회귀 대상에 포함
    names = [fv.get('name', '') for fv in fix_versions]
    if release_name and release_name in names:
        return True
    if release_num:
        for n in names:
            if release_num in n:
                return True
    return False

# 부모별 sub-bug 통계
sk_parent = {}
for line in open(f'{TMPDIR}/all_subtask_keys.txt', encoding='utf-8'):
    parts = line.strip().split(':')
    if len(parts) >= 3: sk_parent[parts[2]] = parts[1]

sub_bugs_by_parent = {}
for f in sorted(glob.glob(f'{TMPDIR}/subtask_detail_*.json')):
    sk = os.path.basename(f).replace('subtask_detail_', '').replace('.json', '')
    parent = sk_parent.get(sk)
    if not parent: continue
    try: d = json.load(open(f, encoding='utf-8'))
    except: continue
    fl = d.get('fields', {})
    itype = (fl.get('issuetype') or {}).get('name', '')
    if itype not in bug_types: continue
    summary = (fl.get('summary') or '').replace('\t', ' ').replace('\n', ' ')
    priority = (fl.get('priority') or {}).get('name', '-')
    status = (fl.get('status') or {}).get('name', '')
    fix_versions = fl.get('fixVersions', []) or []
    fv_names = [fv.get('name', '') for fv in fix_versions]
    same_release = matches_release(fix_versions, RELEASE_NAME, RELEASE_NUM)
    sub_bugs_by_parent.setdefault(parent, []).append({
        'key': sk,
        'summary': summary,
        'priority': priority,
        'status': status,
        'fix_versions': fv_names,
        'is_high': priority in high_priorities,
        'is_open': status not in done_statuses,
        # is_other_release: True = 다른 릴리스 (회귀 대상 제외) / False = 본 릴리스 / None = 미지정 (보수적 포함)
        'is_other_release': (same_release is False)
    })

# 부모별 통계 저장 (STEP 3에서 소비)
with open(f'{TMPDIR}/sub_bugs.json', 'w', encoding='utf-8') as fp:
    json.dump(sub_bugs_by_parent, fp, ensure_ascii=False, indent=2)

for parent, bugs in sub_bugs_by_parent.items():
    high = [b for b in bugs if b['is_high']]
    open_ = [b for b in bugs if b['is_open']]
    other = [b for b in bugs if b['is_other_release']]
    in_scope = [b for b in bugs if not b['is_other_release']]
    print(f'[{parent}] sub-bug {len(bugs)}건 (본 릴리스 {len(in_scope)} / 다른 릴리스 {len(other)} / High {len(high)} / 미해결 {len(open_)})')
PYEOF
```

> **fixVersion 분기 정책 (정본)**:
> - `is_other_release: true` → 본 릴리스 회귀 확인 대상 **제외** (이전/다른 릴리스에서 처리됨). STEP 3 통합 표기에 카운트만 포함, "다른 fixVersion N건" 별도 표시
> - `is_other_release: false` → 본 릴리스 회귀 확인 대상 **포함** (정상 처리)
> - fixVersions 미지정 → `is_other_release: false`로 처리 (보수적 — 회귀 대상에 포함). "fixVersion 미지정" 경고 표기
> - 환경변수 `VERSION_NAME` (1-1에서 설정) + `RELEASE` (STEP 0)로 본 릴리스 식별

> **fetch_subtask 필드 보강 (확정)**: `fields=summary,description,issuetype,priority,status,fixVersions` — 위 fetch_subtask 함수에 이미 반영됨.

### 1-4. Development 타입 처리 기준

Development 타입 티켓은 자동 제외하지 않는다.
설명 또는 코멘트에 테스트 관련 내용이 있으면 분석 대상에 포함한다.
설명/코멘트가 모두 없고 인프라·DB 작업만이면 "QA 범위 외"로 표시하고 넘어간다.

**코멘트 테스트 키워드 판정** (fetch_issue에서 comment 필드를 이미 수집):
`$TMPDIR/issue_${KEY}.json`의 `fields.comment.comments` 배열에서 각 코멘트 body를 ADF → 텍스트로 추출 후, 아래 키워드가 하나라도 포함되면 "코멘트에 테스트 관련 내용 있음"으로 판정한다:
`테스트|QA|확인 필요|시나리오|TC|test|verify|검증`
이 판정은 Development 타입의 Skip 여부와, 기타 타입에서 추가 테스트 포인트 도출에 사용한다.

---

## STEP 1.5: GitHub Compare + PR 수집 [STEP 1 완료 후, STEP 2 이전]

GitHub compare API로 브랜치 간 실제 변경(커밋 + 파일)을 확정하고, PR/open PR에서 테스트 컨텍스트를 확보한다. **compare API가 STEP 2의 glob 전체 스캔을 대체하는 핵심 데이터 소스**다.

### 1.5-A: compare API — 브랜치 간 변경 확정 (client만)

> **server는 gh API 접근 불가**: server repo에 대한 `gh api` 호출(compare, commit detail, PR list)은 일체 실행하지 않는다. server의 변경 파악은 STEP 2에서 repob grep/glob/read만 사용한다. 이 원칙은 STEP 1.5 전체(A/C/D)에 적용된다.

`{PREV}/Main...{RELEASE}/Main` 비교로 커밋 목록 + changed files를 한 번에 확보한다.

```bash
# client: Develop/${PREV}/Main...Develop/${RELEASE}/Main 비교
gh api "repos/bagelcode-cvs/client/compare/Develop/${PREV}/Main...Develop/${RELEASE}/Main" \
  > $TMPDIR/compare_client.json 2>/dev/null &

# server: gh API 접근 불가 — compare 생략 (repob glob fallback으로 처리)
# 서버 repo는 GitHub API 읽기 권한이 없으므로 compare/commit/PR API를 호출하지 않는다.
# 서버의 Evidence 수집은 STEP 2의 repob grep/glob/read만 사용한다.
wait
```

**compare 결과 파싱**: 커밋 목록 + changed files를 구조화한다.

```bash
$PYTHON -c "
import sys, json, re, os
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

for repo, path in [('client', '$TMPDIR/compare_client.json')]:  # server는 gh API 불가 — repob fallback
    if not os.path.exists(path) or os.path.getsize(path) < 10:
        print(f'[{repo}] compare API 실패 또는 브랜치 없음')
        continue
    try:
        d = json.load(open(path, encoding='utf-8', errors='replace'))
    except:
        print(f'[{repo}] JSON 파싱 실패')
        continue
    if 'message' in d and 'Not Found' in str(d.get('message','')):
        print(f'[{repo}] 브랜치 없음 (404)')
        continue

    commits = d.get('commits', [])
    files = d.get('files', [])
    truncated = d.get('truncated', False) if isinstance(d, dict) else False
    print(f'[{repo}] ahead={d.get(\"ahead_by\",0)}, commits={len(commits)}, files={len(files)}, truncated={truncated}')

    # 커밋 목록 저장
    # 정규식 추출은 커밋 메시지 **전체**(subject + body)를 대상으로 한다.
    # 이유: PR 없이 직접 git merge되는 워크플로우에서 merge commit 메시지가
    # `Merge branch 'Features/2026_Q2/cvs-13409' into Develop/241/Main` 형태로
    # branch명에만 Jira key가 있는 경우가 있다. subject 첫 줄만 보면 누락된다.
    # 표시·저장용 msg는 첫 줄 100자로 자르되, ticket_keys 추출은 full_msg 사용.
    commit_lines = []
    for c in commits:
        sha = c.get('sha','')[:8]
        full_msg = c.get('commit',{}).get('message','')
        msg = full_msg.split('\n')[0][:100]
        author = c.get('commit',{}).get('author',{}).get('name','')
        date = c.get('commit',{}).get('author',{}).get('date','')[:10]
        # 커밋 메시지 전체(subject + body + merge branch 라인)에서 Jira 티켓 키 추출
        ticket_keys = sorted(set(re.findall(r'CVS-\d+', full_msg, flags=re.IGNORECASE)))
        ticket_keys = [k.upper() for k in ticket_keys]
        commit_lines.append(f'{sha}\t{date}\t{author}\t{msg}\t{\",\".join(ticket_keys)}')
        print(f'  {sha} {date} [{author}] {msg}')
    with open(f'$TMPDIR/compare_{repo}_commits.tsv', 'w', encoding='utf-8') as f:
        f.write('\n'.join(commit_lines))

    # changed files 저장 — status + previous_filename (rename 추적용) 포함
    # TSV 형식: status\tfilename\t+adds\t-dels\tprevious_filename
    file_lines = []
    for fl in files:
        fname = fl.get('filename','')
        status = fl.get('status','')  # added / modified / removed / renamed
        adds = fl.get('additions', 0)
        dels = fl.get('deletions', 0)
        prev_fname = fl.get('previous_filename','')  # rename 시 원래 경로
        file_lines.append(f'{status}\t{fname}\t+{adds}\t-{dels}\t{prev_fname}')
    with open(f'$TMPDIR/compare_{repo}_files.tsv', 'w', encoding='utf-8') as f:
        f.write('\n'.join(file_lines))
    print(f'  → {repo}_files.tsv: {len(file_lines)}건')
"
```

**compare 결과에서 즉시 확정되는 정보**:
- `added` → **New** (이번 릴리스 신규 파일)
- `modified` → **Changed** (내용 변경 확정 — read 비교 불필요)
- `removed` → **Removed** (이번 릴리스 삭제 파일)
- `renamed` → **Renamed** (경로 변경) — 아래 출력 규칙 참조

**Renamed 최종 출력 규칙**:
- compare에서 `renamed`로 반환된 파일은 내부적으로 Renamed로 분류하되, **최종 출력 시 Changed로 통합**한다.
- 이유: Evidence 유효 상태 집합은 `Changed / New / Removed / Unchanged / 미확인` 5개로 고정 (3-D 테이블, ontology-map 호환). Renamed를 6번째 상태로 추가하면 파싱 호환이 깨진다.
- triage.json `evidence_files[].state`에는 `"Changed"` 기록, 비고에 `(renamed from {old_path})` 추가.
- 3-D 테이블: 상태 컬럼 `Changed`, 비고 컬럼에 `Renamed: {old_path} → {new_path}`.
- rename + 내용 변경 동시 발생 시: 그냥 `Changed` (rename 정보는 비고에만).
- rename only (내용 동일, 경로만 변경): `Changed` + 비고 `Renamed (내용 동일)`. QA는 import/reference 깨짐 여부만 확인.

> **glob과의 핵심 차이**: glob은 HEAD/BASE 전체 파일을 긁어서 set 비교했다 (truncation 필연). compare는 **변경된 파일만** 반환하므로 truncation 없이 정확하다.

**compare truncated 처리** (파일 300개 초과 시):
compare API는 파일 300개까지만 반환한다. `truncated: true`이면 아래 방법으로 보충한다:
1. **커밋별 files API**: 각 커밋의 changed files를 개별 조회해 합산 (**주의**: get-a-commit endpoint는 단일 commit이라 페이지네이션 없음 — `--paginate` 옵션과 `--jq` 조합 시 빈 출력이 저장되므로 `--paginate` 미사용)
2. **open PR files API**: open PR이 있으면 해당 PR의 files API (`--paginate` 지원, 제한 없음)로 보충

> **GitHub API 페이지네이션 한계**:
> - compare API: **250 commits** 상한, changed files **첫 페이지 300개** (페이지네이션 없음)
> - get-a-commit: 단일 commit endpoint, **페이지네이션 없음** (`--paginate` 사용 금지). files 300개 초과 시 일부 잘림은 감수하거나 PR files API로 보충
> - 250 commits 초과 릴리스는 compare 1회로 전체 커밋을 못 가져올 수 있다. 이 경우 `ahead_by` 값과 실제 반환 commits 수를 비교해 누락 여부를 감지하고, STEP 5 커버리지에 경고를 남긴다.

```bash
# truncated 보충 — 커밋별 files 수집 (병렬 5개씩)
if [ "$(grep -c 'truncated.*true' $TMPDIR/compare_client.json 2>/dev/null)" -gt 0 ]; then
  echo "[TRUNCATED] 커밋별 files 보충 수집"
  # full SHA를 compare JSON에서 1회 추출 (루프 밖 — API 재호출 방지)
  $PYTHON -c "
import sys, json
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
d = json.load(open('$TMPDIR/compare_client.json', encoding='utf-8', errors='replace'))
for c in d.get('commits', []):
    print(f\"{c['sha'][:8]}\t{c['sha']}\")
" > "$TMPDIR/compare_client_sha_map.tsv"

  COUNT=0
  while IFS=$'\t' read -r SHA DATE AUTHOR MSG TICKETS; do
    FULL_SHA=$(grep "^${SHA}" "$TMPDIR/compare_client_sha_map.tsv" 2>/dev/null | cut -f2)
    [ -z "$FULL_SHA" ] && continue
    # 단일 commit endpoint는 페이지네이션 없음 — --paginate + --jq 조합 시 빈 출력 발생.
    # 300파일 초과 커밋은 파일을 잘려서 받지만, 본 워크플로우(직접 push)에서는 거의 발현 안 됨.
    gh api "repos/bagelcode-cvs/client/commits/$FULL_SHA" \
      --jq '[.files[] | "\(.status)\t\(.filename)\t+\(.additions)\t-\(.deletions)\t\(.previous_filename // "")"][]' \
      >> "$TMPDIR/compare_client_files_extra.tsv" 2>/dev/null &
    COUNT=$((COUNT + 1))
    [ $((COUNT % 5)) -eq 0 ] && wait
  done < "$TMPDIR/compare_client_commits.tsv"
  wait

  # 기존 + extra 합산 후 path 기준 status 정규화
  # 같은 파일이 여러 커밋에서 touched되면 status가 다를 수 있음 (added → modified 등)
  # 정규화 규칙: path 기준 중복 제거, status 우선순위 적용
  $PYTHON -c "
import sys, os
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

# status 우선순위: modified > added > renamed > removed
# 근거: 릴리스 중 added → modified가 되면 최종 상태는 added (신규 파일이 수정된 것)
# removed → added는 최종 modified (삭제 후 재생성)
PRIORITY = {'added': 0, 'modified': 1, 'renamed': 2, 'removed': 3}

def resolve_status(statuses):
    \"\"\"여러 status 중 최종 상태를 결정\"\"\"
    s = set(statuses)
    if 'removed' in s and ('added' in s or 'modified' in s):
        return 'modified'  # 삭제 후 재생성/수정 → 최종 modified
    if 'added' in s:
        return 'added'  # added가 있으면 신규 파일
    if 'modified' in s:
        return 'modified'
    if 'renamed' in s:
        return 'renamed'
    return statuses[0]

files = {}  # path → {status: [], adds: max, dels: max, prev: first_non_empty}
for tsv in ['$TMPDIR/compare_client_files.tsv', '$TMPDIR/compare_client_files_extra.tsv']:
    if not os.path.exists(tsv): continue
    for line in open(tsv, encoding='utf-8', errors='replace'):
        parts = line.strip().split('\t')
        if len(parts) < 2: continue
        st, fname = parts[0], parts[1]
        adds = parts[2] if len(parts) > 2 else '+0'
        dels = parts[3] if len(parts) > 3 else '-0'
        prev = parts[4] if len(parts) > 4 else ''
        if fname not in files:
            files[fname] = {'statuses': [], 'adds': adds, 'dels': dels, 'prev': prev}
        files[fname]['statuses'].append(st)
        if prev and not files[fname]['prev']:
            files[fname]['prev'] = prev

out = []
for fname, info in sorted(files.items()):
    final_st = resolve_status(info['statuses'])
    out.append(f\"{final_st}\t{fname}\t{info['adds']}\t{info['dels']}\t{info['prev']}\")

with open('$TMPDIR/compare_client_files.tsv', 'w', encoding='utf-8') as f:
    f.write('\n'.join(out))
print(f'[정규화 완료] {len(out)}건 (중복 제거 + status 정규화)')
"
fi
```

### 1.5-B: 커밋 → Jira 티켓 자동 매핑

커밋 메시지에서 Jira 키(`CVS-\d+`)를 추출해 티켓↔커밋 매핑을 생성한다.

```bash
# compare_client_commits.tsv의 5번째 컬럼(tickets)에서 매핑 추출
# 결과: $TMPDIR/commit_ticket_map.tsv — {티켓키}\t{repo}\t{sha}\t{message}
$PYTHON -c "
import sys, os
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
out = []
for repo in ['client', 'server']:
    path = f'$TMPDIR/compare_{repo}_commits.tsv'
    if not os.path.exists(path): continue
    for line in open(path, encoding='utf-8', errors='replace'):
        parts = line.strip().split('\t')
        if len(parts) < 5: continue
        sha, date, author, msg, tickets = parts[0], parts[1], parts[2], parts[3], parts[4]
        for tk in tickets.split(','):
            tk = tk.strip()
            if tk: out.append(f'{tk}\t{repo}\t{sha}\t{msg}')
with open('$TMPDIR/commit_ticket_map.tsv', 'w', encoding='utf-8') as f:
    f.write('\n'.join(out))
print(f'커밋↔티켓 매핑: {len(out)}건')
"
```

### 1.5-C: 커밋별 상세 diff 수집 (QA 포인트 추출용)

각 커밋(merge 커밋, version up 제외)의 patch를 수집해 **뭘 바꿨는지** 파악한다.

```bash
# Fix 6: 일반 branch sync merge는 제외하되, Jira key 있는 feature merge는 포함.
# 이유: 'Merge branch 'Features/2026_Q2/cvs-13409' into ...' 같은 feature merge commit은
# 실제 변경 파일을 모두 포함하므로 (직접 push merge 워크플로우에서) ticket→files 매핑의 핵심.
# 제외: 'Merge branch 'Develop/240/Main' into Develop/241/Main' (Jira key 없음 → branch sync)
# 'Version up' SDK 버전 commit만 제외 — 'Contents version X.Y.Z'는 콘텐츠 변경이므로 포함.
$PYTHON -c "
import sys, os, re
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
for repo in ['client', 'server']:
    path = f'$TMPDIR/compare_{repo}_commits.tsv'
    if not os.path.exists(path): continue
    for line in open(path, encoding='utf-8', errors='replace'):
        parts = line.strip().split('\t')
        if len(parts) < 4: continue
        sha, msg = parts[0], parts[3]
        # 'Version up' SDK/번호 bump commit만 제외
        # 'Contents version X.Y.Z' 같은 콘텐츠 버전업은 실제 변경이므로 포함
        if msg.startswith('Version up'):
            continue
        # merge commit: Jira key 있으면 포함 (feature merge), 없으면 제외 (branch sync)
        if msg.startswith('Merge '):
            if not re.search(r'CVS-\d+', msg, flags=re.I):
                continue
        print(f'{repo}\t{sha}\t{msg}')
" > "$TMPDIR/commits_to_detail.tsv"

# 상세 diff 수집 — client만 (server는 gh API 접근 불가)
COUNT=0
while IFS=$'\t' read -r REPO SHA MSG; do
  [ "$REPO" != "client" ] && continue  # server 커밋은 gh API 불가 → 건너뜀
  # 단일 commit endpoint는 페이지네이션 없음 — --paginate + --jq 조합 시 출력이 빈 파일로 저장됨.
  gh api "repos/bagelcode-cvs/client/commits/$SHA" \
    --jq '{sha: .sha[:8], message: (.commit.message | split("\n")[0]), files: [.files[] | {name: .filename, status: .status, previous_filename: (.previous_filename // ""), patch: (.patch // "")[:2000]}]}' \
    > "$TMPDIR/commit_detail_${REPO}_${SHA}.json" 2>/dev/null &
  COUNT=$((COUNT + 1))
  [ $((COUNT % 5)) -eq 0 ] && wait
done < "$TMPDIR/commits_to_detail.tsv"
wait
```

**커밋 diff에서 QA 정보 추출**: 각 커밋의 patch를 분석해 아래를 도출한다:
- **변경된 함수/클래스명**: diff의 `@@` 헤더에서 함수명 추출
- **변경 의도**: 커밋 메시지 + diff 패턴에서 추론 (버그 픽스, 기능 추가, 리팩토링)
- **테스트 포인트**: 변경된 로직의 입력/출력/조건 변화

### 1.5-C2: 티켓↔변경 파일 정규화 (`ticket_commit_files.tsv`)

commit_detail_*.json을 파싱해 **티켓 → 파일 → 상태** 매핑을 생성한다. 이 산출물이 `source: "commit"` Evidence의 실체이다.

```bash
$PYTHON -c "
import sys, json, os, glob as g
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

# 1. commit_ticket_map.tsv에서 ticket→sha 매핑 로드
ticket_shas = {}  # {ticket: [(repo, sha)]}
map_path = '$TMPDIR/commit_ticket_map.tsv'
if os.path.exists(map_path):
    for line in open(map_path, encoding='utf-8', errors='replace'):
        parts = line.strip().split('\t')
        if len(parts) < 3: continue
        tk, repo, sha = parts[0], parts[1], parts[2]
        ticket_shas.setdefault(tk, []).append((repo, sha))

# 2. commit_detail_*.json에서 sha→files 매핑 로드
sha_files = {}  # {(repo, sha): [{name, status}]}
for f in g.glob('$TMPDIR/commit_detail_*.json'):
    try:
        d = json.load(open(f, encoding='utf-8', errors='replace'))
        sha = d.get('sha', '')
        repo = 'client' if '_client_' in f else 'server' if '_server_' in f else ''
        files = d.get('files', [])
        sha_files[(repo, sha)] = [{'name': fl['name'], 'status': fl['status']} for fl in files]
    except:
        continue

# 3. ticket→file→status 정규화
# 같은 파일이 같은 티켓의 여러 커밋에서 나오면 status 정규화 (added 유지, modified 우선)
ticket_files = {}  # {ticket: {(repo, filename): [statuses]}}
for tk, sha_list in ticket_shas.items():
    ticket_files.setdefault(tk, {})
    for repo, sha in sha_list:
        for fl in sha_files.get((repo, sha), []):
            key = (repo, fl['name'])
            ticket_files[tk].setdefault(key, []).append(fl['status'])

def resolve(statuses):
    s = set(statuses)
    if 'removed' in s and ('added' in s or 'modified' in s):
        return 'modified'
    if 'added' in s: return 'added'
    if 'modified' in s: return 'modified'
    if 'renamed' in s: return 'renamed'
    return statuses[0]

# 4. TSV 출력: ticket\trepo\tfilename\tstatus
out = []
for tk in sorted(ticket_files.keys()):
    for (repo, fname), statuses in sorted(ticket_files[tk].items()):
        final_st = resolve(statuses)
        out.append(f'{tk}\t{repo}\t{fname}\t{final_st}')

with open('$TMPDIR/ticket_commit_files.tsv', 'w', encoding='utf-8') as f:
    f.write('\n'.join(out))
print(f'티켓↔변경파일 매핑: {len(out)}건 ({len(ticket_files)}개 티켓)')
"
```

> **용도**: 이 산출물로 triage.json의 `evidence_files[].source: "commit"`을 실현한다. 티켓 키로 `ticket_commit_files.tsv`를 조회하면 해당 커밋에서 **실제 변경된 파일**과 상태를 즉시 얻을 수 있다. compare 결과(브랜치 전체 diff)와 달리 **이 티켓의 커밋이 직접 변경한 파일**만 포함하므로 신호 품질이 가장 높다.

### 1.5-D: PR 수집 — client만 (merged + open — {RELEASE}/Main 및 {PREV}/Main 타겟)

> **server PR 수집 불가**: server repo는 gh API 접근 권한이 없으므로 PR 수집을 하지 않는다. server 변경 파악은 repob grep/glob/read로만 수행한다.

**검색 범위**: client repo의 릴리스 브랜치 구조에 맞춰 아래를 수집한다:
1. `Develop/${RELEASE}/Main`에 **merged + open** PR → 240에 직접 추가되는 변경
2. `Develop/${PREV}/Main`에 **merged** PR → 239를 경유해 240에 포함된 변경

> **open PR도 수집하는 이유**: merge 예정 PR의 changed files로 향후 변경을 사전 파악한다. open PR은 Evidence 확정이 아니라 "merge 시 영향 예상" 참고용이다.

```bash
# {RELEASE}/Main 타겟 (merged + open)
gh pr list --repo bagelcode-cvs/client --state all \
  --search "base:Develop/${RELEASE}/Main" \
  --json number,title,body,state,mergedAt,author,baseRefName,headRefName,mergeCommit \
  --limit 100 > $TMPDIR/gh_pr_release.json 2>/dev/null &

# {PREV}/Main 타겟 (merged만 — 240에 포함된 변경)
gh pr list --repo bagelcode-cvs/client --state merged \
  --search "base:Develop/${PREV}/Main" \
  --json number,title,body,mergedAt,author,baseRefName,headRefName,mergeCommit \
  --limit 100 > $TMPDIR/gh_pr_prev.json 2>/dev/null &
wait

# PR 100건 상한 도달 경고
$PYTHON -c "
import sys, json, os
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
for name, path in [('release', '$TMPDIR/gh_pr_release.json'), ('prev', '$TMPDIR/gh_pr_prev.json')]:
    if not os.path.exists(path): continue
    try:
        prs = json.load(open(path, encoding='utf-8', errors='replace'))
    except: continue
    if len(prs) >= 100:
        print(f'⚠️ [{name}] PR {len(prs)}건 — 100건 상한 도달. 일부 PR이 누락됐을 수 있음.')
        print(f'  → STEP 5 커버리지에 \"PR 100건 상한 도달 — 추가 PR 누락 가능\" 경고 포함 필요')
    else:
        print(f'[{name}] PR {len(prs)}건 (상한 미도달)')
"
```

> **PR 100건 초과 시**: `gh pr list --limit`은 최대 100건만 반환하고 페이지네이션을 지원하지 않는다. 100건 도달 시 STEP 5 커버리지에 경고를 남기고, 누락 가능성을 명시한다. 실무에서 단일 브랜치에 PR 100건 이상이 몰리는 경우는 드물지만, 바쁜 릴리스에서는 prev branch merged PR이 100건을 넘길 수 있다.

**open PR changed files 수집** (merge 예정 변경 파악):
```bash
# open PR의 changed files (페이지네이션 지원)
$PYTHON -c "
import sys, json, os
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
path = '$TMPDIR/gh_pr_release.json'
if not os.path.exists(path): exit(0)
prs = json.load(open(path, encoding='utf-8', errors='replace'))
open_prs = [p for p in prs if p.get('state') == 'OPEN']
for p in open_prs:
    print(f'{p[\"number\"]}')
" > "$TMPDIR/open_pr_numbers.txt"

# 각 open PR의 files 수집 (병렬)
while read -r PR_NUM; do
  [ -z "$PR_NUM" ] && continue
  gh api "repos/bagelcode-cvs/client/pulls/${PR_NUM}/files" --paginate \
    > "$TMPDIR/pr_files_${PR_NUM}.json" 2>/dev/null &
done < "$TMPDIR/open_pr_numbers.txt"
wait
```

### 1.5-E: Jira dev-status → 티켓↔PR 역매핑

`$TMPDIR/issue_ids.tsv`의 각 티켓 internal ID로 dev-status API를 호출해 Jira↔GitHub PR 연결 정보를 수집한다.

```bash
# 도구 timeout 시 background curl 좀비 방지 — 부모 셸 종료 시 자식 일괄 정리
trap 'kill $(jobs -p) 2>/dev/null; wait 2>/dev/null' EXIT INT TERM

# 각 티켓의 internal ID로 dev-status API 호출 (병렬 5건씩)
fetch_devstatus() {
  KEY=$1; ID=$2
  HTTP_CODE=$(curl -s --connect-timeout 5 --max-time 45 --retry 2 --retry-delay 2 \
    -o "$TMPDIR/devstatus_${KEY}.json" -w '%{http_code}' -u "$JIRA_AUTH" \
    "$JIRA_BASE/rest/dev-status/latest/issue/detail?issueId=${ID}&applicationType=GitHub&dataType=pullrequest")
  if [ "$HTTP_CODE" -lt 200 ] 2>/dev/null || [ "$HTTP_CODE" -ge 300 ] 2>/dev/null; then
    echo "WARN: devstatus $KEY fetch failed (HTTP $HTTP_CODE)" >&2
    printf '%s\t%s\t%s\t%s\n' "partial" "devstatus" "$KEY" "$HTTP_CODE" >> "$TMPDIR/fetch_failed.txt"
  fi
}
COUNT=0
while IFS=$'\t' read -r KEY ID; do
  fetch_devstatus "$KEY" "$ID" &
  COUNT=$((COUNT + 1))
  [ $((COUNT % 5)) -eq 0 ] && wait
done < "$TMPDIR/issue_ids.tsv"
wait

# 파싱 → jira_pr_map.tsv (6컬럼: key, repo, pr_num, title, status, source)
# source: "devstatus" (Atlassian dev-status 강한 매핑) / "fallback" (PR 메타 정규식 약한 매핑) / "desc_url" (티켓 description/comment/remotelink 본문 PR URL 직접 추출, 최종 보강)
$PYTHON <<'PYEOF'
import sys, json, glob, os, re
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
TMPDIR = os.environ['TMPDIR']

# === 1. dev-status 결과 파싱 (강한 매핑) ===
mapped = []  # (key, repo, pr_num, title, status, source)
existing = set()  # (key, repo, pr_num)
for f in sorted(glob.glob(f'{TMPDIR}/devstatus_*.json')):
    key = os.path.basename(f).replace('devstatus_', '').replace('.json', '')
    try: d = json.load(open(f, encoding='utf-8', errors='replace'))
    except: continue
    for det in d.get('detail', []):
        for pr in det.get('pullRequests', []):
            url = pr.get('url', '')
            title = pr.get('name', '').replace('\t', ' ').replace('\n', ' ')
            status = pr.get('status', '')
            m = re.search(r'github\.com/([^/]+/[^/]+)/pull/(\d+)', url)
            if m:
                repo = m.group(1).split('/')[-1]
                pr_num = m.group(2)
                if (key, repo, pr_num) not in existing:
                    mapped.append((key, repo, pr_num, title, status, 'devstatus'))
                    existing.add((key, repo, pr_num))

devstatus_count = len(mapped)

# === 2. Fallback: PR 메타(title + body + headRefName)에서 Jira 키 정규식 추출 ===
# Atlassian Smart Commits 연동 비활성·dev-status 빈 응답 환경에서 PR↔티켓 매핑 복구.
# closed unmerged PR(state="closed" && mergedAt is null)은 코드에 반영되지 않은 변경이므로
# 회귀 분석 대상에서 제외하고 closed_unmerged 카운트만 증가시킨다.
# 동시에 PR-level 머지 상태 인덱스(pr_merge_state)를 만들어 desc_url 매핑에서도 재사용한다.
PR_FILES = [
    (f'{TMPDIR}/gh_pr_release.json', 'client'),
    (f'{TMPDIR}/gh_pr_prev.json', 'client'),
]
closed_unmerged_count = 0
pr_merge_state = {}  # (repo, pr_num) -> ('merged'|'open'|'closed_unmerged', mergedAt)
for path, repo in PR_FILES:
    if not os.path.exists(path): continue
    try: prs = json.load(open(path, encoding='utf-8', errors='replace'))
    except: continue
    for pr in (prs if isinstance(prs, list) else []):
        pr_num = str(pr.get('number', ''))
        title = (pr.get('title') or '').replace('\t', ' ').replace('\n', ' ')
        body = pr.get('body') or ''
        head = pr.get('headRefName') or ''
        state = pr.get('state', '')
        merged_at = pr.get('mergedAt')  # gh CLI: mergedAt (ISO datetime) or null
        # 머지 상태 정규화: state + mergedAt 조합
        if merged_at:
            merge_state = 'merged'
        elif state.lower() == 'open':
            merge_state = 'open'
        else:
            merge_state = 'closed_unmerged'
        pr_merge_state[(repo, pr_num)] = (merge_state, merged_at)
        # closed unmerged는 매핑 제외
        if merge_state == 'closed_unmerged':
            haystack_keys = set(re.findall(r'CVS-\d+', f'{title}\n{body}\n{head}', flags=re.IGNORECASE))
            if haystack_keys:
                closed_unmerged_count += len(haystack_keys)
            continue
        haystack = f'{title}\n{body}\n{head}'
        keys = set(re.findall(r'CVS-\d+', haystack, flags=re.IGNORECASE))
        for k in keys:
            k = k.upper()
            if (k, repo, pr_num) in existing: continue
            mapped.append((k, repo, pr_num, title, state, 'fallback'))
            existing.add((k, repo, pr_num))

fallback_count = len(mapped) - devstatus_count

# === 3. Fallback: Jira issue description / comment / remotelink 본문에서 PR URL 직접 추출 ===
# dev-status 비활성·PR 메타 fallback 둘 다 실패한 환경에서 마지막 매핑 복구.
# 티켓 본문에 손으로 적은 PR 링크(예: "참고 PR: https://github.com/.../pull/422")까지 포착.
# 매핑 source: 'desc_url'.
desc_count_start = len(mapped)
PR_URL_RE = re.compile(r'github\.com/([^/\s"\']+/[^/\s"\']+)/pull/(\d+)')

# 3-a. issue description + comment (ADF) 본문 — JSON 통째 stringify 후 정규식
for f in sorted(glob.glob(f'{TMPDIR}/issue_*.json')):
    key = os.path.basename(f).replace('issue_', '').replace('.json', '')
    try: d = json.load(open(f, encoding='utf-8', errors='replace'))
    except: continue
    fields = d.get('fields', {}) or {}
    haystack = json.dumps(fields.get('description') or {}, ensure_ascii=False)
    comments = ((fields.get('comment') or {}).get('comments') or [])
    for c in comments:
        haystack += '\n' + json.dumps(c.get('body') or {}, ensure_ascii=False)
    seen_local = set()
    for m in PR_URL_RE.finditer(haystack):
        repo = m.group(1).split('/')[-1]
        pr_num = m.group(2)
        # desc_url 매핑도 closed_unmerged 검증 (pr_merge_state 인덱스 활용)
        # PR이 수집 범위 밖이면 상태 미상 → 매핑 유지하되 status='unknown'
        ms = pr_merge_state.get((repo, pr_num))
        if ms and ms[0] == 'closed_unmerged':
            continue
        if (key, repo, pr_num) in existing or (key, repo, pr_num) in seen_local: continue
        status_label = ms[0] if ms else 'unknown'
        mapped.append((key, repo, pr_num, '', status_label, 'desc_url'))
        existing.add((key, repo, pr_num))
        seen_local.add((key, repo, pr_num))

# 3-b. remotelink — object.url 또는 url 필드에 직접 PR 링크가 있는 경우
for f in sorted(glob.glob(f'{TMPDIR}/remotelink_*.json')):
    key = os.path.basename(f).replace('remotelink_', '').replace('.json', '')
    try: d = json.load(open(f, encoding='utf-8', errors='replace'))
    except: continue
    items = d if isinstance(d, list) else (d.get('values') or [])
    for item in items:
        url = ((item.get('object') or {}).get('url')) or item.get('url') or ''
        m = PR_URL_RE.search(url)
        if not m: continue
        repo = m.group(1).split('/')[-1]
        pr_num = m.group(2)
        # desc_url 매핑도 closed_unmerged 검증 (pr_merge_state 인덱스 활용)
        # PR이 수집 범위 밖이면 상태 미상 → 매핑 유지하되 status='unknown'
        ms = pr_merge_state.get((repo, pr_num))
        if ms and ms[0] == 'closed_unmerged':
            continue
        if (key, repo, pr_num) in existing: continue
        status_label = ms[0] if ms else 'unknown'
        mapped.append((key, repo, pr_num, '', status_label, 'desc_url'))
        existing.add((key, repo, pr_num))

desc_count = len(mapped) - desc_count_start

# === 4. 저장 (tmp → validate → mv 패턴, _unverified.flag 인프라) ===
# 트리아지·STEP 3·STEP 5가 jira_pr_map.tsv에 강하게 의존하므로 검증 후에만 정식 파일로 승격.
# 검증 실패 시 _unverified.flag를 남겨 후속 단계가 매핑 미확정 상태를 인지하도록 한다.
import shutil
out_path = f'{TMPDIR}/jira_pr_map.tsv'
tmp_path = out_path + '.tmp'
flag_path = f'{TMPDIR}/jira_pr_map.tsv._unverified.flag'

with open(tmp_path, 'w', encoding='utf-8') as fp:
    for row in mapped:
        fp.write('\t'.join(row) + '\n')

# 검증: (a) tmp 파일이 비어있지 않거나 (b) PR 자체가 0건이거나 (c) devstatus·fallback·desc_url 모두 0이고 PR이 존재 → 후자만 unverified
pr_files_exist = any(os.path.exists(p) for p, _ in PR_FILES)
total_pr_count = 0
for path, _ in PR_FILES:
    if os.path.exists(path):
        try: total_pr_count += len(json.load(open(path, encoding='utf-8', errors='replace')) or [])
        except: pass
unverified = (total_pr_count > 0 and len(mapped) == 0)

if unverified:
    # 정식 파일은 빈 상태로 두고 flag 남김 — 후속 단계가 매핑 0건 + flag로 분기 판단
    shutil.move(tmp_path, out_path)
    with open(flag_path, 'w', encoding='utf-8') as ff:
        ff.write(f'PR={total_pr_count} mapped=0 devstatus={devstatus_count} fallback={fallback_count} desc_url={desc_count} closed_unmerged={closed_unmerged_count}\n')
    print(f'⚠️ jira_pr_map.tsv: PR {total_pr_count}건 있으나 매핑 0건 → _unverified.flag 생성. 트리아지는 commit-mapped fallback 또는 grep으로 진행.')
else:
    # 정식 승격 + 이전 flag 잔존 시 제거
    shutil.move(tmp_path, out_path)
    if os.path.exists(flag_path):
        os.remove(flag_path)
    print(f'jira_pr_map.tsv: 총 {len(mapped)}건 (devstatus {devstatus_count} + fallback {fallback_count} + desc_url {desc_count}); closed_unmerged 제외 {closed_unmerged_count}건')
PYEOF
```

### 1.5-F: github_summary.json 생성

모든 수집 결과를 통합한다:
```json
{
  "release": "{RELEASE}",
  "compare": {
    "client": {
      "ahead": 5,
      "commits": [{"sha": "...", "message": "...", "author": "...", "date": "...", "tickets": ["CVS-XXXXX"]}],
      "files": [{"path": "...", "status": "added/modified/removed", "additions": 0, "deletions": 0}],
      "truncated": false
    },
    "server": { "...동일 구조..." }
  },
  "prs": {
    "release_target": [{"number": 420, "title": "...", "state": "OPEN", "base": "Develop/241/Main"}],
    "prev_target": [{"number": 418, "title": "...", "state": "MERGED", "base": "Develop/239/Main"}]
  },
  "commit_ticket_map": {"CVS-13353": [{"repo": "client", "sha": "1783fa13", "message": "fix: [CVS-13353] ..."}]},
  "jira_pr_map": {"CVS-XXXXX": [{"repo": "client", "pr": 1234, "title": "...", "status": "merged", "source": "devstatus"}]}
}
```

> **실패 처리**: gh CLI 미설치 또는 인증 실패 시, `github_summary.json`에 `"error": "gh CLI unavailable"` 기록 후 STEP 2로 진행한다. compare API가 실패하면 기존 repob glob 방식으로 fallback한다.

---

## STEP 2: Cross-Branch Evidence 수집 [STEP 1.5 완료 후 실행]

STEP 1.5의 compare API 결과를 **1차 소스**로 사용한다. compare가 실패한 경우에만 repob glob으로 fallback한다.

### 2-1. 변경 파일 목록 확정 (compare 기반)

**compare 결과가 있으면** (`$TMPDIR/compare_client_files.tsv` 존재):
- `added` → **New**, `modified` → **Changed**, `removed` → **Removed**, `renamed` → **Renamed**
- glob 전체 스캔이 **불필요** — compare가 변경된 파일만 정확하게 반환했으므로 truncation 문제 없음
- `.meta` 파일은 제외 (Unity 메타 파일은 QA 무관)

```bash
# compare 결과를 New/Changed/Removed로 분류
$PYTHON -c "
import sys, os
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

for repo in ['client', 'server']:
    path = f'$TMPDIR/compare_{repo}_files.tsv'
    if not os.path.exists(path):
        print(f'[{repo}] compare 결과 없음 — repob glob fallback 필요')
        continue
    new, changed, removed, renamed = [], [], [], []
    rename_map = {}  # new_path → old_path (비고용)
    for line in open(path, encoding='utf-8', errors='replace'):
        parts = line.strip().split('\t')
        if len(parts) < 2: continue
        status, fname = parts[0], parts[1]
        prev_fname = parts[4] if len(parts) > 4 else ''
        if fname.endswith('.meta'): continue  # Unity 메타 파일 제외
        if status == 'added': new.append(fname)
        elif status == 'modified': changed.append(fname)
        elif status == 'removed': removed.append(fname)
        elif status == 'renamed':
            renamed.append(fname)  # 내부 분류용, Evidence 출력 시 Changed로 통합
            if prev_fname: rename_map[fname] = prev_fname
    print(f'[{repo}] New: {len(new)}, Changed: {len(changed) + len(renamed)}, Removed: {len(removed)} (Renamed {len(renamed)}건 → Changed로 통합)')
    # rename_map 저장 (3-D 비고 생성용)
    if rename_map:
        with open(f'$TMPDIR/{repo}_rename_map.tsv', 'w') as f:
            for new_p, old_p in rename_map.items():
                f.write(f'{new_p}\t{old_p}\n')
    # 분류 결과 저장
    with open(f'$TMPDIR/{repo}_new.txt', 'w') as f: f.write('\n'.join(new))
    with open(f'$TMPDIR/{repo}_changed.txt', 'w') as f: f.write('\n'.join(changed))
    with open(f'$TMPDIR/{repo}_removed.txt', 'w') as f: f.write('\n'.join(removed))
"
```

**서브모듈 포인터 감지 및 내부 파일 전개** (compare 분류 직후 실행):
compare API는 서브모듈(git submodule) 변경을 **포인터 변경**으로만 반환한다. 예: `Assets/Contents` modified, +1 -1. 서브모듈 내부의 실제 파일(신규 슬롯 *.cs, Popup.cs 등)은 반환하지 않는다. 이를 방치하면 콘텐츠성 변경이 과소평가된다.

**서브모듈 감지 휴리스틱**: compare 결과에서 아래 조건을 **모두** 충족하는 행을 서브모듈 포인터로 판정한다:
1. `status == modified`
2. `additions == 1` 이고 `deletions == 1` (포인터 해시 1줄 변경)
3. 파일명에 확장자가 없음 (디렉토리 이름처럼 보임)

감지된 서브모듈 경로에 대해 `$REPOB remote glob`으로 HEAD/BASE 양쪽의 내부 파일을 전개하고, set 비교로 New/Changed/Removed를 확정한다.

```bash
# 서브모듈 감지 → 내부 전개
$PYTHON -c "
import sys, os
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
submodules = []
path = '$TMPDIR/compare_client_files.tsv'
if os.path.exists(path):
    for line in open(path, encoding='utf-8', errors='replace'):
        parts = line.strip().split('\t')
        if len(parts) < 4: continue
        status, fname, adds, dels = parts[0], parts[1], parts[2], parts[3]
        # 서브모듈 휴리스틱: modified + +1 -1 + 확장자 없음
        if status == 'modified' and adds == '+1' and dels == '-1' and '.' not in fname.split('/')[-1]:
            submodules.append(fname)
            print(f'[SUBMODULE] {fname}')
with open('$TMPDIR/submodule_paths.txt', 'w') as f:
    f.write('\n'.join(submodules))
if not submodules:
    print('서브모듈 포인터 없음')
"

# 서브모듈 전개 실패 fallback: submodule_paths.txt가 비어있거나 repob glob이 전체 실패하면
# client_new/removed 없이 진행한다. 트리아지에서 compare 파일 + grep만으로 분류한다.
# 전개 부분 실패가 전체 스킬을 중단시키지 않도록 각 repob 호출에 2>/dev/null 적용.

# 서브모듈 내부 glob — 동적 디렉토리 분할 (truncation 방지)
# 1단계: 서브모듈의 1단계 하위 디렉토리를 먼저 glob으로 탐색
# portable 배열 빌드 후 별도 for 루프 (repob stdin 오염 회피, moco/CLAUDE.md L23)
SUBMOD_LIST=()
while IFS= read -r LINE || [ -n "$LINE" ]; do
  [ -z "$LINE" ] && continue
  SUBMOD_LIST+=("$LINE")
done < "$TMPDIR/submodule_paths.txt"
for SUBMOD in "${SUBMOD_LIST[@]}"; do
  SAFE=$(echo "$SUBMOD" | tr '/' '_')
  $REPOB remote glob client Develop/${RELEASE}/Main "${SUBMOD}/*/" --pretty \
    > "$TMPDIR/submod_dirs_${SAFE}.json" 2>/dev/null
done

# 2단계: 각 하위 디렉토리별 분할 glob (HEAD + BASE 직렬)
$PYTHON -c "
import sys, json, os, subprocess
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

def load_json_list(path):
    if not os.path.exists(path) or os.path.getsize(path) < 5: return []
    try:
        d = json.load(open(path, encoding='utf-8', errors='replace'))
        if isinstance(d, list): return d
        if isinstance(d, dict): return d.get('files', d.get('matches', d.get('results', [])))
    except: pass
    return []

def parse_dirs(path):
    items = load_json_list(path)
    dirs = set()
    for item in items:
        s = str(item).rstrip('/')
        if '/' in s:
            dirs.add(s)
    return sorted(dirs)

cmds = []
for submod_line in open('$TMPDIR/submodule_paths.txt', encoding='utf-8'):
    submod = submod_line.strip()
    if not submod: continue
    safe = submod.replace('/', '_')
    dirs_file = f'$TMPDIR/submod_dirs_{safe}.json'
    subdirs = parse_dirs(dirs_file)
    if not subdirs:
        # 하위 디렉토리 없으면 서브모듈 전체 glob (fallback)
        subdirs = [submod]
    for sd in subdirs:
        sd_safe = sd.replace('/', '_').replace(' ', '_')
        # HEAD + BASE 명령 생성
        cmds.append(('head', sd, sd_safe, f'$TMPDIR/submod_split_head_{sd_safe}.json'))
        cmds.append(('base', sd, sd_safe, f'$TMPDIR/submod_split_base_{sd_safe}.json'))
# 명령 목록 저장 (bash에서 병렬 실행)
with open('$TMPDIR/_submod_glob_cmds.txt', 'w') as f:
    for kind, sd, sd_safe, outpath in cmds:
        branch = 'Develop/${RELEASE}/Main' if kind == 'head' else 'Develop/${PREV}/Main'
        f.write(f'{branch}\t{sd}/**/*.cs\t{outpath}\n')
print(f'서브모듈 분할 glob 명령: {len(cmds)}건 ({len(cmds)//2} 디렉토리)')
"

# 분할 glob 직렬 실행 (Mac Traps 직렬 원칙 + repob stdin 오염 회피)
SUBMOD_GLOB_CMDS=()
while IFS= read -r LINE || [ -n "$LINE" ]; do
  [ -z "$LINE" ] && continue
  SUBMOD_GLOB_CMDS+=("$LINE")
done < "$TMPDIR/_submod_glob_cmds.txt"
for ROW in "${SUBMOD_GLOB_CMDS[@]}"; do
  IFS=$'\t' read -r BRANCH PATTERN OUTPATH <<< "$ROW"
  [ -z "$BRANCH" ] && continue
  $REPOB remote glob client "$BRANCH" "$PATTERN" --pretty > "$OUTPATH" 2>/dev/null
done

# 2단계 truncation 검사 — 100건 결과가 있으면 추가 분할 (최대 2단계)
$PYTHON -c "
import sys, json, os
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

def load_json_list(path):
    if not os.path.exists(path) or os.path.getsize(path) < 5: return []
    try:
        d = json.load(open(path, encoding='utf-8', errors='replace'))
        if isinstance(d, list): return d
        if isinstance(d, dict): return d.get('files', d.get('matches', d.get('results', [])))
    except: pass
    return []

resplit = []
for line in open('$TMPDIR/_submod_glob_cmds.txt', encoding='utf-8'):
    parts = line.strip().split('\t')
    if len(parts) < 3: continue
    branch, pattern, outpath = parts
    items = load_json_list(outpath)
    if len(items) >= 100:
        # 2단계 분할 필요
        base_dir = pattern.replace('/**/*.cs', '')
        resplit.append((branch, base_dir, outpath))
        print(f'⚠️ truncation: {pattern} → {len(items)}건, 2단계 분할 필요')

with open('$TMPDIR/_submod_resplit.txt', 'w') as f:
    for branch, base_dir, outpath in resplit:
        f.write(f'{branch}\t{base_dir}\t{outpath}\n')
print(f'2단계 분할 대상: {len(resplit)}건')
"

# 2단계 분할 실행 (truncation 발생한 디렉토리만)
if [ -s "$TMPDIR/_submod_resplit.txt" ]; then
  # portable 배열 빌드 후 별도 for 루프 (repob stdin 오염 회피)
  RESPLIT_LIST=()
  while IFS= read -r LINE || [ -n "$LINE" ]; do
    [ -z "$LINE" ] && continue
    RESPLIT_LIST+=("$LINE")
  done < "$TMPDIR/_submod_resplit.txt"
  for ROW in "${RESPLIT_LIST[@]}"; do
    IFS=$'\t' read -r BRANCH BASE_DIR ORIG_OUTPATH <<< "$ROW"
    [ -z "$BRANCH" ] && continue
    SAFE_DIR=$(echo "$BASE_DIR" | tr '/ ' '__')
    # 하위 디렉토리 탐색
    $REPOB remote glob client "$BRANCH" "${BASE_DIR}/*/" --pretty \
      > "$TMPDIR/_resplit_dirs_${SAFE_DIR}.json" 2>/dev/null
  done

  # 하위 디렉토리별 재분할 glob
  $PYTHON -c "
import sys, json, os
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

def load_json_list(path):
    if not os.path.exists(path) or os.path.getsize(path) < 5: return []
    try:
        d = json.load(open(path, encoding='utf-8', errors='replace'))
        if isinstance(d, list): return d
        if isinstance(d, dict): return d.get('files', d.get('matches', d.get('results', [])))
    except: pass
    return []

cmds = []
for line in open('$TMPDIR/_submod_resplit.txt', encoding='utf-8'):
    parts = line.strip().split('\t')
    if len(parts) < 3: continue
    branch, base_dir, orig_outpath = parts
    # head/base 판별: branch 문자열에 RELEASE 번호 포함 여부 (bash가 ${RELEASE}를 이미 치환한 상태)
    _release = '${RELEASE}'  # bash가 치환하므로 실제 릴리스 번호 (예: '241')
    kind = 'head' if _release in branch else 'base'
    safe_dir = base_dir.replace('/', '_').replace(' ', '_')
    dirs = load_json_list(f'$TMPDIR/_resplit_dirs_{safe_dir}.json')
    for d in dirs:
        d = str(d).rstrip('/')
        d_safe = d.replace('/', '_').replace(' ', '_')
        # 파일명에 head/base 구분자 삽입 — 집계에서 glob 패턴으로 분리 가능
        cmds.append(f'{branch}\t{d}/**/*.cs\t$TMPDIR/submod_resplit_{kind}_{d_safe}.json')
with open('$TMPDIR/_submod_resplit_cmds.txt', 'w') as f:
    f.write('\n'.join(cmds))
print(f'2단계 분할 glob 명령: {len(cmds)}건')
"
  # 2단계 분할 직렬 실행 (Mac Traps 직렬 원칙 + repob stdin 오염 회피)
  RESPLIT_GLOB_CMDS=()
  while IFS= read -r LINE || [ -n "$LINE" ]; do
    [ -z "$LINE" ] && continue
    RESPLIT_GLOB_CMDS+=("$LINE")
  done < "$TMPDIR/_submod_resplit_cmds.txt"
  for ROW in "${RESPLIT_GLOB_CMDS[@]}"; do
    IFS=$'\t' read -r BRANCH PATTERN OUTPATH <<< "$ROW"
    [ -z "$BRANCH" ] && continue
    $REPOB remote glob client "$BRANCH" "$PATTERN" --pretty > "$OUTPATH" 2>/dev/null
  done
fi

# set 비교 → New/Removed/Common 확정 → 기존 분류 파일에 추가
$PYTHON -c "
import sys, json, os, glob as g
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

def load_files(path):
    if not os.path.exists(path) or os.path.getsize(path) < 5:
        return set()
    try:
        d = json.load(open(path, encoding='utf-8', errors='replace'))
        if isinstance(d, list): return set(d)
        if isinstance(d, dict): return set(d.get('files', d.get('matches', d.get('results', []))))
    except:
        return set(l.strip() for l in open(path, encoding='utf-8', errors='replace').read().splitlines() if l.strip())
    return set()

# 모든 분할 결과를 HEAD/BASE별로 합산
head_all = set()
base_all = set()
for f in sorted(g.glob('$TMPDIR/submod_split_head_*.json') + g.glob('$TMPDIR/submod_resplit_head_*.json')):
    head_all |= load_files(f)
for f in sorted(g.glob('$TMPDIR/submod_split_base_*.json') + g.glob('$TMPDIR/submod_resplit_base_*.json')):
    base_all |= load_files(f)

# resplit 결과가 있으면 원본 truncated 결과를 대체
resplit_path = '$TMPDIR/_submod_resplit.txt'
if os.path.exists(resplit_path):
    for line in open(resplit_path, encoding='utf-8'):
        parts = line.strip().split('\t')
        if len(parts) >= 3:
            orig = parts[2]
            # resplit이 있는 원본은 합산에서 이미 대체됨 — 별도 처리 불요

submod_new = sorted(head_all - base_all)
submod_removed = sorted(base_all - head_all)
submod_common = sorted(head_all & base_all)

print(f'서브모듈 합산: HEAD {len(head_all)}, BASE {len(base_all)}, New {len(submod_new)}, Removed {len(submod_removed)}, Common {len(submod_common)}')

# common 파일 목록 저장 (Changed 판정용 — 다중 경로에서 사용)
with open('$TMPDIR/submod_common.txt', 'w', encoding='utf-8') as f:
    f.write('\n'.join(submod_common))

# 기존 client_new.txt, client_removed.txt에 추가
if submod_new:
    with open('$TMPDIR/client_new.txt', 'a') as f:
        f.write('\n' + '\n'.join(submod_new))
    print(f'→ client_new.txt에 {len(submod_new)}건 추가')
if submod_removed:
    with open('$TMPDIR/client_removed.txt', 'a') as f:
        f.write('\n' + '\n'.join(submod_removed))
    print(f'→ client_removed.txt에 {len(submod_removed)}건 추가')
"
```

> **서브모듈 내부 common 파일 (Changed 판정 — 다중 경로)**:
> 서브모듈 내부 common 파일은 수가 많을 수 있다 (수십~수백). 전체 read 비교는 비현실적이므로, 아래 우선순위로 Changed 후보를 선정한다. 상위 경로에서 후보가 나오면 하위는 건너뛴다.
>
> | 순위 | 경로 | selector | 코드 확정 |
> |------|------|----------|----------|
> | 1 | CHANGELOG Changed/Removed 항목에 명시된 클래스 | `changelog` | **가능** |
> | 2 | 티켓 키워드 ↔ common 파일명 exact 매칭 | `filename_keyword` | **가능** |
> | 3 | 하위 작업 기술 키워드 ↔ common 파일명 매칭 | `filename_keyword` | **가능** |
> | 4 | broad grep effective_files ∩ common | `broad_grep` | **불가** |
>
> - 1~3순위에서 후보가 나오면 선택적 read (티켓당 최대 3개)
> - 4순위는 마지막 fallback만 — read하더라도 `selector: "broad_grep"` → 코드 확정 불가
> - Changed 확정된 파일을 `client_changed.txt`에 추가
>
> ```bash
> # common 파일 Changed 판정 — 다중 경로 (STEP 2-1-A CHANGELOG 완료 후 실행)
> $PYTHON -c "
> import sys, json, os, re
> sys.stdout.reconfigure(encoding='utf-8', errors='replace')
>
> # 입력: common 파일 목록, CHANGELOG 후보, 티켓 키워드, subtask 키워드, grep effective_files
> common = set()
> if os.path.exists('$TMPDIR/submod_common.txt'):
>     common = set(l.strip() for l in open('$TMPDIR/submod_common.txt') if l.strip())
> if not common:
>     print('common 파일 없음 — Changed 판정 생략')
>     exit(0)
>
> # === 티켓별 키워드 맵 구축 (전체 풀이 아닌 티켓별 귀속) ===
>
> # 티켓별 키워드: 제목 + subtask 설명에서 추출
> import re as _re
> ticket_kw_map = {}  # ticket_key → set of keywords
> if os.path.exists('$TMPDIR/all_issues.txt'):
>     for line in open('$TMPDIR/all_issues.txt', encoding='utf-8', errors='replace'):
>         parts = line.strip().split('|')
>         if len(parts) >= 7:
>             key = parts[0]
>             words = _re.findall(r'[A-Z][a-z]{2,}|[A-Z]{3,}', parts[6])
>             ticket_kw_map[key] = set(w for w in words if len(w) >= 3)
>
> # subtask 키워드를 상위 티켓에 귀속
> sk_parent_map = {}
> if os.path.exists('$TMPDIR/all_subtask_keys.txt'):
>     for line in open('$TMPDIR/all_subtask_keys.txt', encoding='utf-8'):
>         sk_parts = line.strip().split(':')
>         if len(sk_parts) >= 3:
>             sk_parent_map[sk_parts[2]] = sk_parts[1]
> if os.path.exists('$TMPDIR/subtask_keywords.tsv'):
>     for line in open('$TMPDIR/subtask_keywords.tsv', encoding='utf-8', errors='replace'):
>         parts = line.strip().split('\t')
>         if len(parts) >= 2:
>             parent = sk_parent_map.get(parts[0])
>             if parent:
>                 words = _re.findall(r'[A-Z][a-z]{2,}|[A-Z]{3,}', ' '.join(parts[1:]))
>                 ticket_kw_map.setdefault(parent, set()).update(w for w in words if len(w) >= 3)
>
> # 1순위: CHANGELOG candidates (CHANGELOG는 슬롯/기능명 → 특정 티켓 귀속 어려움 → 전체 공용)
> changelog_classes = set()
> cl_path = '$TMPDIR/changelog_candidates.tsv'
> if os.path.exists(cl_path):
>     for line in open(cl_path, encoding='utf-8'):
>         parts = line.strip().split('\t')
>         if parts: changelog_classes.add(parts[0])
>
> # 4순위: grep effective_files (티켓별 귀속)
> grep_effective_map = {}  # ticket_key → set of files
> gn_path = '$TMPDIR/grep_normalized.json'
> if os.path.exists(gn_path):
>     try:
>         gn = json.load(open(gn_path, encoding='utf-8'))
>         for k, v in gn.items():
>             grep_effective_map[k] = set(v.get('effective_files', []))
>     except: pass
>
> # === 티켓별 common 파일 매칭 (귀속 보장) ===
> # 결과: {path → {ticket, selector, priority}}
> changed_candidates = {}
>
> for cf in common:
>     basename = cf.split('/')[-1].replace('.cs', '')
>
>     # 1순위: CHANGELOG (티켓 귀속 없음 — 전체 공용, 티켓은 나중에 트리아지에서 결정)
>     if any(cl in basename for cl in changelog_classes):
>         changed_candidates[cf] = {'ticket': '_CHANGELOG_', 'selector': 'changelog', 'priority': 1}
>         continue
>
>     # 2~3순위: 티켓별 키워드 ↔ 파일명 exact 매칭
>     matched_ticket = None
>     for tk, kws in ticket_kw_map.items():
>         if any(kw == basename or kw in basename for kw in kws if len(kw) >= 4):
>             matched_ticket = tk
>             break
>     if matched_ticket:
>         changed_candidates[cf] = {'ticket': matched_ticket, 'selector': 'filename_keyword', 'priority': 2}
>         continue
>
>     # 4순위: 티켓별 grep effective_files ∩ common
>     for tk, efs in grep_effective_map.items():
>         if any(cf.endswith(ef) or ef.endswith(basename + '.cs') for ef in efs):
>             changed_candidates[cf] = {'ticket': tk, 'selector': 'broad_grep', 'priority': 4}
>             break
>
> # 티켓별 최대 3건씩 선정 (전체 상한 없음 — 티켓 귀속이 있으므로 오탐 위험 낮음)
> from collections import defaultdict
> by_ticket = defaultdict(list)
> for path, info in sorted(changed_candidates.items(), key=lambda x: x[1]['priority']):
>     by_ticket[info['ticket']].append((path, info))
>
> read_targets = []
> for tk, items in by_ticket.items():
>     read_targets.extend(items[:3])
>
> with open('$TMPDIR/common_read_targets.tsv', 'w', encoding='utf-8') as f:
>     for path, info in read_targets:
>         f.write(f'{path}\t{info["selector"]}\t{info["priority"]}\t{info["ticket"]}\n')
> print(f'common Changed 후보: {len(changed_candidates)}건 (read 대상: {len(read_targets)}건, 티켓 {len(by_ticket)}개)')
> for path, info in read_targets[:5]:
>     print(f'  [{info["priority"]}순위] {info["ticket"]}: {path} (selector: {info["selector"]})')
> "
> ```
>
> **common Changed 후보 → repob read 확정 → client_changed.txt 반영** (common_read_targets.tsv 생성 직후 실행):
>
> ```bash
> # common 후보 파일을 HEAD/BASE 양쪽에서 repob read → 내용 비교 → Changed 확정
> # TSV 형식: path\tselector\tpriority\tticket (4컬럼)
> if [ -s "$TMPDIR/common_read_targets.tsv" ]; then
>   # 병렬 read: HEAD + BASE
>   while IFS=$'\t' read -r CPATH CSELECTOR CPRIORITY CTICKET; do
>     [ -z "$CPATH" ] && continue
>     CSAFE=$(echo "$CPATH" | tr '/ .' '___')
>     $REPOB remote read client Develop/${RELEASE}/Main "$CPATH" > "$TMPDIR/common_head_${CSAFE}.txt" 2>/dev/null &
>     $REPOB remote read client Develop/${PREV}/Main "$CPATH" > "$TMPDIR/common_base_${CSAFE}.txt" 2>/dev/null &
>   done < "$TMPDIR/common_read_targets.tsv"
>   wait
>
>   # HEAD ≠ BASE → Changed 확정 → client_changed.txt + common_changed.tsv에 반영
>   $PYTHON -c "
> import sys, os
> sys.stdout.reconfigure(encoding='utf-8', errors='replace')
>
> changed = []
> unchanged = []
> for line in open('$TMPDIR/common_read_targets.tsv', encoding='utf-8'):
>     parts = line.strip().split('\t')
>     if len(parts) < 4: continue
>     cpath, selector, priority, ticket = parts[0], parts[1], parts[2], parts[3]
>     csafe = cpath.replace('/', '_').replace(' ', '_').replace('.', '_')
>     head_path = f'$TMPDIR/common_head_{csafe}.txt'
>     base_path = f'$TMPDIR/common_base_{csafe}.txt'
>     head_content = open(head_path, 'rb').read() if os.path.exists(head_path) else b''
>     base_content = open(base_path, 'rb').read() if os.path.exists(base_path) else b''
>     if head_content != base_content and head_content and base_content:
>         changed.append((cpath, selector, ticket))
>         print(f'[Changed] {ticket}: {cpath} (selector: {selector})')
>     else:
>         unchanged.append(cpath)
>         print(f'[Unchanged] {cpath}')
>
> # Changed 확정 파일을 client_changed.txt에 추가
> if changed:
>     with open('$TMPDIR/client_changed.txt', 'a', encoding='utf-8') as f:
>         for path, sel, tk in changed:
>             f.write(f'{path}\n')
>     print(f'→ client_changed.txt에 {len(changed)}건 추가')
>
> # Changed 확정 결과를 common_changed.tsv에 저장 (티켓 귀속 포함 — 트리아지에서 소비)
> # 형식: path\tselector\tticket
> with open('$TMPDIR/common_changed.tsv', 'w', encoding='utf-8') as f:
>     for path, sel, tk in changed:
>         f.write(f'{path}\t{sel}\t{tk}\n')
> print(f'common Changed 확정: {len(changed)}건, Unchanged: {len(unchanged)}건')
> "
> fi
> ```

**compare 실패 시 repob glob fallback**:
compare API가 404(브랜치 없음) 또는 실패한 repo에 대해서만 기존 repob glob 방식으로 실행한다.

```bash
# fallback: compare 결과가 없는 repo만 repob glob 실행
# server repo는 gh API 접근이 안 될 수 있으므로 fallback 빈도가 높다
if [ ! -s "$TMPDIR/compare_server_files.tsv" ]; then
  echo "[SERVER] compare 실패 — repob glob fallback"
  # truncation 방지: 디렉토리별 분할 glob (직렬, Mac Traps 직렬 원칙)
  for DIR in "src/LOGIC" "src/ADMIN" "src/admin_web" "src/database" "src/laboratory"; do
    SAFE=$(echo "$DIR" | tr '/' '_')
    $REPOB remote glob server ${RELEASE}.0/Main "${DIR}/**/*.ts" --pretty > "$TMPDIR/server_head_${SAFE}.json" 2>/dev/null
    $REPOB remote glob server ${PREV}.0/Main   "${DIR}/**/*.ts" --pretty > "$TMPDIR/server_base_${SAFE}.json" 2>/dev/null
  done
  # 분할 결과 합산 후 set 비교
fi
```

> **glob fallback 개선**: 기존 `src/**/*.ts` 단일 패턴은 100건 truncation이 필연이다. 디렉토리별 분할(`src/LOGIC`, `src/ADMIN`, `src/database` 등)로 각 그룹이 100건 미만이 되도록 한다. 분할 결과를 합산해 set 비교한다.

### 2-1-T. compare 기반 타겟 glob/read (변경 디렉토리만)

compare에서 변경된 파일의 **디렉토리만 추출**해, 해당 디렉토리에 다른 관련 파일이 있는지 확인한다. 전체 스캔 대신 타겟 스캔으로 truncation을 방지한다.

```bash
# 변경 파일 디렉토리 추출 → 타겟 glob
$PYTHON -c "
import sys, os
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
dirs = set()
for repo in ['client', 'server']:
    for status_file in [f'$TMPDIR/{repo}_new.txt', f'$TMPDIR/{repo}_changed.txt']:
        if not os.path.exists(status_file): continue
        for line in open(status_file, encoding='utf-8'):
            path = line.strip()
            if '/' in path:
                d = '/'.join(path.split('/')[:-1])
                dirs.add(f'{repo}:{d}')
for d in sorted(dirs):
    print(d)
" > "$TMPDIR/target_dirs.txt"

# 각 디렉토리에 대해 타겟 glob (직렬 — Mac Traps 직렬 원칙 + repob stdin 오염 회피)
# 목적: 변경 파일의 주변 파일 탐색 (같은 디렉토리의 다른 파일이 영향받는지)
# 이 glob은 디렉토리 단위이므로 100건 truncation이 거의 발생하지 않음
TARGET_DIRS_LIST=()
while IFS= read -r LINE || [ -n "$LINE" ]; do
  [ -z "$LINE" ] && continue
  TARGET_DIRS_LIST+=("$LINE")
done < "$TMPDIR/target_dirs.txt"
for ROW in "${TARGET_DIRS_LIST[@]}"; do
  IFS=: read -r REPO DIR <<< "$ROW"
  [ -z "$DIR" ] && continue
  SAFE_DIR=$(echo "$DIR" | tr '/' '_')
  if [ "$REPO" = "client" ]; then
    $REPOB remote glob client Develop/${RELEASE}/Main "${DIR}/*" --pretty > "$TMPDIR/target_glob_cl_${SAFE_DIR}.json" 2>/dev/null
  else
    $REPOB remote glob server ${RELEASE}.0/Main "${DIR}/*" --pretty > "$TMPDIR/target_glob_sv_${SAFE_DIR}.json" 2>/dev/null
  fi
done
```

> **핵심 개선**: 기존에는 `Assets/**/*.cs` 전체를 HEAD/BASE 양쪽에서 glob해 수만 개 파일을 비교했다. 이제는 compare로 변경된 수십 개 파일을 먼저 확정하고, 해당 디렉토리만 타겟 glob한다. truncation 문제가 사실상 해소된다.

### 2-1-A. CHANGELOG 자동 탐지

compare 결과의 파일 목록 + 서브모듈 전개 후 HEAD 파일 목록 양쪽에서 CHANGELOG 계열 파일을 탐지한다.

```bash
# compare 결과 + 서브모듈 HEAD 파일에서 CHANGELOG 계열 파일 필터링
$PYTHON -c "
import sys, os, glob as g
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
import re, json

found = []

# 1차: compare 결과에서 탐지
for repo in ['client', 'server']:
    path = f'$TMPDIR/compare_{repo}_files.tsv'
    if not os.path.exists(path): continue
    for line in open(path, encoding='utf-8', errors='replace'):
        parts = line.strip().split('\t')
        if len(parts) < 2: continue
        fname = parts[1]
        if re.search(r'CHANGELOG|RELEASE_NOTE|HISTORY', fname, re.I):
            if '3rd Party' not in fname and not fname.endswith('.meta'):
                found.append(f'{repo}\t{fname}')
                print(f'[compare] {repo}: {fname}')

# 2차: 서브모듈 전개 후 HEAD 파일 목록에서 탐지
for f in sorted(g.glob('$TMPDIR/submod_split_head_*.json') + g.glob('$TMPDIR/submod_resplit_head_*.json')):
    try:
        d = json.load(open(f, encoding='utf-8', errors='replace'))
        items = d if isinstance(d, list) else d.get('files', d.get('matches', d.get('results', [])))
    except: continue
    for item in items:
        fname = str(item)
        if re.search(r'CHANGELOG|RELEASE_NOTE|HISTORY', fname, re.I):
            if '3rd Party' not in fname and not fname.endswith('.meta'):
                found.append(f'client\t{fname}')
                print(f'[submod HEAD] client: {fname}')

# 중복 제거 후 저장
unique = sorted(set(found))
with open('$TMPDIR/changelog_files.txt', 'w', encoding='utf-8') as fp:
    fp.write('\n'.join(unique) + '\n' if unique else '')
print(f'CHANGELOG 파일: {len(unique)}건')
"
```

CHANGELOG 파일이 있으면 repob read로 내용 수집 → `Added / Changed / Removed` 항목 추출.
없으면 "CHANGELOG 없음"으로 기록 (에러 아님).

**CHANGELOG → 키워드 풀 연결**: CHANGELOG에 명시된 클래스명·기능명을 `$TMPDIR/changelog_candidates.tsv`에 기록하고 2-3 배치 grep 키워드 풀에 추가한다. CHANGELOG Changed/Removed 항목의 클래스명은 common 파일 Changed 판정 1순위 후보로도 등록된다.

**CHANGELOG Changed/Removed 항목 → evidence_files 등록 의무화**:
CHANGELOG의 Changed/Removed 항목에 명시된 클래스를 grep hit에서 찾아 read한 경우, 해당 파일을 **반드시** triage.json `evidence_files`에 개별 등록한다 (`source: "read", selector: "changelog"`).

### 2-1-B. 변경 파일 요약 (compare 기반 — glob set 비교 대체)

compare API가 이미 New/Changed/Removed를 확정했으므로, 기존 glob set 비교는 **불필요**하다.

```bash
# compare 결과 요약 — 코드 파일만 필터링 (.cs, .ts, .json, .asset, .jslib, .prefab)
$PYTHON -c "
import sys, os, re
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
CODE_EXT = re.compile(r'\.(cs|ts|json|asset|jslib|prefab|tsx|js)$')
for repo in ['client', 'server']:
    for status in ['new', 'changed', 'removed']:
        path = f'$TMPDIR/{repo}_{status}.txt'
        if not os.path.exists(path): continue
        files = [l.strip() for l in open(path) if l.strip()]
        code_files = [f for f in files if CODE_EXT.search(f)]
        asset_files = [f for f in files if not CODE_EXT.search(f)]
        if code_files:
            print(f'[{repo}] {status.upper()} 코드 파일 ({len(code_files)}건):')
            for f in code_files[:20]:
                print(f'  {f}')
            if len(code_files) > 20:
                print(f'  ... +{len(code_files)-20}건')
        if asset_files:
            print(f'[{repo}] {status.upper()} 기타 파일 ({len(asset_files)}건)')
"
```

> **glob set 비교와의 핵심 차이**: glob은 HEAD/BASE 전체 파일 수만 개를 비교해 New/Removed를 추론했고 truncation으로 누락이 발생했다. compare는 git이 계산한 정확한 diff이므로 추론·누락이 없다. **Changed도 즉시 확정**되어 2-2의 read 비교 필요성이 대폭 줄어든다.

> **open PR = 예정 변경 (Evidence 확정 아님)**:
> - open PR의 changed files는 `$TMPDIR/pr_files_*.json`에 저장되지만, **Evidence 확정 소스로 사용하지 않는다**.
> - triage.json `evidence_files`에 등록하지 않으며, 3-D 테이블 상태 컬럼에 반영하지 않는다.
> - 용도: "merge 시 예상 변경" 사전 파악 → STEP 5 커버리지의 `추가 조사 권고`에 "open PR {N}건 미반영 — merge 후 재분석 필요" 기재.
> - 3-A 테스트 방법에서 open PR body의 테스트 가이드는 참고 정보로 활용하되, `Evidence: (open PR — 예정 변경)`으로 별도 표기한다.

### 2-2. 변경 파일 상세 분석 (compare 기반 — read 비교 최소화)

**compare API가 Changed를 이미 확정**했으므로, 기존처럼 모든 common 파일을 HEAD+BASE read로 비교할 필요가 없다.

**repob read가 필요한 경우** (선택적):
1. **커밋 diff에서 patch가 잘린 큰 파일** — STEP 1.5-C에서 patch가 2000자로 잘렸으면 repob read로 전체 확인
2. **변경 의도 파악이 필요한 핵심 파일** — Bug 픽스 파일, 기능 추가 파일 등
3. **서브모듈 포인터 변경** — compare에서 `+1 -1`만 보이는 서브모듈은 내부 변경을 repob로 확인

```bash
# 핵심 변경 파일만 선택적 read (커밋 diff의 patch가 부족한 경우)
# 예: Bug 픽스 파일의 전체 컨텍스트 확인
$REPOB remote read client Develop/${RELEASE}/Main "[변경 파일 경로]" --pretty > $TMPDIR/read_head_${CVS_KEY}_cl_1.txt &
$REPOB remote read client Develop/${PREV}/Main   "[변경 파일 경로]" --pretty > $TMPDIR/read_base_${CVS_KEY}_cl_1.txt &
wait
```

**상태 분류** (compare 결과 기반):

| 상태 | 정의 | 소스 |
|------|------|------|
| **Changed** | compare `modified` → 내용 변경 확정 | compare API |
| **New** | compare `added` → 신규 추가 확정 | compare API |
| **Removed** | compare `removed` → 삭제 확정 | compare API |
| **Renamed** | compare `renamed` → 경로 변경 | compare API |
| **미확인** | compare 실패 repo의 파일 | glob fallback 필요 |

> **기존 방식과의 차이**: 기존에는 glob set 비교로 New/Removed만 확정하고, Changed는 read 2번으로 확인해야 했다. 이제는 compare가 Changed까지 즉시 확정하므로, read는 **상세 분석이 필요한 파일만** 선택적으로 실행한다.

### 2-3. 배치 grep (트리아지 전 실행)

트리아지(2-4)에서 grep hit 여부를 Deep 승격 조건으로 사용하므로 **반드시 2-4 이전에 실행**한다.
STEP 3-A는 이 결과를 재사용하므로 재호출하지 않는다.

> **client와 server의 grep 전략이 근본적으로 다르다**:
> - **client**: compare/commit 데이터가 있으므로 **변경 파일 경로·심볼 기반 타겟 grep** → truncation 거의 발생하지 않음
> - **server**: gh API 접근 불가 → compare/commit 데이터 없음 → **키워드 세분화 + --include 경로 필터링** 방식의 배치 grep

#### 2-3-CL. Client grep — compare/commit 기반 타겟 grep

client는 STEP 1.5에서 확보한 compare/commit 데이터를 활용해 **이미 알려진 변경 파일·심볼을 기반으로 타겟 grep**한다. 전체 키워드 배치 grep 대신, 좁은 범위에서 정밀한 검색을 수행한다.

**전략**: `compare/commit으로 좁히고 → path/symbol 기반 grep → 필요할 때만 read`

**1단계: 커밋 매핑된 티켓 — grep 불필요 (Evidence 즉시 확정)**
- `$TMPDIR/ticket_commit_files.tsv`에 있는 티켓은 **커밋이 직접 변경한 파일**이 이미 확정됨
- 해당 파일은 grep 없이 Evidence 확정 (`source: "commit"`)
- 추가 grep은 **간접 영향 탐지**에만 사용 (해당 파일의 클래스명·함수명으로 호출처를 찾는 용도)

**2단계: 커밋 매핑 없는 티켓 — compare 변경 파일 기반 grep**
- `$TMPDIR/compare_client_files.tsv`의 변경 파일명에서 티켓 키워드와 매칭되는 파일을 먼저 찾는다
- 매칭된 파일의 클래스명·디렉토리명을 grep 키워드로 사용 → **좁은 범위 타겟 grep**
- 매칭 없으면 티켓 고유 키워드(약어, 클래스명)로 1회 grep

**3단계: 간접 영향 grep (커밋 매핑 티켓 포함)**
- 1~2단계에서 확정된 변경 파일의 **공개 심볼**(클래스명, 함수명)을 추출
- 해당 심볼로 grep → 호출처·참조처를 찾아 간접 영향 범위를 파악
- 이 grep은 `--include` 옵션으로 관련 디렉토리만 타겟팅

```bash
# === Client grep: compare/commit 기반 타겟 전략 ===

# 1단계: 커밋 매핑 티켓은 파일 이미 확정 — 간접 영향용 심볼 추출만
$PYTHON -c "
import sys, os, json, re, glob as g
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

# ticket_commit_files에서 커밋 매핑 티켓의 변경 파일 수집
commit_files = {}  # {ticket: [{file, status}]}
tcf = '$TMPDIR/ticket_commit_files.tsv'
if os.path.exists(tcf):
    for line in open(tcf, encoding='utf-8', errors='replace'):
        parts = line.strip().split('\t')
        if len(parts) >= 4 and parts[1] == 'client':
            commit_files.setdefault(parts[0], []).append({'file': parts[2], 'status': parts[3]})

# commit_detail에서 함수명 추출 (@@헤더)
symbols = {}  # {ticket: [symbol_names]}
for f in g.glob('$TMPDIR/commit_detail_client_*.json'):
    try:
        d = json.load(open(f, encoding='utf-8', errors='replace'))
        sha = d.get('sha', '')
        # 이 sha가 어떤 티켓에 매핑되는지 찾기
        map_path = '$TMPDIR/commit_ticket_map.tsv'
        if not os.path.exists(map_path): continue
        for mline in open(map_path, encoding='utf-8', errors='replace'):
            mp = mline.strip().split('\t')
            if len(mp) >= 3 and mp[1] == 'client' and mp[2] == sha:
                tk = mp[0]
                for fl in d.get('files', []):
                    patch = fl.get('patch', '')
                    # @@ ... @@ 함수명 추출
                    for m in re.finditer(r'@@[^@]+@@\s*(?:public\s+)?(?:static\s+)?(?:\w+\s+)*(\w{4,})', patch):
                        symbols.setdefault(tk, []).append(m.group(1))
                    # 파일명에서 클래스명 추출 (확장자 제거)
                    fname = fl.get('name', '').split('/')[-1]
                    cname = re.sub(r'\.\w+$', '', fname)
                    if len(cname) >= 4 and cname[0].isupper():
                        symbols.setdefault(tk, []).append(cname)
    except: continue

# 출력: 간접 영향 grep 키워드 (커밋 매핑 티켓별)
for tk in sorted(commit_files.keys()):
    syms = list(set(symbols.get(tk, [])))[:10]  # 티켓당 최대 10개 심볼
    files = commit_files[tk]
    print(f'COMMIT_MAPPED\t{tk}\t{len(files)} files\t{\"|\".join(syms)}')

# 2단계: 커밋 매핑 없는 티켓 — compare 파일명 매칭
compare_files = []
cf_path = '$TMPDIR/compare_client_files.tsv'
if os.path.exists(cf_path):
    for line in open(cf_path, encoding='utf-8', errors='replace'):
        parts = line.strip().split('\t')
        if len(parts) >= 2:
            compare_files.append(parts[1])

# 티켓 키워드 목록은 all_issues.txt에서 로드
all_tickets = {}
ai_path = '$TMPDIR/all_issues.txt'
if os.path.exists(ai_path):
    for line in open(ai_path, encoding='utf-8', errors='replace'):
        parts = line.strip().split('|')
        if len(parts) >= 7:
            all_tickets[parts[0]] = parts[6]  # summary

for tk, summary in all_tickets.items():
    if tk in commit_files: continue  # 커밋 매핑 있으면 건너뜀
    # summary에서 키워드 추출 (약어, PascalCase)
    keywords = re.findall(r'[A-Z]{2,}|[A-Z][a-z]+(?:[A-Z][a-z]+)+', summary)
    keywords = [k for k in keywords if len(k) >= 3 and k not in ('Bug', 'Contents', 'API')]
    # compare 파일명에서 키워드 매칭
    matched_files = []
    for kw in keywords:
        for cf in compare_files:
            if kw.lower() in cf.lower():
                matched_files.append(cf)
    if matched_files:
        # 매칭된 파일의 디렉토리/클래스명으로 좁은 grep 키워드 생성
        grep_kws = []
        for mf in matched_files[:5]:
            cname = re.sub(r'\.\w+$', '', mf.split('/')[-1])
            if len(cname) >= 4: grep_kws.append(cname)
        print(f'COMPARE_MATCH\t{tk}\t{len(matched_files)} files\t{\"|\".join(set(grep_kws))}')
    else:
        # 매칭 없으면 티켓 고유 키워드로 일반 grep
        grep_kws = [k for k in keywords if len(k) >= 3][:5]
        print(f'NO_MATCH\t{tk}\t0 files\t{\"|\".join(grep_kws)}')
" > "$TMPDIR/client_grep_plan.tsv"

# 3단계: 실행 — 계획에 따라 타겟 grep (직렬)
# COMMIT_MAPPED 티켓: 간접 영향용 심볼 grep (--include로 관련 디렉토리 타겟)
# COMPARE_MATCH 티켓: 매칭된 파일 클래스명 grep
# NO_MATCH 티켓: 티켓 고유 키워드 grep (기존 방식, 단 키워드 수 제한)
# 직렬 실행 (Mac Traps 직렬 원칙 + repob stdin 오염 회피)
GREP_PLAN_LIST=()
while IFS= read -r LINE || [ -n "$LINE" ]; do
  [ -z "$LINE" ] && continue
  GREP_PLAN_LIST+=("$LINE")
done < "$TMPDIR/client_grep_plan.tsv"
for ROW in "${GREP_PLAN_LIST[@]}"; do
  IFS=$'\t' read -r TYPE TK INFO KEYWORDS <<< "$ROW"
  [ -z "$KEYWORDS" ] && continue
  SAFE_TK=$(echo "$TK" | tr '-' '_')
  if [ "$TYPE" = "COMMIT_MAPPED" ]; then
    # 간접 영향: 해당 심볼이 다른 파일에서 참조되는지 확인
    $REPOB remote grep client Develop/${RELEASE}/Main "$KEYWORDS" --pretty \
      > "$TMPDIR/grep_cl_indirect_${SAFE_TK}.txt" 2>/dev/null
  else
    # 직접 탐색: 티켓과 관련된 파일 찾기
    $REPOB remote grep client Develop/${RELEASE}/Main "$KEYWORDS" --pretty \
      > "$TMPDIR/grep_cl_${SAFE_TK}.txt" 2>/dev/null
  fi
done
```

> **핵심 개선**: 기존에는 모든 티켓 키워드를 하나의 배치 grep에 넣어 100건 truncation이 필연이었다. 이제는 compare/commit에서 **이미 알려진 변경 파일·심볼**을 기반으로 타겟 grep하므로, 각 grep이 좁은 범위에서 실행되어 truncation이 거의 발생하지 않는다. 특히 커밋 매핑된 티켓은 grep 없이 Evidence가 즉시 확정되어 grep 호출 자체가 줄어든다.

**client grep 정규화 파이프라인** (결과 파싱 시 적용 — truncation 판정 + 범용 파일 제거 + 재시도):

모든 티켓의 grep 결과를 Python 1회로 일괄 정규화한다. 결과를 `$TMPDIR/grep_normalized.json`에 저장해 이후 트리아지(2-4)와 STEP 3에서 참조한다.

**범용 파일 패턴** (client):
`ClientAPI/`, `ClientModels`, `ClientAPI2Blackboard`, `BagelCodeClientModelsExtend`, `BagelCodeClientAPI2Blackboard`, `BagelCodeClientAPI.cs`

```bash
# client grep 정규화 — truncation 판정 + 범용 파일 제거 + effective 산출
$PYTHON -c "
import sys, os, json, glob as g
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

GENERIC = ['ClientAPI/', 'ClientModels', 'ClientAPI2Blackboard',
           'BagelCodeClientModelsExtend', 'BagelCodeClientAPI2Blackboard',
           'BagelCodeClientAPI.cs']

normalized = {}
for f in sorted(g.glob('$TMPDIR/grep_cl_*.txt')):
    name = os.path.basename(f)
    # 티켓 키 추출: grep_cl_CVS_13255.txt → CVS-13255, grep_cl_indirect_CVS_13353.txt → skip
    if 'indirect' in name:
        continue
    tk = name.replace('grep_cl_', '').replace('.txt', '').replace('_retry', '').replace('_', '-', 1)
    # retry 파일이 있으면 더 큰 쪽을 사용
    try:
        d = json.load(open(f, encoding='utf-8', errors='replace'))
    except:
        continue
    raw_count = d.get('count', 0)
    matches = d.get('matches', [])
    truncated = raw_count >= 100

    # 범용 파일 제거
    effective = []
    generic_count = 0
    for m in matches:
        fpath = m.get('file', '')
        if any(gp in fpath for gp in GENERIC):
            generic_count += 1
        else:
            effective.append(fpath)
    # 중복 파일 제거
    effective = list(dict.fromkeys(effective))

    # 기존 결과보다 effective가 많으면 갱신 (retry 결과 반영)
    prev = normalized.get(tk)
    if prev and prev['effective_count'] >= len(effective):
        continue

    normalized[tk] = {
        'raw_count': raw_count,
        'truncated': truncated,
        'effective_count': len(effective),
        'effective_files': effective[:10],  # 상위 10건 보존
        'generic_filtered': generic_count
    }
    status = 'TRUNCATED' if truncated else 'OK'
    print(f'[{tk}] raw={raw_count} effective={len(effective)} generic={generic_count} ({status})')

with open('$TMPDIR/grep_normalized.json', 'w', encoding='utf-8') as fp:
    json.dump(normalized, fp, ensure_ascii=False, indent=2)
print(f'정규화 완료: {len(normalized)}건')
"
```

**truncation 자동 재시도** (effective_count==0이고 truncated인 티켓):
정규화 후 effective_count가 0인데 truncated인 티켓은 **범용 파일을 제외한 키워드 세분화 재시도**를 1회 실행한다. 재시도 키워드는 하위 작업 설명에서 추출한 기술 키워드(2-3 키워드 풀)를 활용한다. 재시도 결과도 `grep_normalized.json`에 반영한다.

```bash
# truncated + effective=0 티켓 재시도
$PYTHON -c "
import sys, json, os
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
norm = json.load(open('$TMPDIR/grep_normalized.json', encoding='utf-8'))
retry_needed = []
for tk, v in norm.items():
    if v['truncated'] and v['effective_count'] == 0:
        retry_needed.append(tk)
        print(f'[RETRY NEEDED] {tk}: raw={v[\"raw_count\"]} effective=0 generic={v[\"generic_filtered\"]}')
if not retry_needed:
    print('재시도 필요 없음')
with open('$TMPDIR/grep_retry_needed.txt', 'w') as fp:
    fp.write('\n'.join(retry_needed))
"

# 재시도 대상이 있으면 하위 작업 키워드로 세분화 grep 실행
if [ -s "$TMPDIR/grep_retry_needed.txt" ]; then
  $PYTHON -c "
import sys, json, os, re
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

# 하위 작업 키워드 맵 로드 (상위키 → [키워드들])
subtask_kw = {}
sk_path = '$TMPDIR/subtask_keywords.tsv'
sk_map_path = '$TMPDIR/all_subtask_keys.txt'
if os.path.exists(sk_path) and os.path.exists(sk_map_path):
    parent_map = {}
    for line in open(sk_map_path, encoding='utf-8'):
        parts = line.strip().split(':')
        if len(parts) >= 3:
            parent_map[parts[2]] = parts[1]
    for line in open(sk_path, encoding='utf-8', errors='replace'):
        parts = line.strip().split('\t')
        if len(parts) >= 2:
            parent = parent_map.get(parts[0])
            if parent:
                # 기술 키워드 추출: 3글자 이상 영문 단어
                words = re.findall(r'[A-Z][a-z]{2,}|[A-Z]{3,}', ' '.join(parts[1:]))
                subtask_kw.setdefault(parent, []).extend(w for w in words if len(w) >= 3)

# 이슈 제목 키워드 맵
issue_kw = {}
if os.path.exists('$TMPDIR/all_issues.txt'):
    for line in open('$TMPDIR/all_issues.txt', encoding='utf-8', errors='replace'):
        parts = line.strip().split('|')
        if len(parts) >= 7:
            key = parts[0]
            words = re.findall(r'[A-Z][a-z]{2,}|[A-Z]{3,}', parts[6])
            issue_kw[key] = [w for w in words if len(w) >= 3]

cmds = []
for line in open('$TMPDIR/grep_retry_needed.txt', encoding='utf-8'):
    tk = line.strip()
    if not tk: continue
    # 세분화 키워드: subtask > issue title
    keywords = subtask_kw.get(tk, []) or issue_kw.get(tk, [])
    if not keywords:
        print(f'[SKIP] {tk}: 세분화 키워드 없음')
        continue
    # 상위 3개 키워드 선택 (중복 제거)
    unique_kw = list(dict.fromkeys(keywords))[:3]
    safe_tk = tk.replace('-', '_')
    for kw in unique_kw:
        cmds.append(f'{tk}\t{kw}\t{safe_tk}')
    print(f'[RETRY] {tk}: keywords={unique_kw}')

with open('$TMPDIR/_grep_retry_cmds.txt', 'w', encoding='utf-8') as f:
    f.write('\n'.join(cmds))
print(f'재시도 grep 명령: {len(cmds)}건')
"

  # 세분화 키워드별 grep 직렬 실행 (Mac Traps 직렬 원칙 + repob stdin 오염 회피)
  GREP_RETRY_LIST=()
  while IFS= read -r LINE || [ -n "$LINE" ]; do
    [ -z "$LINE" ] && continue
    GREP_RETRY_LIST+=("$LINE")
  done < "$TMPDIR/_grep_retry_cmds.txt"
  for ROW in "${GREP_RETRY_LIST[@]}"; do
    IFS=$'\t' read -r TK KW SAFE_TK <<< "$ROW"
    [ -z "$TK" ] && continue
    $REPOB remote grep client Develop/${RELEASE}/Main "$KW" \
      --include="*.cs" --exclude="ClientAPI/" --exclude="ClientModels/" \
      --pretty > "$TMPDIR/grep_cl_${SAFE_TK}_retry2_${KW}.txt" 2>/dev/null
  done

  # 재시도 결과를 grep_normalized.json에 반영
  $PYTHON -c "
import sys, json, os, glob as g
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

GENERIC = ['ClientAPI/', 'ClientModels', 'ClientAPI2Blackboard',
           'BagelCodeClientModelsExtend', 'BagelCodeClientAPI2Blackboard',
           'BagelCodeClientAPI.cs']

norm = json.load(open('$TMPDIR/grep_normalized.json', encoding='utf-8'))
updated = 0

for tk_line in open('$TMPDIR/grep_retry_needed.txt', encoding='utf-8'):
    tk = tk_line.strip()
    if not tk: continue
    safe_tk = tk.replace('-', '_')
    # 모든 retry2 결과 합산
    all_files = set()
    for f in g.glob(f'$TMPDIR/grep_cl_{safe_tk}_retry2_*.txt'):
        try:
            d = json.load(open(f, encoding='utf-8', errors='replace'))
            for m in d.get('matches', []):
                fp = m.get('file', '')
                if fp and not any(gen in fp for gen in GENERIC):
                    all_files.add(fp)
        except: pass

    if all_files:
        norm[tk]['effective_count'] = len(all_files)
        norm[tk]['effective_files'] = sorted(all_files)[:10]
        norm[tk]['retry'] = True
        updated += 1
        print(f'[RETRY OK] {tk}: effective={len(all_files)}')
    else:
        norm[tk]['retry'] = True
        print(f'[RETRY 0] {tk}: 재시도 후에도 0 hits')

with open('$TMPDIR/grep_normalized.json', 'w', encoding='utf-8') as fp:
    json.dump(norm, fp, ensure_ascii=False, indent=2)
print(f'grep_normalized.json 갱신: {updated}건')
"
fi
```

> **핵심 원칙**: `grep_normalized.json`의 `effective_count`가 트리아지(2-4)의 grep 기반 Deep 승격 판정에 사용된다. `raw_count`가 아닌 `effective_count`만 참조한다. `effective_count == 0`이면 grep 경로로는 Deep 승격하지 않는다.

#### 2-3-SV. Server grep — 키워드 세분화 + --include 경로 필터링

server는 gh API 접근이 없어 compare/commit 데이터가 없다. 기존 배치 grep 방식을 유지하되, **키워드 세분화**와 **--include 경로 필터링**으로 truncation을 방지한다.

**서버 키워드 풀 구성 원칙** (client와 공통 부분):
- 상위 티켓 제목·설명에서 추출한 기술 키워드
- **1-3-B 하위 작업 설명의 기술 키워드** (SDK명, 클래스명, API명, 기능명)
- **CHANGELOG/릴리스노트에서 추출한 키워드** (2-1-A)
- **약어·클래스명 필수 포함** (MIF, EA, IAM 등)
- **키워드 중복 제거**
- **제네릭 키워드 분리** (`config`, `flag` 등은 별도 배치)
- **설정값 패턴 분리** (`defaultValue|isEnabled|FeatureFlag|RemoteConfig`는 HAS_CONFIG=true일 때만)

**서버 전용 규칙 — 키워드 세분화 + --include**:
1. **키워드를 2~3개씩 묶어 분할 실행**: 전체 키워드를 한 번에 넣지 않고, 기능 도메인별 2~3개 키워드씩 분할한다. 각 grep이 100건 미만이 되도록 한다.
2. **--include로 경로 필터링**: 서버 repo의 디렉토리 구조(`src/LOGIC`, `src/ADMIN`, `src/admin_web`, `src/database`, `src/laboratory`)를 활용해, 키워드 그룹에 맞는 디렉토리만 대상으로 한다.
3. **그룹별 직렬 실행**: 각 키워드 그룹을 직렬로 실행한다 (Mac Traps 직렬 원칙).

```bash
# === Server grep: 키워드 세분화 + --include 경로 필터링 ===
# 직렬 실행 (Mac Traps 직렬 원칙, moco/.claude/CLAUDE.md)

# 그룹 1: 결제/코인 관련 (2~3 키워드 + 관련 디렉토리)
$REPOB remote grep server ${RELEASE}.0/Main \
  "Payment|Xsolla|CoinSettlement" \
  --include "src/LOGIC/**" --pretty > $TMPDIR/grep_sv_payment.txt 2>/dev/null

# 그룹 2: 미션/보상 관련
$REPOB remote grep server ${RELEASE}.0/Main \
  "Mission|FreeGame|Reward" \
  --include "src/LOGIC/**" --pretty > $TMPDIR/grep_sv_mission.txt 2>/dev/null

# 그룹 3: 채팅/소셜 관련
$REPOB remote grep server ${RELEASE}.0/Main \
  "ChatMessenger|ChatMute|mute" \
  --include "src/LOGIC/**" --include "src/ADMIN/**" --pretty > $TMPDIR/grep_sv_chat.txt 2>/dev/null

# 그룹 4: 이벤트/태그 관련
$REPOB remote grep server ${RELEASE}.0/Main \
  "MIFPotTrigger|EventTag|TimeBonus" \
  --include "src/LOGIC/**" --pretty > $TMPDIR/grep_sv_events.txt 2>/dev/null

# 그룹 5: Admin/DB 관련 (필요 시)
$REPOB remote grep server ${RELEASE}.0/Main \
  "admin_chat|route_purchase|logic_reward" \
  --include "src/ADMIN/**" --include "src/admin_web/**" --pretty > $TMPDIR/grep_sv_admin.txt 2>/dev/null

# 설정값 배치 (HAS_CONFIG=true일 때만)
if [ "$HAS_CONFIG" = "true" ]; then
  $REPOB remote grep server ${RELEASE}.0/Main \
    "defaultValue|initialValue|isEnabled|FeatureFlag|RemoteConfig" \
    --include "src/LOGIC/**" --pretty > $TMPDIR/grep_sv_config.txt 2>/dev/null
fi
```

> **핵심 개선**: 기존에는 서버도 전체 키워드 1회 배치 grep이었고 항상 100건에서 잘렸다. 이제 2~3개 키워드씩 분할 + `--include`로 디렉토리 한정 → 각 그룹이 100건 미만으로 유지되어 truncation이 해소된다.

**서버 범용 파일 패턴**: `types/interface`, `route_admin`, `route_main`, `games.ts`, `test_passive_event` — 결과 파싱 시 우선순위를 낮춘다.

**서버 grep truncation 처리** (100건 도달 시):
- 분할 grep 결과가 100건에 도달한 그룹: 해당 그룹의 키워드를 **1개씩 개별 grep**으로 추가 분할한다.
- 개별 grep에서도 100건이면 **--include를 더 좁은 디렉토리로 변경** (예: `src/LOGIC/**` → `src/LOGIC/logic_*.ts`).
- 2단계 분할까지만 시도하고, 여전히 truncated이면 "grep 기반 전환" (Evidence에 Sampled 표시).

#### 2-3 공통: grep 0 hits 처리

**grep 0 hits 처리** (이 규칙이 정본 — 2-3-B B규칙·3-A·금지사항에서 참조):
- client + server grep 완료 후 **0 hits인 티켓을 일괄 식별**한다.
- **조건부 2차 grep**: 0 hits 티켓 중 아래 조건을 **모두** 충족하는 티켓에 대해서만 2차 grep을 실행한다:
  1. 티켓 상태가 `Need Review` / `완료` / `Done` / `Closed` (개발 완료 사인 — 코드가 존재할 가능성이 높음)
  2. 하위 작업 설명에서 배치에 포함되지 않은 새 키워드를 추출할 수 있음
- 조건 미충족 티켓 (TODO-Dev, 진행 중 등)은 바로 `0 hits 확정`으로 처리한다. 아직 코드가 커밋되지 않았을 가능성이 높으므로 추가 grep은 낭비다.
- **2차 grep 실행** (조건 충족 티켓만 — 해당 티켓들의 새 키워드를 모아 실행):
  - client: compare 파일명에서 새로운 매칭 후보를 찾거나, 하위 작업 키워드로 타겟 grep
  - server: 하위 작업 키워드를 2~3개씩 묶어 --include와 함께 추가 grep
  - 그래도 0 hits이면 "코드 위치 미확인"으로 확정 — 단, **하위 작업 설명 기반 테스트 포인트**는 체크리스트에 포함
- 이 규칙을 거친 티켓은 `0 hits 확정` 상태다. 이후 단계(2-3-B, 3-A)에서 동일 키워드로 재시도하지 않는다.

**별도 repo 가능성 탐지** (0 hits 확정 후 적용):
아래 **4가지 조건을 모두** 충족하면, 해당 티켓은 **별도 repo 또는 별도 빌드** 가능성이 높다. Light로 강등하지 않고 Deep을 유지하되, "개발팀에 코드 위치 확인 필요"를 권고한다.
1. 티켓 제목·설명에 **외부 플랫폼 키워드** 포함 (`WebGL|Xsolla|Facebook|CVS\.com|브라우저|web|iOS|Android|Steam`)
2. **하위 작업 설명에 구현 키워드** 있음 (SDK명, API명, 클래스명 등 코드 수준 키워드 1개 이상)
3. **client grep 0 hits** 확정 (배치 grep + 재시도 포함)
4. 티켓 상태가 **Need Review / 완료 / Done / Closed** (개발 완료 사인)

이 패턴은 CVS.com(웹), 별도 플랫폼 빌드, 외부 SDK 연동 등 메인 client/server repo에 코드가 없는 작업에 해당한다.
처리: Deep 유지 → 3-A에서 "코드 위치 미확인 (별도 repo 가능성)" 표시 + 하위 작업 설명 기반 테스트 포인트 작성 + "추가 조사 권고"에 "개발팀에 실제 코드 위치 확인 필요" 추가.

**client grep truncation 처리** (커밋 매핑 없는 타겟 grep에서 100건 도달 시):
- 타겟 grep은 좁은 범위이므로 truncation 빈도가 낮지만, 범용 파일 대량 hit 키워드(EarlyAccess, Payment 등)는 여전히 가능.
- **재시도**: 해당 키워드를 범용 파일 패턴 제외 후 Python 필터링으로 실제 의미 있는 hit만 추출.
- **강제 실행 조건**: grep 결과가 100건이고 filtered_files=0이면 반드시 재시도.

결과를 티켓별로 분류해두고 2-4 트리아지와 STEP 3-A 양쪽에 활용한다.

### 2-3-B. grep 결과 기반 파일 read 확정 [A+B+C]

배치 grep 완료 직후, 트리아지(2-4) 이전에 아래 3개 규칙을 순서대로 적용한다.

---

**A. Deep 후보 — compare 확정 + grep hit 파일 선택적 read**

compare API가 파일별 Changed/New/Removed 상태를 이미 확정했으므로, **모든 grep hit 파일을 HEAD+BASE read할 필요가 없다**. compare 결과를 1차 소스로 사용하고, compare에 없는 파일만 선택적으로 read한다.

**A규칙 판정 흐름** (grep hit 파일마다 순서대로 적용):
1. **compare 확인**: grep hit 파일이 `$TMPDIR/compare_client_files.tsv` (또는 `compare_server_files.tsv`)에 있는가?
   - `modified` → **Changed 즉시 확정** (read 불필요)
   - `added` → **New 즉시 확정** (read 불필요)
   - `removed` → **Removed 즉시 확정** (read 불필요)
   - `renamed` → **Renamed 즉시 확정** (read 불필요)
2. **compare에 없음**: grep이 찾았지만 compare에 없는 파일 → **간접 영향 가능성**. 이 경우만 HEAD+BASE read로 Changed/Unchanged를 확인한다.
3. **compare 실패 repo**: `compare_*_files.tsv`가 없는 repo → 기존 방식대로 HEAD+BASE read

**범용 파일 패널티**: 아래 경로 패턴에 해당하는 파일은 **범용 파일**로 간주한다. 대부분의 티켓에서 grep hit가 발생하지만 실제 변경과 무관한 경우가 많아, read 대상 선택 시 우선순위를 낮춘다.

| repo | 범용 파일 경로 패턴 |
|------|---------------------|
| client | `ClientAPI/`, `ClientModels`, `ClientAPI2Blackboard`, `BagelCodeClientModelsExtend`, `BagelCodeClientAPI2Blackboard`, `BagelCodeClientAPI.cs` |
| server | `types/interface`, `route_admin`, `route_main`, `games.ts`, `test_passive_event` |

**read 대상 선택 우선순위** (compare에 없는 파일 중 상위 1~2개 선택 시):
1. **직매칭**: 티켓 키워드가 파일명에 직접 포함 (예: `EarlyAccess` 키워드 → `ModuleEarlyAccess/index.tsx`)
2. **경로 다양성**: 동일 디렉토리 파일이 중복되면, 다른 디렉토리의 파일을 우선 선택
3. **범용 파일 fallback**: 위 1~2로 선택할 파일이 없을 때만 범용 파일을 read 대상에 포함

**read 후보 선택 로그**: 선택 결과를 `$TMPDIR/read_selection.log`에 기록한다 (false-Light 튜닝 근거).

```
# read_selection.log 형식 (티켓당 1블록)
[CVS-XXXXX] A규칙 read 후보 선택
  grep hits: file_a.cs(5), file_b.cs(3), BagelCodeClientModelsExtend.cs(12)
  compare 확정: file_a.cs → modified (Changed 즉시 확정, read 스킵)
  compare 미포함: file_b.cs → read 대상
  범용 패널티: BagelCodeClientModelsExtend.cs → fallback으로 강등
  최종: file_a.cs (compare Changed), file_b.cs (read 필요 → HEAD+BASE read)
```

```bash
# Deep 후보 티켓별 — compare 확인 + 선택적 read
# 1단계: grep hit 파일을 compare 결과와 대조

$PYTHON -c "
import sys, os, json
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

# compare 결과 로드
compare_status = {}  # {repo: {filepath: status}}
for repo in ['client', 'server']:
    tsv = f'$TMPDIR/compare_{repo}_files.tsv'
    compare_status[repo] = {}
    if os.path.exists(tsv):
        for line in open(tsv, encoding='utf-8', errors='replace'):
            parts = line.strip().split('\t')
            if len(parts) >= 2:
                compare_status[repo][parts[1]] = parts[0]

# 각 티켓의 grep hit를 분류
# grep hit 파일 목록은 배치 grep 결과에서 추출 (2-3에서 이미 파싱됨)
# 출력: compare_confirmed / need_read / generic_only
for key in ['CVS-XXXXX']:  # 실제 실행 시 Deep 후보 티켓 목록
    confirmed = []   # compare에서 확정된 파일
    need_read = []   # compare에 없어서 read 필요
    for repo in ['client', 'server']:
        # grep_hits_{key}_{repo}.txt 에서 파일 목록 읽기
        hit_path = f'$TMPDIR/grep_hits_{key}_{repo}.txt'
        if not os.path.exists(hit_path): continue
        for line in open(hit_path):
            fpath = line.strip()
            if not fpath: continue
            if fpath in compare_status.get(repo, {}):
                st = compare_status[repo][fpath]
                confirmed.append(f'{repo}:{fpath}:{st}')
            else:
                need_read.append(f'{repo}:{fpath}')

    if confirmed:
        print(f'[{key}] compare 확정: {len(confirmed)}개 → read 스킵')
        for c in confirmed[:5]:
            print(f'  {c}')
    if need_read:
        print(f'[{key}] compare 미포함: {len(need_read)}개 → read 필요')
        for n in need_read[:5]:
            print(f'  {n}')
    if not confirmed and not need_read:
        print(f'[{key}] grep hit 없음')
"

# 2단계: compare에 없는 파일만 HEAD+BASE read (병렬)
# 파일명: ${CVS_KEY}_{REPO}_{IDX} — 티켓·repo·순번을 모두 포함해 병렬 덮어쓰기 방지
# compare 확정 파일은 read 생략 → read 횟수 대폭 감소

# compare 미포함 파일 read (필요한 경우만)
$REPOB remote read client Develop/${RELEASE}/Main "[compare 미포함 파일]" --pretty > $TMPDIR/read_head_${CVS_KEY}_cl_1.txt &
$REPOB remote read client Develop/${PREV}/Main   "[compare 미포함 파일]" --pretty > $TMPDIR/read_base_${CVS_KEY}_cl_1.txt &
wait

# 비교 (compare 미포함 파일만 — compare 확정 파일은 이미 Changed/New/Removed)
$PYTHON -c "
import sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace'); sys.stderr.reconfigure(encoding='utf-8', errors='replace')
import json, re
key, repo, idx = '${CVS_KEY}', 'cl', '1'

def extract_body(path):
    raw = open(path, encoding='utf-8', errors='replace').read()
    try:
        d = json.loads(raw)
        if isinstance(d, dict) and 'content' in d:
            raw = d['content']
    except: pass
    lines = raw.splitlines()
    cleaned = []
    for l in lines:
        l = re.sub(r'^\d+\|\s?', '', l)
        l = l.rstrip()
        l = l.replace('\xa0', ' ')
        l = re.sub(r'[ \t]+', ' ', l)
        cleaned.append(l)
    body = '\n'.join(cleaned).strip()
    return body

head = extract_body(f'$TMPDIR/read_head_{key}_{repo}_{idx}.txt')
base = extract_body(f'$TMPDIR/read_base_{key}_{repo}_{idx}.txt')
if head == base:
    print(f'[{key}] UNCHANGED — 파일 내용 동일 (compare 미포함 파일)')
else:
    print(f'[{key}] CHANGED — 내용 다름 (compare 미포함 파일에서 간접 변경 발견)')
"
```

**Changed 확정 판정** (compare + read 결합):
- **compare 확정 파일이 1개라도 있으면** → 해당 티켓은 Changed 확정 → Deep 유지. read 불필요.
- **compare 확정 파일 없음 + read로 Changed** → Deep 유지 (간접 영향 파일에서 변경 발견).
- **compare 확정 파일 없음 + read로 Unchanged** → Light 강등 후보. D규칙으로 넘어간다.
- **compare 확정 파일 없음 + read 대상도 없음 (grep hit가 모두 compare에 있는데 상태가 modified 아님)** → 상태에 따라 판단.

> **핵심 개선**: 기존에는 모든 Deep 후보의 grep hit 파일을 HEAD+BASE read해야 Changed를 확인할 수 있었다. compare 도입으로 **대부분의 grep hit 파일이 compare에서 이미 확정**되므로, read 횟수가 대폭 감소한다. read는 compare에 없는 파일(간접 영향 탐지)에만 실행한다.

- **`{CVS_KEY}_{REPO}_{IDX}` 3-부분 파일명 필수**: 티켓 키만 넣으면 client/server가 같은 파일명을 써서 병렬 실행 시 덮어써진다. `_cl_1` / `_sv_1` 처럼 repo와 순번을 항상 붙인다.
- **client·server 모두 적용**: grep hit가 client 파일이면 client 브랜치로, server 파일이면 server 브랜치로 각각 read한다. 한쪽만 read하면 반대쪽 Evidence가 누락된다.
- **Unchanged 확정 시** (compare 확정 파일도 없는 경우만): 해당 티켓을 Deep → Light 재분류한다. 2-4 트리아지 결과에 반영한다.
- compare 미포함 파일 read는 티켓당 **최대 2개**로 제한한다 (시간 제어).
- **여러 Deep 후보는 반드시 한꺼번에 큐잉하고 마지막에 1회 wait**: 티켓마다 wait를 넣으면 병렬 효과가 없어진다.

```bash
# 여러 Deep 후보 — compare 미포함 파일 read + D규칙 후보를 한 배치에서 동시 큐잉
# compare 확정 파일이 있는 티켓은 read 자체를 건너뛴다 (Changed 이미 확정)
# D규칙 후보: compare 확정 파일이 없는 + 완료/Need Review 티켓의 추가 파일
for CVS_KEY in CVS-XXXXX CVS-YYYYY CVS-ZZZZZ; do
  # ── compare 확정 여부 확인 ──
  # compare에서 해당 티켓의 grep hit가 modified/added로 확정됐으면 read 스킵
  # compare 미포함 파일만 A규칙 read
  $REPOB remote read client Develop/${RELEASE}/Main "[compare 미포함 파일]" --pretty > $TMPDIR/read_head_${CVS_KEY}_cl_1.txt &
  $REPOB remote read client Develop/${PREV}/Main   "[compare 미포함 파일]" --pretty > $TMPDIR/read_base_${CVS_KEY}_cl_1.txt &
  # ── D규칙 사전큐잉 (compare 확정 파일 없는 + 완료/Need Review 티켓만) ──
  $REPOB remote read client Develop/${RELEASE}/Main "[D후보 파일 1]" --pretty > $TMPDIR/read_head_${CVS_KEY}_cl_3.txt &
  $REPOB remote read client Develop/${PREV}/Main   "[D후보 파일 1]" --pretty > $TMPDIR/read_base_${CVS_KEY}_cl_3.txt &
done
wait  # 전체 완료 후 1회만
```

> **사전큐잉 원리**: A규칙과 D규칙 read를 순차 wait 2회 대신 1회 wait로 병렬 실행한다. A규칙 비교 후 UNCHANGED인 티켓만 D규칙 파일을 비교하고, CHANGED인 티켓의 D규칙 파일은 무시한다. compare 확정 파일이 있는 티켓은 read 자체를 건너뛰므로 전체 read 횟수가 대폭 줄어든다.

---

**B. 0 hits 티켓 — Negative confirmation 명시 의무화**

배치 grep에서 특정 티켓의 모든 키워드가 0 hits이면 다음을 명시적으로 기록한다:

```
[CVS-XXXXX] grep 0 hits 확인
  사용 키워드: [키워드 목록]
  → 2-3 재시도 규칙 적용
```

이후 재시도 및 Light 확정 절차는 **2-3 grep 0 hits 처리 규칙**을 따른다. (재기술하지 않음)

---

**C. Bug 타입 — 파일 read 강제화**

Bug 타입 티켓은 grep 결과 유무와 무관하게 연관 파일을 **최소 1개** HEAD + BASE read한다.
목적: Bug 재현 조건·픽스 코드가 실제로 달라졌는지 확인이 QA 체크 근거로 필수다.

파일 선택 우선순위 (상위 조건이 있으면 하위 조건은 건너뜀):
1. **파일명 직접 매칭**: glob 결과에서 티켓 키워드(버그명·클래스명)와 파일명이 일치하는 파일
2. **New/Removed 확정 파일**: 2-1 비교에서 New·Removed로 확정된 파일 중 티켓 관련성 있는 파일
3. **키워드 매칭**: grep hit 파일 중 hit 수가 가장 많은 파일 (A와 동일이면 A 결과 재사용)
4. **매핑 없음 → Light 처리**: 위 세 조건 모두 없으면 무관한 파일을 추정 선택하지 않는다. "신뢰 가능한 코드 매핑 없음"을 명시하고 Light(0 hits)로 재분류한다. 무관한 파일을 근거처럼 보이게 만드는 것보다 미확인으로 남기는 편이 안전하다.

---

**D. 완료/Need Review + grep hits > 0 + compare 확정 없음 + 기존 read 모두 UNCHANGED → top 3 추가 read**

A 규칙 적용 후, 아래 **네 조건을 모두** 충족하는 티켓에 대해 추가 파일 read를 실행한다:
1. 티켓 상태가 `완료` / `Need Review` / `Done` / `Closed` (개발 완료 사인)
2. 배치 grep에서 해당 티켓 키워드에 1개 이상 hit 발생
3. **A규칙에서 compare 확정 파일이 없음** (grep hit가 모두 compare에 없거나, compare 자체가 실패한 repo)
4. A 규칙에서 read한 파일이 **모두 UNCHANGED**로 확정됨

> **compare 확정이 있으면 D규칙 불필요**: A규칙에서 compare로 Changed가 1개라도 확정된 티켓은 이미 Deep이 확정됐으므로 D규칙을 적용하지 않는다. D규칙은 "compare에도 없고 read에서도 Unchanged인데, 다른 파일에서 변경됐을 가능성"을 탐지하는 규칙이다.

```
[CVS-XXXXX] D규칙 적용: grep hits [N]개, compare 확정 0개, A규칙 read [N]개 모두 UNCHANGED
  → A규칙에서 read한 파일 외 grep hit 파일 중 상위 3개 추가 read
```

**추가 read 대상 선택**: A 규칙에서 이미 read한 파일을 제외하고, A규칙과 동일한 **범용 파일 패널티 + 선택 우선순위**(직매칭 → 경로 다양성 → 범용 fallback)를 적용해 상위 3개를 선택한다. compare에 없는 파일만 대상이다 (compare에 있으면 상태가 이미 확정). 선택 결과는 `$TMPDIR/read_selection.log`에 `D규칙 read 후보 선택` 블록으로 추가 기록한다.

```bash
# D규칙 — 사전큐잉 방식 (2-3-B A규칙 배치에서 이미 read 완료)
# A규칙 비교 후 compare 확정 없음 + 모두 UNCHANGED인 티켓만, 이미 저장된 D후보 파일을 비교한다.
# 별도 wait 없음 — A규칙 배치의 단일 wait에서 이미 완료됨.
# 비교 대상 파일: $TMPDIR/read_head_${CVS_KEY}_cl_3.txt ~ _cl_5.txt (사전큐잉된 것)
```

- 추가 read에서 **Changed가 1개라도 나오면** Deep을 유지하고 해당 파일을 Evidence로 확정한다.
- 추가 read도 모두 UNCHANGED이면 Light(강등)로 재분류하되, "D규칙 적용: top 3 추가 read 포함 모두 UNCHANGED"를 기록한다.
- 추가 read는 **최대 3개 파일**로 제한한다 (시간 제어).

**UNCHANGED 원인 분류** (D규칙 포함 전체 read에서 UNCHANGED일 때):
티켓 상태에 따라 UNCHANGED의 원인이 다르다. 아래 기준으로 분류하고 사유를 명시한다:
- **완료/Need Review/Done/Closed** + UNCHANGED → "이전 릴리스에서 이미 반영된 변경 (핫픽스 등)" 가능성. PREV 이전 브랜치와의 비교가 필요할 수 있음을 권고한다.
- **진행 중/In Progress/TODO-Dev** + UNCHANGED → "코드 미커밋 상태". 개발 완료 후 재분석 필요를 명시한다.
- **그 외 상태** + UNCHANGED → "원인 불명 — 수동 확인 필요"로 기록한다.

---

### 2-4. 트리아지: STEP 2 기반 티켓 분류

#### Confluence 리다이렉트 조기 판정 [트리아지 직전 — 반드시 동기 실행]

`$TMPDIR/spec_links.tsv`에서 `confluence` 타입 행을 읽고, 페이지 ID가 있는 행마다 Confluence REST를 1회 호출해 리다이렉트 전용 페이지인지 판정한다. 결과를 tsv 6번째 컬럼에 `redirect` 또는 `normal`로 기록한다.

> **동기 실행 필수**: 이 스크립트를 `&`(background)로 실행하면 트리아지(2-4)가 `spec_links.tsv` 업데이트 전에 시작되어 redirect 판정이 누락된다. 반드시 동기(`wait` 없이 직접 실행)로 완료 후 2-4를 시작한다.

```bash
# Confluence 리다이렉트 조기 판정 — 트리아지 직전 1회 실행
$PYTHON -c "
import sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace'); sys.stderr.reconfigure(encoding='utf-8', errors='replace')
import json, re, subprocess, os
tsv_path = '$TMPDIR' + '/spec_links.tsv'
if not os.path.exists(tsv_path):
    exit(0)
lines = open(tsv_path, encoding='utf-8').read().strip().splitlines()
updated = []
for line in lines:
    cols = line.split('\t')
    if len(cols) < 5:
        updated.append(line); continue
    if cols[1] != 'confluence' or not cols[3]:
        # 6번째 컬럼이 없으면 빈값 추가
        if len(cols) < 6: cols.append('')
        updated.append('\t'.join(cols)); continue
    page_id = cols[3]
    try:
        import urllib.request, urllib.error
        # JIRA_AUTH — bash 변수 확장으로 주입됨 (export 불필요)
        import base64
        auth = base64.b64encode('$JIRA_AUTH'.encode()).decode()
        domain = '$JIRA_BASE'
        # 캐시 파일 경로 (3-C에서 재사용)
        cache_path = f'$TMPDIR/_confluence_{page_id}.json'
        req = urllib.request.Request(
            f'{domain}/wiki/rest/api/content/{page_id}?expand=body.storage',
            headers={'Authorization': f'Basic {auth}'})
        resp = urllib.request.urlopen(req, timeout=10)
        raw = resp.read()
        d = json.loads(raw)
        # 캐시 저장 (3-C에서 REST 재호출 방지)
        with open(cache_path, 'wb') as cfp: cfp.write(raw)
        body_html = d.get('body',{}).get('storage',{}).get('value','')
        body_text = re.sub('<[^>]+>', '', body_html).strip()
        ext_urls = re.findall(r'href=[\"\\x27](https?://(?:docs\\.google\\.com|drive\\.google\\.com|slides\\.google\\.com|dropbox\\.com|www\\.figma\\.com)[^\"\\x27]*)', body_html)
        # href 태그 없이 plain text로 URL만 있는 경우도 감지 (예: Dropbox 링크만 텍스트로 붙여넣은 페이지)
        if not ext_urls:
            ext_urls = re.findall(r'(https?://(?:docs\\.google\\.com|drive\\.google\\.com|slides\\.google\\.com|dropbox\\.com|www\\.dropbox\\.com|www\\.figma\\.com)[^\\s<\"\\x27]*)', body_text)
        status = 'redirect' if len(body_text) <= 100 and ext_urls else 'normal'
    except:
        status = ''  # 판정 실패 → 빈값 (보수적으로 Deep 유지)
    if len(cols) < 6: cols.append(status)
    else: cols[5] = status
    updated.append('\t'.join(cols))
with open(tsv_path, 'w', encoding='utf-8') as fp:
    fp.write('\n'.join(updated) + '\n')
" 2>/dev/null
```

판정 결과 활용: Deep 승격 조건에서 Confluence 링크를 확인할 때, `spec_links.tsv` 6번째 컬럼이 `redirect`인 행은 Deep 승격 근거에서 제외한다. 빈값(판정 실패)이면 보수적으로 Deep 유지.

2-1~2-3-B 완료 후, 모든 티켓을 **확인 대상** / **제외**로 분류한다.

내부적으로는 기존 Deep/Light/Skip 로직을 그대로 사용하되, **출력물에는 아래 2개 레이블만 사용**한다:

| 출력 레이블 | 내부 분류 | 근거 강도 태그 | STEP 3 처리 |
|------------|----------|--------------|------------|
| **확인 대상** | Deep | `코드 확정` — Changed/New/Removed read 확인 | 3-A·3-B·3-C 전체 실행 |
| **확인 대상** | Deep (별도 repo) | `코드 미확인 (별도 repo)` — 0 hits + 별도 repo 4조건 | 3-A·3-B 실행 + "별도 repo 가능성" 표시 |
| **확인 대상** | Light | `코드 미확인` — grep 0 hits / UNCHANGED 확정 | 설명 기반 테스트 방법 |
| **확인 대상** | Light (강등) | `코드 미확인 (UNCHANGED)` — A규칙 Unchanged 확정 | 설명 기반 + Unchanged 근거 |
| **확인 대상** | Light (D규칙 강등) | `코드 미확인 (D규칙 UNCHANGED)` — top 3 추가 read 포함 모두 Unchanged | 설명 기반 + D규칙 근거 |
| **확인 대상** | Light (0 hits) | `코드 미확인 (0 hits)` — 재시도 포함 0 hits 확정 | "코드 위치 미확인" 사유 포함 |
| **제외** | Skip | `제외 사유` 명시 | "QA 범위 외" 표시 후 제외 |

> **레이블 결정 트리** (triage.json 기록 시 사용 — **평가 순서 엄수: Skip → Deep → 강등 → Light**):
> 1. **Skip 조건 충족?** → **제외** (사유 명시: "인프라 작업", "0 hits + 설명 없음" 등). Skip 판정은 반드시 Deep 판정보다 먼저 실행한다. Skip으로 분류된 티켓은 이후 Deep 승격 조건을 평가하지 않는다.
> 2. **Deep 조건 충족?** → **확인 대상** + 근거 강도 태그 결정:
>    - read로 Changed/New/Removed 확정 → `코드 확정`
>    - 별도 repo 4조건 충족 → `코드 미확인 (별도 repo)`
>    - CHANGELOG 근거만 → `코드 확정 (CHANGELOG)`
> 3. **Deep → Light 강등?** → **확인 대상** + 근거 강도 태그:
>    - A규칙 UNCHANGED → `코드 미확인 (UNCHANGED)`
>    - D규칙 UNCHANGED → `코드 미확인 (D규칙 UNCHANGED)`
> 4. **나머지 (Light)** → **확인 대상** + `코드 미확인 (0 hits)` 또는 `코드 미확인`

**UNCHANGED → 자동 강등 가드레일** (강화):
- 2-3-B A규칙에서 **compare 확정 파일이 없고**, grep hit 파일을 read한 결과 **HEAD = BASE (Unchanged)**이고, 파일명 매칭(New/Removed)이나 실질적 Confluence 링크(리다이렉트 아닌)가 없으면, **무조건 Light로 강등**한다.
- **compare 확정이 1개라도 있으면 강등하지 않는다**: compare에서 modified/added/removed로 확정된 파일은 "이번 릴리스에서 코드가 바뀌었다"는 git 수준 확정이므로, read Unchanged가 일부 있어도 Changed가 우선한다.
- 이 가드레일은 다른 승격 조건(서버 hits, Need Review 상태 등)보다 우선한다. compare 확정도 없고 UNCHANGED 확정이면 "이번 릴리스에서 코드가 바뀌지 않았다"는 객관적 근거이므로, 상태나 hit 수로 재승격하지 않는다.
- 예외: CHANGELOG에 해당 기능 변경이 명시된 경우에만 강등하지 않는다 (CHANGELOG → read 파이프라인에서 다른 파일이 Changed일 수 있음).

**제외 조건** (하나라도 해당하면 제외 — 사유 필수):
- Development + 설명·코멘트 모두 없음 + 인프라·DB 작업만 → 제외 사유: "인프라/DB 작업 — QA 확인 영역 아님"
- **Development + 0 hits 확정 + 설명이 없거나 인프라 키워드만 포함** (강화): 배치 grep 재시도 포함 0 hits이고, 티켓 설명이 비어있거나 `infrastructure|MySQL|AWS|DB|migration|인프라|서버 환경|CI/CD|Docker|OS|테이블|table|정리|cleanup` 키워드만 포함하는 경우 → 제외 사유: "0 hits + 인프라 키워드만 — QA 확인 영역 아님"
- **Development + 0 hits 확정 + 설명 부재** (추가): 배치 grep 재시도 포함 0 hits이고, 티켓 설명 길이(desc_len)가 50자 미만이고, has_subtask_code == false이면 → 제외 사유: "Development + 0 hits + 설명 부재"
- 단, 하위 작업에 "서버"/"클라" 키워드가 있으면 코드 변경 가능성이 있으므로 제외하지 않는다.

**Skip/Deep/Light 분류는 정본 triage.py가 실행한다** (inline pseudocode 대신 스킬 디렉토리의 정본 스크립트를 호출):

```bash
# 트리아지 실행 — 정본 triage.py 호출
# SKILL_DIR: 이 스킬의 base directory를 동적으로 해결
# 우선순위: 1) CLAUDE_PLUGIN_ROOT (claude-code 환경변수) 2) 사용자 글로벌 3) 워크스페이스 4) 워크트리
# OS·경로 hardcoding 회피 — 사용자 환경(Mac/Win/Linux) 모두 동작
SKILL_DIR=""
for CAND in \
    "${CLAUDE_PLUGIN_ROOT:-}/skills/release-diff" \
    "$HOME/.claude/skills/release-diff" \
    "$(pwd)/.claude/skills/release-diff" \
    "$(pwd)/../../.claude/skills/release-diff" \
    "$HOME/Desktop/moco/.claude/skills/release-diff" \
    "C:/moco/.claude/skills/release-diff"; do
  if [ -f "$CAND/triage.py" ]; then
    SKILL_DIR="$CAND"
    break
  fi
done
if [ -z "$SKILL_DIR" ]; then
  echo "ERROR: triage.py 미발견 — SKILL_DIR을 수동 지정하거나 스킬 설치 위치 확인" >&2
  exit 1
fi
echo "SKILL_DIR=$SKILL_DIR"
$PYTHON "$SKILL_DIR/triage.py"
```

> **triage.py 구현 내용** (스킬 디렉토리에 고정된 정본 — `${SKILL_DIR}/triage.py`):
> - Skip 판정: Development + 인프라 키워드 + (grep 0 hits OR grep effective_files가 모두 범용 파일) → 제외
> - Skip 판정: Development + 설명 부재(desc_len < 50) + grep 0 hits → 제외
> - Deep 승격: commit_map > compare_match > client/server new/removed > CHANGELOG > grep > 별도 repo > Confluence 순서
> - compare_match 범용화: 티켓 제목 + 하위 작업 키워드를 compare 파일명/디렉토리명과 매칭 (하드코딩 없음)
> - client_new/removed + server_new/removed 소비 경로 포함
> - common_changed.tsv 자동 병합 (_CHANGELOG_ 재매칭 포함)
> - 범용 파일 패턴(ClientAPI/, ClientModels, route_admin 등) 필터링
> - 출력: `$TMPDIR/triage.json`

**Deep 승격 조건** (하나라도 해당하면 내부 Deep):
- **compare 커밋→티켓 매핑**: STEP 1.5-B에서 커밋 메시지의 `CVS-\d+`로 해당 티켓에 매핑된 커밋이 있고, 해당 커밋에서 변경된 파일이 있음 (가장 강력한 근거 — git이 직접 확인한 변경)
- 2-1 파일 목록 비교에서 티켓 키워드와 **파일명 매칭** (Changed/New/Removed)
- 2-3-B A규칙에서 **compare 확정 파일** 있음 (grep hit 파일이 compare에서 modified/added/removed)
- 2-3 배치 grep **정규화 후 effective_count > 0** (`$TMPDIR/grep_normalized.json` 참조 — `raw_count`가 아닌 `effective_count`만 사용). grep 경로 Deep은 `evidence_tag: "코드 미확인"` 유지 (grep은 코드 확정 근거가 아님)
- 2-3 **별도 repo 가능성 탐지** 4조건 충족 (외부 플랫폼 키워드 + 하위 작업 구현 키워드 + client 0 hits + 개발 완료)
- **CHANGELOG에 해당 기능 변경 항목 있음** (2-1-A에서 매칭)
- **해당 티켓에 연결된 PR이 1개 이상 + branch match (또는 other-branch-linked 예외)** (STEP 1.5 결과 활용): `$TMPDIR/jira_pr_map.tsv`에서 해당 티켓 키가 있고, PR classification이 `match` 또는 `other-branch-linked`이면 Deep 승격. baseRefName mismatch이더라도 Jira dev-status로 연결된 PR은 hotfix/cross-release PR이어도 Deep 대상에 포함한다. **단, `source: "fallback"`인 PR(PR 메타 정규식 추출)은 약한 매핑이므로 단독으로는 Deep 승격 근거가 되지 못한다** — 다른 강한 근거(commit_map / compare_match / changelog / filename_keyword)와 결합될 때만 Deep 승격에 기여한다. fallback 단독이면 `evidence_tag: "코드 미확인"` 유지.
- STEP 1에서 수집한 **Confluence 기획서 링크** 있음 (**티켓 상태 무관** — TODO-Dev, 진행 중이라도 Confluence 링크가 실질적이면 Deep 승격). 단, **리다이렉트 전용 페이지**는 Deep 승격 근거에서 제외한다. 판정 방법: 트리아지(2-4) 직전에 Confluence 링크가 있는 티켓의 페이지를 REST 1회 호출해 리다이렉트 여부를 조기 판정한다 (3-C와 동일한 판정 로직: HTML 제거 후 본문 100자 이하 + 외부 URL 포함). 리다이렉트 확정 시 해당 링크는 Deep 승격 근거에서 제외하고, `spec_links.tsv`에 `redirect` 표시를 추가한다. REST 실패 시에는 보수적으로 Deep 유지.
  - **예외**: 리다이렉트 확정이더라도 **Jira 티켓 설명(description)이 300자 이상**이면 Deep을 유지한다. 기획서 본문이 없더라도 티켓 설명 자체가 충분히 상세하면 그 정보만으로 테스트 방법·영향 범위 분석이 가능하다. 이 경우 3-C는 "Confluence: 리다이렉트 (티켓 설명 기반 분석)" 으로 기록한다.

**Deep → Light 강등 조건** (2-3-B 확인 후 적용 — UNCHANGED 가드레일):
- 2-3-B A규칙에서 **compare 확정 파일이 없고**, grep hit 파일을 read한 결과 HEAD = BASE (Unchanged 확정)
- **가드레일**: compare 확정도 없고 Unchanged 확정일 때, 서버 hits·Need Review 상태 등 다른 조건으로 재승격하지 않는다. git diff에서 변경이 없다는 객관적 근거가 상태 기반 추정보다 우선한다.
- **compare 확정이 있으면 강등 불가**: compare에서 modified/added/removed가 1개라도 있으면 Deep 유지.
- 강등 예외 (아래 중 하나라도 해당하면 강등하지 않음):
  - compare에서 해당 티켓 관련 파일이 modified/added/removed로 확정됨
  - 파일명 매칭(New/Removed)이 있음
  - 실질적 Confluence 링크(리다이렉트 전용 아닌)가 있음
  - CHANGELOG에 해당 기능 변경이 명시됨

> 파일명에 기능명이 드러나지 않는 공용 모듈(logic_reward, logic_inbox 등)은 파일명 매칭 실패해도 grep hit로 Deep 승격된다.

**common_changed.tsv 병합**: 정본 triage.py가 triage.json 저장 직전에 `$TMPDIR/common_changed.tsv`를 자동으로 병합한다. 별도 실행 블록 불필요.

> **_CHANGELOG_ 재매칭 상세**: CHANGELOG에서 나온 `PopupManager` 같은 클래스가 `_CHANGELOG_` 티켓으로 귀속돼 있다. triage.py가 각 티켓의 키워드와 대조해서 매칭되는 티켓에 배정한다. 매칭되는 티켓이 없으면 해당 항목은 어느 티켓에도 등록되지 않는다(오탐 방지).
>
> **evidence_tag 재평가**: common Changed가 추가된 후, 해당 티켓의 evidence_files에 코드 확정 가능한 selector(`changelog`, `filename_keyword`)가 하나라도 있으면 evidence_tag를 `코드 확정`으로 승격한다. `broad_grep`만이면 `코드 미확인` 유지.

**triage.json 저장** (triage.py가 자동 수행 — 이후 모든 STEP의 단일 소스):
정본 triage.py가 `$TMPDIR/triage.json`을 저장한다 (common_changed.tsv 병합 포함). STEP 3, 3-D, 4, 5, 6의 모든 출력은 이 파일을 참조해 일관성을 보장한다.

```json
{
  "tickets": [
    {
      "key": "CVS-XXXXX",
      "label": "확인 대상",
      "internal": "Deep",
      "evidence_tag": "코드 확정",
      "evidence_files": [
        {"path": "PopupManager.cs", "state": "Changed", "source": "read", "selector": "changelog"},
        {"path": "Popup.cs", "state": "Changed", "source": "read", "selector": "filename_keyword"},
        {"path": "Assets/Contents/.../El Oro De Zorro/*.cs", "state": "New", "source": "compare", "selector": "compare_match"}
      ],
      "deep_empty_reason": null,
      "reason": "CHANGELOG 매칭 + read Changed 확정",
      "exclude_reason": null
    },
    {
      "key": "CVS-YYYYY",
      "label": "확인 대상",
      "internal": "Deep",
      "evidence_tag": "코드 미확인 (별도 repo)",
      "evidence_files": [],
      "deep_empty_reason": "other_repo",
      "reason": "별도 repo 4조건 충족",
      "exclude_reason": null
    },
    {
      "key": "CVS-ZZZZZ",
      "label": "제외",
      "internal": "Skip",
      "evidence_tag": null,
      "evidence_files": [],
      "deep_empty_reason": null,
      "reason": null,
      "exclude_reason": "인프라/DB 작업 — QA 확인 영역 아님"
    }
  ]
}
```

#### evidence_files 필드 규격

- `evidence_files`는 `{path, state, source, selector}` 객체 배열이다. 파일마다 상태가 다를 수 있으므로 파일별로 기록한다.
- **source**: 상태 확정 방법. 유효값: `"commit"` | `"compare"` | `"read"` | `"grep"` | `"pr_hint"`
- **selector**: evidence 선정 근거. 유효값: `"commit_map"` | `"compare_match"` | `"changelog"` | `"filename_keyword"` | `"broad_grep"` | `"confluence"` | `"other_repo"` | `"pr_linked"`
- **source 우선순위**: `commit > compare > read > grep > pr_hint` — 같은 파일이 여러 source로 확정될 때 상위 1개만 기록
- **status 충돌 시 규칙**: source가 다른데 status도 다르면 **compare의 status를 채택** (브랜치 전체의 최종 상태)

#### source×selector 코드 확정 판정 규칙

| source | selector | 코드 확정 가능 | 이유 |
|--------|----------|--------------|------|
| commit | commit_map | **가능** | git commit이 티켓에 직접 귀속 |
| compare | compare_match | **가능** | git diff가 브랜치 간 변경 확정 |
| read | changelog | **가능** | CHANGELOG가 변경 파일을 지정 |
| read | filename_keyword | **가능** | 티켓 키워드↔파일명 exact 매칭 |
| read | compare_match | **가능** | compare 파일의 세부 확인 |
| read | broad_grep | **불가** | grep이 넓은 키워드로 선택, 티켓 귀속 약함 |
| grep | (모두) | **불가** | "브랜치에 존재"일 뿐 "변경됨" 아님 |
| pr_hint | (모두) | **불가** | 힌트용, 확정 근거 아님 |

> **evidence_tag 결정 규칙**: evidence_files 중 코드 확정 가능한 항목(위 테이블 기준)이 **1개라도 있으면** `evidence_tag: "코드 확정"`. 전부 코드 확정 불가이면 `evidence_tag: "코드 미확인"`. evidence_files가 비어있으면 `deep_empty_reason`에 따라 결정.

#### deep_empty_reason 필드 (Deep + evidence_files=[] 허용 예외)

- Deep이고 evidence_files==[]일 때 허용 사유를 구조화 필드로 기록
- 유효값: `"other_repo"` | `"confluence_only"` | `"pr_linked"` | `null`
- `null`이면 self-check에서 경고 (`⚠️ Deep이나 evidence/허용사유 없음`)
- evidence_files가 비어있지 않으면 이 필드는 `null`

#### grep 경로 Deep 승격 시 evidence 적재

grep 정규화(`$TMPDIR/grep_normalized.json`)에서 `effective_count > 0`인 티켓이 grep 경로로 Deep 승격할 때:
- `effective_files` 상위 3건을 evidence_files에 적재: `{source: "grep", selector: "broad_grep"}`
- `evidence_tag`는 `"코드 미확인"` 유지 (grep은 코드 확정 근거가 아님)
- 이 파일을 A규칙으로 read할 때 selector 분기:
  - 파일명이 티켓 키워드와 exact 매칭 → `{source: "read", selector: "filename_keyword"}` → 코드 확정 **가능**
  - 그렇지 않으면 → `{source: "read", selector: "broad_grep"}` → 코드 확정 **불가**

- 기존 `evidence_state` 필드는 제거한다 — 파일별 상태가 `evidence_files[].state`로 이동했으므로 중복이다.
- 3-D Evidence 요약 테이블은 `evidence_files` 배열을 순회해 파일별 행을 생성한다.

Deep(확인 대상 중 코드 확정) 티켓을 먼저 처리하고, Light(확인 대상 중 코드 미확인)는 마지막에 일괄 처리한다.

---

## STEP 3: 티켓별 분석

> **triage.json 참조 필수**: 이 STEP의 모든 출력은 `$TMPDIR/triage.json`을 읽어 레이블(확인 대상/제외), 근거 강도 태그, evidence 상태를 참조한다. 직접 판단하지 않고 triage.json의 값을 그대로 사용해 일관성을 보장한다.

처리 순서: `확인 대상 (코드 확정) [Bug 우선] → 확인 대상 (코드 확정) [기타] → 확인 대상 (코드 미확인)`

**확인 대상 (코드 미확인)** 티켓 (내부 Light): **설명 기반 테스트 방법**을 작성한다. 3-A와 동일한 형식(진입 경로 / 전제 조건 / 확인 포인트 / 예상 결과)을 사용하되, Evidence는 근거 강도 태그에 따라 다르게 표기한다. 3-B·3-C는 실행하지 않는다.
- `코드 미확인 (UNCHANGED)` / `코드 미확인 (D규칙 UNCHANGED)`: `Evidence: 코드 미확인 (UNCHANGED) — {파일명} (HEAD = BASE 동일)` → 코드를 확인했으나 변경이 없었음을 의미
- `코드 미확인 (0 hits)`: `Evidence: 코드 미확인 (0 hits, {사유})` → grep에서 코드를 찾지 못했음을 의미. 사유는 "진행 중", "TODO-Dev" 등
- `코드 미확인 (별도 repo)`: `Evidence: 코드 미확인 (별도 repo 가능성)` → 별도 repo에 코드가 있을 수 있음
Light 분류가 된 시점에서 배치 grep·하위 작업 키워드 재시도가 완료된 상태이므로, 추가 grep은 실행하지 않는다.
(Jira 키 `CVS-XXXXX`는 코드에 기재되지 않는 경우가 대부분이라 신호 품질이 낮고, 금지사항 "티켓별 개별 grep 반복 금지"와도 충돌한다.)

코드 미확인 티켓 출력 형식:
```
### [CVS-XXXXX] 티켓 제목 (확인 대상 — 코드 미확인)

**[설명 기반 테스트 방법]**
- 진입 경로: [티켓 설명에서 추론한 진입 경로]
- 전제 조건: [티켓 설명에서 추론한 전제 조건]
- 확인 포인트:
  1. [티켓 설명 기반 확인 항목]
  2. ...
- 예상 결과: [티켓 설명 기반 예상 결과]
- Evidence: [triage.json evidence_tag 기반 — 아래 참조]
  - UNCHANGED: `코드 미확인 (UNCHANGED) — {파일명} (HEAD = BASE 동일)`
  - 0 hits: `코드 미확인 (0 hits, {사유: 진행 중/TODO-Dev 등})`
  - 별도 repo: `코드 미확인 (별도 repo 가능성)`
```
**제외 티켓**: STEP 5 커버리지 보고에만 카운트한다. 제외 사유를 명시한다.

각 **확인 대상 (코드 확정)** 티켓(내부 Deep)에 대해 아래 3개를 반드시 분리해서 출력한다.

---

### 3-A. 테스트 방법

STEP 2-1에서 **Changed / New / Removed**로 분류된 파일을 우선 참조한다. (재호출 불필요)
배치 grep 결과는 STEP 2-3에서 이미 실행됐으므로 그 결과를 재사용한다. 재호출하지 않는다.

grep 결과에서 이 티켓 키워드에 해당하는 hit를 추출해 Evidence로 사용한다.

**PR body 테스트 컨텍스트 활용** (STEP 1.5 결과):
`$TMPDIR/github_summary.json`의 `jira_pr_map`에서 해당 티켓에 연결된 PR body를 확인한다. PR body에서 테스트 관련 섹션을 추출하여 테스트 방법을 보강한다:
- `## Test`, `## 테스트`, `## QA`, `## 확인` 섹션
- 체크리스트 (`- [ ]`, `- [x]`) 항목
- PR body에 테스트 관련 내용이 있으면 "PR 테스트 가이드" 섹션으로 테스트 방법에 반영한다.

**query 호출 제한**: 아래 조건 중 하나를 충족하는 경우에만 허용한다.
- **조건 A**: `Bug 타입 + High/Highest priority` + grep 미매칭
- **조건 B**: `(새 기능 또는 개선) + 중요 이상 priority + (Need Review 또는 완료/Done/Closed) + grep 0 hits 확정`
- **조건 C** (common-file-only fallback): `(완료/Need Review/Done/Closed) + grep hits > 0 + hit 파일이 모두 범용 파일 + D규칙 포함 모두 UNCHANGED`
  - **repo 단위 판정**: client hit가 모두 범용 파일이면 client만 query, server hit가 모두 범용 파일이면 server만 query. 양쪽 모두 해당하면 각각 병렬 실행.
  - 범용 파일 기준: A규칙의 범용 파일 패널티 경로 패턴과 동일 (`ClientAPI/`, `ClientModels`, `ClientAPI2Blackboard`, `types/interface`, `route_admin`, `route_main`)

조건 A·B는 grep 미매칭 시 코드 위치 탐색, 조건 C는 범용 파일만 hit됐을 때 실제 변경 파일 탐색 목적이다.
그 외 타입·조건에서 grep 미매칭이면 "코드 위치 미확인"으로 표시하고 넘어간다.
> **주의**: 2-3에서 `0 hits 확정`된 티켓은 이미 재시도를 거쳤으므로, 3-A에서 같은 키워드로 추가 grep을 실행하지 않는다. query만 조건부 허용된다.

- **조건 A·B**: grep 0 hits인 repo만 query 실행 (client 0 hits → client만, server 0 hits → server만, 양쪽 0 hits → 병렬)
- **조건 C**: 범용 파일만 hit된 repo만 query 실행 (client hit가 모두 범용 → client만, 양쪽 모두 범용 → 병렬). grep hit가 있어도 범용 파일뿐이면 query 대상이다.

```bash
# query는 조건 A/B/C에서만 실행 (60~300초 소요)
# 조건 A·B: grep 0 hits인 repo만 선택
# 조건 C: grep hits > 0이지만 hit 파일이 모두 범용인 repo만 선택

# 예시 1: 조건 A·B — client만 0 hits → client만 실행
$REPOB remote query client Develop/${RELEASE}/Main "[티켓 제목] 관련 코드가 어디 있나?" --pretty > $TMPDIR/query_${CVS_KEY}_cl.txt

# 예시 2: 조건 A·B — 두 repo 모두 0 hits → 병렬 실행
$REPOB remote query client Develop/${RELEASE}/Main "[티켓 제목] 관련 코드가 어디 있나?" --pretty > $TMPDIR/query_${CVS_KEY}_cl.txt &
$REPOB remote query server ${RELEASE}.0/Main "[티켓 제목] 관련 서버 코드가 어디 있나?" --pretty > $TMPDIR/query_${CVS_KEY}_sv.txt &
wait

# 예시 3: 조건 C — client hit가 모두 범용 파일 + D규칙 UNCHANGED → client만 query
$REPOB remote query client Develop/${RELEASE}/Main "[티켓 제목] 관련 코드가 어디 있나?" --pretty > $TMPDIR/query_${CVS_KEY}_cl.txt
# 주의: 조건 C는 grep hit가 있어도 범용 파일뿐인 repo에 query를 실행한다
```

출력 형식:
```
[테스트 방법]
- 진입 경로:
- 전제 조건:
- 확인 포인트:
  1. ...
  2. ...
- 예상 결과:
- Evidence: [코드 위치] (Changed / New / Removed / Unchanged / 미확인 중 하나로 상태 표시)
  - **Sampled** (비고 flag — 상태가 아님): glob truncation으로 파일 목록이 불완전하여 grep 결과 기반으로 확인한 상태. 3-A에서는 자유 서술 가능하지만, **3-D 테이블 상태 컬럼에는 `미확인`으로 기재**하고 비고 컬럼에 `Sampled` flag를 붙인다.
  - **Common-only** (비고 flag): hit 파일이 모두 범용 파일인 경우. 비고 flag끼리 조합 가능 (예: `Sampled + Common-only`)
  - Removed인 경우: 삭제된 기능/파일이 대체됐는지, 완전 제거됐는지 확인 포인트 추가
- **open PR 참고 (있는 경우만)**: ⏳ `(open PR #번호 — 예정 변경, 미확정)`
  - Evidence 행과 **별도 행**으로 출력 — 같은 줄에 섞지 않음
  - 아이콘 `⏳`으로 실반영 Evidence(`Evidence:`)와 시각 구분
  - STEP 4 체크리스트에는 포함하지 않음 (merge 전이므로 확인 항목 아님)
  - 예시:
    ```
    - Evidence: Assets/SlotMaker/SlotManager.cs (Changed, source: commit)
    - ⏳ open PR #420 — merge 시 CVS.com 관련 추가 변경 예상 (미확정)
    ```
```

---

### 3-B. 티켓 외 영향 범위

티켓에 기술된 내용 이외에 해당 변경이 영향을 줄 수 있는 영역을 탐색한다.

탐색 대상:
- **공용 컴포넌트**: 해당 코드가 다른 기능에서도 사용되는지
- **연결 흐름**: 보상, 팝업, 라우팅, 초기화 경로
- **설정값/플래그**: `default`, `config`, `flag`, `enable`, `disable`, `show`, `hide`
- **서버-클라이언트 인터페이스**: 한쪽만 변경됐을 때 다른 쪽 영향

플래그·설정값 탐색은 **2-3 배치 grep 결과를 재사용**한다. 별도 grep을 재호출하지 않는다.
(설정값 패턴 `isEnabled|defaultValue|FeatureFlag|RemoteConfig|config|flag`는 2-3 배치에 이미 포함돼 있다)

출력 형식:
```
[티켓 외 영향 범위]
- 직접 영향 (High): 코드 공유로 반드시 같이 확인해야 하는 기능
- 간접 영향 (Medium): 흐름 연동으로 영향 가능성 있는 기능
- 확인 권고 (Low): 근거 약하나 리스크 존재
- 영향 없음: 근거와 함께 명시
```

---

### 3-B-1. Sub-Bug 통합 표기 (3-tier 정책 — 부모 티켓 분석에 통합)

`$TMPDIR/sub_bugs.json`에서 해당 부모 티켓의 sub-bug 목록을 읽어 **부모 분석 안에 통합**한다. 개별 sub-bug 단위로 테스트 방법을 작성하지 않는다.

**fixVersion 분기 적용** (sub_bugs.json의 `is_other_release` 필드 기준):
- `is_other_release: false` 또는 미지정 → **본 릴리스 회귀 대상** (정상 처리)
- `is_other_release: true` → **본 릴리스 회귀 대상 제외** (이전/다른 릴리스에서 처리). 카운트만 별도 표기

출력 형식 (3-A/3-B 다음, 3-C 직전):

```
[수정된 Sub-Bug — 본 릴리스 회귀 대상] N건
- 수정 영역 키워드: [sub-bug summary에서 추출한 PascalCase 키워드 묶음 — 중복 제거, 상위 8개]
- High/Highest priority: M건 (개별 항목으로 STEP 4 분리)
  - [CVS-XXXXX] sub-bug 제목 ({priority})
  - ...
- 그 외 (N-M)건: Low/Medium/None — 일괄 회귀 확인으로 커버
- 미해결 sub-bug: K건 (있는 경우만 — STEP 5 경고에 반영)
  - [CVS-YYYYY] sub-bug 제목 ({priority}, {status})

[다른 릴리스 fixVersion Sub-Bug] O건 (회귀 대상 제외, 참고용)
- [CVS-ZZZZZ] sub-bug 제목 → fixVersion: 240.0 QA (이미 처리됨)
- ...
```

> **출력 조건**:
> - 본 릴리스 sub-bug 0건이면 첫 번째 섹션 생략
> - 다른 릴리스 sub-bug 0건이면 두 번째 섹션 생략
> - 부모가 코드 미확인 (Light)이어도 sub-bug가 있으면 표기 (회귀 확인은 코드 매핑과 무관)
> - **High/Highest priority도 `is_other_release: true`이면 STEP 4 개별 승격 안 함** (이전 릴리스에서 처리됨)

---

### 3-C. 기획서 비교 (코드 확정 티켓 + spec_links.tsv에 링크가 있는 티켓)

**확인 대상 (코드 확정)** 티켓(내부 Deep) 중 `spec_links.tsv`에 링크가 있는 티켓에 대해 실행한다. 코드 미확인 티켓(내부 Light)은 3-C를 실행하지 않는다 — 외부 링크만 보유한 코드 미확인 티켓은 STEP 5 커버리지 보고의 기획서 링크 목록에서만 보고한다.
Confluence를 우선 처리하고, Google/외부 링크는 URL을 명시한 뒤 "기획서 미확인"으로 처리한다.

**우선순위 1 — Atlassian MCP 인증된 경우**: MCP 도구로 Confluence 페이지를 직접 읽는다.

**우선순위 2 — MCP 미인증, Confluence REST fallback**:
같은 Jira 인증 정보로 Confluence REST API를 직접 호출한다.
**캐싱**: 2-4 Confluence 리다이렉트 조기 판정에서 이미 REST 호출한 페이지는 `$TMPDIR/_confluence_${PAGE_ID}.json` 파일이 존재한다. 이 파일이 있으면 REST를 재호출하지 않고 캐시된 결과를 사용한다.

```bash
# Confluence 페이지 ID 추출 (remotelink URL에서)
# 예: https://bagelcode.atlassian.net/wiki/spaces/XXX/pages/123456789
PAGE_ID="[추출한 페이지 ID]"

# 2-4 조기 판정에서 캐시된 결과가 있으면 REST 재호출 생략
if [ -f "$TMPDIR/_confluence_${PAGE_ID}.json" ]; then
  cp "$TMPDIR/_confluence_${PAGE_ID}.json" "$TMPDIR/_confluence_page.json"
  CONF_HTTP=200
else
  CONF_HTTP=$(curl -s --connect-timeout 5 --max-time 45 --retry 2 --retry-delay 2 -o "$TMPDIR/_confluence_page.json" -w '%{http_code}' -u "$JIRA_AUTH" \
    "$JIRA_BASE/wiki/rest/api/content/$PAGE_ID?expand=body.storage")
fi
if [ "$CONF_HTTP" -lt 200 ] 2>/dev/null || [ "$CONF_HTTP" -ge 300 ] 2>/dev/null; then
  echo "WARN: Confluence REST failed (HTTP $CONF_HTTP) — 기획서 미확인으로 처리" >&2
  printf '%s\t%s\t%s\t%s\n' "partial" "confluence" "$PAGE_ID" "$CONF_HTTP" >> "$TMPDIR/fetch_failed.txt"
else
  $PYTHON -c "
import sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace'); sys.stderr.reconfigure(encoding='utf-8', errors='replace')
import json, re
try:
    d = json.load(open(sys.argv[1], encoding='utf-8', errors='replace'))
except (json.JSONDecodeError, ValueError):
    print('WARN: Confluence REST JSON parse error — 기획서 미확인으로 처리', file=sys.stderr)
    exit(1)
body_html = d.get('body', {}).get('storage', {}).get('value', '')
title = d.get('title', '')
# HTML 태그 제거 후 순수 텍스트 추출
body_text = re.sub('<[^>]+>', '', body_html).strip()
# 리다이렉트 전용 페이지 감지: HTML 본문에서 외부 URL 추출
ext_urls = re.findall(r'href=[\"\\x27](https?://(?:docs\.google\.com|drive\.google\.com|slides\.google\.com|dropbox\.com|www\.figma\.com)[^\"\\x27]*)', body_html)
# href 태그 없이 plain text로 URL만 있는 경우도 감지
if not ext_urls:
    ext_urls = re.findall(r'(https?://(?:docs\.google\.com|drive\.google\.com|slides\.google\.com|dropbox\.com|www\.dropbox\.com|www\.figma\.com)[^\s<\"\\x27]*)', body_text)
# 판정: 텍스트 100자 이하 + 외부 URL 1개 이상 → 리다이렉트 페이지
if len(body_text) <= 100 and ext_urls:
    print(f'=== {title} ===')
    print(f'[REDIRECT PAGE] 본문 {len(body_text)}자, 외부 URL {len(ext_urls)}건')
    # 외부 문서 제목 추출: Confluence anchor text → URL basename fallback
    for u in ext_urls:
        # 1차: Confluence HTML에서 해당 URL의 anchor text 추출
        anchor_match = re.search(r'href=[\"\\x27]' + re.escape(u) + r'[\"\\x27][^>]*>([^<]+)<', body_html)
        if anchor_match and anchor_match.group(1).strip():
            doc_title = anchor_match.group(1).strip()
        else:
            # 2차: URL 경로의 마지막 세그먼트를 제목으로 사용
            from urllib.parse import urlparse, unquote
            path = urlparse(u).path.rstrip('/')
            doc_title = unquote(path.split('/')[-1]) if path else u
        print(f'  → {doc_title}: {u}')
    # Jira 티켓 설명 300자 이상이면 티켓 설명 기반 분석으로 전환
    # (이 판정은 2-4 트리아지에서 Deep 유지 여부와 연동)
    print('→ 기획서 미확인 (리다이렉트 전용 페이지) — 외부 URL 명시')
    print('  ※ Jira 티켓 설명이 300자 이상이면 티켓 설명 기반으로 기획서 비교를 수행한다.')
else:
    print(f'=== {title} ===')
    print(body_text[:3000])
" "$TMPDIR/_confluence_page.json"
fi
```

**우선순위 3 — REST도 실패 시 PR body fallback**:
Confluence REST 실패 또는 리다이렉트 전용 페이지인 경우, 해당 티켓에 연결된 PR body에서 기획서 관련 정보를 검색한다:
1. `$TMPDIR/github_summary.json`의 `jira_pr_map`에서 해당 티켓의 PR body 확인
2. PR body에서 URL 추출 (`docs.google.com`, `confluence`, `dropbox`, `figma` 등)
3. PR body에서 기획 관련 텍스트 추출 (기획, spec, 요구사항, requirement 등)
4. 결과: PR body에서 링크가 발견되면 "기획서 미확인 — PR body에서 링크 발견: {url}" 표시, 없으면 "기획서 미확인" 표시

**우선순위 4 — PR body에도 정보 없음**: "기획서 미확인" 표시 후 넘어간다.

**리다이렉트 전용 페이지 감지**: Confluence 페이지가 HTML 태그 제거 후 본문 100자 이하이면서 외부 URL(Google Docs/Slides/Drive, Dropbox, Figma 등)을 포함하면 **리다이렉트 전용 페이지**로 판정한다. 이 경우:
- **Jira 티켓 설명 300자 이상**: "Confluence: 리다이렉트 (티켓 설명 기반 분석)" — Jira 티켓 설명(description)을 기획서 대신 사용해 확인 항목(일치/불일치/누락/추가 구현)을 작성한다. 외부 URL도 함께 명시한다.
- **Jira 티켓 설명 300자 미만**: "기획서 미확인 (리다이렉트 전용 페이지)" — 외부 URL을 명시하고 Confluence 본문으로 기획서 비교를 시도하지 않는다.

확인 항목:
- 기획서에 명시된 동작/조건이 코드에 구현됐는가
- 기획서에는 있지만 코드에 없는 항목
- 코드에는 있지만 기획서에 없는 항목 (추가 구현 또는 임시 코드)
- 기획서의 "주의", "QA 확인 필요" 표시 항목

출력 형식:
```
[기획서 비교]
- 일치: 기획서 내용과 코드 구현이 동일한 항목
- 불일치 ⚠️: 기획서와 코드가 다른 항목 → QA 필수 확인
- 누락: 기획서에 있으나 코드에 없는 항목
- 추가 구현: 코드에 있으나 기획서에 없는 항목
- 기획서 미확인: REST 실패 또는 외부 파일(Slides/PPT)인 경우 — **URL을 그대로 명시** (예: `기획서 미확인 — https://docs.google.com/...`)
```

---

### 3-D. Evidence 요약 테이블 [STEP 3 전체 완료 후 1회 출력]

> **triage.json 참조 필수**: 테이블의 레이블, evidence 상태, 근거 강도 태그는 `$TMPDIR/triage.json`에서 읽어 기재한다. 3-A/3-B/3-C에서 출력한 내용과 이 테이블이 불일치하면 triage.json을 정본으로 사용한다.

코드 확정 티켓 분석이 모두 끝나면 테이블 출력 전에 아래 self-check를 1회 실행한다.

**출력 전 self-check (consistency validator)**:
1. **triage.json ↔ 3-A Evidence 일관성**: triage.json의 각 티켓 `evidence_files[].state`와 3-A에서 출력한 Evidence 상태가 일치하는지 확인한다. 복수 파일 티켓은 파일별 상태를 각각 대조한다. 불일치 시 triage.json을 정본으로 수정하고 `⚠️ 상태 보정` 비고를 추가한다.
2. **레이블 일관성**: 3-A에서 `(확인 대상 — 코드 확정)`으로 출력한 티켓이 triage.json에서 `코드 미확인`으로 돼 있거나 그 반대인 경우를 검출한다.
3. **"미확인" 상태 사유 점검**: 미확인 상태 행마다 → 0 hits 확인 로그 또는 "탐색 방법 없음" 사유가 명시됐는지 점검한다.
4. 사유 없이 미확인인 행이 있으면 해당 행의 **비고 컬럼**에 `⚠️ 탐색 미완료` 경고를 표시한다. (티켓 키 셀을 건드리지 않는다 — ontology-map 파싱 기준이 티켓 키 셀이므로 경고 삽입 금지)
5. Bug 타입이면서 미확인인 행 → 2-3-B C규칙 미적용 가능성. 비고 컬럼에 `⚠️ C규칙 미적용` 추가 후 STEP 3 재처리를 권고한다.
6. **복수 Evidence 행 검증**: triage.json의 `evidence_files`에 2개 이상 파일이 있는 티켓은 테이블에 복수 행으로 출력됐는지 확인한다. 단일 행으로 합쳐져 있으면 분리한다.
7. **STEP 4 체크리스트 ↔ triage.json 근거 일관성**: 체크리스트 각 항목의 근거 텍스트(Changed/New/grep hit 등)가 triage.json `evidence_files[].state`와 일치하는지 확인한다. 예: triage.json에서 `state: "New"`인 파일을 체크리스트에서 "grep hit"로 적으면 불일치 — triage.json 기준으로 "New"로 수정한다.
8. **CHANGELOG read 파일 → evidence_files 누락 검증**: CHANGELOG Changed/Removed 항목에서 언급된 클래스를 read해 Changed를 확인한 경우, 해당 파일이 triage.json `evidence_files`에 등록됐는지 확인한다. 누락 시 추가하고 3-D 표에 행을 보충한다. (예: Popup.Close() 변경 → Popup.cs read → Changed 확인 → evidence_files에 `{path: "Popup.cs", state: "Changed", source: "read"}` 추가)
9. **compare→evidence source 일관성**: evidence_files의 `source`가 정확한지 확인한다. compare_client_files.tsv에 있는 파일은 `source: "compare"`, HEAD+BASE read로 확인한 파일은 `source: "read"`, 커밋→티켓 매핑으로 확정된 파일은 `source: "commit"`.
10. **Deep + evidence 빈 상태 검증**: `internal == "Deep"`이고 `evidence_files == []`이고 `deep_empty_reason == null` → 경고 `⚠️ Deep이나 evidence/허용사유 없음`. deep_empty_reason이 `other_repo|confluence_only|pr_linked` 중 하나면 정당한 예외로 경고하지 않는다.
11. **코드 확정 오승격 차단**: `evidence_tag == "코드 확정"`인 티켓의 evidence_files 전체가 `source: "grep"` 또는 `selector: "broad_grep"`만으로 구성 → evidence_tag를 `"코드 미확인"`으로 강등하고 경고 `⚠️ grep/broad_grep 단독 — 코드 확정 강등`. triage.json도 함께 수정한다.
12. **selector 필드 무결성**: evidence_files 각 항목에 `selector` 필드가 누락된 경우 → 경고 `⚠️ selector 필드 누락 ({path})`. source×selector 체계 도입 이후 모든 evidence 항목은 selector를 갖고 있어야 한다.

온톨로지 매핑 입력용으로 아래 테이블을 한 번 출력한다.
`/ontology-map` 스킬은 이 테이블을 input으로 사용한다.

```
## Evidence 요약 (온톨로지 매핑용)

| 티켓 | 타입 | 우선순위 | 파일/코드 위치 | 상태 | 기능 키워드 | 비고 |
|------|------|---------|--------------|------|-----------|------|
| CVS-XXXXX | Bug | High | Assets/SlotMaker/SlotManager.cs | Changed | SlotManager, SpinResult | 코드 확정, PR #1234 |
| CVS-XXXXX | Story | Medium | src/logic/reward.ts | New | reward, settlement | 코드 확정, PR #1256 |
| CVS-XXXXX | Task | Low | - | 미확인 | CVS.com, Xsolla, Facebook | 코드 미확인 (별도 repo) + ⚠️ 탐색 미완료 |
| CVS-XXXXX | 개선 | 중요 | BagelCodeClientModelsExtend.cs | Unchanged | PaymentLink | 코드 미확인 (UNCHANGED) + Common-only |
| CVS-XXXXX | Development | None | src/LOGIC/route_main.ts | 미확인 | Pulsar, TimeBonus | 코드 미확인 (0 hits) + Sampled |
```

- **7컬럼 고정** (`/ontology-map` 파싱 호환): 근거 강도 태그는 비고 컬럼 앞부분에 기재한다. ontology-map은 비고 컬럼을 파싱하지 않으므로 영향 없다.
- 비고 컬럼 형식: `{근거 강도 태그}` 또는 `{근거 강도 태그} + {기존 flag}` (예: `코드 미확인 (UNCHANGED) + Common-only`)
- 코드 미확인 티켓(내부 Light)도 키워드와 상태(미확인)로 포함한다.
- 제외 티켓(내부 Skip)은 테이블에서 제외한다.
- **상태 컬럼 유효값** (ontology-map 호환): `Changed` / `New` / `Removed` / `Unchanged` / `미확인` — 이 5개만 사용한다.
- **비고 컬럼 flag**: `Sampled` (glob truncation 기반 — 상태는 `미확인`으로 기재), `Common-only` (hit 파일이 모두 범용 파일), `⚠️ 탐색 미완료`, `⚠️ C규칙 미적용`
  - flag는 조합 가능: `Sampled`, `Common-only`, `Sampled + Common-only` 등
- **PR 참조 표시**: `$TMPDIR/jira_pr_map.tsv`(6컬럼: key, repo, pr_num, title, status, source)에서 해당 티켓에 연결된 PR 번호를 비고 컬럼에 `PR #번호` 형식으로 표시한다. 복수 PR이면 `PR #1234, #1256` 형식. **`source: "fallback"`인 PR은 약한 매핑이므로 `PR #1234 (fallback)`으로 표기**해 dev-status 기반 강한 매핑과 구분한다. PR 연결이 없으면 생략한다.
- **복수 Evidence 행 분리 규칙**: triage.json의 `evidence_files`에 2개 이상 파일이 있는 티켓은 **파일별로 별도 행**을 출력한다. 첫 행에만 티켓 키·타입·우선순위·기능 키워드를 기재하고, 이후 행은 파일/코드 위치·상태·비고만 기재한다 (나머지 컬럼은 빈칸). 이렇게 하면 ontology-map이 파일별로 독립 매핑할 수 있다.
  ```
  | CVS-13349 | Development | None | PopupManager.cs | Changed | PopupManager, FGP, ODZ | 코드 확정 |
  | | | | Popup.cs | Changed | | |
  | | | | Assets/Contents/.../El Oro De Zorro/*.cs | New | | |
  ```

---

> **온톨로지 매핑은 `/ontology-map` 스킬로 분리됐다.** 위 Evidence 요약 테이블을 input으로 넣으면 Feature Module별 cross-cutting 영향을 분석한다.

---

## STEP 4: 최종 QA 체크리스트

> **triage.json 참조 필수**: 체크리스트 항목의 레이블, evidence 상태, 근거 강도 태그는 `$TMPDIR/triage.json`에서 읽어 기재한다.

STEP 3(티켓별 분석) 결과를 바탕으로 최종 체크리스트를 작성한다. **evidence 강도별로 분리**해 QA가 우선순위를 판단할 수 있게 한다.

### 최종 QA 체크리스트

```
## {RELEASE} 릴리스 최종 QA 체크리스트

### 코드 확정 — 필수 확인 (High)
- Changed/New/Removed 파일 기반 확정 변경
- 기획서 불일치 항목
- 설정값 변경은 배치 grep 탐지 근거 기반 (Changed 확정 아님, 명시 필요)

[ ] [CVS-XXXXX] 기능명 — 확인 포인트 — 근거 (Changed, PR #1234)
[ ] [CVS-XXXXX] 기능명 — 삭제 여부·대체 여부 확인 — 근거 (Removed, PR #1256)
[ ] ...

### 코드 확정 — 추가 확인 (Medium)
- 3-B 영향 범위 분석에서 나온 간접 영향 항목

[ ] 기능명 — 확인 포인트 — 근거: 간접 영향
[ ] ...

### 코드 미확인 — 직접 확인 필요
- 코드 근거 없음. 기능 동작 수준에서 직접 확인 필요
- 근거 강도 태그를 각 항목에 명시 (UNCHANGED / 0 hits / 별도 repo 등)

[ ] [CVS-XXXXX] 기능명 — 확인 포인트 — 코드 미확인 (UNCHANGED)
[ ] [CVS-XXXXX] 기능명 — 확인 포인트 — 코드 미확인 (0 hits)
[ ] [CVS-XXXXX] 기능명 — 확인 포인트 — 코드 미확인 (별도 repo)
[ ] ...

### Sub-Bug 회귀 확인
- 부모 티켓의 통합 회귀 + High/Highest priority sub-bug 개별 항목

[ ] [CVS-XXXXX] 부모 통합 회귀 — sub-bug N건 수정 영역 한 번에 확인 (수정 영역 키워드)
[ ] [CVS-YYYYY] (sub-bug, High) sub-bug 제목 — 개별 회귀 확인
[ ] [CVS-ZZZZZ] (sub-bug, Highest) sub-bug 제목 — 개별 회귀 확인

### 제외 (사유 명시)
- QA 범위에서 제외된 티켓. 제외 사유를 각 항목에 명시

- [CVS-XXXXX] 기능명 — 제외 사유: 인프라/DB 작업
- [CVS-YYYYY] 기능명 — 제외 사유: 0 hits + 설명 없음
```

---

## STEP 5: 분석 커버리지 보고 [필수]

> **triage.json 참조 필수**: 커버리지 집계는 `$TMPDIR/triage.json`에서 읽어 기재한다.

```
[분석 커버리지]
- Jira 티켓: 릴리스 {RELEASE} 상위 티켓 [N]건
  - Bug [N] / 새 기능 [N] / 개선 [N] / Development [N]
  - 확인 대상 [N]건 (코드 확정 [N] / 코드 미확인 [N]) / 제외 [N]건
- 기획서: Confluence 링크 있음 [N]건 / MCP 성공 [N]건 / REST 성공 [N]건 / 미확인 [N]건
- 기획서 링크 목록 (`$TMPDIR/spec_links.tsv` 기반 — 읽은 것·못 읽은 것 모두 나열):
  ```
  CVS-13255  📄 Google   https://docs.google.com/presentation/d/1xxx  (CVS.com 기획서)
  CVS-13260  🗂 Confluence  https://bagelcode.atlassian.net/wiki/.../pages/123  (보상 정책)
  CVS-13270  🔗 외부     https://example.com/spec.pdf  (외부 기획서)
  ```
  링크가 없으면 `(기획서 링크 없음)` 으로 표시한다.
- Cross-Branch 비교 ({PREV} → {RELEASE}) — **compare API 기반**:
  - client: compare 총 파일 [N]건 (Changed [N] / New [N] / Removed [N] / Renamed [N])
  - server: compare 총 파일 [N]건 (Changed [N] / New [N] / Removed [N] / Renamed [N]) 또는 "compare 실패 → glob fallback"
  - compare 커밋 수: client [N]건 / server [N]건
  - 커밋→티켓 매핑: {mapped}건 / {total}건
- GitHub PR: client {N}건 (merged {n1} / open {n2}) | server {M}건
  - PR target: {RELEASE}/Main {a}건 / {PREV}/Main {b}건
- PR→티켓 매핑: {mapped}건 / {total}건
- CHANGELOG 탐지 결과: 있음 [파일명] / 없음
- 조건부 grep 실행 여부:
  - 설정값 grep: HAS_CONFIG=[true/false] → [실행됨/조건 미충족으로 미탐색]
- repo Evidence: 배치 grep 실행 [N]회 / query 실행 [N]회
- compare→read 최적화: compare 확정 [N]건 (read 스킵) / compare 미포함 read [N]건
- compare truncated: [true/false] → [true: 커밋별 files API로 +{N}건 보충, 정규화 후 총 {N}건 / false: 300건 이내 — 보충 불필요]
- compare commits 상한: ahead_by {N} / 실반환 {M}건 [일치 / ⚠️ 250건 상한 도달 — {N-M}건 커밋 누락 가능]
- PR 상한: release {N}건 [OK / ⚠️ 100건 상한 도달] / prev {M}건 [OK / ⚠️ 100건 상한 도달]
- ticket_commit_files: {N}건 ({M}개 티켓) — source: "commit" Evidence 실현
- read 후보 선택 로그: `$TMPDIR/read_selection.log` ([N]건 기록, 범용 파일 fallback [N]건)
- Sub-Bug 통계 (`$TMPDIR/sub_bugs.json` — `is_other_release` 필드 기반 분기):
  - 총 sub-bug {N}건 ({M}개 부모 티켓에 분포)
  - 본 릴리스 회귀 대상 {S}건 (`is_other_release: false` 또는 미지정 — `${VERSION_NAME}`)
    - High/Highest priority {H}건 → STEP 4 개별 항목으로 승격
    - 그 외 {S-H}건 → 부모 통합 회귀로 커버
  - 다른 릴리스 sub-bug {O}건 (`is_other_release: true` — 회귀 대상 제외, 참고용)
    - fixVersion 분포: [예: 240.0 QA × 5건, 239.0 QA × 2건]
    - High/Highest 포함 여부 (포함되어도 STEP 4 승격 X — 이전 릴리스에서 처리됨)
  - fixVersion 미지정 sub-bug {U}건 (있을 때만) — 보수적으로 본 릴리스 회귀 대상에 포함, 개발팀 확인 권고
  - ⚠️ 미해결 sub-bug {K}건 (있을 때만): [부모 키 / sub-bug 키 / status / fixVersion 목록] — 본 릴리스 미반영, 개발팀 확인 필요
- 확인한 영역:
- 샘플링만 한 영역: (Sampled 상태 파일이 있으면 해당 디렉토리 명시)
- 확인 못한 영역:
- 추가 조사 권고:

[수집 실패] (`$TMPDIR/fetch_failed.txt` 기반)
- Critical {N}건 — 분석 신뢰도 영향 큼 (상위 티켓/검색 누락 시 결과는 부분 분석):
  - search: page_{P} (HTTP {code})
  - issue: {KEY} (HTTP {code})
- Partial {M}건 — 항목 누락 가능 (Sub-Bug/PR 매핑/외부링크/기획서):
  - remotelink: {KEY} (HTTP {code})
  - subtask: {KEY} (HTTP {code})
  - devstatus: {KEY} (HTTP {code})
  - confluence: page {PAGE_ID} (HTTP {code})
- 실패 0건이면: `(수집 실패 없음)` 한 줄로 표시
```

> **[수집 실패] 렌더링 규칙**: `$TMPDIR/fetch_failed.txt`(TSV: TIER\tENDPOINT\tKEY\tHTTP_CODE)를 직접 읽어 critical/partial로 분리해 위 형식으로 출력한다. 파일이 없거나 비어있으면 `(수집 실패 없음)`으로 표시한다. **Critical 1건 이상이면 분석 보고에 "부분 분석"임을 명시**한다 (versions 실패는 exit 1로 STEP 5 도달 불가, search/issue critical만 여기서 처리).

### 분석 결과 파일 저장 [STEP 5 출력 직후 실행]

STEP 3~5의 대화 출력 내용을 `$TMPDIR/analysis_output.md`에 저장한다. 컨텍스트 윈도우가 압축되어도 STEP 6 Slack 전송 시 이 파일을 읽어 메시지를 구성할 수 있다.

저장 내용:
- 트리아지 요약 (확인 대상 N건 / 제외 N건 — `$TMPDIR/triage.json` 참조)
- STEP 3: 각 코드 확정 티켓의 테스트 방법 + 영향 범위 + 기획서 비교
- STEP 3: 각 코드 미확인 티켓의 설명 기반 테스트 방법
- STEP 3-D: Evidence 요약 테이블
- STEP 4: 최종 QA 체크리스트
- STEP 5: 분석 커버리지 보고

**Write 도구**로 `$TMPDIR/analysis_output.md`에 아래 내용을 저장한다 (bash heredoc이 아니라 Write 도구를 사용해야 한다):

- STEP 3: 각 Deep 티켓의 테스트 방법 + 영향 범위 + 기획서 비교 (대화에 출력한 내용 그대로)
- STEP 3-D: Evidence 요약 테이블
- STEP 4: 최종 QA 체크리스트
- STEP 5: 분석 커버리지 보고

`$TMPDIR` 경로는 Bash 도구로 `echo $TMPDIR`을 실행해 절대 경로를 확인한 뒤, 그 절대 경로를 Write 도구의 `file_path`에 전달한다.

> STEP 6 시작 시 컨텍스트가 부족하면 `$TMPDIR/analysis_output.md`를 Read 도구로 읽어 Slack 메시지를 구성한다.

---

## STEP 6: Slack 보고 [선택 실행]

> **사용 도구**: Slack MCP 서버의 `slack_send_message` 도구를 사용한다. MCP 서버가 연결되지 않은 환경에서는 이 STEP을 스킵하고 `$TMPDIR/analysis_output.md` 파일 경로를 안내한다.

STEP 4~5 결과를 대화에 먼저 출력한다. 그 후 `AskUserQuestion`으로 Slack 전송 여부를 묻는다.

```
question: "Slack #qa-ai-report 채널에 분석 결과를 전송할까요?"
options:
  - label: "전송", description: "Slack 채널에 QA 분석 결과 전송"
  - label: "생략", description: "Slack 전송 없이 종료"
```

"생략" 선택 시 STEP 6은 스킵하고 종료한다.
"전송" 선택 시 아래 형식으로 `#qa-ai-report` 채널(ID: `C0AQTSRRFHC`)에 전송한다.

#### 형식 규칙 (전체 공통)
- Slack Block Kit은 사용하지 않는다. 일반 텍스트(`mrkdwn`)로 전송한다
- **이모지 최소화**: 불필요한 이모지를 넣지 않는다. 텍스트 위주로 작성한다
- 이탤릭(`_텍스트_`)은 버전·제목 강조, 볼드(`*텍스트*`)는 섹션 헤더에 활용한다
- **테스터용 정보와 분석 상세를 분리**한다: 티켓 스레드(6-2)에는 테스트 방법만, Evidence/기획서비교/Confidence는 분석 원문(6-5)에

#### 6-1. 타이틀 메시지 전송

첫 번째 메시지로 분석 개요를 보낸다. 이 메시지에는 스레드를 달지 않는다:

```
_release-diff {RELEASE} 분석 결과_
client: Develop/${RELEASE}/Main | server: ${RELEASE}.0/Main
확인 대상 {N}건 (코드 확정 {N} / 코드 미확인 {N}) / 제외 {N}건
```

#### 6-2. 코드 확정 티켓별 메시지 + 스레드

각 코드 확정 티켓(내부 Deep)마다 **별도 메시지**를 보내고, 해당 메시지에 **스레드로 테스트 방법**을 단다.
Bug 타입 티켓을 먼저 보내고, 그 외 타입을 우선순위 순으로 보낸다.

**부모 메시지** (채널에 노출 — 담당자명 + Jira 링크 포함):
```
_릴리스 {RELEASE}_
*[CVS-XXXXX]* 티켓 제목
타입: Bug | 우선순위: High | 담당: 홍길동
{JIRA_BASE}/browse/CVS-XXXXX
```

**스레드 답글** — 테스터용 정보만 (Evidence/기획서비교/Confidence는 6-5 분석 원문으로 분리):
```
*테스트 방법*
진입 경로: [...]
전제 조건: [...]

*확인 포인트*
1. [...]
2. [...]

*예상 결과*
- [...]

*영향 범위*
- 직접: [같이 확인해야 하는 기능 — 코드 경로가 아닌 기능명으로 기술]
- 간접: [영향 가능성 있는 기능]
```

> 스레드에 **포함하지 않는 항목** (→ 6-5 분석 원문으로 이동):
> - `Evidence: [코드 위치] (Changed/New/Removed)` — 테스터에게 불필요한 코드 경로
> - `기획서 비교` (일치/불일치) — 분석 상세
> - `Confidence: High/Medium/Low` — 메타 분석 정보
>
> Evidence 제거로 스레드 크기가 대폭 줄어 5000자 초과가 거의 발생하지 않는다. 만약 초과 시 영향 범위를 두 번째 스레드 답글로 분리한다.

#### 6-3. 코드 미확인 티켓별 메시지 (축약형 스레드 포함)

각 코드 미확인 티켓(내부 Light)마다 **개별 부모 메시지**를 보내고, **축약형 스레드 1개**를 달아 설명 기반 테스트 방법을 전달한다. 담당자가 자기 티켓을 채널에서 바로 찾을 수 있도록 코드 확정 티켓과 동일하게 개별 메시지로 전송한다.

**부모 메시지**:
```
_릴리스 {RELEASE}_
*[CVS-XXXXX]* 티켓 제목
타입: Story | 담당: 김철수 | 코드 미확인 (설명 기반)
{JIRA_BASE}/browse/CVS-XXXXX
```

**스레드 답글** (축약형 — 1개):
```
*설명 기반 테스트 방법*
진입 경로: [...]
전제 조건: [...]

*확인 포인트*
1. [...]
2. [...]

*예상 결과*
- [...]

_Evidence: [triage.json 기반 — UNCHANGED면 "코드 미확인 (UNCHANGED) — {파일명}", 0 hits면 "코드 미확인 (0 hits, {사유})", 별도 repo면 "코드 미확인 (별도 repo)"]_
_기능 동작 수준에서 직접 확인 필요_
```

> 코드 미확인 티켓이 0건이면 6-3을 건너뛴다.
> **순차 전송 필수**: 코드 미확인 티켓 메시지는 우선순위 순으로 **1건씩 순차 전송**한다. 병렬 전송하면 Slack에서 메시지 순서가 보장되지 않아 정렬 의도가 깨진다.

#### 6-4. QA 체크리스트 메시지 + 스레드

**부모 메시지**:
```
_릴리스 {RELEASE}_
*QA 체크리스트*
```

**스레드 답글** — 근거 텍스트 제거, 액션 중심으로 작성한다 (근거는 6-5 분석 원문에서 확인):
```
*코드 확정 — 필수 확인 (High)*
[ ] [CVS-XXXXX] 기능명 -- 확인 포인트
[ ] [CVS-YYYYY] 기능명 -- 확인 포인트

*코드 확정 — 추가 확인 (Medium)*
[ ] 기능명 -- 확인 포인트

*코드 미확인 — 직접 확인 필요*
[ ] [CVS-XXXXX] 기능명 -- 확인 포인트
```

> 체크리스트가 5000자를 초과하면 High/Medium과 Light를 별도 스레드 답글로 분리한다.

#### 6-5. 분석 원문 (Evidence + 커버리지 통합)

6-2/6-3/6-4에서 제거한 분석 상세(Evidence, 기획서 비교, Confidence, 커버리지 보고)를 한 곳에 모아 보낸다. QA 리드/매니저가 분석 깊이와 신뢰도를 확인하는 용도다.

**부모 메시지**:
```
_릴리스 {RELEASE}_
*분석 원문* -- Evidence 및 상세 분석
```

**스레드 답글 1**: Evidence 요약 + 티켓별 상세

> **Slack은 마크다운 테이블을 지원하지 않는다.** 불릿 리스트(`•`)로 작성한다.

```
*Evidence 요약*

• CVS-XXXXX | Bug | Assets/.../SlotManager.cs | Changed | SlotManager
• CVS-YYYYY | Story | src/logic/reward.ts | New | reward
• CVS-ZZZZZ | Task | - | 미확인 | Xsolla, Facebook

*티켓별 상세*

_[CVS-XXXXX]_ 티켓 제목
Evidence: Assets/SlotMaker/SlotManager.cs (Changed)
Confidence: High
기획서 비교: 일치 — [요약]

_[CVS-YYYYY]_ 티켓 제목
Evidence: 코드 위치 미확인
Confidence: Low
기획서 비교: 미확인 — https://docs.google.com/...
```

**스레드 답글 2**: 커버리지 보고 (STEP 5 내용)
```
*분석 커버리지*

Jira: 상위 티켓 {N}건 (Bug {N} / 새 기능 {N} / 개선 {N} / Development {N})
분류: 확인 대상 {N}건 (코드 확정 {N} / 코드 미확인 {N}) / 제외 {N}건
기획서: 링크 {N}건 / 확인 {N}건 / 미확인 {N}건
Cross-Branch (compare): client Changed {N} / New {N} / Removed {N} (커밋 {N}건) | server Changed {N} / New {N} / Removed {N}

확인한 영역: [...]
확인 못한 영역: [...]
추가 조사 권고: [...]
```

> 5000자 초과 시: Evidence 테이블(답글1) + 티켓별 상세(답글2) + 커버리지(답글3)로 분리한다.

#### 6-6. 전송 순서 및 실패 처리

전송 순서: 6-1 → 6-2 코드 확정 (Bug 우선, 그 다음 우선순위 순) → 6-3 코드 미확인 (우선순위 순) → 6-4 → 6-5
각 단계에서 부모 메시지 전송 결과의 `thread_ts`를 받아 스레드 답글에 사용한다.

전송 실패 시: 실패한 메시지를 1회 재시도한다. 재시도도 실패하면 "Slack 전송 실패: [메시지 종류]"를 대화에 출력하고 다음 메시지로 넘어간다.

---

## 절대 원칙

1. STEP 1.5 compare API 또는 STEP 2 cross-branch read 비교로 Changed/New/Removed가 확정된 파일만 "이번에 변경됐다"고 말할 수 있다. compare API가 가장 정확한 소스이며, grep/glob hit만으로는 "현재 브랜치에 존재한다"는 뜻이다
2. Evidence 없이 "문제 없음"이라고 결론내리지 마라
3. 3-B 영향 범위와 티켓 분석이 충돌하면 그 차이를 명시적으로 보고하라
4. 마지막에 반드시 커버리지 한계를 써라
5. 티켓 설명이 없으면 코드 탐색 비중을 높여라

## 금지 사항

- 단순 티켓 목록 나열로 끝내지 마라
- 티켓 제목만 보고 영향 범위를 추정하지 마라
- "전체를 다 봤다"고 말하지 마라
- "영향 없음"을 근거 없이 단정하지 마라
- 티켓별 개별 grep을 반복하지 마라 (배치 grep으로 대체)
- query를 3-A query 호출 제한 조건(A: Bug+High, B: 새 기능/개선+중요+Need Review/완료+0 hits, C: 완료/Need Review+grep hits>0+hit 파일 모두 범용+D규칙 포함 모두 UNCHANGED) 외 티켓에 사용하지 마라
- grep 0 hits가 나왔을 때 바로 "코드 위치 미확인"으로 끝내지 마라. 하위 작업 설명을 먼저 확인하고 키워드를 재추출해 1회 재시도하라
- 상위 티켓 제목이 추상적이면 (기능명·제품명 수준) 하위 작업 설명을 반드시 읽어라. 구체 기술 키워드는 하위 작업에 있다
- `Need Review` 상태를 "미완료"로 해석하지 마라. 개발팀 완료 사인이므로 QA 분석 대상이다
- glob count:0이 나왔을 때 "해당 경로에 파일 없음"으로 확정하지 마라. 실제 client 디렉토리 구조(`Assets/Meta/`, `Assets/Contents/` 등)에 맞는 패턴으로 재시도하라
- grep hit 파일을 근거 없이 바로 "Changed"로 단정하지 마라. compare API에서 modified/added/removed로 확정되거나, compare에 없는 파일은 2-3-B A규칙에 따라 HEAD+BASE read로 확정하라
- grep 0 hits가 나온 티켓을 아무 기록 없이 Light/Skip으로 조용히 처리하지 마라. 반드시 "0 hits 확인" 로그를 남기고 재시도 결과를 명시하라
- Bug 타입 티켓에서 파일 read를 생략하지 마라. 2-3-B C규칙에 따라 grep hit 유무와 무관하게 최소 1개 파일을 HEAD+BASE read하라
