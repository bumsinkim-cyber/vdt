---
name: ticket-qa
description: Jira 티켓 1건을 입력하면 PR/코드를 딥 다이브 분석해 테스트 방법·영향 범위·QA 체크리스트를 생성합니다. "/ticket-qa", "티켓 분석", "CVS-13353 QA" 요청 시 사용합니다.
---

# /ticket-qa — 단일 티켓 QA 딥 다이브 분석

> **판정 로직의 정본은 `evidence.py`이다.** 상태 enum, 등급 판정, 집계 로직을 변경할 때는 `evidence.py`만 수정한다. 이 문서(SKILL.md)는 수집·실행 절차를 정의하며, `evidence.py`의 출력을 소비한다. 판정 규칙을 이 문서에서 중복 정의하지 않는다.

### Artifact Contract

| 산출물 | 생산자 | 소비자 | 형식 | 비고 |
|--------|--------|--------|------|------|
| `ticket_detail.json` | STEP 0 | evidence.py, STEP 2 | JSON | Jira REST API 응답 원본 |
| `pr_info.tsv` | STEP 0 | evidence.py, STEP 1 | TSV | repo, pr_num, title, status, baseRefName |
| `pr_files_client_*.json` | STEP 1 A-1 | evidence.py | JSON | GitHub PR files API 응답 |
| `grep_*.txt` | STEP 1 B-1.5/B-2 | evidence.py, B-3 | JSON (repob --pretty) | grep valid: JSON parse 가능 + `count` 필드 존재 |
| `read_*_head.txt` / `read_*_base.txt` | STEP 1 B-1.5/B-3/1.4 | evidence.py | text (repob read) | read valid: `-s` (non-zero size) |
| `read_results/{repo}/` | STEP 1.4 | evidence.py | text | repo별 서브디렉토리 분리 필수 |
| `version_targets.txt` | STEP 0-7 | evidence.py, B-2 grep | text (1행 1버전명) | fixVersions 기반 |
| `callers.txt` | STEP 1 B-3 | evidence.py (caller 수집) | text (1행 1경로) | evidence_files에 caller 경로 포함 |
| `config_flags.txt` | STEP 1.4 | evidence.py | JSON lines | |
| `server_query_result.txt` | STEP 1 B-2.5 | evidence.py | JSON 또는 plain text | |
| `evidence.json` | evidence.py | STEP 2, STEP 3 | JSON | 최종 판정 결과 (정본) |
| `analysis_output.md` | STEP 3 (Write 도구) | 사용자 | Markdown | 상세 분석본 |
| `slack_output.md` | STEP 3 (Write 도구) | Slack/Jira | Markdown | 요약본 (Evidence 제외) |
| `subtask_regression.tsv` | STEP 0-4.5 | STEP 2-7 | TSV | 회귀 항목 (key, issuetype, priority, summary). High/Highest 개별 승격 |
| `subtask_new_impl.tsv` | STEP 0-4.5 | STEP 2-7 | TSV | 신규 구현 하위 작업 (분석 대상). 동일 컬럼 |
| `pr_fallback_search.json` | STEP 0-5-F-1 | STEP 0-5-F-3 merge | JSON | gh pr list --search 결과 (tmp→validate→mv) |
| `pr_fallback_head.tsv` | STEP 0-5-F-2 | STEP 0-5-F-3 merge | TSV | branch head matching 결과 (state 정규화 완료) |
| `branch_candidates.txt` | STEP 0-5-F-2 | STEP 0-5-F-2 head matching 루프 | text (1행 1브랜치) | summary+description+subtask에서 추출한 브랜치 후보 |
| `pr_fallback_closed_unmerged.tsv` | STEP 0-5-F-3 | STEP 2 (참고용) | TSV | closed unmerged PR — 분석 제외, 참고만 |
| `pr_fallback_*_unverified.flag` | STEP 0-5-F-1/2 | STEP 2-6/2-7 | empty file | gh API 호출 실패 또는 응답 JSON 검증 실패 시 생성 (보조 단계 미검증) |

### repob write 안정성 규칙

STEP 1의 모든 `$REPOB remote grep`/`$REPOB remote read` 호출은 아래 패턴을 따른다:

1. **grep**: tmp 파일에 기록 → JSON parse + `count` 필드 존재 검증 → 통과 시 본 파일로 `mv`
2. **read**: tmp 파일에 기록 → `-s` (non-zero size) 검증 → 통과 시 본 파일로 `mv`
3. **보존 규칙**: 본 파일이 이미 valid하면 (`-s` + grep은 JSON parse 통과) 덮어쓰지 않는다

```bash
# grep valid 검증 함수 (예시 — 실행용 아님)
_grep_valid() {
  local F="$1"
  [ -s "$F" ] || return 1
  $PYTHON -c "import json,sys; d=json.load(open(sys.argv[1],encoding='utf-8')); assert 'count' in d" "$F" 2>/dev/null
}

# read valid 검증 함수 (예시 — 실행용 아님)
_read_valid() { [ -s "$1" ]; }
```

> **실행 환경**: 이 스킬의 bash 명령은 Claude Code Bash 도구 기준으로 작성됐다. Windows에서는 Git Bash 환경에서 실행된다. PowerShell에서 직접 실행하면 동작하지 않는다.

### 파일 루프 패턴 (필독 — repob 호환성 + 셸 호환성)

> **⚠️ 두 가지 동시 위반 금지**:
> 1. **`while read ... done < file` 안에서 직접 repob 호출 금지** — `done < file`은 루프 전체의 stdin을 리다이렉트한다. repob는 stdin이 파일로 리다이렉트되면 0B를 반환한다.
> 2. **`for-in $(cat file)` 금지** — 공백이 포함된 경로를 분할한다.
> 3. **`mapfile -t` 금지** — bash 4+ 빌트인이라 macOS 기본 `/bin/bash` 3.2와 zsh에서 미동작. cross-platform 스킬에서 사용 불가.
>
> **정본 패턴 (portable while-read 배열 빌드 + 별도 for 루프)**:
> - 배열 빌드 단계: `while IFS= read -r ... done < file`로 배열에 로드 (stdin 리다이렉트는 빌드 단계에 한정 — repob 호출 안 함)
> - 사용 단계: `for ITEM in "${ARRAY[@]}"` 안에서 repob 호출 (이 시점엔 stdin 자유)
> - 빈 라인 skip + `tr -d '\r\n'` Windows CRLF 제거
> - bash 3.2 + bash 4+ + zsh 모두 호환
>
> ```bash
> # ✅ 정본 패턴 (예시)
> _FILES=()
> while IFS= read -r _LINE || [ -n "$_LINE" ]; do
>   [ -z "$_LINE" ] && continue
>   _FILES+=("$_LINE")
> done < "$TMPDIR/targets.txt"
>
> for FILE_PATH in "${_FILES[@]}"; do
>   FILE_PATH=$(echo "$FILE_PATH" | tr -d '\r\n')
>   [ -z "$FILE_PATH" ] && continue
>   SAFE=$(echo "$FILE_PATH" | sed 's|/|_|g')
>   $REPOB remote read client "$TARGET_BRANCH" "$FILE_PATH" --pretty > "$TMPDIR/read_${SAFE}_head.txt"
> done
>
> # ❌ 금지 패턴
> mapfile -t FILES < file                              # bash 3.2 / zsh 미지원
> while IFS= read -r X; do repob ...; done < file      # repob에 stdin 리다이렉트
> for X in $(cat file); do ... done                    # 공백 경로 분할
>
> # process substitution은 bash 3.2/zsh 둘 다 일부 케이스에서 불안정 → 임시 파일 경유
> # ❌ mapfile -t ARR < <(tail ... )
> # ✅ tail ... > "$TMPDIR/.tmp_X.txt" 후 위 정본 패턴으로 read
> ```

### 코드 블록 실행 규칙 (필독)

1. **블록 분리 금지**: 이 스킬의 각 코드 블록은 **하나의 Bash 호출로 실행**한다. 병렬화·최적화 목적으로 블록을 쪼개거나 재구성하지 않는다. 블록이 길어도 그대로 실행한다.
2. **설계 의도 주석 필독**: 코드 블록 상단에 `> **설계 의도**` 또는 `# ⚠️` 주석이 있으면 반드시 읽고 이해한 뒤 실행한다. 해당 주석은 과거 실패 경험에서 도출된 제약이다.
3. **대기 로직 생략 금지**: `sleep`/`while` 대기 루프가 포함된 블록에서 대기 부분을 건너뛰지 않는다. 대기 시간이 길어도(최대 180초) 완료까지 기다린다.

### gh API / 외부 응답 처리 규칙 (필독)

> 외부 API 응답(`gh api`, `curl` 등)을 Python에 넘길 때는 **직접 파이프 또는 파일 경유**를 사용한다. `VAR=$(...)` + `echo "$VAR" | python` 두 단계 패턴은 **금지**한다.
>
> **이유**: 큰 JSON 응답에 PR body·description의 control character(`\r`, `\n`, 0x01–0x1F)가 포함되면 bash 변수 캡처 + `echo` 출력 과정에서 손상되어 `json.load(sys.stdin)`이 `Invalid control character at: ...`로 실패한다 (CVS-10785 PR #422 케이스에서 실측 확인). 직접 파이프와 파일 경유는 stdout이 stdin/파일로 직결되어 control character가 보존된다.

| 패턴 | 안전성 | 예시 |
|---|---|---|
| ✅ 직접 파이프 | 안전 | `gh api ... \| $PYTHON -c "import json,sys; d=json.load(sys.stdin); ..."` |
| ✅ 파일 경유 | 안전 | `gh api ... > "$TMPDIR/x.json" && $PYTHON -c "...json.load(open('$TMPDIR/x.json'))..."` |
| ❌ 변수 + echo 파이프 | **금지** | `RESP=$(gh api ...); echo "$RESP" \| python` |

큰 응답을 두 번 이상 파싱해야 하면 파일 경유를 쓰고, 한 번만 파싱하면 직접 파이프가 단순하다.

### JSON 결과 파일의 빈 list 검사 (`-s` 함정 주의)

`json.dump([], f)`는 항상 `[]` (2바이트)를 기록하므로 `[ ! -s file.json ]` 조건이 통과하지 않는다. 결과가 비었는지 검사하려면:

- 명령 성공/실패 카운터(`SEARCH_OK == 0`)로 판정하거나
- Python으로 `len(json.load(...)) == 0` 직접 확인

`-s` 검사로 "결과 0건"을 판정하지 않는다.

### 블록 자립성 원칙 (필독)

이 스킬은 **이전 Bash 블록의 셸 상태를 신뢰하지 않는다.** Claude Code의 Bash 도구는 블록 간 환경변수를 유지하지 않는다. 따라서:

- **자유 텍스트 저장**은 셸 HEREDOC가 아니라 **Write/Edit 도구**를 사용한다.
- **persist 대상**은 비밀값이 아닌 "재계산 비용이 있거나 이미 결정된 런타임 결과"만 `$TMPDIR/run_context.json`에 저장한다.
- **비밀값(JIRA_AUTH)**은 run_context.json에 넣지 않는다. Jira 호출이 필요한 블록은 매번 `~/.bagelcode/jira.json`에서 email/token을 읽어 조합한다.
- 각 블록은 필요한 값만 `$TMPDIR`와 `run_context.json`에서 읽는다.

### 공통 부트스트랩 (정본)

**적용 범위**: run_context.json이 생성된 이후의 모든 standalone Bash 블록 (STEP 1 이후)에 아래 부트스트랩을 **그대로** 붙인다. STEP 0 내부 블록은 아직 run_context.json이 없으므로 부트스트랩을 사용하지 않는다. 수정/축약/변형하지 않는다.

> **아래 코드 블록은 형식 예시이다 (직접 실행 대상 아님).** `{입력받은 티켓 키}` 등 placeholder를 실제 값으로 치환한 뒤 각 STEP 블록 앞에 삽입한다.

```bash
# ── 공통 부트스트랩 (정본 — 수정 금지) ──
TICKET_KEY={입력받은 티켓 키}
export TMPDIR="$(cygpath -m /tmp 2>/dev/null || echo /tmp)/ticket-qa-${TICKET_KEY}"
PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)
CTX="$TMPDIR/run_context.json"

[ -f "$CTX" ] || { echo "ERROR: run_context.json not found: $CTX"; exit 1; }
```

그 다음, **해당 블록에 필요한 키만** run_context.json에서 추출한다:

```bash
# 블록별 필요한 키만 추출 (전부 복원하지 않는다)
REPOB=$($PYTHON -c "import json,sys; print(json.load(open(sys.argv[1], encoding='utf-8'))['repob'])" "$CTX")
TARGET_BRANCH=$($PYTHON -c "import json,sys; print(json.load(open(sys.argv[1], encoding='utf-8'))['target_branch'])" "$CTX")
SERVER_BRANCH=$($PYTHON -c "import json,sys; print(json.load(open(sys.argv[1], encoding='utf-8'))['server_branch'])" "$CTX")
BASE_BRANCH=$($PYTHON -c "import json,sys; print(json.load(open(sys.argv[1], encoding='utf-8')).get('base_branch',''))" "$CTX")
SERVER_BASE_BRANCH=$($PYTHON -c "import json,sys; print(json.load(open(sys.argv[1], encoding='utf-8')).get('server_base_branch',''))" "$CTX")

# Jira 호출이 필요한 블록만 — 비밀값은 매번 jira.json에서 재구성
JIRA_JSON=$($PYTHON -c "import json,sys; print(json.load(open(sys.argv[1], encoding='utf-8'))['jira_json_path'])" "$CTX")
JIRA_BASE=$($PYTHON -c "import json,sys; print(json.load(open(sys.argv[1], encoding='utf-8'))['jira_base'])" "$CTX")
JIRA_EMAIL=$($PYTHON -c "import json,sys; print(json.load(open(sys.argv[1], encoding='utf-8'))['email'])" "$JIRA_JSON")
JIRA_TOKEN=$($PYTHON -c "import json,sys; print(json.load(open(sys.argv[1], encoding='utf-8'))['token'])" "$JIRA_JSON")
JIRA_AUTH="$JIRA_EMAIL:$JIRA_TOKEN"
```

### run_context.json 스키마

STEP 0에서 branch 결정까지 완료된 후 **1회만** 기록한다. 필수 키가 누락되면 즉시 중단한다.

| 키 | 필수 | 설명 |
|---|---|---|
| `ticket_key` | O | Jira 티켓 키 (예: CVS-13349) |
| `ticket_id` | O | Jira internal ID |
| `jira_json_path` | O | `~/.bagelcode/jira.json` 절대 경로 |
| `jira_base` | O | `https://{domain}` — jira.json의 domain에서 파생 |
| `repob` | O | repob 실행 파일 절대 경로 |
| `target_branch` | O | client 타겟 브랜치 |
| `server_branch` | O | server 타겟 브랜치 |
| `base_branch` | - | 이전 스프린트 client 브랜치 |
| `server_base_branch` | - | 이전 스프린트 server 브랜치 |

**제외 항목**: `jira_auth`, `email`, `token` — 비밀값은 저장하지 않는다.

### 임시 파일 경로 (Windows 호환)

Git Bash의 `/tmp`는 Python에서 접근 불가할 수 있다. 모든 임시 파일은 `$TMPDIR`을 사용한다.
**TMPDIR 초기화는 STEP 0에서 TICKET_KEY 변수 확정 직후에 실행한다.** 아래 코드 블록은 STEP 0 참고용이다.

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
question: "분석할 Jira 티켓 키를 Other에 직접 입력해 주세요."
options:
  - label: "예시",  description: "CVS-13353  ← Other에 이 형식으로 입력"
```

입력값이 `[A-Z]+-\d+` 형식이 아니면 같은 질문으로 한 번 더 묻는다.

---

## Jira 인증 설정

인증 정보는 `~/.bagelcode/jira.json`에서 읽는다.

```bash
PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)
JIRA_JSON="$(cygpath -m "$HOME/.bagelcode/jira.json" 2>/dev/null || echo "$HOME/.bagelcode/jira.json")"

# 파일 존재 및 JSON 유효성 사전 검사 (파싱 전에 실행해 Python 에러 대신 친절한 안내 출력)
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
JIRA_AUTH="$JIRA_EMAIL:$JIRA_TOKEN"
JIRA_BASE="https://$JIRA_DOMAIN"
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
  echo "ERROR: repob 미발견 — 코드 탐색 불가. 스킬 실행을 중단합니다."
  echo "bagel-marketplace 플러그인 설치 또는 PATH에 repob 추가 후 재실행하세요."
  exit 1
fi
```

---

## STEP 0: 초기화 + 티켓 수집

### 0-1. TMPDIR 초기화

> **아래 코드 블록은 형식 예시이다.** `{입력받은 티켓 키}`를 실제 값으로 치환해 실행한다.

```bash
TICKET_KEY={입력받은 티켓 키}   # 예: CVS-13353

# TMPDIR 초기화 — TICKET_KEY 확정 직후, 다른 STEP보다 먼저 실행
export TMPDIR="$(cygpath -m /tmp 2>/dev/null || echo /tmp)/ticket-qa-${TICKET_KEY}"
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"
```

### 0-2. Jira 티켓 상세 fetch

```bash
curl -s -u "$JIRA_AUTH" \
  "$JIRA_BASE/rest/api/2/issue/${TICKET_KEY}?fields=summary,description,status,priority,assignee,issuetype,fixVersions,subtasks,comment,issuelinks&expand=renderedFields" \
  -o "$TMPDIR/ticket_detail.json"
```

결과에서 추출할 항목:
- `summary` — 티켓 제목
- `description` — 설명 본문
- `status.name` — 상태
- `priority.name` — 우선순위
- `assignee.displayName` — 담당자
- `issuetype.name` — 타입 (Bug, Story, Development 등)
- `fixVersions` — 릴리즈 버전
- `subtasks` — 하위 작업 목록
- `comment.comments` — 댓글
- `issuelinks` — 연결된 이슈

### 0-3. Jira internal ID 추출

dev-status API에 필요한 internal ID를 추출한다.

```bash
TICKET_ID=$($PYTHON -c "
import json, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
d = json.load(open('$TMPDIR/ticket_detail.json', encoding='utf-8', errors='replace'))
print(d['id'])
")
```

### 0-4. 하위 작업 description fetch (병렬)

하위 작업이 있으면 각각의 description을 가져와 키워드 추출에 활용한다. 병렬 curl로 수집한다.

```bash
$PYTHON -c "
import json, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
d = json.load(open('$TMPDIR/ticket_detail.json', encoding='utf-8', errors='replace'))
subs = d.get('fields', {}).get('subtasks', [])
for s in subs:
    print(s['key'])
" > "$TMPDIR/subtask_keys.txt"

_JOB_COUNT=0
while read -r SUBKEY; do
  [ -z "$SUBKEY" ] && continue
  curl -s -u "$JIRA_AUTH" \
    "$JIRA_BASE/rest/api/2/issue/${SUBKEY}?fields=summary,description,issuetype,priority" \
    -o "$TMPDIR/subtask_${SUBKEY}.json" &
  _JOB_COUNT=$(( _JOB_COUNT + 1 ))
  if [ "$_JOB_COUNT" -ge 5 ]; then wait; _JOB_COUNT=0; fi
done < "$TMPDIR/subtask_keys.txt"
wait
```

### 0-4.5. 하위 작업 회귀/신규 분류

CVS 프로젝트에는 issuetype이 `하위 작업`이어도 summary prefix가 `[Bug]`, `[Re][Bug]`, `[Polish]`, `[Re][Polish]`인 사후 수정 작업이 다수 존재한다. 이들은 신규 구현 분석 대상이 아니라 **회귀 항목**으로 분리한다. 검증 케이스: CVS-13039.

**회귀 항목 조건 (둘 중 하나라도 충족):**
- `issuetype.name`이 `하위 버그`, `Sub-Bug`, `Sub-bug`, `버그`, `Bug` 중 하나
- summary 첫 토큰 prefix가 `[Bug]`, `[Re][Bug]`, `[Polish]`, `[Re][Polish]` (case-insensitive). 정규식: `^\s*\[(?:re\]\[)?(?:bug|polish)\]`

**주의:**
- `Profile Scene polish`처럼 prefix가 아닌 단어는 회귀로 잡지 않는다 (반드시 첫 토큰 위치).
- 회귀 항목도 **키워드 추출 풀에는 포함**한다 (B-1 스코프 유지).
- 신규 구현 분석 대상에서는 제외한다.

> ⚠️ heredoc 사용 — bash `$PYTHON -c "..."` 안에서 정규식 escape 충돌 회피 (B-1.5 패턴과 동일).

```bash
$PYTHON - "$TMPDIR" << 'PYEOF'
import json, sys, re, glob, os
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

tmpdir = sys.argv[1]

REGRESSION_TYPES = {'하위 버그', 'Sub-Bug', 'Sub-bug', '버그', 'Bug'}
PREFIX_RE = re.compile(r'^\s*\[(?:re\]\[)?(?:bug|polish)\]', re.IGNORECASE)

regression = []
new_impl = []

for f in sorted(glob.glob(os.path.join(tmpdir, 'subtask_*.json'))):
    try:
        sd = json.load(open(f, encoding='utf-8', errors='replace'))
        key = sd.get('key', '')
        fields = sd.get('fields', {})
        summary = fields.get('summary', '') or ''
        itype = (fields.get('issuetype') or {}).get('name', '') or ''
        # priority: 0-4 fetch fields=...,priority로 받아옴. 없으면 빈 문자열.
        priority = (fields.get('priority') or {}).get('name', '') or ''
        is_regression = (itype in REGRESSION_TYPES) or bool(PREFIX_RE.search(summary))
        # TSV 컬럼 순서: key, issuetype, priority, summary
        row = f'{key}\t{itype}\t{priority}\t{summary}'
        (regression if is_regression else new_impl).append(row)
    except Exception:
        continue

with open(os.path.join(tmpdir, 'subtask_regression.tsv'), 'w', encoding='utf-8') as w:
    w.write('\n'.join(regression) + ('\n' if regression else ''))
with open(os.path.join(tmpdir, 'subtask_new_impl.tsv'), 'w', encoding='utf-8') as w:
    w.write('\n'.join(new_impl) + ('\n' if new_impl else ''))

print(f'subtask 분류: 회귀 {len(regression)}건 / 신규 {len(new_impl)}건')
PYEOF
```

생성 파일 (Artifact Contract 추가):
- `$TMPDIR/subtask_regression.tsv` — 회귀 항목 (사후 수정 — 부모 영역 통합 회귀로 커버, priority가 `High`/`Highest`인 항목만 개별 승격). 컬럼: key, issuetype, priority, summary.
- `$TMPDIR/subtask_new_impl.tsv` — 신규 구현 하위 작업 (분석 대상). 동일 컬럼.

STEP 2-7 QA 체크리스트 출력 시 두 그룹을 분리해 표시한다 (신규 구현 = 분석 대상 / 회귀 = 회귀 확인 블록).

### 0-5. 브랜치 결정

dev-status API → PR baseRefName → fixVersions/sprint → AskUserQuestion fallback 순으로 브랜치를 결정한다.

```bash
# TICKET_ID는 이전 블록(0-3)에서 계산됐지만 셸 상태가 유지되지 않으므로 재추출
TICKET_ID=$($PYTHON -c "
import json, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
d = json.load(open('$TMPDIR/ticket_detail.json', encoding='utf-8', errors='replace'))
print(d['id'])
")

# dev-status + agile sprint 병렬 호출 (TICKET_ID 확정 후 둘 다 독립적으로 실행 가능)
curl -s -u "$JIRA_AUTH" \
  "$JIRA_BASE/rest/dev-status/latest/issue/detail?issueId=${TICKET_ID}&applicationType=GitHub&dataType=pullrequest" \
  -o "$TMPDIR/devstatus.json" &
curl -s -u "$JIRA_AUTH" \
  "$JIRA_BASE/rest/agile/1.0/issue/${TICKET_KEY}?fields=sprint" \
  -o "$TMPDIR/agile_sprint.json" 2>/dev/null &
wait

# PR 정보 파싱 → pr_info.tsv (repo, pr_num, title, status, baseRefName)
$PYTHON -c "
import json, sys, re
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
d = json.load(open('$TMPDIR/devstatus.json', encoding='utf-8', errors='replace'))
for det in d.get('detail', []):
    for pr in det.get('pullRequests', []):
        url = pr.get('url', '')
        title = pr.get('name', '')
        status = pr.get('status', '')
        dest = pr.get('destination', {}).get('branch', '') if 'destination' in pr else ''
        m = re.search(r'github\.com/([^/]+/[^/]+)/pull/(\d+)', url)
        if m:
            repo = m.group(1).split('/')[-1]
            pr_num = m.group(2)
            print(f'{repo}\t{pr_num}\t{title}\t{status}\t{dest}')
" > "$TMPDIR/pr_info.tsv"
```

#### 0-5-F. Client PR fallback (dev-status 누락 보완)

> **설계 의도**: Jira dev-status가 PR을 못 잡아도 실제 client PR이 존재하는 경우가 있다 (예: PR title/body에 ticket key가 없고 dev-status 매칭 실패 — CVS-10785에서 description branch head matching으로만 발견됨). client는 GitHub 접근 가능하므로 두 단계 fallback을 직접 시도한다. **server에는 동일 fallback을 적용하지 않는다 (server gh API 시도 금지 — 원본 원칙 유지).**
>
> 보조 단계 — gh API 호출 자체가 실패한 경우에만 unverified flag 남김. 결과 0건은 정상으로 처리.
>
> 실행 순서: 이 블록은 0-5 pr_info.tsv 생성 **직후**, 0-6 subtask dev-status fallback **이전**에 실행한다. 그래야 0-6의 "부모 PR 없음" 판정이 우리 fallback 결과까지 반영한다.

**0-5-F-1. 다중 키워드 PR search** — ticket key + 티켓 summary 영문 토큰 + 브랜치 path segment

> **설계 의도**: PR body가 markdown 링크 형식(`[제목](링크에-ticket-key)`)일 때 `gh pr list --search "$TICKET_KEY"`가 매칭에 실패한다 (CVS-10785 PR #422 케이스). title/plain body에 ticket key 글자가 노출되지 않으면 검색 자체가 0건. 따라서 ticket key 외에 (1) 티켓 summary의 영문 토큰 묶음 (2) `branch_candidates.txt`의 마지막 path segment를 보조 query로 추가 검색하고, 결과를 union+dedup한다. 모든 query 직렬 실행 (Mac Traps 회피).
>
> 부분 실패 허용: 일부 query가 실패해도 다른 query에서 결과가 잡히면 unverified 처리하지 않는다. 모든 query가 실패하고 결과도 0건인 경우에만 unverified flag.

```bash
# stale unverified flag 제거 (같은 TMPDIR에서 0-5-F만 재실행하는 경우 대비)
rm -f "$TMPDIR"/pr_fallback_*_unverified.flag

# 검색 query 후보 생성: ticket key + summary 영문 토큰 + branch path segment
# branch_candidates.txt는 0-5-F-2가 생성하는데, 이번엔 0-5-F-1이 그것까지 활용하도록
# 사전에 동일 추출 로직을 inline으로 실행한다.
$PYTHON - "$TMPDIR" "$TICKET_KEY" << 'PYEOF' > "$TMPDIR/pr_search_queries.txt"
import json, sys, re, os, glob
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
tmpdir, ticket_key = sys.argv[1], sys.argv[2]
queries = [ticket_key]

# (1) 티켓 summary 영문 토큰 묶음 — title에 ticket key 없는 PR도 잡힘
try:
    d = json.load(open(os.path.join(tmpdir, 'ticket_detail.json'), encoding='utf-8', errors='replace'))
    summary = d.get('fields', {}).get('summary', '') or ''
    tokens = re.findall(r'[A-Za-z][A-Za-z0-9]+', summary)
    if len(tokens) >= 2:
        queries.append(' '.join(tokens[:min(4, len(tokens))]))
    if len(tokens) >= 3:
        queries.append(' '.join(tokens[:3]))
except Exception:
    pass

# (2) 부모 + subtask description에서 브랜치 후보 path segment
text = ''
try:
    d = json.load(open(os.path.join(tmpdir, 'ticket_detail.json'), encoding='utf-8', errors='replace'))
    fields = d.get('fields', {})
    text = (fields.get('summary', '') or '') + '\n' + (fields.get('description', '') or '')
except Exception:
    pass
for f in sorted(glob.glob(os.path.join(tmpdir, 'subtask_*.json'))):
    try:
        sd = json.load(open(f, encoding='utf-8', errors='replace'))
        sf = sd.get('fields', {})
        text += '\n' + (sf.get('summary', '') or '') + '\n' + (sf.get('description', '') or '')
    except Exception:
        continue
for m in re.findall(r'(?:Features|Develop|develop|feature|hotfix|release)/[A-Za-z0-9_./\-]+', text):
    seg = m.strip().rstrip('.,;:)"\'').rsplit('/', 1)[-1]
    if re.match(r'^[A-Za-z][A-Za-z0-9_]+$', seg) and len(seg) >= 4:
        queries.append(seg)

# dedup 보존 순서, 빈 문자열 제거
seen, out = set(), []
for q in queries:
    q = q.strip()
    if q and q not in seen:
        seen.add(q); out.append(q)
for q in out:
    print(q)
PYEOF

# 각 query 직렬 검색 → 개별 tmp 파일에 저장 (Mac Traps 회피 — & 금지)
SEARCH_TOTAL=0
SEARCH_OK=0
QIDX=0

# portable while-read 배열 빌드 (mapfile은 bash 3.2/zsh 미지원)
_QUERIES=()
while IFS= read -r _LINE || [ -n "$_LINE" ]; do
  [ -z "$_LINE" ] && continue
  _QUERIES+=("$_LINE")
done < "$TMPDIR/pr_search_queries.txt"

for QUERY in "${_QUERIES[@]}"; do
  QIDX=$(( QIDX + 1 ))
  SEARCH_TOTAL=$(( SEARCH_TOTAL + 1 ))
  gh pr list \
    --repo bagelcode-cvs/client \
    --state all \
    --search "$QUERY" \
    --json number,title,mergedAt,state,baseRefName \
    --limit 30 \
    > "$TMPDIR/.tmp_pr_search_${QIDX}.json" 2>/dev/null </dev/null
  if [ $? -ne 0 ]; then
    rm -f "$TMPDIR/.tmp_pr_search_${QIDX}.json"
    continue
  fi
  if $PYTHON -c "import json,sys; d=json.load(open(sys.argv[1],encoding='utf-8')); assert isinstance(d, list)" "$TMPDIR/.tmp_pr_search_${QIDX}.json" 2>/dev/null; then
    SEARCH_OK=$(( SEARCH_OK + 1 ))
  else
    rm -f "$TMPDIR/.tmp_pr_search_${QIDX}.json"
  fi
done

# 모든 query 결과 union+dedup → 본 파일
$PYTHON - "$TMPDIR" << 'PYEOF'
import os, json, sys, glob
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
tmpdir = sys.argv[1]
seen = set()
merged = []
for fp in sorted(glob.glob(os.path.join(tmpdir, '.tmp_pr_search_*.json'))):
    try:
        arr = json.load(open(fp, encoding='utf-8', errors='replace'))
        if isinstance(arr, list):
            for pr in arr:
                num = pr.get('number')
                if num is None or num in seen: continue
                seen.add(num); merged.append(pr)
    except Exception:
        continue
with open(os.path.join(tmpdir, 'pr_fallback_search.json'), 'w', encoding='utf-8') as w:
    json.dump(merged, w, ensure_ascii=False)
print(f'pr_fallback_search.json: {len(merged)}건 (dedup 후, query {len(list(glob.glob(os.path.join(tmpdir, ".tmp_pr_search_*.json"))))}개 union)')
PYEOF

# 모든 query 실패 시 unverified flag (부분 성공은 OK)
# ⚠️ `[ ! -s pr_fallback_search.json ]`로 결과 길이 검사 금지 —
#    Python이 빈 list라도 `[]` (2바이트)를 항상 기록하므로 -s 조건이 통과하지 않는다.
#    SEARCH_OK == 0 이면 결과는 자동으로 0건이라 길이 검사 불필요.
if [ "$SEARCH_OK" -eq 0 ] && [ "$SEARCH_TOTAL" -gt 0 ]; then
  : > "$TMPDIR/pr_fallback_search_unverified.flag"
fi

# 임시 파일 정리
rm -f "$TMPDIR"/.tmp_pr_search_*.json
```

**0-5-F-2. description branch head matching** — title/body에 key 없는 PR도 잡기

> ⚠️ heredoc 사용 — `[A-Za-z0-9_./\\-]+` 등 정규식 escape 충돌 회피.
> ⚠️ portable 배열 빌드 패턴 — `while read < file` 안에서 직접 gh API 호출하면 stdin 리다이렉트가 자식 명령에 영향 가능. 배열 빌드는 while-read로 받고 gh API 호출은 별도 for 루프에서 실행한다 (mapfile은 bash 3.2/zsh 미지원이라 사용 금지 — 헤더 정본 참고).
> ⚠️ gh api 응답은 변수 경유 금지 — 파일로 저장 후 Python이 직접 읽도록 한다 (PR body의 control character로 echo 파이프에서 JSON parse가 깨지는 문제. SKILL.md 상단 "gh API / 외부 응답 처리 규칙" 참조).

```bash
$PYTHON - "$TMPDIR" << 'PYEOF' > "$TMPDIR/branch_candidates.txt"
import json, sys, re, os, glob
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

tmpdir = sys.argv[1]

# 부모 티켓 summary + description
d = json.load(open(os.path.join(tmpdir, 'ticket_detail.json'), encoding='utf-8', errors='replace'))
fields = d.get('fields', {})
text = (fields.get('summary', '') or '') + '\n' + (fields.get('description', '') or '')

# 하위 작업 summary + description도 포함 (부모에 브랜치명이 없고 subtask에만 있을 수 있음)
for f in sorted(glob.glob(os.path.join(tmpdir, 'subtask_*.json'))):
    try:
        sd = json.load(open(f, encoding='utf-8', errors='replace'))
        sf = sd.get('fields', {})
        text += '\n' + (sf.get('summary', '') or '') + '\n' + (sf.get('description', '') or '')
    except Exception:
        continue

# 슬래시 포함된 브랜치형 토큰 추출 (영문/숫자/_/-/. 만 허용)
candidates = set()
for m in re.findall(r'(?:Features|Develop|develop|feature|hotfix|release)/[A-Za-z0-9_./\-]+', text):
    candidates.add(m.strip().rstrip('.,;:)"\''))
for c in sorted(candidates):
    print(c)
PYEOF

# 후보 브랜치마다 head matching 시도 (직렬 — 보조 단계)
# unverified flag는 gh api 호출 자체가 실패한 경우에만 남긴다.
# - 후보 0건 / matching 0건은 모두 정상 결과 (flag 없음)
: > "$TMPDIR/pr_fallback_head.tsv"
HEAD_FAILED=0
# portable while-read 배열 빌드 (mapfile은 bash 3.2/zsh 미지원 — 헤더 정본 참고)
_F_BRANCHES=()
while IFS= read -r _LINE || [ -n "$_LINE" ]; do
  [ -z "$_LINE" ] && continue
  _F_BRANCHES+=("$_LINE")
done < "$TMPDIR/branch_candidates.txt"
for BRANCH in "${_F_BRANCHES[@]}"; do
  BRANCH=$(echo "$BRANCH" | tr -d '\r\n')
  [ -z "$BRANCH" ] && continue

  # ⚠️ 변수 경유 echo 금지 — gh api 응답에 PR body의 control character(\r\n 등)가
  #    포함되면 `echo "$RESP" | python`에서 JSON parse 실패한다. 반드시 파일 경유로 처리.
  #    (CVS-10785 PR #422 케이스: 응답은 정상 15KB JSON이었지만 echo 파이프에서 깨졌음)
  _RESP_FILE="$TMPDIR/.tmp_head_resp.json"
  rm -f "$_RESP_FILE"
  gh api "repos/bagelcode-cvs/client/pulls?state=all&head=bagelcode-cvs:${BRANCH}&per_page=50" \
    > "$_RESP_FILE" 2>/dev/null </dev/null
  RC=$?

  # 빈 응답 / 빈 list `[]` / 실패면 1회 재시도 (transient gh API 실패 방어)
  _IS_EMPTY=0
  if [ $RC -ne 0 ] || [ ! -s "$_RESP_FILE" ]; then
    _IS_EMPTY=1
  else
    # 빈 list만 검사 — 공백/개행 제거 후 `[]`인지 확인 (control char 영향 없는 quick check)
    _TRIM=$(tr -d '[:space:]' < "$_RESP_FILE")
    [ "$_TRIM" = "[]" ] && _IS_EMPTY=1
  fi
  if [ "$_IS_EMPTY" = "1" ]; then
    sleep 1
    gh api "repos/bagelcode-cvs/client/pulls?state=all&head=bagelcode-cvs:${BRANCH}&per_page=50" \
      > "$_RESP_FILE" 2>/dev/null </dev/null
    RC=$?
  fi

  if [ $RC -ne 0 ]; then
    HEAD_FAILED=1
    continue
  fi
  [ ! -s "$_RESP_FILE" ] && continue

  # JSON list 검증 — 파일 경로로 직접 읽어 control char 영향 없음
  if ! $PYTHON -c "import json,sys; d=json.load(open(sys.argv[1],encoding='utf-8',errors='replace')); assert isinstance(d, list)" "$_RESP_FILE" 2>/dev/null; then
    HEAD_FAILED=1
    continue
  fi

  # 결과 추출 — 파일 경로로 읽기
  $PYTHON -c "
import json, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
try:
    arr = json.load(open(sys.argv[1], encoding='utf-8', errors='replace'))
    if isinstance(arr, list):
        for pr in arr:
            num = pr.get('number', '')
            title = (pr.get('title', '') or '').replace('\t',' ').replace('\n',' ').replace('\r',' ')
            # state 정규화: gh REST 응답은 closed로 옴. merged_at 있으면 merged로 변환
            # evidence.py는 status.lower()로 'merged'/'open'만 PR 확정 인식
            raw_state = (pr.get('state', '') or '').lower()
            merged_at = pr.get('merged_at')
            if raw_state == 'closed' and merged_at:
                state = 'merged'
            else:
                state = raw_state  # open / closed
            base = (pr.get('base') or {}).get('ref', '')
            print(f'client\t{num}\t{title}\t{state}\t{base}')
except Exception:
    pass
" "$_RESP_FILE" >> "$TMPDIR/pr_fallback_head.tsv"
done
rm -f "$TMPDIR/.tmp_head_resp.json"

# gh api 실패가 한 건이라도 있으면 unverified 플래그
if [ "$HEAD_FAILED" -eq 1 ]; then
  : > "$TMPDIR/pr_fallback_head_unverified.flag"
fi
```

**0-5-F-3. fallback 결과를 pr_info.tsv에 합산 + (repo, pr_num) dedup**

```bash
$PYTHON - "$TMPDIR" << 'PYEOF'
import os, json, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

tmpdir = sys.argv[1]
rows = []          # pr_info.tsv 본 결과 (open/merged + dev-status 원본)
closed_rows = []   # closed unmerged — 분석 대상 제외, 참고용으로만 보관
seen = set()

def _is_closed_unmerged(state):
    return (state or '').lower() == 'closed'

# 기존 dev-status 결과 — 그대로 유지 (dev-status가 보낸 PR은 신뢰)
try:
    for line in open(os.path.join(tmpdir, 'pr_info.tsv'), encoding='utf-8', errors='replace'):
        line = line.rstrip('\n')
        if not line: continue
        parts = line.split('\t')
        if len(parts) < 2: continue
        key = (parts[0], parts[1])
        if key in seen: continue
        seen.add(key); rows.append(line)
except FileNotFoundError:
    pass

# search fallback (gh pr list --search)
# state 정규화: gh pr list --json state는 'OPEN'/'CLOSED'/'MERGED' 대문자.
# evidence.py는 lower()로 'merged'/'open'만 PR 확정 인식. 'closed'는 무시(unmerged).
# CLOSED + mergedAt 있으면 merged로 변환 (방어적 처리 — 일반적으로 MERGED로 옴).
# closed unmerged는 pr_info.tsv에 넣지 않음 (PR files를 받아도 evidence.py가 코드 확정 오판할 수 있음).
try:
    arr = json.load(open(os.path.join(tmpdir, 'pr_fallback_search.json'), encoding='utf-8', errors='replace'))
    if isinstance(arr, list):
        for pr in arr:
            num = str(pr.get('number', ''))
            if not num: continue
            key = ('client', num)
            if key in seen: continue
            title = pr.get('title', '') or ''
            raw_state = (pr.get('state', '') or '').lower()
            merged_at = pr.get('mergedAt')
            if raw_state == 'closed' and merged_at:
                state = 'merged'
            else:
                state = raw_state  # open / closed / merged
            base = pr.get('baseRefName', '') or ''
            seen.add(key)
            row = f'client\t{num}\t{title}\t{state}\t{base}'
            if _is_closed_unmerged(state):
                closed_rows.append(row)  # 분석 대상 제외
            else:
                rows.append(row)
except Exception:
    pass

# head matching fallback (이미 0-5-F-2에서 closed/merged/open으로 정규화돼 있음)
# closed unmerged는 분석 대상에서 분리.
try:
    for line in open(os.path.join(tmpdir, 'pr_fallback_head.tsv'), encoding='utf-8', errors='replace'):
        line = line.rstrip('\n')
        if not line: continue
        parts = line.split('\t')
        if len(parts) < 2: continue
        key = (parts[0], parts[1])
        if key in seen: continue
        seen.add(key)
        state = parts[3] if len(parts) >= 4 else ''
        if _is_closed_unmerged(state):
            closed_rows.append(line)
        else:
            rows.append(line)
except FileNotFoundError:
    pass

with open(os.path.join(tmpdir, 'pr_info.tsv'), 'w', encoding='utf-8') as w:
    w.write('\n'.join(rows) + ('\n' if rows else ''))

# closed unmerged는 별도 참고 파일 — STEP 2 보고에서 "참고: closed unmerged PR" 한 줄로 인용 가능
with open(os.path.join(tmpdir, 'pr_fallback_closed_unmerged.tsv'), 'w', encoding='utf-8') as w:
    w.write('\n'.join(closed_rows) + ('\n' if closed_rows else ''))

print(f'pr_info.tsv: {len(rows)}건 (open/merged 분석 대상)')
if closed_rows:
    print(f'pr_fallback_closed_unmerged.tsv: {len(closed_rows)}건 (분석 제외 — 참고용)')
PYEOF
```

**보조 단계 unverified 처리 원칙:**
- `pr_fallback_search_unverified.flag`, `pr_fallback_head_unverified.flag`가 남으면 STEP 2-6 Evidence 섹션에 `PR fallback 미검증 — 분석은 핵심 단계 기준으로 진행됨` 한 줄 추가한다.
- **이 보조 단계 실패는 전체 분석 무효가 아니다.** 후속 STEP은 그대로 진행한다.
- 핵심 단계(Jira ticket fetch, subtask fetch, client PR files fetch, repob grep/read 핵심 분석) 실패 시에만 분석을 중단한다.
- **server에는 이 fallback을 적용하지 않는다.** server는 신규 ZIP의 A-3/B-2.5(repob grep/query) 경로만 사용한다.

**브랜치 결정 우선순위:**

1. **PR baseRefName이 있으면** → 해당 브랜치 사용 (예: `Develop/240/Main`)
2. **PR이 있지만 baseRefName이 비어있으면** → fixVersions에서 스프린트 번호 추출 → `Develop/{SPRINT}/Main`
3. **PR이 없으면** → fixVersions → sprint 필드 → 연결 이슈 dev-status → AskUserQuestion 순으로 시도

**3단계 상세 (PR 없는 경우):**

```bash
# 3-0. PR baseRefName 우선 채택 (PR이 있는 경우 — fallback 결과 포함)
# pr_info.tsv 5번째 컬럼(baseRefName)에서 첫 non-empty 값을 찾아 sprint 추출
# fixVersions가 비거나 틀린 경우에도 PR 자체의 base 브랜치를 신뢰
SPRINT=$($PYTHON -c "
import sys, re
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
try:
    for line in open('$TMPDIR/pr_info.tsv', encoding='utf-8', errors='replace'):
        parts = line.rstrip('\n').split('\t')
        if len(parts) >= 5 and parts[4]:
            m = re.search(r'(\d{3})', parts[4])
            if m:
                print(m.group(1))
                break
except Exception:
    pass
")

# 3-a. fixVersions에서 스프린트 번호 추출
# ⚠️ 3-0(baseRefName 우선)이 SPRINT를 채웠으면 skip — 조건 가드 필수.
#    이 가드 없으면 fixVersion이 PR base와 다를 때 잘못된 sprint로 덮어쓴다.
if [ -z "$SPRINT" ]; then
  SPRINT=$($PYTHON -c "
import json, sys, re
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
d = json.load(open('$TMPDIR/ticket_detail.json', encoding='utf-8', errors='replace'))
fv = d.get('fields', {}).get('fixVersions', [])
for v in fv:
    m = re.search(r'(\d{3})', v.get('name', ''))
    if m:
        print(m.group(1))
        sys.exit(0)
")
fi

# 3-b. sprint 필드에서 추출 (agile_sprint.json은 0-5 병렬 호출에서 이미 수집됨)
if [ -z "$SPRINT" ]; then
  SPRINT=$($PYTHON -c "
import json, sys, re
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
d = json.load(open('$TMPDIR/agile_sprint.json', encoding='utf-8', errors='replace'))
sprint = d.get('fields', {}).get('sprint') or {}
name = sprint.get('name', '')
m = re.search(r'(\d{3})', name)
if m: print(m.group(1))
" 2>/dev/null)
fi

# 3-c. 연결 이슈(issuelinks)의 dev-status에서 브랜치 추출
if [ -z "$SPRINT" ]; then
  SPRINT=$($PYTHON -c "
import json, sys, re
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
d = json.load(open('$TMPDIR/ticket_detail.json', encoding='utf-8', errors='replace'))
links = d.get('fields', {}).get('issuelinks', [])
for link in links:
    for direction in ('outwardIssue', 'inwardIssue'):
        issue = link.get(direction)
        if issue:
            # fixVersions에서 스프린트 번호 추출
            fv = issue.get('fields', {}).get('fixVersions', []) if 'fields' in issue else []
            for v in fv:
                m = re.search(r'(\d{3})', v.get('name', ''))
                if m:
                    print(m.group(1))
                    sys.exit(0)
" 2>/dev/null)

  # 연결 이슈의 fixVersions에 없으면 dev-status API로 PR base branch 확인
  if [ -z "$SPRINT" ]; then
    $PYTHON -c "
import json, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
d = json.load(open('$TMPDIR/ticket_detail.json', encoding='utf-8', errors='replace'))
links = d.get('fields', {}).get('issuelinks', [])
for link in links:
    for direction in ('outwardIssue', 'inwardIssue'):
        issue = link.get(direction)
        if issue:
            print(issue.get('key', ''))
" > "$TMPDIR/linked_keys.txt" 2>/dev/null

    while read -r LINKED_KEY; do
      [ -z "$LINKED_KEY" ] && continue
      LINKED_ID=$(curl -s -u "$JIRA_AUTH" "$JIRA_BASE/rest/api/2/issue/${LINKED_KEY}?fields=id" | $PYTHON -c "import json,sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace'); print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
      [ -z "$LINKED_ID" ] && continue
      LINKED_BRANCH=$(curl -s -u "$JIRA_AUTH" "$JIRA_BASE/rest/dev-status/latest/issue/detail?issueId=${LINKED_ID}&applicationType=GitHub&dataType=pullrequest" | $PYTHON -c "
import json, sys, re
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
d = json.load(sys.stdin)
for det in d.get('detail', []):
    for pr in det.get('pullRequests', []):
        dest = pr.get('destination', {}).get('branch', '') if 'destination' in pr else ''
        if dest:
            m = re.search(r'(\d{3})', dest)
            if m:
                print(m.group(1))
                sys.exit(0)
" 2>/dev/null)
      if [ -n "$LINKED_BRANCH" ]; then
        SPRINT="$LINKED_BRANCH"
        break
      fi
    done < "$TMPDIR/linked_keys.txt"
  fi
fi
```

스프린트 번호가 추출되면 `Develop/{SPRINT}/Main`으로 결정한다. 모든 방법 실패 시 AskUserQuestion으로 묻는다.

```
question: "타겟 브랜치를 Other에 직접 입력해 주세요."
options:
  - label: "예시",  description: "Develop/240/Main  ← Other에 이 형식으로 입력"
```

결정된 브랜치를 `$TARGET_BRANCH` 변수에 저장한다. server 브랜치는 `{SPRINT}.0/Main` 패턴으로 변환한다 (예: client `Develop/240/Main` → server `240.0/Main`).

```bash
# 이전 블록 셸 상태 불가 — TICKET_ID 재추출
TICKET_ID=$($PYTHON -c "
import json, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
d = json.load(open('$TMPDIR/ticket_detail.json', encoding='utf-8', errors='replace'))
print(d['id'])
")

# TARGET_BRANCH / SERVER_BRANCH 확정 (이후 모든 repob 호출이 이 변수를 전제로 실행됨)
if [ -n "$SPRINT" ]; then
  TARGET_BRANCH="Develop/${SPRINT}/Main"
  SERVER_BRANCH="${SPRINT}.0/Main"
fi

# AskUserQuestion 응답으로 TARGET_BRANCH가 설정된 경우 SERVER_BRANCH 파생
if [ -n "$TARGET_BRANCH" ] && [ -z "$SERVER_BRANCH" ]; then
  _SPRINT_NUM=$(echo "$TARGET_BRANCH" | grep -oE '[0-9]+' | head -1)
  SERVER_BRANCH="${_SPRINT_NUM}.0/Main"
  # SPRINT이 비어있으면 추출한 숫자로 보충 (BASE_BRANCH 계산에 필요)
  [ -z "$SPRINT" ] && SPRINT="$_SPRINT_NUM"
fi

# grep+read 비교용 BASE_BRANCH (이전 스프린트 기준, PR 없는 경우에 활용)
# SPRINT이 빈 문자열이면 산술 연산 실패하므로 가드 필수
if [ -n "$SPRINT" ]; then
  _PREV=$(( SPRINT - 1 ))
  BASE_BRANCH="Develop/${_PREV}/Main"
  SERVER_BASE_BRANCH="${_PREV}.0/Main"
fi

export TARGET_BRANCH SERVER_BRANCH BASE_BRANCH SERVER_BASE_BRANCH
echo "TARGET_BRANCH=$TARGET_BRANCH  SERVER_BRANCH=$SERVER_BRANCH  BASE_BRANCH=$BASE_BRANCH  SERVER_BASE_BRANCH=$SERVER_BASE_BRANCH"

# ── run_context.json 생성 (1회만) ──
# 모든 값을 셸 치환으로 전달한다. os.environ에 의존하지 않는다.
# 방식: STEP 0은 sys.argv 전달 (셸 변수가 아직 살아있는 같은 블록), STEP 1+ 단독 블록은 파일 직접 읽기.
JIRA_JSON_PATH="$(cygpath -m ~/.bagelcode/jira.json 2>/dev/null || echo "$HOME/.bagelcode/jira.json")"
$PYTHON - "$TMPDIR" "$TICKET_KEY" "$TICKET_ID" "$JIRA_JSON_PATH" "$JIRA_BASE" "$REPOB" "$TARGET_BRANCH" "$SERVER_BRANCH" "$BASE_BRANCH" "$SERVER_BASE_BRANCH" << 'PYEOF'
import json, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
_, tmpdir, ticket_key, ticket_id, jira_json_path, jira_base, repob, target_branch, server_branch, base_branch, server_base_branch = sys.argv
ctx = {
    'ticket_key':         ticket_key,
    'ticket_id':          ticket_id,
    'jira_json_path':     jira_json_path,
    'jira_base':          jira_base,
    'repob':              repob,
    'target_branch':      target_branch,
    'server_branch':      server_branch,
    'base_branch':        base_branch,
    'server_base_branch': server_base_branch,
}
missing = [k for k in ('ticket_key','ticket_id','jira_json_path','repob','target_branch','server_branch') if not ctx[k]]
if missing:
    print(f'ERROR: run_context.json 필수 키 누락: {missing}', file=sys.stderr)
    sys.exit(1)
import os
out = os.path.join(tmpdir, 'run_context.json')
with open(out, 'w', encoding='utf-8') as f:
    json.dump(ctx, f, ensure_ascii=False, indent=2)
print(f'run_context.json created: {out}')
PYEOF
```

### 0-7. version_targets.txt 생성 (fixVersions 기반)

`ticket_detail.json`의 `fixVersions`에서 버전명을 추출해 `version_targets.txt`를 생성한다. 이 파일은 B-2 grep 키워드에 버전명을 보조 추가하고, evidence.py가 결과 JSON에 기록한다.

```bash
$PYTHON -c "
import json, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
d = json.load(open('$TMPDIR/ticket_detail.json', encoding='utf-8', errors='replace'))
fv = d.get('fields', {}).get('fixVersions', [])
for v in fv:
    name = v.get('name', '').strip()
    if name:
        print(name)
" > "$TMPDIR/version_targets.txt"
echo "version_targets: $(wc -l < "$TMPDIR/version_targets.txt") 건"
```

### 0-6. 하위 작업 dev-status 탐색 (부모 티켓 PR 없을 때 fallback)

**Development 타입 부모 티켓**은 PR이 하위 작업(서버/클라 subtask)에 붙는 경우가 많다. 부모 티켓 dev-status에서 PR이 없으면 하위 작업 dev-status를 병렬로 조회해 `pr_info.tsv`에 병합한다.

```bash
if [ ! -s "$TMPDIR/pr_info.tsv" ] && [ -s "$TMPDIR/subtask_keys.txt" ]; then
  echo "부모 PR 없음 — 하위 작업 dev-status 조회"
  while read -r SUBKEY; do
    [ -z "$SUBKEY" ] && continue
    SUBID=$($PYTHON -c "
import json, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
try:
    d = json.load(open('$TMPDIR/subtask_${SUBKEY}.json', encoding='utf-8', errors='replace'))
    print(d.get('id', ''))
except: pass
" 2>/dev/null)
    [ -z "$SUBID" ] && continue
    curl -s -u "$JIRA_AUTH" \
      "$JIRA_BASE/rest/dev-status/latest/issue/detail?issueId=${SUBID}&applicationType=GitHub&dataType=pullrequest" \
      -o "$TMPDIR/devstatus_${SUBKEY}.json" &
  done < "$TMPDIR/subtask_keys.txt"
  wait

  # 하위 작업 PR을 pr_info.tsv에 병합
  $PYTHON -c "
import json, sys, re, glob
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
for fpath in sorted(glob.glob('$TMPDIR/devstatus_CVS-*.json')):
    try:
        d = json.load(open(fpath, encoding='utf-8', errors='replace'))
    except: continue
    for det in d.get('detail', []):
        for pr in det.get('pullRequests', []):
            url = pr.get('url', '')
            title = pr.get('name', '')
            status = pr.get('status', '')
            dest = pr.get('destination', {}).get('branch', '') if pr.get('destination') else ''
            m = re.search(r'github\.com/([^/]+/[^/]+)/pull/(\d+)', url)
            if m:
                repo = m.group(1).split('/')[-1]
                pr_num = m.group(2)
                print(f'{repo}\t{pr_num}\t{title}\t{status}\t{dest}')
" >> "$TMPDIR/pr_info.tsv"
  echo "하위 작업 PR 탐색 완료: $(wc -l < "$TMPDIR/pr_info.tsv") 건"
fi
```

---

## STEP 1: Evidence 수집 (딥 다이브 전략)

> **⚠️ 블록 실행 규칙 (STEP 1~3 전체)**
> 이 아래의 모든 standalone `bash` 블록은 **공통 부트스트랩 (정본)**을 블록 첫 줄에 삽입한 뒤 실행한다.
> 부트스트랩은 상단 "공통 부트스트랩 (정본)" 섹션의 코드를 **그대로** 복사한다.
> 그 다음 해당 블록에서 사용하는 키만 `run_context.json`에서 추출한다.
> **블록 본문에 부트스트랩이 생략되어 있어도 반드시 삽입한다.**

단일 티켓이므로 시간 제약이 낮다. **truncation이나 부족한 결과에서 멈추지 않고 반복 심화 탐색**한다.

### PR 유무 판정

`$TMPDIR/pr_info.tsv`가 비어있지 않으면 **분기 A**, 비어있으면 **분기 B**로 진행한다.

---

### 분기 A: PR이 있는 경우 (코드 확정 경로)

#### A-1. client PR files 수집

```bash
# ── 공통 부트스트랩 (정본 — 수정 금지) ──
TICKET_KEY={입력받은 티켓 키}
export TMPDIR="$(cygpath -m /tmp 2>/dev/null || echo /tmp)/ticket-qa-${TICKET_KEY}"
PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)
CTX="$TMPDIR/run_context.json"
[ -f "$CTX" ] || { echo "ERROR: run_context.json not found: $CTX"; exit 1; }
# ── 부트스트랩 끝 — 이후 블록에도 동일하게 삽입 ──

# pr_info.tsv에서 client PR 번호 추출 — files + commits + body를 PR 단위로 병렬 수집
CLIENT_PRS=$(grep "^client" "$TMPDIR/pr_info.tsv" | cut -f2)
for PR_NUM in $CLIENT_PRS; do
  (
    gh api "repos/bagelcode-cvs/client/pulls/${PR_NUM}/files" --paginate \
      > "$TMPDIR/pr_files_client_${PR_NUM}.json" 2>/dev/null &
    gh api "repos/bagelcode-cvs/client/pulls/${PR_NUM}/commits" --paginate \
      > "$TMPDIR/pr_commits_client_${PR_NUM}.json" 2>/dev/null &
    gh api "repos/bagelcode-cvs/client/pulls/${PR_NUM}" --jq '.body' \
      > "$TMPDIR/pr_body_client_${PR_NUM}.txt" 2>/dev/null &
    wait
  ) &
done
wait
```

#### A-2. 주요 변경 파일 repob read

+50줄 이상 또는 핵심 로직 파일은 `$REPOB remote read`로 전체 파일을 읽어 변경 맥락을 파악한다.

```bash
# changed files에서 주요 파일 추출
$PYTHON -c "
import json, sys, glob
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
for f in sorted(glob.glob('$TMPDIR/pr_files_client_*.json')):
    try:
        files = json.load(open(f, encoding='utf-8', errors='replace'))
        if not isinstance(files, list): continue
        for item in files:
            adds = item.get('additions', 0)
            dels = item.get('deletions', 0)
            path = item.get('filename', '')
            status = item.get('status', '')
            # +50줄 이상이거나 .cs/.ts 핵심 로직 파일
            if (adds + dels >= 50) or path.endswith(('.cs', '.ts', '.js')):
                print(f'{path}\t{status}\t+{adds}/-{dels}')
    except: continue
" > "$TMPDIR/key_files_client.txt"
```

각 주요 파일을 `$REPOB remote read client "$TARGET_BRANCH" "{path}" --pretty`로 읽는다. 파일이 10개 이상이면 상위 10개만 읽는다.

#### A-3. server PR 파일 발견

server repo는 gh API 접근 불가이므로 다른 전략을 사용한다.

server PR 유무 판정: `grep "^server" "$TMPDIR/pr_info.tsv"` 결과가 있으면 아래 **"server PR이 있는 경우"** 절차를 따른다.

**server PR이 있는 경우:**

1. dev-status에서 PR 메타 확보 (번호, target branch, status)
2. 티켓 제목/설명에서 키워드 추출 (B-1 키워드 추출 로직 동일하게 적용)
3. 추출된 키워드로 `$REPOB remote grep server "$SERVER_BRANCH" "{키워드}" --pretty` 실행
4. grep hit가 있는 파일만 `$REPOB remote read`로 읽기
5. grep 결과가 0건이면 **"서버 코드 미확인 (grep 0 hits)"** 으로 기재하고 추론하지 않는다

**금지 사항**: client 파일명에서 서버 파일명을 임의로 유추하는 것은 금지한다. 반드시 실제 grep 결과에 있는 파일만 Evidence로 등록한다.

**server PR이 없는 경우:** 분기 B의 server 부분을 실행한다.

#### A-4. PR body 테스트 섹션 추출

PR body는 A-1에서 이미 `$TMPDIR/pr_body_client_${PR_NUM}.txt`로 병렬 수집됐다.

PR body에서 "테스트", "Test", "QA", "확인" 등의 섹션을 추출해 테스트 방법에 참고한다.

#### A-5. PR 커밋 메시지 분석

`pr_commits_*.json`에서 커밋 메시지를 추출해 테스트 포인트 도출에 활용한다.

```bash
# CLIENT_PRS는 이전 블록(A-1) 셸 상태이므로 재계산
CLIENT_PRS=$(grep "^client" "$TMPDIR/pr_info.tsv" | cut -f2)

for PR_NUM in $CLIENT_PRS; do
  $PYTHON -c "
import json, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
data = json.load(open('$TMPDIR/pr_commits_client_${PR_NUM}.json', encoding='utf-8', errors='replace'))
if not isinstance(data, list): sys.exit(0)
for c in data:
    msg = c.get('commit', {}).get('message', '').strip()
    if msg:
        print(msg)
" 2>/dev/null >> "$TMPDIR/commit_messages.txt"
done
```

커밋 메시지에서 다음을 추출해 STEP 2 분석에 반영한다:
- 수정된 동작의 **조건** (예: "on bet change", "베팅 변경 시")
- 픽스 대상 **케이스** (예: "Fix amount showing 000 when jackpot board initialized")
- 영향 범위 힌트 (예: "affects all slots using JackpotBoard")

커밋 메시지는 테스트 방법의 확인 포인트 세부 조건 도출에 직접 활용한다. PR body와 함께 참고한다.

---

### 분기 B: PR이 없는 경우 (repob 딥 다이브)

> **실행 규칙 재확인**
> 이 섹션 이하의 standalone `bash` 블록은 실행 전에 상단 `공통 부트스트랩 (정본)`을 반드시 먼저 붙인다.
> 코드 블록 본문에 부트스트랩이 생략돼 있어도 예외 없이 삽입한다.

PR이 없으므로 키워드 기반 탐색을 반복 심화한다.

#### B-1. 키워드 추출

```bash
$PYTHON -c "
import json, sys, re, glob
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

# 메인 티켓
d = json.load(open('$TMPDIR/ticket_detail.json', encoding='utf-8', errors='replace'))
summary = d.get('fields', {}).get('summary', '')
desc = d.get('fields', {}).get('description', '') or ''

# 하위 작업
sub_texts = []
for f in sorted(glob.glob('$TMPDIR/subtask_*.json')):
    try:
        sd = json.load(open(f, encoding='utf-8', errors='replace'))
        sub_texts.append(sd.get('fields', {}).get('summary', ''))
        sub_texts.append(sd.get('fields', {}).get('description', '') or '')
    except: continue

all_text = summary + ' ' + desc + ' ' + ' '.join(sub_texts)

# 댓글: 노이즈가 많으므로 최근 5개만 보조 텍스트로 수집
# Jira 댓글 body는 ADF 객체(dict)이거나 plain string일 수 있음 — 두 경우 모두 처리
def _flatten_adf(node):
    if isinstance(node, str): return node
    if isinstance(node, dict):
        t = node.get('type', '')
        if t == 'text': return node.get('text', '')
        return ' '.join(_flatten_adf(c) for c in node.get('content', []))
    if isinstance(node, list): return ' '.join(_flatten_adf(c) for c in node)
    return ''

comment_texts = []
comments = d.get('fields', {}).get('comment', {}).get('comments', [])
for c in comments[-5:]:
    body = c.get('body', '') or ''
    comment_texts.append(_flatten_adf(body) if isinstance(body, (dict, list)) else body)
comment_text = ' '.join(comment_texts)

# 키워드 추출: PascalCase 단어, 기술 용어, 클래스명 패턴
keywords = set()
# PascalCase / camelCase 단어 (4글자 이상)
keywords.update(re.findall(r'[A-Z][a-zA-Z0-9]{3,}', all_text))
# 전체 대문자 약어 (2~5글자) — FGP, ODZ, FRK 등 슬롯 코드 누락 방지 필수
keywords.update(re.findall(r'\b[A-Z]{2,5}\b', all_text))
# snake_case 단어
keywords.update(re.findall(r'[a-z][a-z0-9]*_[a-z][a-z0-9_]*', all_text))
# 범용 단어 제외 (언어 범용어 + 도메인 범용어 모두 포함)
# ⚠️ stopwords는 context_kws, keywords 모두에서 사용하므로 반드시 먼저 선언한다
stopwords = {
    # 언어 범용어
    'None', 'True', 'False', 'This', 'That', 'From', 'With', 'Main',
    'Data', 'Type', 'Name', 'List', 'Item', 'Info', 'Base', 'View',
    'Page', 'Size', 'Count', 'Value', 'Event', 'State', 'Model',
    'Error', 'Result', 'Config', 'Manager', 'Service', 'Controller',
    'Handler', 'Helper', 'Utils', 'Util',
    # 게임 도메인 범용어 (단독으로는 grep noise 유발)
    'Game', 'User', 'Player', 'Time', 'Slot', 'Bonus', 'Reward',
    'Score', 'Level', 'Stage', 'Mission', 'Quest', 'Item', 'Shop',
    'Store', 'Menu', 'Popup', 'Panel', 'Button', 'Text', 'Image',
    'Icon', 'Sound', 'Audio', 'Asset', 'Scene', 'Object', 'Prefab',
    'Canvas', 'Component', 'Update', 'Start', 'Awake', 'Init',
    'Load', 'Save', 'Send', 'Receive', 'Request', 'Response',
    # 대문자 약어 범용어 (슬롯 코드 아닌 일반 약어 — grep noise 방지)
    'API', 'QA', 'UI', 'UX', 'ID', 'DB', 'URL', 'HTTP', 'JSON', 'XML',
    'SDK', 'DEV', 'FSM', 'FPS', 'PC', 'OK', 'NA', 'TBD', 'WIP',
    # 한글 범용어
    '구현', '수정', '변경', '추가', '삭제', '확인', '기능', '적용',
    '처리', '관련', '설정', '화면', '버튼', '팝업', '메뉴', '이동',
    '표시', '노출', '클릭', '선택', '조건', '경우', '상태', '정보',
}

# 한글 키워드는 grep 대상에서 제외 — context_keywords.txt로 분리 (STEP 2 분석 참조용)
context_kws = set(re.findall(r'[가-힣]{2,}', all_text))
context_kws -= stopwords

# 댓글 보조 키워드 (PascalCase + 약어만 — 노이즈 제한)
comment_kws = set()
comment_kws.update(re.findall(r'[A-Z][a-zA-Z0-9]{3,}', comment_text))
comment_kws.update(re.findall(r'\b[A-Z]{2,5}\b', comment_text))
keywords.update(comment_kws)
keywords -= stopwords  # comment_kws 추가 후 최종 필터

for kw in sorted(keywords):
    print(kw)
" > "$TMPDIR/keywords.txt"

# 한글 컨텍스트 키워드 저장 (STEP 2 분석에서 티켓 의도 파악용, grep 대상 아님)
$PYTHON -c "
import json, sys, re, glob
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

d = json.load(open('$TMPDIR/ticket_detail.json', encoding='utf-8', errors='replace'))
summary = d.get('fields', {}).get('summary', '')
desc = d.get('fields', {}).get('description', '') or ''
sub_texts = []
for f in sorted(glob.glob('$TMPDIR/subtask_*.json')):
    try:
        sd = json.load(open(f, encoding='utf-8', errors='replace'))
        sub_texts.append(sd.get('fields', {}).get('summary', ''))
        sub_texts.append(sd.get('fields', {}).get('description', '') or '')
    except: continue
all_text = summary + ' ' + (desc if isinstance(desc, str) else '') + ' ' + ' '.join(sub_texts)

stopwords_kr = {'구현','수정','변경','추가','삭제','확인','기능','적용','처리','관련','설정','화면','버튼','팝업','메뉴','이동','표시','노출','클릭','선택','조건','경우','상태','정보'}
kws = set(re.findall(r'[가-힣]{2,}', all_text)) - stopwords_kr
for kw in sorted(kws):
    print(kw)
" > "$TMPDIR/context_keywords.txt"
```

#### B-1.5. description 명시 변경 대상 강제 read

티켓 description/subtask에서 **변경 행위 동사 + PascalCase 클래스명** 패턴을 추출한다. 이 파일들은 grep hit 수와 무관하게 HEAD+BASE를 반드시 읽는다.

> **실행 순서**: B-1.5는 **B-2보다 먼저 완료**한다. B-1.5가 생성하는 `grep_client_*.txt` 파일을 B-2가 skip 판정에 사용하므로, B-1.5가 repob 부하로 0 hits를 반환한 채 B-2가 시작되면 핵심 키워드가 영구 누락된다.

```bash
# description에서 "Changed X", "remove X dependency", "separate X logic" 등 변경 대상 추출
# ⚠️ heredoc 사용 필수 — regex 특수문자(\s, \`, [A-Z] 등)가 bash $PYTHON -c "..." 안에서 에스케이프 충돌을 일으킨다
$PYTHON - "$TMPDIR" << 'PYEOF' > "$TMPDIR/desc_change_targets.txt"
import json, sys, re, glob, os
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

tmpdir = sys.argv[1]

d = json.load(open(os.path.join(tmpdir, 'ticket_detail.json'), encoding='utf-8', errors='replace'))
desc = d.get('fields', {}).get('description', '') or ''

# ADF → plain text
def _flatten(node):
    if isinstance(node, str): return node
    if isinstance(node, dict):
        if node.get('type') == 'text': return node.get('text', '')
        return ' '.join(_flatten(c) for c in node.get('content', []))
    if isinstance(node, list): return ' '.join(_flatten(c) for c in node)
    return ''
text = _flatten(desc) if isinstance(desc, (dict, list)) else desc

# 하위 작업 description도 포함
for f in sorted(glob.glob(os.path.join(tmpdir, 'subtask_*.json'))):
    try:
        sd = json.load(open(f, encoding='utf-8', errors='replace'))
        sub_desc = sd.get('fields', {}).get('description', '') or ''
        text += ' ' + (_flatten(sub_desc) if isinstance(sub_desc, (dict, list)) else sub_desc)
    except: continue

# 변경 동사 패턴 뒤의 PascalCase 클래스명 추출
# 예: 'Changed PopupManager', 'remove manifest', 'separate Active/InActive'
change_verbs = r'(?:Changed?|Modify|Update|Refactor|Remove|Add|Fix|Separate|Replace|Rename|Move|Split|Merge|Deprecate|Rewrite|Revise|Overhaul)'
targets = set()
for m in re.finditer(r'(?i)' + change_verbs + r'\s+`?([A-Z][a-zA-Z0-9]+)`?', text):
    targets.add(m.group(1))

# 불릿 항목에서 PascalCase 클래스명도 추출 (예: '** Changed ContentsManifestDataPatcher to ...')
for m in re.finditer(r'[*\-]\s*(?:\w+\s+)?([A-Z][a-zA-Z0-9]{4,})', text):
    targets.add(m.group(1))

for t in sorted(targets):
    print(t)
PYEOF
```

추출된 클래스명마다 grep 1회로 정의 파일을 찾고, HEAD+BASE를 강제 read한다:

```bash
# grep valid 검증 함수
_grep_valid() {
  local F="$1"
  [ -s "$F" ] || return 1
  $PYTHON -c "import json,sys; d=json.load(open(sys.argv[1],encoding='utf-8')); assert 'count' in d" "$F" 2>/dev/null
}

# ⚠️ portable 배열 빌드 사용 — while read 안에서 repob 호출 금지 (stdin 리다이렉트 → repob 0B 반환)
# portable while-read 배열 빌드 (mapfile은 bash 3.2/zsh 미지원 — 헤더 정본 참고)
_B15_CLASSES=()
while IFS= read -r _LINE || [ -n "$_LINE" ]; do
  [ -z "$_LINE" ] && continue
  _B15_CLASSES+=("$_LINE")
done < "$TMPDIR/desc_change_targets.txt"
for CLASS_NAME in "${_B15_CLASSES[@]}"; do
  CLASS_NAME=$(echo "$CLASS_NAME" | tr -d '\r\n')
  [ -z "$CLASS_NAME" ] && continue
  SAFE=$(echo "$CLASS_NAME" | tr -cd '[:alnum:]_.-')
  # 기존 valid 결과 보존 — valid하면 skip
  _grep_valid "$TMPDIR/grep_client_${SAFE}.txt" && continue
  # tmp에 기록 → valid할 때만 본 파일로 교체
  $REPOB remote grep client "$TARGET_BRANCH" "$CLASS_NAME" --pretty \
    > "$TMPDIR/.tmp_grep_client_${SAFE}.txt" 2>/dev/null
  if _grep_valid "$TMPDIR/.tmp_grep_client_${SAFE}.txt"; then
    mv "$TMPDIR/.tmp_grep_client_${SAFE}.txt" "$TMPDIR/grep_client_${SAFE}.txt"
  else
    rm -f "$TMPDIR/.tmp_grep_client_${SAFE}.txt"
  fi
done

# grep 결과에서 클래스 정의 파일을 찾아 HEAD+BASE read
# ⚠️ heredoc 사용 필수 — rf'class\s+...' 등 regex가 bash $PYTHON -c "..." 안에서 에스케이프 충돌
$PYTHON - "$TMPDIR" << 'PYEOF' > "$TMPDIR/desc_read_targets.txt"
import json, sys, re, glob, os
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

tmpdir = sys.argv[1]

targets = [l.strip() for l in open(os.path.join(tmpdir, 'desc_change_targets.txt'), encoding='utf-8', errors='replace') if l.strip()]
SKIP_EXT = ('.prefab', '.meta', '.asset', '.unity', '.anim', '.controller', '.png', '.jpg', '.wav', '.mp3')

for cls in targets:
    safe = re.sub(r'[^a-zA-Z0-9_.-]', '', cls)
    fpath = os.path.join(tmpdir, f'grep_client_{safe}.txt')
    try:
        raw = open(fpath, encoding='utf-8', errors='replace').read().strip()
        if not raw: continue
        data = json.loads(raw)
        if not isinstance(data, dict) or 'matches' not in data: continue
        # 클래스 정의 파일 우선 (class {ClassName} 패턴이 있는 파일)
        for m in data['matches']:
            f = m.get('file', '')
            t = m.get('text', '')
            if f.endswith(SKIP_EXT): continue
            if re.search(r'class\s+' + re.escape(cls), t) or f.endswith(f'{cls}.cs') or f.endswith(f'{cls}.ts'):
                print(f)
                break
        else:
            # 정의 파일 못 찾으면 첫 번째 코드 파일
            for m in data['matches'][:1]:
                f = m.get('file', '')
                if not f.endswith(SKIP_EXT):
                    print(f)
    except: continue
PYEOF

# HEAD+BASE 강제 read (병렬, tmp→validate→mv)
# ⚠️ SAFE 네이밍 규칙: sed 's|/|_|g' 로 경로 구분자를 단일 밑줄로 치환
# evidence.py가 이 패턴으로 매칭하므로 다른 방식으로 변환하지 않는다
# ⚠️ portable 배열 빌드 사용 — while read 안에서 repob 호출 금지 (stdin 리다이렉트 → repob 0B 반환)
# for-in $(cat)은 공백 경로 분할 문제. portable while-read 배열은 두 문제 모두 안전.
# portable while-read 배열 빌드 (mapfile은 bash 3.2/zsh 미지원 — 헤더 정본 참고)
_B15_FILES=()
while IFS= read -r _LINE || [ -n "$_LINE" ]; do
  [ -z "$_LINE" ] && continue
  _B15_FILES+=("$_LINE")
done < "$TMPDIR/desc_read_targets.txt"
for FILE_PATH in "${_B15_FILES[@]}"; do
  FILE_PATH=$(echo "$FILE_PATH" | tr -d '\r\n')
  [ -z "$FILE_PATH" ] && continue
  SAFE=$(echo "$FILE_PATH" | sed 's|/|_|g')
  # 기존 valid 결과 보존
  [ -s "$TMPDIR/read_${SAFE}_head.txt" ] && continue
  echo "B-1.5 read: $FILE_PATH"
  $REPOB remote read client "$TARGET_BRANCH" "$FILE_PATH" --pretty \
    > "$TMPDIR/.tmp_read_${SAFE}_head.txt" 2>/dev/null
  [ -s "$TMPDIR/.tmp_read_${SAFE}_head.txt" ] && \
    mv "$TMPDIR/.tmp_read_${SAFE}_head.txt" "$TMPDIR/read_${SAFE}_head.txt"
  if [ -n "$BASE_BRANCH" ]; then
    $REPOB remote read client "$BASE_BRANCH" "$FILE_PATH" --pretty \
      > "$TMPDIR/.tmp_read_${SAFE}_base.txt" 2>/dev/null
    [ -s "$TMPDIR/.tmp_read_${SAFE}_base.txt" ] && \
      mv "$TMPDIR/.tmp_read_${SAFE}_base.txt" "$TMPDIR/read_${SAFE}_base.txt"
  fi
done

# 0B read 재시도 (B-1.5 — desc_change_targets는 핵심 파일이므로 반드시 확보)
for FILE_PATH in "${_B15_FILES[@]}"; do
  FILE_PATH=$(echo "$FILE_PATH" | tr -d '\r\n')
  [ -z "$FILE_PATH" ] && continue
  SAFE=$(echo "$FILE_PATH" | sed 's|/|_|g')
  if [ ! -s "$TMPDIR/read_${SAFE}_head.txt" ]; then
    $REPOB remote read client "$TARGET_BRANCH" "$FILE_PATH" --pretty \
      > "$TMPDIR/.tmp_read_${SAFE}_head.txt" 2>/dev/null
    if [ -s "$TMPDIR/.tmp_read_${SAFE}_head.txt" ]; then
      mv "$TMPDIR/.tmp_read_${SAFE}_head.txt" "$TMPDIR/read_${SAFE}_head.txt"
    else
      rm -f "$TMPDIR/.tmp_read_${SAFE}_head.txt"
      echo "WARN: 0B read 재시도 실패 — $FILE_PATH"
    fi
  fi
done
```

이 단계에서 읽은 파일은 B-3의 read 대상에서 중복 제외된다 (이미 `read_*_head.txt`가 **0B가 아닌 상태로** 존재 시 skip).

#### B-1.6. CHANGELOG 탐색 (있으면 read)

description/subtask에서 버전 번호나 릴리즈 관련 키워드가 있으면 CHANGELOG를 탐색한다.

```bash
# CHANGELOG 파일 탐색 — 프로젝트에 없을 수 있으므로 실패 무시
$REPOB remote grep client "$TARGET_BRANCH" "CHANGELOG" --pretty 2>/dev/null \
  | $PYTHON -c "
import json, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
try:
    d = json.load(sys.stdin)
    if isinstance(d, dict) and 'matches' in d:
        seen = set()
        for m in d['matches']:
            f = m.get('file', '')
            if f.endswith(('.md', '.txt')) and 'CHANGELOG' in f.upper() and f not in seen:
                seen.add(f)
                print(f)
except: pass
" > "$TMPDIR/changelog_candidates.txt" 2>/dev/null

# 첫 번째 CHANGELOG만 read (있으면)
CHANGELOG_PATH=$(head -1 "$TMPDIR/changelog_candidates.txt")
if [ -n "$CHANGELOG_PATH" ]; then
  SAFE=$(echo "$CHANGELOG_PATH" | sed 's|/|_|g')
  $REPOB remote read client "$TARGET_BRANCH" "$CHANGELOG_PATH" --pretty \
    > "$TMPDIR/read_changelog.txt" 2>/dev/null
  echo "CHANGELOG read: $CHANGELOG_PATH ($(wc -c < "$TMPDIR/read_changelog.txt")B)"
fi
```

CHANGELOG 내용은 STEP 2에서 변경 항목 컨텍스트로 참고한다. CHANGELOG가 없으면 이 단계는 무시한다.

#### B-2. Level 1 — 키워드 grep (병렬 — job limit 5)

client와 server grep을 키워드 단위로 병렬 실행한다. 동시 실행 수는 5개로 제한한다.

```bash
# ⚠️ skip 조건: 기존 valid 결과가 있으면 skip (grep valid = JSON parse + count 필드)
# B-1.5가 선행 생성한 grep 파일이 rate limit/timeout으로 invalid일 수 있다.
# valid하지 않으면 재시도한다.
_grep_valid() {
  local F="$1"
  [ -s "$F" ] || return 1
  $PYTHON -c "import json,sys; d=json.load(open(sys.argv[1],encoding='utf-8')); assert 'count' in d" "$F" 2>/dev/null
}

# ⚠️ portable 배열 빌드 사용 — while read 안에서 repob 호출 금지 (stdin 리다이렉트 → repob 0B 반환)
# portable while-read 배열 빌드 (mapfile은 bash 3.2/zsh 미지원 — 헤더 정본 참고)
_B2_KEYWORDS=()
while IFS= read -r _LINE || [ -n "$_LINE" ]; do
  [ -z "$_LINE" ] && continue
  _B2_KEYWORDS+=("$_LINE")
done < "$TMPDIR/keywords.txt"
_JOB_COUNT=0
for KW in "${_B2_KEYWORDS[@]}"; do
  KW=$(echo "$KW" | tr -d '\r\n')
  [ -z "$KW" ] && continue
  SAFE_KW=$(echo "$KW" | tr '/\\: ' '____' | tr -cd '[:alnum:]_.-')
  [ -z "$SAFE_KW" ] && SAFE_KW="$(echo "$KW" | md5sum | cut -c1-8)"
  # skip: client+server 모두 valid할 때만
  if _grep_valid "$TMPDIR/grep_client_${SAFE_KW}.txt" && \
     _grep_valid "$TMPDIR/grep_server_${SAFE_KW}.txt"; then
    continue
  fi
  (
    # client grep — tmp→validate→mv
    $REPOB remote grep client "$TARGET_BRANCH" "$KW" --pretty \
      > "$TMPDIR/.tmp_grep_client_${SAFE_KW}.txt" 2>/dev/null
    if _grep_valid "$TMPDIR/.tmp_grep_client_${SAFE_KW}.txt"; then
      mv "$TMPDIR/.tmp_grep_client_${SAFE_KW}.txt" "$TMPDIR/grep_client_${SAFE_KW}.txt"
    else
      rm -f "$TMPDIR/.tmp_grep_client_${SAFE_KW}.txt"
    fi &
    # server grep — tmp→validate→mv
    $REPOB remote grep server "$SERVER_BRANCH" "$KW" --pretty \
      > "$TMPDIR/.tmp_grep_server_${SAFE_KW}.txt" 2>/dev/null
    if _grep_valid "$TMPDIR/.tmp_grep_server_${SAFE_KW}.txt"; then
      mv "$TMPDIR/.tmp_grep_server_${SAFE_KW}.txt" "$TMPDIR/grep_server_${SAFE_KW}.txt"
    else
      rm -f "$TMPDIR/.tmp_grep_server_${SAFE_KW}.txt"
    fi &
    wait
  ) &
  _JOB_COUNT=$(( _JOB_COUNT + 1 ))
  if [ "$_JOB_COUNT" -ge 5 ]; then
    wait
    _JOB_COUNT=0
  fi
done
wait
```

결과를 취합해 hit 파일 목록을 만든다. **100건 이상 truncated면 범용 파일(`ClientAPI/`, `ClientModels/`, `*.meta`, `*.asset`, `*.prefab`, `*.unity`, `Packages/`, `ProjectSettings/`, `Library/`)을 제외하고 재시도한다.**

#### B-2.1. grep hit 파일 경로에서 2차 키워드 자동 추출

> **설계 의도**: 티켓 description이 한글 중심이거나 추상적 기능 설명만 포함된 경우 B-1 키워드가 부족해진다. B-2 grep 결과에서 hit된 파일 경로의 PascalCase 클래스명을 추출해 2차 키워드로 활용하면 관련 파일을 더 넓게 탐색할 수 있다.

B-2 grep 결과에서 client hit 파일이 5건 이하이고 키워드가 6개 이하인 경우 실행한다.

```bash
# B-2 grep 결과에서 hit 파일 경로 수집 → PascalCase 클래스명 추출 → 2차 키워드
CLIENT_HIT_COUNT=$($PYTHON -c "
import json, sys, glob, os
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
seen = set()
for f in glob.glob(os.path.join('$TMPDIR', 'grep_client_*.txt')):
    try:
        d = json.load(open(f, encoding='utf-8', errors='replace'))
        for hit in d.get('files', []):
            p = hit.get('path', '')
            if p: seen.add(p)
    except: pass
print(len(seen))
" 2>/dev/null || echo 0)

KW_COUNT=$(wc -l < "$TMPDIR/keywords.txt" 2>/dev/null || echo 0)

if [ "$CLIENT_HIT_COUNT" -le 5 ] || [ "$KW_COUNT" -le 6 ]; then
  echo "B-2.1: hit=$CLIENT_HIT_COUNT, kw=$KW_COUNT — 2차 키워드 추출"
  $PYTHON -c "
import json, sys, glob, os, re
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

# 기존 키워드 로드
existing = set()
kw_path = os.path.join('$TMPDIR', 'keywords.txt')
if os.path.exists(kw_path):
    existing = set(l.strip() for l in open(kw_path, encoding='utf-8', errors='replace') if l.strip())

# grep hit 파일 경로에서 PascalCase 클래스명 추출
new_kws = set()
for f in glob.glob(os.path.join('$TMPDIR', 'grep_client_*.txt')):
    try:
        d = json.load(open(f, encoding='utf-8', errors='replace'))
        for hit in d.get('files', []):
            p = hit.get('path', '')
            if not p: continue
            # 파일명에서 확장자 제거 후 PascalCase 이름 추출
            basename = os.path.splitext(os.path.basename(p))[0]
            # PascalCase 이름이 2단어 이상이면 키워드 후보
            parts = re.findall(r'[A-Z][a-z]+', basename)
            if len(parts) >= 2 and basename not in existing:
                new_kws.add(basename)
            # 경로 중간 디렉토리에서도 의미 있는 이름 추출 (예: SlotListV2, Lobby)
            for segment in p.split('/'):
                seg_name = os.path.splitext(segment)[0]  # 확장자 제거
                seg_parts = re.findall(r'[A-Z][a-z]+', seg_name)
                if len(seg_parts) >= 2 and seg_name not in existing and seg_name != basename:
                    new_kws.add(seg_name)
    except: pass

# server grep hit에서도 동일 추출
for f in glob.glob(os.path.join('$TMPDIR', 'grep_server_*.txt')):
    try:
        d = json.load(open(f, encoding='utf-8', errors='replace'))
        for hit in d.get('files', []):
            p = hit.get('path', '')
            if not p: continue
            basename = os.path.splitext(os.path.basename(p))[0]
            parts = re.findall(r'[A-Z][a-z]+', basename)
            if len(parts) >= 2 and basename not in existing:
                new_kws.add(basename)
    except: pass

# 범용 파일/디렉토리 제외 (어떤 티켓이든 hit되는 noise)
GENERIC_NAMES = {
    'BagelCodeClientModels', 'BagelCodeClientModelsExtend', 'BagelCodeClientAPI2Blackboard',
    'BlackboardQueryUtils', 'BlackboardQueryUtilsGame', 'MetaDefines',
    'ClientAPI', 'ClientModels', 'ProjectSettings', 'PackageManager',
    'EditorSettings', 'BuyItemWithGem',
}
new_kws -= GENERIC_NAMES

# 기존 키워드와 중복 제거 후 추가 (최대 10개)
added = []
for kw in sorted(new_kws):
    if kw not in existing and len(kw) > 3:
        added.append(kw)
        if len(added) >= 10:
            break

if added:
    with open(kw_path, 'a', encoding='utf-8') as f:
        for kw in added:
            f.write(kw + '\n')
    print(f'2차 키워드 {len(added)}건 추가: {added}')
else:
    print('추출할 2차 키워드 없음')
" 2>/dev/null

  # 2차 키워드가 추가됐으면 해당 키워드만 grep 실행
  if [ -s "$TMPDIR/keywords.txt" ]; then
    # ⚠️ portable 배열 빌드 사용 — pipe | while read 안에서 repob 호출 금지 (stdin 소비 → repob 0B 반환)
    _NEW_START=$(( $(wc -l < "$TMPDIR/keywords.txt") - 10 ))
    [ "$_NEW_START" -lt 1 ] && _NEW_START=1
    # portable while-read 배열 빌드 (process substitution + mapfile은 zsh/bash 3.2 호환 위해 임시 파일 경유)
    _B21_KWS_TMP="$TMPDIR/.tmp_b21_kws_src.txt"
    tail -n +${_NEW_START} "$TMPDIR/keywords.txt" > "$_B21_KWS_TMP"
    _B21_NEW_KWS=()
    while IFS= read -r _LINE || [ -n "$_LINE" ]; do
      [ -z "$_LINE" ] && continue
      _B21_NEW_KWS+=("$_LINE")
    done < "$_B21_KWS_TMP"
    rm -f "$_B21_KWS_TMP"
    _JOB_COUNT=0
    for KW in "${_B21_NEW_KWS[@]}"; do
      KW=$(echo "$KW" | tr -d '\r\n')
      [ -z "$KW" ] && continue
      SAFE_KW=$(echo "$KW" | tr '/\\: ' '____' | tr -cd '[:alnum:]_.-')
      [ -z "$SAFE_KW" ] && SAFE_KW="$(echo "$KW" | md5sum | cut -c1-8)"
      # 이미 grep 결과가 있으면 skip
      [ -s "$TMPDIR/grep_client_${SAFE_KW}.txt" ] && [ -s "$TMPDIR/grep_server_${SAFE_KW}.txt" ] && continue
      (
        $REPOB remote grep client "$TARGET_BRANCH" "$KW" --pretty \
          > "$TMPDIR/.tmp_grep_client_${SAFE_KW}.txt" 2>/dev/null
        if $PYTHON -c "import json,sys; d=json.load(open(sys.argv[1],encoding='utf-8')); assert 'count' in d" "$TMPDIR/.tmp_grep_client_${SAFE_KW}.txt" 2>/dev/null; then
          mv "$TMPDIR/.tmp_grep_client_${SAFE_KW}.txt" "$TMPDIR/grep_client_${SAFE_KW}.txt"
        else
          rm -f "$TMPDIR/.tmp_grep_client_${SAFE_KW}.txt"
        fi &
        $REPOB remote grep server "$SERVER_BRANCH" "$KW" --pretty \
          > "$TMPDIR/.tmp_grep_server_${SAFE_KW}.txt" 2>/dev/null
        if $PYTHON -c "import json,sys; d=json.load(open(sys.argv[1],encoding='utf-8')); assert 'count' in d" "$TMPDIR/.tmp_grep_server_${SAFE_KW}.txt" 2>/dev/null; then
          mv "$TMPDIR/.tmp_grep_server_${SAFE_KW}.txt" "$TMPDIR/grep_server_${SAFE_KW}.txt"
        else
          rm -f "$TMPDIR/.tmp_grep_server_${SAFE_KW}.txt"
        fi &
        wait
      ) &
      _JOB_COUNT=$(( _JOB_COUNT + 1 ))
      if [ "$_JOB_COUNT" -ge 5 ]; then
        wait
        _JOB_COUNT=0
      fi
    done
    wait
  fi
fi
```

#### B-2.5. server grep 0 hits → server query 동기 실행

server grep 결과가 전부 0 hits이면 **server query를 동기로 실행**한다. 결과가 `$TMPDIR/server_query_result.txt`에 직접 기록되므로 별도 수합 단계가 필요 없다.

> **설계 의도**: background 실행은 Bash 블록 간 PID/변수 유실로 결과 수합 실패가 반복됐다. 30~60초 추가 대기보다 server query 결과가 100% 분석에 반영되는 것이 QA 품질에 중요하다.

> **⚠️ 이 블록은 분리 금지**: 아래 코드 블록(SERVER_TOTAL_HITS 계산 ~ server_query_result.txt 생성)을 **반드시 하나의 Bash 호출로 실행**한다. repob query가 비동기 task를 반환할 수 있으므로 대기 루프까지 포함해야 결과가 확정된다. 블록을 쪼개면 대기 루프가 누락되어 server query가 분석에 반영되지 않는다.

```bash
SERVER_TOTAL_HITS=$($PYTHON -c "
import json, sys, glob
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
total = 0
for f in glob.glob('$TMPDIR/grep_server_*.txt'):
    try:
        d = json.load(open(f, encoding='utf-8', errors='replace'))
        total += d.get('count', 0)
    except: pass
print(total)
" 2>/dev/null || echo 0)

if [ "$SERVER_TOTAL_HITS" -eq 0 ]; then
  echo "server grep 0 hits — server query 동기 실행"
  # 티켓 제목을 query 프롬프트로 사용 — 하드코딩 금지
  # query 문자열: 영문 키워드만 전달 (한글·특수문자는 서버 파싱 실패 유발)
  QUERY_TEXT=$($PYTHON -c "
import json, sys, re
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
d = json.load(open('$TMPDIR/ticket_detail.json', encoding='utf-8', errors='replace'))
summary = d.get('fields', {}).get('summary', '')
# PascalCase + 영문 단어만 추출, 한글·특수문자 제거
words = re.findall(r'[A-Za-z][A-Za-z0-9]+', summary)
# description 변경 대상도 포함
import os
targets_path = os.path.join('$TMPDIR', 'desc_change_targets.txt')
if os.path.exists(targets_path):
    words += [l.strip() for l in open(targets_path, encoding='utf-8', errors='replace') if l.strip()]
# 중복 제거 + 키로 결합
seen = set()
unique = []
for w in words:
    if w not in seen: seen.add(w); unique.append(w)
print(' '.join(unique[:15]) + ' $TICKET_KEY')
" 2>/dev/null || echo "$TICKET_KEY")

  # 동기 실행 — 완료될 때까지 대기 후 결과 처리
  $REPOB remote query server "$SERVER_BRANCH" \
    "$QUERY_TEXT" --pretty \
    > "$TMPDIR/server_query_meta.txt" 2>&1

  # repob query 결과 처리 (동기/비동기 task 방식 모두 대응)
  if [ -s "$TMPDIR/server_query_meta.txt" ]; then
    META_CONTENT=$(cat "$TMPDIR/server_query_meta.txt")

    # 비동기 task 방식: "Output is being written to: /path/to/file" 패턴 감지
    OUTPUT_PATH=$(echo "$META_CONTENT" | grep -oP '(?<=Output is being written to: )\S+' 2>/dev/null || true)

    if [ -n "$OUTPUT_PATH" ]; then
      echo "비동기 task 방식 감지 — output 파일 대기: $OUTPUT_PATH (최대 180초)"
      _WAIT=0
      while [ ! -s "$OUTPUT_PATH" ] && [ "$_WAIT" -lt 180 ]; do
        sleep 3
        _WAIT=$(( _WAIT + 3 ))
      done
      if [ -s "$OUTPUT_PATH" ]; then
        cp "$OUTPUT_PATH" "$TMPDIR/server_query_result.txt"
        echo "server query 수신 완료 (비동기): $(wc -c < "$TMPDIR/server_query_result.txt")B"
      else
        echo '{"answer": "server query 결과 미수신 (output 파일 180초 대기 초과)"}' > "$TMPDIR/server_query_result.txt"
      fi

    # 메타 문자열만 있는 경우
    elif echo "$META_CONTENT" | grep -qiE 'Command running|running in background|task (id|ID)|Output will be'; then
      echo '{"answer": "server query 메타 문자열만 수신됨 — 유효한 답변 없음"}' > "$TMPDIR/server_query_result.txt"

    # 동기 완료: 실제 답변이 직접 기록됨
    else
      cp "$TMPDIR/server_query_meta.txt" "$TMPDIR/server_query_result.txt"
      echo "server query 수신 완료 (동기): $(wc -c < "$TMPDIR/server_query_result.txt")B"
    fi
  else
    echo '{"answer": "server query 결과 없음 (빈 파일)"}' > "$TMPDIR/server_query_result.txt"
  fi
fi
```

#### B-3. Level 3 — 파일 직접 읽기 + 호출 관계 추적

grep hit 파일 중 **품질 점수** 상위 10건을 HEAD/BASE 양쪽으로 읽어 standalone read 파일을 생성하고, 호출 관계를 추적한다. 이후 호출 추적에서 추가 파일을 발견하면 반복 확장한다.

```bash
# grep hit 파일을 품질 점수로 정렬해 상위 10건 읽기
# 점수 기준:
#   +3: desc_change_targets.txt의 basename과 일치 (description 명시 변경 대상)
#   +2: .cs / .ts / .js 코드 파일
#   -2: Docs/, Tests/, ClientAPI/, ClientModels/, Packages/, ProjectSettings/, Library/ 경로
#   -1: .md / .sh / .txt 비코드 파일
$PYTHON -c "
import glob, re, json, sys, os
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

# desc_change_targets basename 로드 (가점용)
desc_targets = set()
dct_path = os.path.join('$TMPDIR', 'desc_change_targets.txt')
if os.path.exists(dct_path):
    for line in open(dct_path, encoding='utf-8', errors='replace'):
        t = line.strip()
        if t: desc_targets.add(t)

SKIP_EXT = ('.prefab', '.meta', '.asset', '.unity', '.anim', '.controller', '.png', '.jpg', '.wav', '.mp3')
PENALTY_DIRS = ('Docs/', 'Tests/', 'ClientAPI/', 'ClientModels/', 'Packages/', 'ProjectSettings/', 'Library/')
CODE_EXT = ('.cs', '.ts', '.js')
NON_CODE_EXT = ('.md', '.sh', '.txt')

seen = set()
candidates = []  # (score, path)
for fpath in sorted(glob.glob('$TMPDIR/grep_client_*.txt')):
    try:
        raw = open(fpath, encoding='utf-8', errors='replace').read().strip()
        if not raw: continue
        data = json.loads(raw)
        if not isinstance(data, dict) or 'matches' not in data: continue
        for m in data['matches']:
            p = m.get('file', '')
            if not p or p in seen or p.endswith(SKIP_EXT): continue
            seen.add(p)
            score = 0
            bn = os.path.basename(p).rsplit('.', 1)[0]
            if bn in desc_targets: score += 3
            if p.endswith(CODE_EXT): score += 2
            if any(p.startswith(d) for d in PENALTY_DIRS): score -= 2
            if p.endswith(NON_CODE_EXT): score -= 1
            candidates.append((score, p))
    except: continue
candidates.sort(key=lambda x: (-x[0], x[1]))
for _, p in candidates[:10]:
    print(p)
" > "$TMPDIR/b3_read_targets.txt"

# read — tmp→validate→mv (기존 valid 결과 보존)
# ⚠️ portable 배열 빌드 사용 — while read 안에서 repob 호출 금지 (stdin 리다이렉트 → repob 0B 반환)
# portable while-read 배열 빌드 (mapfile은 bash 3.2/zsh 미지원 — 헤더 정본 참고)
_B3_FILES=()
while IFS= read -r _LINE || [ -n "$_LINE" ]; do
  [ -z "$_LINE" ] && continue
  _B3_FILES+=("$_LINE")
done < "$TMPDIR/b3_read_targets.txt"
for FILE_PATH in "${_B3_FILES[@]}"; do
  FILE_PATH=$(echo "$FILE_PATH" | tr -d '\r\n')
  [ -z "$FILE_PATH" ] && continue
  SAFE=$(echo "$FILE_PATH" | sed 's|/|_|g')
  # 기존 valid head가 있으면 skip
  [ -s "$TMPDIR/read_${SAFE}_head.txt" ] && continue
  $REPOB remote read client "$TARGET_BRANCH" "$FILE_PATH" --pretty \
    > "$TMPDIR/.tmp_read_${SAFE}_head.txt" 2>/dev/null
  [ -s "$TMPDIR/.tmp_read_${SAFE}_head.txt" ] && \
    mv "$TMPDIR/.tmp_read_${SAFE}_head.txt" "$TMPDIR/read_${SAFE}_head.txt"
  if [ -n "$BASE_BRANCH" ]; then
    $REPOB remote read client "$BASE_BRANCH" "$FILE_PATH" --pretty \
      > "$TMPDIR/.tmp_read_${SAFE}_base.txt" 2>/dev/null
    [ -s "$TMPDIR/.tmp_read_${SAFE}_base.txt" ] && \
      mv "$TMPDIR/.tmp_read_${SAFE}_base.txt" "$TMPDIR/read_${SAFE}_base.txt"
  fi
done

# ⚠️ 0B read 재시도: head 파일이 없으면 1회 재시도 후 경고
_RETRY_COUNT=0
for FILE_PATH in "${_B3_FILES[@]}"; do
  FILE_PATH=$(echo "$FILE_PATH" | tr -d '\r\n')
  [ -z "$FILE_PATH" ] && continue
  SAFE=$(echo "$FILE_PATH" | sed 's|/|_|g')
  if [ ! -s "$TMPDIR/read_${SAFE}_head.txt" ]; then
    $REPOB remote read client "$TARGET_BRANCH" "$FILE_PATH" --pretty \
      > "$TMPDIR/.tmp_read_${SAFE}_head.txt" 2>/dev/null
    if [ -s "$TMPDIR/.tmp_read_${SAFE}_head.txt" ]; then
      mv "$TMPDIR/.tmp_read_${SAFE}_head.txt" "$TMPDIR/read_${SAFE}_head.txt"
    else
      rm -f "$TMPDIR/.tmp_read_${SAFE}_head.txt"
      echo "WARN: 0B read 재시도 실패 — $FILE_PATH"
    fi
    _RETRY_COUNT=$(( _RETRY_COUNT + 1 ))
  fi
done
[ "$_RETRY_COUNT" -gt 0 ] && echo "0B read 재시도: ${_RETRY_COUNT}건"
```

read 완료 후:
1. head vs base를 비교해 Changed/New/Removed/Unchanged 판정
2. 변경 파일에서 호출하는 클래스/메서드를 추출해 추가 grep
3. 추가 grep hit 파일도 동일하게 HEAD+BASE read → 영향 범위 확장

**New 파일 핵심 로직 read (버그 관련 신규 코드 딥 다이브):**

head/base 비교에서 **New**로 판정된 파일(base 없음 또는 빈 base)은 diff가 불가하다. 그러나 하위 작업에 **버그 티켓**이 있고 해당 버그가 New 파일(신규 슬롯 등)에 관련되면, **head만이라도 read해서 핵심 로직을 파악**한다.

- 대상 선정: 하위 작업 중 Bug 타입 티켓의 description에서 언급된 키워드(슬롯 코드, 기능명)와 매칭되는 New 파일
- read 범위: 키워드와 관련된 .cs/.ts 파일 중 핵심 로직 파일 (Controller, Manager, Popup, Utility 등) **최대 8개**
- 목적: 초기화/갱신/표시 로직에서 **구체적 확인 포인트** 도출 (예: betCredit 기반 갱신, 포맷팅 함수, 분기 조건)
- head read 결과는 STEP 2 테스트 방법에서 확인 포인트의 코드 근거로 직접 활용한다

```bash
# 하위 Bug 티켓 키워드와 매칭되는 New 파일의 핵심 .cs 파일을 head read
$PYTHON -c "
import json, sys, re, glob, os
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

def flatten(node):
    if isinstance(node, str): return node
    if isinstance(node, dict):
        if node.get('type') == 'text': return node.get('text', '')
        return ' '.join(flatten(c) for c in node.get('content', []))
    if isinstance(node, list): return ' '.join(flatten(c) for c in node)
    return ''

# 하위 Bug 티켓에서 키워드 추출 (가중치 강화)
# Bug subtask + 부모 티켓 양쪽에서 키워드를 추출해 매칭 범위 확대
bug_keywords = set()

# 1) 부모 티켓에서 보조 키워드 (슬롯 코드, 기능명)
try:
    parent = json.load(open(os.path.join('$TMPDIR', 'ticket_detail.json'), encoding='utf-8', errors='replace'))
    pf = parent.get('fields', {})
    parent_text = pf.get('summary', '')
    parent_desc = pf.get('description', '') or ''
    if isinstance(parent_desc, (dict, list)): parent_desc = flatten(parent_desc)
    parent_text += ' ' + parent_desc
    # 슬롯 코드 (대문자 2-5자) — FGP, ODZ, FRK 등 부모 티켓에만 있는 경우 대비
    bug_keywords.update(re.findall(r'\b[A-Z]{2,5}\b', parent_text))
except: pass

# 2) Bug subtask에서 핵심 키워드
for f in sorted(glob.glob(os.path.join('$TMPDIR', 'subtask_*.json'))):
    try:
        sd = json.load(open(f, encoding='utf-8', errors='replace'))
        sf = sd.get('fields', {})
        itype = sf.get('issuetype', {}).get('name', '')
        if 'Bug' not in itype and 'bug' not in sf.get('summary', '').lower():
            continue
        text = sf.get('summary', '')
        desc = sf.get('description', '') or ''
        if isinstance(desc, (dict, list)): desc = flatten(desc)
        text += ' ' + desc
        # 슬롯 코드 (대문자 2-5자)
        bug_keywords.update(re.findall(r'\b[A-Z]{2,5}\b', text))
        # PascalCase (4글자 이상)
        bug_keywords.update(re.findall(r'[A-Z][a-zA-Z0-9]{3,}', text))
        # camelCase 기능명 (jackpot, respin 등 소문자로 시작하는 기능명)
        bug_keywords.update(re.findall(r'[a-z][a-zA-Z]{4,}', text))
    except: continue

stopwords = {'Bug', 'None', 'Main', 'Test', 'All', 'Game', 'Slot', 'Error',
             'Added', 'Changed', 'Fixed', 'Update', 'Version', 'Contents'}
bug_keywords -= stopwords

# New 파일 중 bug 키워드 매칭되는 .cs 파일 추출
new_read_targets = []
SKIP_EXT = ('.prefab', '.meta', '.asset', '.unity', '.anim', '.controller', '.png', '.jpg', '.wav', '.mp3')
PRIORITY_NAMES = ('Controller', 'Manager', 'Popup', 'Utility', 'Utils', 'Base', 'Result')

# grep hit에서 New 파일 후보 추출 (read되지 않은 파일)
for fpath in sorted(glob.glob(os.path.join('$TMPDIR', 'grep_client_*.txt'))):
    try:
        raw = open(fpath, encoding='utf-8', errors='replace').read().strip()
        if not raw: continue
        data = json.loads(raw)
        if not isinstance(data, dict) or 'matches' not in data: continue
        for m in data['matches']:
            p = m.get('file', '')
            if not p or p.endswith(SKIP_EXT) or not p.endswith('.cs'): continue
            # bug 키워드와 매칭 (부모 티켓 슬롯 코드 포함)
            basename = os.path.basename(p).replace('.cs', '')
            if any(kw in basename or kw in p for kw in bug_keywords):
                # 이미 read된 파일 skip — sed 's|/|_|g' 패턴과 일치시킨다 (단일 밑줄)
                safe = p.replace('/', '_').replace(chr(92), '_')
                if os.path.exists(os.path.join('$TMPDIR', f'read_{safe}_head.txt')):
                    continue
                # 우선순위: Controller/Manager/Popup 등
                priority = any(pn in basename for pn in PRIORITY_NAMES)
                new_read_targets.append((priority, p))
    except: continue

# 우선순위 정렬 후 최대 8개
new_read_targets.sort(key=lambda x: (not x[0], x[1]))
seen = set()
for _, p in new_read_targets:
    if p not in seen:
        seen.add(p)
        print(p)
    if len(seen) >= 8:
        break
" > "$TMPDIR/new_bug_read_targets.txt"

# head만 read (순차)
# ⚠️ portable 배열 빌드 사용 — while read 안에서 repob 호출 금지 (stdin 리다이렉트 → repob 0B 반환)
# portable while-read 배열 빌드 (mapfile은 bash 3.2/zsh 미지원 — 헤더 정본 참고)
_NEWBUG_FILES=()
while IFS= read -r _LINE || [ -n "$_LINE" ]; do
  [ -z "$_LINE" ] && continue
  _NEWBUG_FILES+=("$_LINE")
done < "$TMPDIR/new_bug_read_targets.txt"
for FILE_PATH in "${_NEWBUG_FILES[@]}"; do
  FILE_PATH=$(echo "$FILE_PATH" | tr -d '\r\n')
  [ -z "$FILE_PATH" ] && continue
  SAFE=$(echo "$FILE_PATH" | sed 's|/|_|g')
  [ -s "$TMPDIR/read_${SAFE}_head.txt" ] && continue
  $REPOB remote read client "$TARGET_BRANCH" "$FILE_PATH" --pretty \
    > "$TMPDIR/read_${SAFE}_head.txt" 2>/dev/null
done

# 0B read 재시도 (New 파일은 head만 — base 없음)
for FILE_PATH in "${_NEWBUG_FILES[@]}"; do
  FILE_PATH=$(echo "$FILE_PATH" | tr -d '\r\n')
  [ -z "$FILE_PATH" ] && continue
  SAFE=$(echo "$FILE_PATH" | sed 's|/|_|g')
  if [ ! -s "$TMPDIR/read_${SAFE}_head.txt" ]; then
    $REPOB remote read client "$TARGET_BRANCH" "$FILE_PATH" --pretty \
      > "$TMPDIR/read_${SAFE}_head.txt" 2>/dev/null
    [ ! -s "$TMPDIR/read_${SAFE}_head.txt" ] && echo "WARN: 0B read 재시도 실패 — $FILE_PATH"
  fi
done

echo "New 파일 bug read: $(wc -l < "$TMPDIR/new_bug_read_targets.txt") 건"
```

**호출 체인 추적 (Changed 파일 기반 — 범용):**

B-3 read에서 **Changed**로 판정된 모든 파일과 B-1.5 `desc_change_targets.txt`의 클래스에 대해 호출 체인(callers)을 추적한다. 티켓 타입(버그, 신규 기능, 개선, 슬롯)과 무관하게 **항상 실행**한다.

**목적**: 변경된 코드를 참조하는 다른 모듈을 파악해 리그레션 범위를 결정한다.
- 버그: 수정된 함수의 호출처 → 같은 버그가 다른 곳에 없는지
- 신규 기능: 프레임워크 변경(desc_change_targets) → 기존 기능 호환성
- 개선/리팩터: 변경된 API의 소비자 → 서명/동작 변경 영향
- 슬롯: 공용 컴포넌트 변경 → 어느 슬롯이 참조하는지 개별 열거

```bash
# 1. Changed 파일에서 클래스명 추출 (범용 단어 필터 포함)
$PYTHON -c "
import os, re, glob, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

# ⚠️ CALLER_STOPWORDS: 단독으로 grep하면 100+ hits → truncated → 유효 caller 추출 불가인 단어.
# PascalCase 합성명(PopupManager, ContentsManifest 등)은 이 목록에 넣지 않는다.
CALLER_STOPWORDS = {
    'Active', 'InActive', 'Contents', 'Server', 'Version', 'Popup',
    'Slots', 'SlotMaker', 'manifest', 'Changed', 'Added', 'Fixed',
    'Open', 'Close', 'Main', 'Base', 'Data', 'Config', 'Manager',
    'Controller', 'Editor', 'Scripts', 'Test', 'Tests', 'Core',
}

changed_classes = set()

# standalone read에서 Changed 판정 (head ≠ base, base 비어있지 않음)
for hf in glob.glob('$TMPDIR/read_*_head.txt'):
    m = re.match(r'read_(.+)_head\.txt$', os.path.basename(hf))
    if not m: continue
    key = m.group(1)
    bf = os.path.join('$TMPDIR', f'read_{key}_base.txt')
    if not os.path.exists(bf): continue
    hc = open(hf, encoding='utf-8', errors='replace').read()
    bc = open(bf, encoding='utf-8', errors='replace').read()
    if not bc.strip(): continue  # base 비면 New (Changed 아님)
    if hc == bc: continue  # Unchanged
    # Changed — 파일명에서 클래스명 추출
    parts = key.replace('.cs', '').replace('.ts', '').replace('.js', '').split('_')
    cls = parts[-1] if parts else key
    if len(cls) >= 3:
        changed_classes.add(cls)

# desc_change_targets 추가 (description에서 명시된 변경 대상)
targets_path = os.path.join('$TMPDIR', 'desc_change_targets.txt')
if os.path.exists(targets_path):
    for line in open(targets_path, encoding='utf-8', errors='replace'):
        cls = line.strip()
        if cls and len(cls) >= 3:
            changed_classes.add(cls)

# 필터: 범용 단어 제거, 파일 확장자 포함 제거
changed_classes = {
    cls for cls in changed_classes
    if cls not in CALLER_STOPWORDS and '.' not in cls
}

for cls in sorted(changed_classes):
    print(cls)
" > "$TMPDIR/caller_targets.txt"

echo "caller targets: $(wc -l < "$TMPDIR/caller_targets.txt") 건"

# 2. 각 클래스명으로 역참조 grep (병렬 — job limit 4)
# ⚠️ portable 배열 빌드 사용 — while read 안에서 repob 호출 금지 (stdin 리다이렉트 → repob 0B 반환)
# portable while-read 배열 빌드 (mapfile은 bash 3.2/zsh 미지원 — 헤더 정본 참고)
_B3_CALLERS=()
while IFS= read -r _LINE || [ -n "$_LINE" ]; do
  [ -z "$_LINE" ] && continue
  _B3_CALLERS+=("$_LINE")
done < "$TMPDIR/caller_targets.txt"
_JOB_COUNT=0
for CLASS_NAME in "${_B3_CALLERS[@]}"; do
  CLASS_NAME=$(echo "$CLASS_NAME" | tr -d '\r\n')
  [ -z "$CLASS_NAME" ] && continue
  # 이미 grep된 키워드면 기존 결과 복사 (중복 repob 호출 방지)
  if [ -f "$TMPDIR/grep_client_${CLASS_NAME}.txt" ]; then
    cp "$TMPDIR/grep_client_${CLASS_NAME}.txt" "$TMPDIR/callers_${CLASS_NAME}.txt"
  else
    $REPOB remote grep client "$TARGET_BRANCH" "$CLASS_NAME" --pretty \
      > "$TMPDIR/callers_${CLASS_NAME}.txt" 2>/dev/null &
    _JOB_COUNT=$(( _JOB_COUNT + 1 ))
    if [ "$_JOB_COUNT" -ge 4 ]; then wait; _JOB_COUNT=0; fi
  fi
done
wait

# 3. callers_*.txt → callers.txt 병합 (정본)
$PYTHON -c "
import glob, re, json, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
seen = set()
SKIP_EXT = ('.prefab', '.meta', '.asset', '.unity', '.anim', '.controller', '.png', '.jpg', '.wav', '.mp3')
for fpath in sorted(glob.glob('$TMPDIR/callers_*.txt')):
    raw = open(fpath, encoding='utf-8', errors='replace').read().strip()
    if not raw: continue
    try:
        data = json.loads(raw)
        if isinstance(data, dict) and 'matches' in data:
            for m in data['matches']:
                p = m.get('file', '')
                if p and p not in seen and not p.endswith(SKIP_EXT):
                    seen.add(p); print(p)
            continue
    except (json.JSONDecodeError, ValueError):
        pass
    for line in raw.split('\n'):
        m = re.match(r'^([^:]+):\d+:', line.strip())
        if m:
            p = m.group(1).strip()
            if p and p not in seen and not p.endswith(SKIP_EXT):
                seen.add(p); print(p)
" > "$TMPDIR/callers.txt"

echo "callers: $(wc -l < "$TMPDIR/callers.txt") 건"
```

**STEP 2 보정 규칙**: callers.txt에 포함된 파일 중 영향 범위 판단에 중요한 파일이 아직 read되지 않았다면, Claude Code는 해당 파일을 추가 read한 뒤 evidence 반영 여부를 다시 확인한다.

**출력 규칙 (STEP 2 영향 범위에서):**
- "기존 슬롯 전체" 처럼 뭉개지 말고 **파일명에서 슬롯명을 추출해 개별 열거**한다
- read 없이 grep hit 파일명만으로도 슬롯명 열거에 활용 가능
- callers 0건이면 영향 범위를 "호출 체인 미확인"으로 명시한다

#### B-4. Level 4 — 자연어 탐색 (Level 3에서도 부족할 때)

```
# 설명 예시 — 실제 실행 시 {키워드}를 Level 1~3에서 사용한 키워드로 치환
$REPOB remote query client "$TARGET_BRANCH" "이 기능의 진입점은 어디인가: {키워드}" --pretty \
  > "$TMPDIR/query_result_{키워드}.txt" 2>/dev/null
```

**query 결과 처리 규칙:**
1. query가 반환한 파일 경로는 반드시 `$REPOB remote read`로 실제 존재 여부를 확인한다
2. read가 성공한 파일만 Evidence에 등록한다
3. read가 실패하거나 빈 결과면 해당 경로는 **"query 결과 미검증 (read 실패)"** 로 기재하고 Evidence에서 제외한다
4. query 결과 자체가 없으면 "Level 4 탐색 결과 없음" 으로 명시한다

query 결과에서 존재가 확인된 새 파일이 발견되면 Level 3로 복귀한다.

#### 탐색 종료 조건

**분기 A (PR 있음):**
- Evidence 파일 2건 이상 확보하면 종료 가능
- 단, Changed 파일이 있으면 → 종료 전 호출 체인 추적(callers grep)을 반드시 실행한다 (B-3의 "호출 체인 추적" 블록과 동일 로직)

**분기 B (PR 없음):**
- **Changed 파일 있을 때**: 호출 체인 추적(callers grep) 완료 후 종료
- Evidence 파일 **5건 이상** 확보
- Level 4까지 실행해도 신규 파일 미발견
- 동일 파일이 반복 등장 (수렴)

---

## STEP 1.4: 부가 산출물 저장

evidence.py가 읽는 중간 파일을 STEP 1 탐색 결과로부터 명시적으로 생성한다. **이 단계는 분기 A/B 공통으로 STEP 1.5 직전에 실행한다.**

> **실행 규칙 재확인**
> 이 섹션 이하의 standalone `bash` 블록은 실행 전에 상단 `공통 부트스트랩 (정본)`을 반드시 먼저 붙인다.
> 코드 블록 본문에 부트스트랩이 생략돼 있어도 예외 없이 삽입한다.

### read_results/ (grep+read 비교 판정 — 분기 B 전용)

분기 B (PR 없음) 경로에서만 의미 있다. 분기 A는 pr_diff에서 이미 상태를 확보한다.

**evidence.py는 3-tier 탐색**으로 read 파일을 찾는다: `read_results/{repo}/` → `read_results/` → `$TMPDIR/read_*_head.txt` (standalone). Level 3에서 이미 standalone read를 했다면 여기서 **같은 파일을 중복 읽지 않는다.** Level 3에서 읽지 않은 나머지 grep hit 파일만 read_results/에 저장한다.

**client와 server는 repo가 다르므로 반드시 별도 서브디렉토리에 저장한다.**

```bash
mkdir -p "$TMPDIR/read_results/client" "$TMPDIR/read_results/server"

# ── client hit 파일 수집 (grep_client_*.txt만) ───────────────────────────────
_extract_hits() {
  local PATTERN="$1"
  $PYTHON -c "
import glob, re, json, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
seen = set()
# .prefab/.meta/.asset/.unity 파일은 read해도 무의미 — 제외
SKIP_EXT = ('.prefab', '.meta', '.asset', '.unity', '.anim', '.controller', '.png', '.jpg', '.wav', '.mp3')
for fpath in sorted(glob.glob('$TMPDIR/${PATTERN}')):
    try:
        raw = open(fpath, encoding='utf-8', errors='replace').read().strip()
        if not raw: continue
        try:
            data = json.loads(raw)
            if isinstance(data, dict) and 'matches' in data:
                for m in data['matches']:
                    p = m.get('file', '')
                    if p and p not in seen and not p.endswith(SKIP_EXT):
                        seen.add(p); print(p)
                continue
        except: pass
        for line in raw.split('\n'):
            m = re.match(r'^([^:]+):\d+:', line.strip())
            if m:
                p = m.group(1).strip()
                if p not in seen and not p.endswith(SKIP_EXT):
                    seen.add(p); print(p)
    except: continue
"
}

_extract_hits "grep_client_*.txt" > "$TMPDIR/hit_files_client.txt"
_extract_hits "grep_server_*.txt" > "$TMPDIR/hit_files_server.txt"

# ── client: client repo에서 head/base 읽기 (순차) ──
# ⚠️ portable 배열 빌드 사용 — while read 안에서 repob 호출 금지 (stdin 리다이렉트 → repob 0B 반환)
# Level 3에서 standalone read($TMPDIR/read_*_head.txt)가 이미 있는 파일은 건너뛴다
# portable while-read 배열 빌드 (mapfile은 bash 3.2/zsh 미지원 — 헤더 정본 참고)
_HIT_CLIENT=()
while IFS= read -r _LINE || [ -n "$_LINE" ]; do
  [ -z "$_LINE" ] && continue
  _HIT_CLIENT+=("$_LINE")
done < "$TMPDIR/hit_files_client.txt"
for FILE_PATH in "${_HIT_CLIENT[@]}"; do
  FILE_PATH=$(echo "$FILE_PATH" | tr -d '\r\n')
  [ -z "$FILE_PATH" ] && continue
  SAFE=$(echo "$FILE_PATH" | sed 's|/|_|g')
  # standalone head가 0B가 아닌 상태로 존재 시: head skip, base만 보충 (base 누락 시 evidence.py가 BaseUnavailable로 판정)
  if [ -s "$TMPDIR/read_${SAFE}_head.txt" ]; then
    if [ -n "$BASE_BRANCH" ] && [ ! -s "$TMPDIR/read_${SAFE}_base.txt" ]; then
      $REPOB remote read client "$BASE_BRANCH" "$FILE_PATH" --pretty \
        > "$TMPDIR/read_${SAFE}_base.txt" 2>/dev/null
    fi
    continue
  fi
  $REPOB remote read client "$TARGET_BRANCH" "$FILE_PATH" --pretty \
    > "$TMPDIR/read_results/client/head_${SAFE}.txt" 2>/dev/null
  [ -n "$BASE_BRANCH" ] && \
    $REPOB remote read client "$BASE_BRANCH" "$FILE_PATH" --pretty \
      > "$TMPDIR/read_results/client/base_${SAFE}.txt" 2>/dev/null
done

# ── server: server repo에서 head/base 읽기 (순차) ──
# portable while-read 배열 빌드 (mapfile은 bash 3.2/zsh 미지원 — 헤더 정본 참고)
_HIT_SERVER=()
while IFS= read -r _LINE || [ -n "$_LINE" ]; do
  [ -z "$_LINE" ] && continue
  _HIT_SERVER+=("$_LINE")
done < "$TMPDIR/hit_files_server.txt"
for FILE_PATH in "${_HIT_SERVER[@]}"; do
  FILE_PATH=$(echo "$FILE_PATH" | tr -d '\r\n')
  [ -z "$FILE_PATH" ] && continue
  SAFE=$(echo "$FILE_PATH" | sed 's|/|_|g')
  $REPOB remote read server "$SERVER_BRANCH" "$FILE_PATH" --pretty \
    > "$TMPDIR/read_results/server/head_${SAFE}.txt" 2>/dev/null
  [ -n "$SERVER_BASE_BRANCH" ] && \
    $REPOB remote read server "$SERVER_BASE_BRANCH" "$FILE_PATH" --pretty \
      > "$TMPDIR/read_results/server/base_${SAFE}.txt" 2>/dev/null
done
```

### config_flags.txt (설정/플래그 탐지 — Evidence 디렉토리 범위로 제한)

Evidence 파일 주변에서만 설정/플래그를 탐색한다. repob grep 자체는 전체 repo를 대상으로 실행되지만, **term당 1회만 호출**하고 Python에서 Evidence 디렉토리로 필터링한다.

```bash
# Evidence hit 파일의 디렉토리 목록 추출 → 결과 필터링에 사용
$PYTHON -c "
import sys, os, glob, json
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
dirs = set()
# PR changed files
for f in glob.glob('$TMPDIR/pr_files_client_*.json'):
    try:
        for item in json.load(open(f, encoding='utf-8', errors='replace')):
            if isinstance(item, dict) and item.get('filename'):
                dirs.add(os.path.dirname(item['filename']))
    except: pass
# grep hit files
for f in glob.glob('$TMPDIR/hit_files_*.txt'):
    for line in open(f, encoding='utf-8', errors='replace'):
        p = line.strip()
        if p: dirs.add(os.path.dirname(p))
# 상위 2단계 디렉토리로 정리 (너무 세분화 방지)
short = set()
for d in dirs:
    parts = d.replace('\\\\', '/').split('/')
    short.add('/'.join(parts[:3]) if len(parts) >= 3 else d)
for d in sorted(short):
    if d: print(d)
" > "$TMPDIR/evidence_dirs.txt"

# term당 1회 전체 grep → Evidence 디렉토리 매칭만 추출 (O(4) grep으로 제한)
: > "$TMPDIR/config_flags.txt"
for TERM in RemoteConfig FeatureFlag isEnabled defaultValue; do
  $REPOB remote grep client "$TARGET_BRANCH" "$TERM" --pretty 2>/dev/null \
    > "$TMPDIR/_cfg_raw_${TERM}.json" &
done
wait

# 전체 Evidence 디렉토리를 한 번의 Python pass로 필터
$PYTHON -c "
import json, sys, glob
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
dirs = [line.strip() for line in open('$TMPDIR/evidence_dirs.txt', encoding='utf-8', errors='replace') if line.strip()]
if not dirs:
    sys.exit(0)
for fpath in sorted(glob.glob('$TMPDIR/_cfg_raw_*.json')):
    try:
        d = json.load(open(fpath, encoding='utf-8', errors='replace'))
        for m in d.get('matches', []):
            f = m.get('file', '')
            if any(f.startswith(d_) for d_ in dirs):
                print(json.dumps(m, ensure_ascii=False))
    except: pass
" > "$TMPDIR/config_flags.txt"
```

---

## STEP 1.5: evidence.py 실행

> **실행 규칙 재확인**
> 이 섹션 이하의 standalone `bash` 블록은 실행 전에 상단 `공통 부트스트랩 (정본)`을 반드시 먼저 붙인다.
> 코드 블록 본문에 부트스트랩이 생략돼 있어도 예외 없이 삽입한다.

STEP 1 수집 결과를 정본 스크립트로 판정한다.

```bash
# evidence.py 경로 동적 탐색 (하드코딩 금지)
EVIDENCE_PY=""
for _try in \
  "./.claude/skills/ticket-qa/evidence.py" \
  "$HOME/.claude/skills/ticket-qa/evidence.py" \
  "$(cygpath -u "$(pwd)/.claude/skills/ticket-qa/evidence.py" 2>/dev/null || true)"
do
  [ -f "$_try" ] && EVIDENCE_PY="$_try" && break
done

if [ -z "$EVIDENCE_PY" ]; then
  echo "ERROR: evidence.py 미발견 — 코드 확정 판정 불가" >&2
  $PYTHON -c "
import json, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
result = {
  'key': '$TICKET_KEY', 'summary': '', 'type': '',
  'evidence_tag': '코드 미확인 (evidence.py 없음)',
  'client_evidence_level': '판정 불가 (evidence.py 없음)',
  'server_evidence_level': '판정 불가 (evidence.py 없음)',
  'evidence_files': [], 'callers': [], 'config_flags': [],
  'prs': []
}
json.dump(result, open('$TMPDIR/evidence.json', 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print('evidence.json: 빈 결과로 초기화 (evidence.py 없음)')
"
else
  $PYTHON "$EVIDENCE_PY" "$TMPDIR"
fi
```

결과: `$TMPDIR/evidence.json` 생성. evidence.py를 찾지 못하면 `evidence_tag`가 `"코드 미확인 (evidence.py 없음)"`인 빈 결과로 초기화된다. STEP 2에서 이 파일을 참조한다.

**STEP 2에서 evidence.json 유효성 확인 필수**: `evidence_tag`가 `"코드 미확인 (evidence.py 없음)"`이면 Evidence 섹션에 그 사실을 명시하고, 코드 기반 추론을 하지 않는다.

### STEP 1→2 전환 체크포인트 (필수 검증)

evidence.py 실행 직후, STEP 2 진입 전에 아래 검증을 **반드시 실행**한다. 누락 항목이 있으면 STEP 2로 넘어가지 않고 해당 수집을 재실행한다.

```bash
# ⚠️ STEP 1→2 체크포인트 — 이 블록을 생략하지 않는다
echo "=== STEP 1→2 체크포인트 ==="
_PASS=true

# 1. evidence.json 존재
if [ ! -s "$TMPDIR/evidence.json" ]; then
  echo "FAIL: evidence.json 미생성 — STEP 1.5 재실행 필요"
  _PASS=false
fi

# 2. server query 반영 여부 (server grep 0 hits인 경우만)
SERVER_TOTAL_HITS=$($PYTHON -c "
import json, sys, glob
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
total = 0
for f in glob.glob('$TMPDIR/grep_server_*.txt'):
    try:
        d = json.load(open(f, encoding='utf-8', errors='replace'))
        total += d.get('count', 0)
    except: pass
print(total)
" 2>/dev/null || echo 0)

if [ "$SERVER_TOTAL_HITS" -eq 0 ]; then
  if [ ! -s "$TMPDIR/server_query_result.txt" ]; then
    echo "FAIL: server grep 0 hits인데 server_query_result.txt 미생성 — B-2.5 재실행 필요"
    _PASS=false
  else
    echo "OK: server_query_result.txt $(wc -c < "$TMPDIR/server_query_result.txt")B"
  fi
fi

# 3. Changed 파일 read 존재 여부 (desc_change_targets 대상)
if [ -s "$TMPDIR/desc_change_targets.txt" ]; then
  _READ_COUNT=$(ls "$TMPDIR"/read_*_head.txt 2>/dev/null | wc -l)
  if [ "$_READ_COUNT" -eq 0 ]; then
    echo "WARN: desc_change_targets 있지만 read 파일 0건 — B-1.5/B-3 확인 필요"
  else
    echo "OK: read HEAD 파일 ${_READ_COUNT}건"
  fi
fi

if [ "$_PASS" = true ]; then
  echo "체크포인트 통과 — STEP 2 진입"
else
  echo "체크포인트 실패 — 위 FAIL 항목 해결 후 STEP 2 진입"
fi
```

---

## STEP 2: 티켓 분석 (딥 다이브 결과 활용)

`$TMPDIR/evidence.json`과 수집된 코드를 기반으로 분석을 수행한다.

**evidence.json `server_query` 필드 활용**: evidence.json에 `server_query` 객체가 존재하면 (`source`, `answer` 키), 서버 관련 분석 시 이 데이터를 적극 참조한다. 특히 server grep 0 hits인 경우 server_query.answer가 유일한 서버 근거이므로 "[서버 구조 (query)]" 섹션을 반드시 생성한다.

### 2-1. 테스트 방법

release-diff STEP 3-A 출력 형식 기반이되 **단일 티켓이므로 더 구체적**으로 작성한다.

```
[테스트 방법]
- 진입 경로: (게임 내에서 해당 기능에 도달하는 구체적 경로 — 메뉴 > 탭 > 버튼 순서)
- 전제 조건: (테스트 전 필요한 상태 — 계정 조건, 레벨, 보유 재화 등)
- 재현 절차:
  1. {구체적 조작 단계 1}
  2. {구체적 조작 단계 2}
  3. ...
- 확인 포인트:
  1. {무엇을 확인하는지 + 기대 동작}
  2. ...
- 예상 결과: (정상 동작 시 사용자에게 보이는 결과)
- Evidence: [코드 위치] (Changed / New / Removed / Unchanged / BaseUnavailable / 미확인 중 하나로 상태 표시)
  - BaseUnavailable인 경우: `비교 불가 (base read failed)` 라벨로 출력. 변경 여부를 단정하지 않는다
  - Removed인 경우: 삭제된 기능/파일이 대체됐는지, 완전 제거됐는지 확인 포인트 추가
- **open PR 참고 (있는 경우만)**: ⚠️ `(open PR #번호 — 예정 변경, 미확정)` — Evidence 행과 **별도 행**으로 출력
```

**재현 절차 작성 원칙:**
- QA 테스터가 **코드를 모르는 상태에서** 그대로 따라할 수 있어야 한다
- "해당 기능 진입" 같은 추상적 표현 금지 — 구체적 메뉴/버튼/탭 경로를 기재
- 코드에서 파악된 분기 조건(if문, 상태 체크)을 **사용자 관점 조건**으로 변환해 기재 (예: `if (betLevel >= 3)` → "베팅 레벨 3 이상으로 설정한 상태에서")
- 재현 절차는 PR diff/커밋 메시지에서 파악된 변경 조건을 반드시 반영한다
- **New 파일 head read 활용**: B-3에서 수집한 `$TMPDIR/new_bug_read_targets.txt` 및 해당 파일의 repob read 결과에서 파악한 초기화/갱신/분기 로직을 확인 포인트에 코드 근거로 반영한다. 예: 잭팟 초기화 함수에서 0 체크 로직 발견 → "잭팟 보드 진입 시 금액이 000이 아닌 정상 값 표시" 확인 포인트 도출

### 2-2. 딥 다이브 추가 분석 (release-diff 대비 차별점)

1. **PR diff 정밀 분석**: 패치 hunk에서 before/after 비교 → "정확히 뭐가 바뀌었는지" 명시. 변경된 분기 조건/파라미터에서 엣지 케이스 추출
2. **호출 체인 역추적**: 변경 함수명을 `$REPOB remote grep`으로 탐색 → grep hit 파일을 반드시 `$REPOB remote read`로 실제 코드 확인 → read에서 실제 호출 코드가 확인된 파일만 소비자 목록에 포함. **grep hit만으로는 호출 관계를 단정하지 않는다.** read 결과가 없거나 실패하면 "호출 체인 미확인"으로 기재한다.
3. **서버-클라이언트 교차 검증**: 클라이언트 변경 → 서버에서 같은 API/필드명 grep. 결과를 아래 항목 중 하나로 반드시 명시한다:
   - **양측 확인**: client PR diff + server repob read 모두에서 관련 변경 확인됨
   - **client만 확인**: client PR diff는 명확하나 server repob에서 관련 코드 미발견
   - **server 근거 부족**: server repob 권한 제약 또는 0 hits — server 영향 없음으로 단정하지 않는다
   - **server query 결과 있음**: `evidence.json`의 `server_query.answer` 또는 `$TMPDIR/server_query_result.txt`에서 파악한 서버 구조 정보를 "[서버 구조 (query)]" 섹션으로 테스트 방법에 추가 반영한다. query 결과는 자연어 추론이므로 grep+read로 확인된 파일보다 신뢰도 낮음을 명시한다. 서버 등록 여부, API 엔드포인트, 게임 설정 등 QA에 필요한 정보를 추출해 확인 포인트에 포함한다.
4. **설정/플래그 변경 탐지**: 변경 파일 주변에서 `RemoteConfig`, `FeatureFlag`, `isEnabled`, `defaultValue` 추가 grep → default 값 변경 시 테스트 포인트에 포함
5. **PR 커밋 메시지 활용**: `$TMPDIR/commit_messages.txt`에서 수집한 커밋 메시지를 분석해 테스트 조건을 구체화한다. "on bet change", "when jackpot initialized" 같은 조건 표현이 있으면 확인 포인트에 반드시 반영한다. PR body와 커밋 메시지가 충돌하면 커밋 메시지를 우선한다.

### 2-3. 코드 변경 → 사용자 영향

evidence_files[]에서 **Changed/New/Removed** 상태인 파일 각각에 대해 **코드 변경이 사용자에게 어떻게 보이는지** 1문장으로 번역한다.

```
[코드 변경 → 사용자 영향]
- {파일:라인} {변경 요약}
  → {사용자에게 보이는 동작 변화 1문장}
- {파일:라인} {변경 요약}
  → {사용자에게 보이는 동작 변화 1문장}
```

**대상 판정:**
- **번역 대상**: state가 Changed, New, Removed인 파일
- **번역 대상 아님**: state가 Unchanged, 미확인인 파일 — 코드 변경이 확인되지 않았으므로 사용자 영향을 번역할 근거가 없다
- evidence_files가 1건 이상이지만 Changed/New/Removed가 0건이면: `[코드 변경 → 사용자 영향] 변경 확인된 파일 없음 (Unchanged/미확인만 존재) — 생략`으로 출력
- evidence_files 자체가 0건이면: `[코드 변경 → 사용자 영향] evidence_files 없음 — 생략`으로 출력

**규칙:**
- 번역 대상이 1건 이상이면 이 섹션은 **반드시 출력**한다
- diff/read에서 확인된 실제 코드 변경만 기술한다 (추론 금지)
- "내부 리팩토링으로 사용자 영향 없음"도 유효한 출력이다
- 사용자 영향이 불확실하면 `→ 영향 불확실 — {이유}`로 명시한다 (빈칸 채우기 금지)

**예시:**
```
[코드 변경 → 사용자 영향]
- PopupManager.Close() L127: base.Close() → this.Close()
  → 스택 top이 아니라 self만 닫혀, 뒤에 깔린 팝업이 화면에 남을 수 있음
- RewardPopup.Show() L45: delay 0.5f → 0.3f
  → 보상 팝업 등장 애니메이션이 0.2초 빨라짐
- CoinManager.cs L200: 내부 변수명 리네이밍
  → 내부 리팩토링으로 사용자 영향 없음
```

### 2-4. 영향 범위 분석

```
[티켓 외 영향 범위]
- 직접 영향 (High): 코드 공유로 반드시 같이 확인해야 하는 기능 — grep/read로 확인된 호출 관계 필수
- 간접 영향 (Medium): 흐름 연동으로 영향 가능성 있는 기능 — 코드 근거(grep hit 파일 또는 호출 체인) 필수 기재
- 확인 권고 (Low): 근거 약하나 리스크 존재 — "추론" 임을 명시
- 영향 없음: 근거와 함께 명시
```

**할루시네이션 방지 원칙**: High/Medium은 반드시 코드 근거(파일명, grep hit, read 결과)를 기재한다. grep/read 없이 "아마 영향 있을 것"이라는 추론만으로 Medium 이상을 부여하지 않는다. 코드 근거가 없으면 Low 또는 생략한다.

탐색 대상:
- **공용 컴포넌트**: 다른 기능에서도 사용되는 코드
- **연결 흐름**: 보상, 팝업, 라우팅, 초기화 경로
- **설정값/플래그**: `default`, `config`, `flag`, `enable`, `disable`, `show`, `hide`
- **서버-클라이언트 인터페이스**: 한쪽만 변경 시 다른 쪽 영향

**공용 컴포넌트 영향 범위 출력 규칙:**

Changed 파일이 공용 컴포넌트(PopupManager, JackpotBoard, JackpotBoardController 등)인 경우:
- STEP 1 B-3에서 수집한 `callers_*.txt`를 읽어 참조 슬롯 파일명을 개별 열거한다
- 출력 형식: `직접 영향 (High): Wolf Moon, Rich Hits, Wild Hit Buffalo, Spin Blitz, ... (JackpotBoardController 참조 확인)`
- grep hit 파일명만으로 슬롯명을 식별할 수 있으면 read 없이도 열거 가능
- **"기존 슬롯 전체", "모든 슬롯" 같은 뭉개기 금지** — 파일명에서 확인된 슬롯만 열거하고 미확인은 "외 N건"으로 명시

### 2-5. 기획서 비교

기획서 비교는 이 스킬의 범위 밖이다. 항상 아래 한 줄만 출력한다:

```
[기획서 비교]
→ /spec-review {TICKET_KEY} 로 Google Drive 기획서를 별도 분석할 수 있습니다.
```

**금지 사항**: Jira 설명(description)이나 PR body 텍스트만으로 일치/불일치 판정을 하지 않는다.

### 2-6. Evidence 목록

repo별 등급을 먼저 표시한 뒤 파일 목록을 출력한다.

```
[Evidence]
분석 한계: 서버 저장소는 GitHub PR diff 직접 확인 불가 — repob 기반 간접 확인만 수행
- client: {client_evidence_level}
- server: {server_evidence_level}
---
- {path} | {state} | {source} | {diff_summary}
- {path} | {state} | {source} | {diff_summary}
호출 체인: {callers 목록}
설정 플래그: {config_flags 목록 또는 "없음"}
```

### 2-7. QA 체크리스트

분석 결과를 **영향 항목별로 그룹화**한 체크리스트. open PR이 있으면 `[open]` 프리픽스를 추가한다.

```
[QA 체크리스트]

■ {영향 항목 1: 변경된 기능/컴포넌트명}
  [ ] 기본 동작: {이 변경의 정상 시나리오 확인} — 근거: {파일:라인}
  [ ] 리그레션: {이 변경으로 깨질 수 있는 기존 동작} — 근거: {callers 또는 영향 범위 파일}

■ {영향 항목 2}
  [ ] 기본 동작: ... — 근거: ...
  [ ] 리그레션: ... — 근거: ...

■ [open] {영향 항목 3} — PR #123 merge 후 재확인
  [ ] 기본 동작: ... — 근거: ...
```

**그룹화 규칙:**
- 영향 항목은 evidence_files의 Changed/New/Removed 파일 또는 2-4 영향 범위의 직접 영향에서 도출한다
- **Removed 파일**은 "삭제된 기능이 대체됐는지, 완전 제거됐는지" 확인 체크를 기본 동작으로 포함한다
- 각 영향 항목에 **최소 1개 기본 동작** + **관련 리그레션 체크**를 묶는다
- 리그레션 항목은 callers.txt 또는 영향 범위에서 도출된 것만 기재한다 — 근거 없는 리그레션 추론 금지
- 리그레션 근거가 없으면 기본 동작만 출력한다 (리그레션 행 생략)
- [open] 프리픽스 규칙은 현행 유지
- **하위 작업 분리 표시 (0-4.5 산출물 활용)**: 두 TSV 모두 컬럼은 `key / issuetype / priority / summary` (3번째 컬럼이 priority).
  - `subtask_new_impl.tsv` 항목은 `■ [{priority}] {key} | {summary}` 형식으로 본 그룹에 정렬 출력한다 (priority가 빈 값이면 `[ ]`).
  - `subtask_regression.tsv` 항목은 본 그룹 끝 `■ [회귀 확인 — 사후 수정]` 블록으로 묶어 부모 영역 통합 회귀로 커버한다.
  - **High/Highest 개별 승격**: 회귀 블록의 `priority`가 `High` 또는 `Highest`인 항목만 별도 체크리스트 행으로 승격하고, 나머지는 통합 회귀 한 줄로 흡수한다. priority가 빈 값/Medium/Low인 항목은 승격하지 않는다.
  - 두 파일 모두 비어있으면 분리 블록은 출력하지 않는다.
- **보조 확인 미검증 표시 (0-5-F unverified flag 활용)**: `pr_fallback_search_unverified.flag` 또는 `pr_fallback_head_unverified.flag`가 존재하면 체크리스트 최상단에 `> ⚠️ PR fallback 미검증 — 분석은 핵심 단계 기준으로 진행됨` 한 줄을 삽입한다.

---

## STEP 3: 출력 + Slack (선택)

### 3-1. 대화에 결과 출력

STEP 2의 전체 분석 결과를 대화에 출력한다. 출력 순서:

1. 티켓 요약 (키, 제목, 타입, 우선순위, 담당자, Evidence 태그 + client 등급 / server 등급)
   - client 등급과 server 등급이 다른 경우 **반드시 둘 다 명시**한다. 단일 Evidence 태그만 보고 server 한계를 숨기지 않는다.
2. 테스트 방법
3. 코드 변경 → 사용자 영향
4. 영향 범위
5. 기획서 비교
6. Evidence 목록
7. QA 체크리스트

open PR이 있는 경우 최상단에 경고를 삽입한다:
```
⚠️ open PR #{num} 기반 분석 — merge 전이므로 코드가 변경될 수 있음
```

### 3-2. 파일 저장

> **설계 의도**: 분석 결과 텍스트에 single quote·backtick·특수문자가 포함되면 HEREDOC가 비결정적으로 깨진다. **Write 도구**를 사용해 저장한다. Bash 블록이 아니라 Claude Code의 Write 도구 호출이다.

두 개의 파일을 **Write 도구**로 저장한다.

**analysis_output.md** — STEP 2 전체 출력 (Evidence, 기획서 비교 포함 상세본):

```
Write 도구 호출:
  file_path: $TMPDIR/analysis_output.md     ← $TMPDIR을 실제 경로로 치환
  content:   {STEP 2 전체 출력 내용}
```

**slack_output.md** — 슬랙/Jira 공통 요약본 (테스터용 — Evidence·기획서비교 제외):

```
Write 도구 호출:
  file_path: $TMPDIR/slack_output.md     ← $TMPDIR을 실제 경로로 치환
  content:   아래 템플릿에 분석 결과를 채운 텍스트
```

slack_output.md 템플릿:
```
[ticket-qa 분석 결과]

*테스트 방법*
진입 경로: {진입 경로}
전제 조건: {전제 조건}

*재현 절차*
1. {구체적 조작 단계 1}
2. {구체적 조작 단계 2}

*확인 포인트*
1. {확인 포인트 1}
2. {확인 포인트 2}

*예상 결과*
- {예상 결과}

*코드 변경 → 사용자 영향*
- {파일:라인} {변경 요약} → {사용자 영향 1문장}
- {파일:라인} {변경 요약} → {사용자 영향 1문장}

*영향 범위*
- 직접: {직접 영향 — 기능명으로 기술}
- 간접: {간접 영향}

*QA 체크리스트*
■ {영향 항목 1}
  [ ] 기본 동작: {정상 시나리오} — 근거: {파일}
  [ ] 리그레션: {기존 동작 확인} — 근거: {파일}
■ {영향 항목 2}
  [ ] 기본 동작: ... — 근거: ...
```

포함하지 않는 항목: Evidence 파일 목록, 기획서 비교, 호출 체인, 설정 플래그

### 3-3. spec-fetch 안내

결과 출력 직후 아래 안내를 출력한다:

> **기획서 비교는 `/spec-review {TICKET_KEY}` 스킬로 분리됐다.** 이 분석 결과를 컨텍스트로 Google Drive 기획서를 읽어와 요구사항과 구현을 교차 검증한다.

---

### 3-4. Slack 전송

> **실행 규칙 재확인**
> 이 섹션 이하의 standalone `bash` 블록은 실행 전에 상단 `공통 부트스트랩 (정본)`을 반드시 먼저 붙인다.
> 코드 블록 본문에 부트스트랩이 생략돼 있어도 예외 없이 삽입한다.

기본 채널은 `#qa-ai-report` (ID: `C0AQTSRRFHC`).

AskUserQuestion으로 Slack 전송 여부를 확인한다.

```
question: "분석 결과를 Slack에 전송할까요?"
options:
  - label: "전송",  description: "#qa-ai-report 채널에 전송합니다"
  - label: "건너뛰기",  description: "Slack 전송 없이 종료합니다"
```

**"전송" 선택 시:** 기본 채널 `#qa-ai-report` (C0AQTSRRFHC)로 바로 전송한다. 별도 채널 질문 없이 진행한다.

**Slack 전송 형식** (release-diff 6-2 패턴):

**부모 메시지** (채널에 노출):
```
_ticket-qa_
*[{TICKET_KEY}]* {티켓 제목}
타입: {타입} | 우선순위: {우선순위} | 담당: {담당자}
{JIRA_BASE}/browse/{TICKET_KEY}
```

**스레드 답글**: `slack_output.md` 내용을 그대로 전송한다 (Evidence/기획서비교 제외 — 3-2에서 이미 필터됨).

open PR인 경우 부모 메시지에 `open PR` 명시, 스레드 첫 줄에 `⚠️ open PR #{num} 기반 — merge 전이므로 변경 가능` 경고 추가.

5000자 초과 시 영향 범위를 두 번째 스레드 답글로 분리한다.

---

### 3-5. Jira 코멘트 등록

Slack 전송이 완료된 경우에만 실행한다. 전송 전 AskUserQuestion으로 확인한다.

```
question: "Jira 티켓에 QA 분석 코멘트를 등록할까요?"
options:
  - label: "전송",  description: "{TICKET_KEY} 티켓에 코멘트 등록"
  - label: "건너뛰기",  description: "Jira 코멘트 등록하지 않음"
```

사용자가 "건너뛰기"를 선택하면 Jira 코멘트 등록을 건너뛰고 스킬을 종료한다.

Slack에 보낸 내용(부모 메시지 + 스레드 답글)을 Jira 티켓 코멘트로 등록한다.

**코멘트 내용:** `slack_output.md` 내용을 사용한다 (Evidence·기획서비교 미포함). Jira wiki markup과 Slack mrkdwn은 `*bold*`와 `_italic_`이 호환되므로 대부분 그대로 렌더링된다. 하단에 `_Slack: #qa-ai-report 에도 전송됨_` 한 줄을 추가한다.

open PR이 있는 경우 코멘트 최상단에 경고를 삽입한다.

```bash
# ── 공통 부트스트랩 (정본 — 수정 금지) ──
TICKET_KEY={입력받은 티켓 키}
export TMPDIR="$(cygpath -m /tmp 2>/dev/null || echo /tmp)/ticket-qa-${TICKET_KEY}"
PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)
CTX="$TMPDIR/run_context.json"
[ -f "$CTX" ] || { echo "ERROR: run_context.json not found: $CTX"; exit 1; }

# Jira 코멘트 등록 — Python이 run_context.json + jira.json을 직접 읽는다
# 셸 변수 문자열 주입 없음
$PYTHON - "$CTX" << 'PYEOF'
import sys, json, urllib.request, base64, os
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

ctx_path = sys.argv[1]
ctx = json.load(open(ctx_path, encoding='utf-8'))
jira_json = json.load(open(ctx['jira_json_path'], encoding='utf-8'))

jira_base   = ctx['jira_base']
ticket_key  = ctx['ticket_key']
jira_auth   = f"{jira_json['email']}:{jira_json['token']}"
auth_header = base64.b64encode(jira_auth.encode()).decode()
tmpdir      = os.path.dirname(ctx_path)

# open PR 여부: evidence.json의 prs 목록 확인
try:
    ev = json.load(open(os.path.join(tmpdir, 'evidence.json'), encoding='utf-8', errors='replace'))
    open_prs = [p for p in ev.get('prs', []) if p.get('status', '').lower() == 'open']
except Exception:
    open_prs = []

lines = []
if open_prs:
    nums = ', '.join(f'#{p["num"]}' for p in open_prs)
    lines.append(f'⚠️ open PR {nums} 기반 분석 — merge 전이므로 코드가 변경될 수 있음')
    lines.append('')
lines.append(open(os.path.join(tmpdir, 'slack_output.md'), encoding='utf-8', errors='replace').read())
lines.append('')
lines.append('_Slack: #qa-ai-report 에도 전송됨_')
comment_body = '\n'.join(lines)

payload = json.dumps({'body': comment_body}).encode('utf-8')
url = f'{jira_base}/rest/api/2/issue/{ticket_key}/comment'
req = urllib.request.Request(url, data=payload, headers={
    'Authorization': f'Basic {auth_header}',
    'Content-Type': 'application/json'
}, method='POST')

try:
    with urllib.request.urlopen(req) as resp:
        result = json.load(resp)
        print(f'Jira 코멘트 등록 완료: {jira_base}/browse/{ticket_key}?focusedCommentId={result["id"]}')
except Exception as e:
    print(f'Jira 코멘트 등록 실패: {e}')
PYEOF
```

---

## Evidence 판정 기준

판정 로직은 `evidence.py`가 정본이다. SKILL.md에서 중복 정의하지 않는다. `evidence.json`의 필드를 그대로 사용한다.

**evidence.json 주요 필드:**
- `evidence_tag` — 통합 판정 태그
- `client_evidence_level` / `server_evidence_level` — repo별 등급
- `evidence_files[].state` — 파일별 상태 (Changed / New / Removed / Unchanged / BaseUnavailable / 미확인)
- `evidence_files[].state_label` — BaseUnavailable인 경우 출력용 라벨 (`비교 불가 (base read failed)`)
- `unresolved_base_reads` — base 비교 불가 파일 요약 리스트
- `version_targets` — fixVersions 기반 버전 대상 리스트

**코드 확정 대상**: Changed, New, Removed
**코드 확정 제외**: BaseUnavailable, Unchanged, 미확인

## repob vs gh API 우선순위

| 상황 | 도구 |
|------|------|
| client PR files | gh API |
| server PR/코드 | repob (gh API 접근 불가) |
| PR 없음 + 브랜치 확정 | repob grep → read |
| 코드 위치 불명 | repob query |
