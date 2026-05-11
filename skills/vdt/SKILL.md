# /vdt — 가상 개발팀: 기획 문서 리스크 분석

**트리거**: `/vdt [TICKET_KEY]` 또는 "vdt 실행", "가상 개발팀 분석"

---

## 실행 전 확인

인자가 없으면 `AskUserQuestion`으로 한 번 묻는다.

```
question: "분석할 Jira 티켓 키를 Other에 직접 입력해 주세요."
options:
  - label: "예시", description: "CVS-13045  ← Other에 이 형식으로 입력"
```

입력값이 `[A-Z]+-\d+` 형식이 아니면 같은 질문으로 한 번 더 묻는다.

---

## STEP 0: 초기화

```bash
TICKET_KEY={입력받은 티켓 키}
PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)

export TMPDIR="$(cygpath -m /tmp 2>/dev/null || echo /tmp)/vdt-${TICKET_KEY}"
rm -rf "$TMPDIR" && mkdir -p "$TMPDIR"

# skill 위치 기준으로 web/viewer.html 경로 설정
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SKILL_DIR/../.." && pwd)"
export VIEWER_PATH="$PROJECT_DIR/web/viewer.html"
export OUTPUT_PATH="$TMPDIR/report.html"
export TICKET_KEY

echo "TMPDIR: $TMPDIR"
echo "VIEWER_PATH: $VIEWER_PATH"
```

---

## STEP 1: Jira 인증 + 티켓 수집

```bash
source "$TMPDIR/../vdt-${TICKET_KEY}/../_" 2>/dev/null || true

JIRA_JSON="$(cygpath -m "$HOME/.bagelcode/jira.json" 2>/dev/null || echo "$HOME/.bagelcode/jira.json")"
if [ ! -f "$JIRA_JSON" ]; then
  echo "~/.bagelcode/jira.json 없음. 생성 후 재실행하세요."; exit 1
fi

JIRA_DOMAIN=$($PYTHON -c "import json,sys; sys.stdout.reconfigure(encoding='utf-8',errors='replace'); print(json.load(open(sys.argv[1]))['domain'])" "$JIRA_JSON")
JIRA_EMAIL=$($PYTHON -c "import json,sys; sys.stdout.reconfigure(encoding='utf-8',errors='replace'); print(json.load(open(sys.argv[1]))['email'])" "$JIRA_JSON")
JIRA_TOKEN=$($PYTHON -c "import json,sys; sys.stdout.reconfigure(encoding='utf-8',errors='replace'); print(json.load(open(sys.argv[1]))['token'])" "$JIRA_JSON")
JIRA_AUTH="$JIRA_EMAIL:$JIRA_TOKEN"
JIRA_BASE="https://$JIRA_DOMAIN"

# 티켓 기본 정보
curl -s -u "$JIRA_AUTH" \
  "$JIRA_BASE/rest/api/2/issue/${TICKET_KEY}?fields=summary,description,subtasks,assignee,status,priority" \
  -o "$TMPDIR/ticket.json"

# 서브태스크 상세
$PYTHON -c "
import json,sys
sys.stdout.reconfigure(encoding='utf-8',errors='replace')
d = json.load(open('$TMPDIR/ticket.json',encoding='utf-8'))
subs = d.get('fields',{}).get('subtasks',[])
result = []
for s in subs:
    result.append({'key': s['key'], 'summary': s['fields'].get('summary',''), 'status': s['fields'].get('status',{}).get('name','')})
print(json.dumps(result, ensure_ascii=False))
" > "$TMPDIR/subtasks.json"

# remotelink
curl -s -u "$JIRA_AUTH" \
  "$JIRA_BASE/rest/api/2/issue/${TICKET_KEY}/remotelink" \
  -o "$TMPDIR/remotelinks.json"

echo "티켓 수집 완료"
```

---

## STEP 2: 기획 문서 수집 (Google Drive + Confluence)

> 기획서 텍스트는 `$TMPDIR/spec_*.txt` 파일에 저장된다.
> remotelink 종류에 따라 아래 두 경로로 분기한다.
>
> | URL 패턴 | 처리 방식 |
> |----------|----------|
> | `drive.google.com` / `docs.google.com` | Python Google API (아래 bash 블록) |
> | `atlassian.net/wiki` | `mcp__claude_ai_Atlassian__getConfluencePage` MCP 호출 |
>
> 이미지 전용 슬라이드는 `[이미지 전용 슬라이드 — 텍스트 추출 불가]`로 표기한다.

### 2-1. Confluence remotelink 처리

remotelinks.json에서 Confluence URL을 추출한 뒤, URL당 `mcp__claude_ai_Atlassian__getConfluencePage` 를 호출한다.

```bash
# Confluence pageId 목록 추출
$PYTHON -c "
import json, re, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
links = json.load(open('$TMPDIR/remotelinks.json', encoding='utf-8'))
for lk in links:
    url   = lk.get('object', {}).get('url', '')
    title = lk.get('object', {}).get('title', '') or 'confluence'
    if 'atlassian.net/wiki' not in url: continue
    m = re.search(r'pageId=(\d+)', url)
    if m: print(m.group(1) + '\t' + title)
" > $TMPDIR/confluence_pages.tsv

echo "Confluence 페이지: $(wc -l < $TMPDIR/confluence_pages.tsv)개"
```

Confluence 페이지가 1개 이상이면, 각 pageId에 대해 아래를 수행한다.

- `mcp__claude_ai_Atlassian__getConfluencePage` 호출
  - `cloudId`: `bagelcode.atlassian.net`
  - `pageId`: 추출한 pageId
  - `contentFormat`: `markdown`
- 응답의 `body` 필드(markdown 텍스트)를 `$TMPDIR/spec_confluence_{pageId}.txt` 에 저장

```bash
# 저장 예시 (각 pageId 반복)
echo "{응답 body 내용}" > "$TMPDIR/spec_confluence_{pageId}.txt"
echo "✅ {title} 저장 완료"
```

### 2-2. Google Drive 처리

> 인증 토큰: `~/.bagelcode/google_token.json` (최초 1회 `python3 skills/vdt/vdt-auth.py` 실행 필요)

```bash
$PYTHON - << 'PYEOF'
import json, re, sys, os
from pathlib import Path
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

TMPDIR = os.environ['TMPDIR']

# ── Google 인증 ──
TOKEN_FILE = Path.home() / ".bagelcode" / "google_token.json"
if not TOKEN_FILE.exists():
    print("[ERROR] ~/.bagelcode/google_token.json 없음. python3 skills/vdt/vdt-auth.py 먼저 실행하세요.")
    sys.exit(1)

from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError

SCOPES = [
    "https://www.googleapis.com/auth/drive.readonly",
    "https://www.googleapis.com/auth/presentations.readonly",
]
creds = Credentials.from_authorized_user_file(str(TOKEN_FILE), SCOPES)
if creds.expired and creds.refresh_token:
    creds.refresh(Request())
    TOKEN_FILE.write_text(creds.to_json())

slides_svc = build("slides", "v1", credentials=creds, cache_discovery=False)
drive_svc  = build("drive",  "v3", credentials=creds, cache_discovery=False)

# ── remotelink → Google Drive 파일 목록 ──
def extract_gdrive(url, title):
    if 'drive.google.com' not in url and 'docs.google.com' not in url:
        return None
    m = re.search(r'/(?:presentation|document|spreadsheets)/d/([a-zA-Z0-9_-]+)', url)
    if not m:
        m = re.search(r'[?&]id=([a-zA-Z0-9_-]+)', url)
    if not m:
        return None
    fid = m.group(1)
    if '/presentation' in url:
        kind = 'slides'
    elif '/spreadsheets' in url:
        kind = 'sheet'
    else:
        kind = 'doc'
    return (fid, kind, title)

links = json.load(open(f"{TMPDIR}/remotelinks.json", encoding='utf-8'))
files = []
for lk in links:
    url   = lk.get('object', {}).get('url', '')
    title = lk.get('object', {}).get('title', '') or 'spec'
    r = extract_gdrive(url, title)
    if r:
        files.append(r)

print(f"Google Drive 파일: {len(files)}개")

# ── 텍스트 추출 (textRun 기반, 이미지 분석 없음) ──
def txt_from_slides(obj):
    result = []
    if isinstance(obj, dict):
        if 'textRun' in obj:
            t = obj['textRun'].get('content', '').strip()
            if t and t != '\n':
                result.append(t)
        for v in obj.values():
            result.extend(txt_from_slides(v))
    elif isinstance(obj, list):
        for i in obj:
            result.extend(txt_from_slides(i))
    return result

def extract_notes(slide):
    """발표자 노트 텍스트 추출 — 이미지 중심 슬라이드의 보조 텍스트 소스"""
    notes_page = slide.get('slideProperties', {}).get('notesPage', {})
    return [t for t in txt_from_slides(notes_page) if t and len(t) > 2]

TEXT_MIN_CHARS = 10  # 공백 제거 후 이 미만이면 이미지 중심 슬라이드로 판정

for fid, kind, title in files:
    cache = f"{TMPDIR}/spec_{fid}.txt"
    try:
        if kind == 'slides':
            pres = slides_svc.presentations().get(presentationId=fid).execute()
            lines = []
            for i, slide in enumerate(pres.get('slides', []), 1):
                texts = [t for t in txt_from_slides(slide) if t]
                notes = extract_notes(slide)
                body = ''.join(texts).replace(' ', '')
                if len(body) < TEXT_MIN_CHARS:
                    if notes:
                        lines.append(f"=== 슬라이드 {i} === [이미지 중심 — 발표자 노트만]\n노트: " + " / ".join(notes))
                    else:
                        lines.append(f"=== 슬라이드 {i} === [이미지 전용 슬라이드 — 텍스트 추출 불가]")
                else:
                    content = "\n".join(texts)
                    if notes:
                        content += "\n[발표자 노트]: " + " / ".join(notes)
                    lines.append(f"=== 슬라이드 {i} ===\n{content}")
            open(cache, 'w', encoding='utf-8').write("\n\n".join(lines))
        elif kind == 'sheet':
            content = drive_svc.files().export(fileId=fid, mimeType='text/csv').execute()
            open(cache, 'wb').write(content)
        else:
            content = drive_svc.files().export(fileId=fid, mimeType='text/plain').execute()
            open(cache, 'wb').write(content)
        print(f"✅ {title}")
    except HttpError as e:
        open(cache, 'w').write(f"[FETCH_FAILED:{e.status_code}]")
        print(f"⚠️ 추출 실패: {title} ({e.status_code})")
    except Exception as e:
        open(cache, 'w').write(f"[FETCH_FAILED:UNKNOWN]")
        print(f"⚠️ 추출 실패: {title} ({e})")

PYEOF
```

수동 파일(`$TMPDIR/spec_manual.txt`)이 있으면 자동으로 분석에 포함한다.

> **분기 요약**: remotelink가 Confluence만 있으면 2-1만 실행, Google Drive만 있으면 2-2만 실행, 둘 다 있으면 모두 실행한다. 수집된 모든 `spec_*.txt`가 STEP 3 Planner의 입력이 된다.

---

## STEP 3: Planner 에이전트 실행

아래 절차로 실행한다.

### 3-1. 기획서 텍스트 준비

```bash
SPEC_TEXT=$($PYTHON -c "
import glob, sys, os
sys.stdout.reconfigure(encoding='utf-8',errors='replace')
chunks = []
for f in sorted(glob.glob('$TMPDIR/spec_*.txt')):
    first = open(f,encoding='utf-8',errors='replace').readline().strip()
    if first.startswith('[FETCH_FAILED') or os.path.getsize(f)==0: continue
    chunks.append(open(f,encoding='utf-8',errors='replace').read())
print('\n\n---\n\n'.join(chunks) if chunks else '[기획서 없음]')
")

TICKET_INFO=$($PYTHON -c "
import json,sys
sys.stdout.reconfigure(encoding='utf-8',errors='replace')
d=json.load(open('$TMPDIR/ticket.json',encoding='utf-8'))
f=d.get('fields',{})
print(json.dumps({'title': f.get('summary',''), 'assignee': (f.get('assignee') or {}).get('displayName','')}, ensure_ascii=False))
")

SUBTASKS_JSON=$(cat "$TMPDIR/subtasks.json" 2>/dev/null || echo "[]")
```

### 3-2. Agent 실행

아래 내용을 그대로 Agent tool의 prompt로 사용한다.
`{SPEC_TEXT}`, `{TICKET_INFO}`, `{SUBTASKS_JSON}` 는 위에서 준비한 실제 값으로 대체한다.

```
[Planner 역할 지시]
당신은 시니어 기획자입니다. 아래 기획서 원문을 읽고 JSON을 출력하라.

원문 충실도 규칙 (CRITICAL):
- 의미 단위 재해석 금지
- 누락 요구사항 보완 금지
- 항목 분해 방식 임의 변경 금지
- 원문에 없는 섹션 생성 금지
- [이미지 전용 슬라이드] 항목은 ac_items 제외, image_only_slides 배열에 슬라이드 번호 추가

AC 카테고리 분류 기준:
M = 메인 메카닉/매칭/메타  U = UI/UX  S = 시스템/서버/스테이지
A = 애니메이션/아트         L = 로직/로비  E = 예외/엣지케이스

티켓 정보: {TICKET_INFO}
서브태스크: {SUBTASKS_JSON}

기획서 원문:
---
{SPEC_TEXT}
---

출력: 아래 JSON 스키마를 정확히 지켜 JSON 코드 블록으로 출력하라. 설명 텍스트 없이 JSON만.

{
  "title": "기능명",
  "ticket_key": "티켓 키",
  "purpose": "목적/배경 (원문에 있을 때만, 없으면 빈 문자열)",
  "key_features": [{"component": "구성", "content": "내용"}],
  "subtasks": [{"key": "CVS-XXXX", "owner": "담당", "status": "Done|IN PROGRESS|TODO"}],
  "incomplete_areas": [{"author": "이름 또는 빈 문자열", "comment": "내용"}],
  "ui_ux_changes": ["항목"],
  "edge_cases": ["항목"],
  "image_only_slides": [1, 3],
  "ac_items": [
    {
      "id": "M-01",
      "category": "M",
      "category_name": "메인/매칭",
      "content": "AC 항목 원문",
      "source": "기획서 원문 섹션명"
    }
  ]
}
```

### 3-3. JSON 저장

Agent 응답에서 JSON 코드 블록을 추출하여 아래 명령으로 저장한다.

```bash
# Agent 응답의 JSON 부분을 변수 PLANNER_JSON에 담아 저장
echo "$PLANNER_JSON" > "$TMPDIR/planner.json"
echo "Planner JSON 저장: $(wc -c < "$TMPDIR/planner.json") bytes"
```

---

## STEP 4: Developer + Artist 에이전트 병렬 실행

Developer와 Artist 모두 `planner.json`만 있으면 되므로 **두 Agent를 동시에 실행**한다.

### 4-1. Developer Agent 프롬프트

```
[Developer 역할 지시]
당신은 시니어 개발자(Tech Lead)입니다.
아래 기획서 요약을 바탕으로 개발 리스크와 검토사항을 JSON으로 출력하라.

Planner 분석 결과:
{PLANNER_JSON}

출력 스키마 (JSON 코드 블록으로만):
{
  "impact_scope": [
    {
      "module": "모듈/영역명",
      "change_type": "신규 | 수정 | 공용 수정 | 삭제 | 완료",
      "is_risky": true,
      "detail": "변경 상세 및 사이드 이펙트 위험"
    }
  ],
  "impl_risks": [
    {
      "feature": "기능/구현 항목명",
      "complexity": "High | Med | Low",
      "risk": "리스크 내용"
    }
  ],
  "impl_order": [
    "1순위 작업 — 이유",
    "2순위 작업 — 이유"
  ],
  "tech_notes": [
    "기술 리스크 또는 주의사항 1문장"
  ]
}

is_risky=true: 다른 기능에 영향을 주는 공용 컴포넌트 변경
complexity: High=🔴 / Med=🟠 / Low=🟢
```

### 4-2. Artist Agent 프롬프트

```
[Artist 역할 지시]
당신은 시니어 게임 아티스트 / UI 디자이너입니다.
아래 기획서 요약을 바탕으로 UI/UX 플로우와 에셋 목록을 JSON으로 출력하라.

주의: image_only_slides에 포함된 슬라이드 번호 기반 항목은 에셋 목록에서 제외하라.

Planner 분석 결과:
{PLANNER_JSON}

출력 스키마 (JSON 코드 블록으로만):
{
  "ui_ux_flow": ["화면A → (액션) → 화면B"],
  "assets": {
    "images": [{"name": "에셋명", "usage": "용도", "size": "크기", "is_new": true}],
    "animations": [{"name": "에셋명", "type": "종류", "trigger": "조건"}],
    "effects": [{"name": "에셋명", "trigger": "트리거", "note": "비고"}],
    "fonts": ["폰트명"]
  },
  "design_guidelines": ["가이드라인"],
  "total_asset_days": 0,
  "asset_summary": "에셋 규모 1줄 요약"
}
```

### 4-3. JSON 저장

```bash
echo "$DEVELOPER_JSON" > "$TMPDIR/developer.json"
echo "$ARTIST_JSON"   > "$TMPDIR/artist.json"
```

---

## STEP 4.5: TA 에이전트 실행

Artist 분석 완료 후 실행한다 (`artist.json` 의존).

### 4.5-1. 컨텍스트 준비

```bash
ARTIST_JSON=$(cat "$TMPDIR/artist.json")
```

### 4.5-2. Agent 프롬프트

```
[TA 역할 지시]
당신은 테크니컬 아티스트(Technical Artist)입니다.
아트 요구사항과 개발 기술 계획을 바탕으로 기술 스펙과 리스크를 JSON으로 출력하라.

Planner 분석:
{PLANNER_JSON}

Developer 분석:
{DEVELOPER_JSON}

Artist 분석:
{ARTIST_JSON}

출력 스키마 (JSON 코드 블록으로만):
{
  "asset_specs": [
    {"name": "에셋명", "format": "PNG", "resolution": "크기", "atlas": "Y/N", "memory_est": "~KB"}
  ],
  "effect_specs": [
    {"name": "이펙트명", "impl_method": "구현방식", "perf_note": "성능주의점"}
  ],
  "pipeline_impact": {
    "build_changed": false,
    "import_changes": ["변경항목"],
    "bundle_note": "번들 영향"
  },
  "performance_notes": [
    {"item": "항목", "impact": "영향", "mitigation": "대응"}
  ],
  "ta_risks": [
    {"item": "항목", "risk": "리스크", "recommendation": "권고"}
  ]
}
```

### 4.5-3. JSON 저장

```bash
echo "$TA_JSON" > "$TMPDIR/ta.json"
```

---

## STEP 5: QA Pre-analyst 에이전트 실행

### 5-1. 컨텍스트 준비

```bash
AC_ITEMS_JSON=$(jq '.ac_items' "$TMPDIR/planner.json")
ARTIST_JSON=$(cat "$TMPDIR/artist.json" 2>/dev/null || echo '{}')
TA_JSON=$(cat "$TMPDIR/ta.json" 2>/dev/null || echo '{}')
```

### 5-2. Agent 프롬프트

```
[QA Pre-analyst 역할 지시]
당신은 기획서 품질 분석가입니다.
"개발자가 이 기획서만 보고 착수할 수 있는가"의 관점에서 각 AC 항목을 판정하고 JSON으로 출력하라.

베이스라인 무결성 규칙 (CRITICAL):
- Planner가 제공한 ac_items를 그대로 베이스라인으로 사용
- AC 항목 재해석 금지 / 누락 항목 보완 금지
- image_only_slides에 포함된 슬라이드 기반 항목은 분석 제외

판정 기준:
✅ = 착수가능 (기획서만으로 구현 방향 결정 가능)
⚠️ = 확인필요 (세부 조건 불명확 — 기획자 확인 없이는 착수 불가)
🔴 = 착수불가 (핵심 정보 누락 또는 상충 — 기획서 보완 필수)

각 항목에서 다음을 분석하라:
- ambiguity: 어떤 표현이 모호한가? (원문 인용 권장, 없으면 빈 문자열)
- missing_info: 구현을 위해 기획서에 없는 정보가 무엇인가? (없으면 빈 문자열)
- question: 기획자에게 확인해야 할 질문 (없으면 빈 문자열)
- qa_prediction: ⚠️/🔴 판정 시, 이 모호함·누락이 해소되지 않고 개발된 경우 QA 테스트에서 발생할 것으로 예측되는 구체적 문제. "어떤 케이스에서 → 어떤 증상이 발생할 것으로 예측" 구조로 기술. ✅이면 빈 문자열.

UI/에셋 관련 AC(카테고리 U, A) 판정 시 Artist 분석을 참조하라.
기술 리스크(TA 리스크 항목)가 있으면 해당 AC의 verdict를 ⚠️ 이상으로 올려라.

Planner AC 항목:
{AC_ITEMS_JSON}

개발 리스크:
{DEVELOPER_JSON}

Artist 에셋 분석 (UI/아트 리스크 참조):
{ARTIST_JSON}

TA 기술 리스크 (에셋·파이프라인 리스크 참조):
{TA_JSON}

출력 스키마 (JSON 코드 블록으로만):
{
  "spec_quality": [
    {
      "id": "M-01",
      "verdict": "✅|⚠️|🔴",
      "verdict_label": "착수가능|확인필요|착수불가",
      "ambiguity": "모호한 표현 구체적으로 (없으면 빈 문자열)",
      "missing_info": "구현을 위해 필요하지만 없는 정보 (없으면 빈 문자열)",
      "question": "기획자에게 확인해야 할 질문 (없으면 빈 문자열)",
      "qa_prediction": "⚠️/🔴 판정 시 예측되는 테스트 실패 또는 버그 증상 (✅이면 빈 문자열)"
    }
  ],
  "critical_questions": [
    {
      "priority": "P0|P1",
      "related_ids": ["M-01"],
      "question": "개발 착수 전 반드시 확인해야 할 질문",
      "impact": "미해결 시 개발에 미치는 영향"
    }
  ]
}
```

### 5-3. JSON 저장

```bash
echo "$QA_JSON" > "$TMPDIR/qa.json"
```

---

## STEP 5.5: 팀 회의 에이전트 실행

Planner / Developer / Artist / TA / QA 분석 결과를 바탕으로 가상 팀 회의를 시뮬레이션한다.

### 5.5-1. 컨텍스트 준비

```bash
PLANNER_TITLE=$(jq -r '.title' "$TMPDIR/planner.json")
INCOMPLETE_AREAS=$(jq -r '[.incomplete_areas[]?.comment] | join(" / ")' "$TMPDIR/planner.json")
RISK_AC_ITEMS=$(jq -r '[.spec_quality[] | select(.verdict=="🔴") | .id + ": " + .missing_info] | join(", ")' "$TMPDIR/qa.json" 2>/dev/null || echo "없음")
DEVELOPER_IMPL_RISKS=$(jq -r '[.impl_risks[] | .feature + " (" + .complexity + "): " + .risk] | join(" / ")' "$TMPDIR/developer.json")
QA_RISK_ITEMS=$(jq -r '[.spec_quality[] | select(.verdict=="🔴") | .id + ": " + .missing_info] | join(" / ")' "$TMPDIR/qa.json")
CRITICAL_QUESTIONS=$(jq -r '[.critical_questions[] | select(.priority=="P0") | "• " + .question + " — 영향: " + .impact] | join("\n")' "$TMPDIR/qa.json" 2>/dev/null || echo "없음")
ARTIST_SUMMARY=$(jq -r '.asset_summary // "에셋 정보 없음"' "$TMPDIR/artist.json" 2>/dev/null || echo "없음")
TA_RISK_SUMMARY=$(jq -r '[.ta_risks[]? | .item + ": " + .risk] | join(" / ")' "$TMPDIR/ta.json" 2>/dev/null || echo "없음")
```

### 5.5-2. Agent 프롬프트

```
[팀 회의 진행자 지시]
당신은 가상 개발팀의 회의 퍼실리테이터입니다.
아래 다섯 에이전트의 분석 결과를 바탕으로 팀 회의를 시뮬레이션하라.

규칙:
- 각 에이전트는 자신의 전문 관점에서 발언한다 (기획 → 개발 → 아트 → TA → QA 순)
- 앞 에이전트의 발언을 참고하여 동의·보완·이의를 표현한다
- 라운드는 최대 2라운드 (핵심 이슈 위주, 반복 없음)
- 강조할 내용은 **bold** 마크다운 사용
- 합의 결과는 실행 가능한 액션 아이템으로 정리 (P0 = 즉시, P1 = 스프린트 내, P2 = 권고)

참가 에이전트: 기획(planner), 개발(developer), 아트(artist), TA(ta), QA(qa)

기획서 요약:
제목: {PLANNER_TITLE}
주요 미완성: {INCOMPLETE_AREAS}
AC 리스크 항목 (🔴만): {RISK_AC_ITEMS}

개발 구현 리스크:
{DEVELOPER_IMPL_RISKS}

아트 에셋 요약:
{ARTIST_SUMMARY}

TA 기술 리스크:
{TA_RISK_SUMMARY}

QA 고위험 판정:
{QA_RISK_ITEMS}

출력 스키마 (JSON 코드 블록으로만):
{
  "date": "YYYY-MM-DD",
  "participants": ["기획 에이전트", "개발 에이전트", "아트 에이전트", "TA 에이전트", "QA 에이전트"],
  "rounds": [
    {
      "round": 1,
      "agent": "기획 에이전트",
      "agent_type": "planner",
      "content": "발언 내용 (**bold** 사용 가능)"
    },
    {
      "round": 1,
      "agent": "개발 에이전트",
      "agent_type": "developer",
      "content": "발언 내용"
    },
    {
      "round": 1,
      "agent": "아트 에이전트",
      "agent_type": "artist",
      "content": "발언 내용"
    },
    {
      "round": 1,
      "agent": "TA 에이전트",
      "agent_type": "ta",
      "content": "발언 내용"
    },
    {
      "round": 1,
      "agent": "QA 에이전트",
      "agent_type": "qa",
      "content": "발언 내용"
    }
  ],
  "consensus": [
    {"priority": "P0", "action": "합의된 액션 아이템 (담당자·기한 포함)"},
    {"priority": "P1", "action": "다음 스프린트 내 처리 항목"}
  ]
}
```

### 5.5-3. JSON 저장

```bash
echo "$MEETING_JSON" > "$TMPDIR/meeting.json"
```

---

## STEP 6: HTML 보고서 생성

아래 Python 스크립트를 실행한다. 경로 변수는 STEP 0에서 설정된 것을 사용.

```bash
$PYTHON -c "
import json, sys, os
from datetime import datetime
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

TMPDIR   = os.environ['TMPDIR']
TICKET   = os.environ['TICKET_KEY']
VIEWER   = os.environ['VIEWER_PATH']
OUTPUT   = os.environ['OUTPUT_PATH']

planner  = json.load(open(f'{TMPDIR}/planner.json',  encoding='utf-8'))
developer= json.load(open(f'{TMPDIR}/developer.json', encoding='utf-8'))
qa       = json.load(open(f'{TMPDIR}/qa.json',        encoding='utf-8'))
artist   = json.load(open(f'{TMPDIR}/artist.json',    encoding='utf-8')) if os.path.exists(f'{TMPDIR}/artist.json') else {}
ta       = json.load(open(f'{TMPDIR}/ta.json',        encoding='utf-8')) if os.path.exists(f'{TMPDIR}/ta.json')     else {}
meeting_path = f'{TMPDIR}/meeting.json'
meeting  = json.load(open(meeting_path, encoding='utf-8')) if os.path.exists(meeting_path) else {}

# AC 항목 + QA 분석 병합
ac_map = {ac['id']: dict(ac) for ac in planner.get('ac_items', [])}
for a in qa.get('spec_quality', []):
    if a['id'] in ac_map:
        ac_map[a['id']].update(a)

# 통계
label_map = {'✅':'착수가능','⚠️':'확인필요','🔴':'착수불가'}
stats = {v:0 for v in label_map.values()}
for ac in ac_map.values():
    stats[label_map.get(ac.get('verdict','⚠️'), '확인필요')] += 1

data = {
    'ticket_key':    TICKET,
    'title':         planner.get('title', TICKET),
    'analysis_date': datetime.now().strftime('%Y-%m-%d'),
    'status':        'Director 승인 대기',
    'stats':         stats,
    'spec': {
        'purpose':          planner.get('purpose',''),
        'key_features':     planner.get('key_features',[]),
        'subtasks':         planner.get('subtasks',[]),
        'incomplete_areas': planner.get('incomplete_areas',[]),
        'ui_ux_changes':    planner.get('ui_ux_changes',[]),
        'edge_cases':       planner.get('edge_cases',[]),
    },
    'ac_items': list(ac_map.values()),
    'developer': {
        'impact_scope': developer.get('impact_scope', []),
        'impl_risks':   developer.get('impl_risks',   []),
        'impl_order':   developer.get('impl_order',   []),
        'tech_notes':   developer.get('tech_notes',   []),
    },
    'artist': {
        'ui_ux_flow':        artist.get('ui_ux_flow', []),
        'assets':            artist.get('assets', {}),
        'design_guidelines': artist.get('design_guidelines', []),
        'total_asset_days':  artist.get('total_asset_days', 0),
        'asset_summary':     artist.get('asset_summary', ''),
    },
    'ta': {
        'asset_specs':       ta.get('asset_specs', []),
        'effect_specs':      ta.get('effect_specs', []),
        'pipeline_impact':   ta.get('pipeline_impact', {}),
        'performance_notes': ta.get('performance_notes', []),
        'ta_risks':          ta.get('ta_risks', []),
    },
    'critical_questions': qa.get('critical_questions', []),
    'meeting': meeting if meeting else None,
}

template = open(VIEWER, encoding='utf-8').read()
html = template.replace('__DATA_PLACEHOLDER__', json.dumps(data, ensure_ascii=False))
open(OUTPUT, 'w', encoding='utf-8').write(html)

dev = data['developer']
print(f'✅ HTML 생성: {OUTPUT}')
cq = qa.get('critical_questions', [])
print(f'기획서 품질: {stats}')
print(f'AC 항목: {len(ac_map)}건  |  착수불가: {stats.get(\"착수불가\",0)}건  |  Critical Questions: {len(cq)}건')
print(f'에셋: {len(artist.get(\"assets\", {}).get(\"images\", []))}건  |  TA 리스크: {len(ta.get(\"ta_risks\", []))}건')
"
```

---

## STEP 6.5: BagelPages 배포

HTML 보고서를 BagelPages에 배포하여 사내 전용 접근 링크를 생성한다.

```bash
APP_NAME="vdt-$(echo ${TICKET_KEY} | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
REPORT_DIR="$TMPDIR/report_deploy"
mkdir -p "$REPORT_DIR"
cp "$OUTPUT_PATH" "$REPORT_DIR/index.html"

# BagelPages 배포
codeb pages deploy "$REPORT_DIR" --app "$APP_NAME"

REPORT_URL="https://${APP_NAME}.pages.bagelgames.com"
echo "✅ 보고서 URL: $REPORT_URL"
echo "$REPORT_URL" > "$TMPDIR/report_url.txt"
```

> 배포 완료 후 사내 네트워크에서만 접근 가능하다.

---

## STEP 7: Slack 채널 전송

HTML 보고서 URL과 요약을 Slack 채널에 전송한다.

### 7-1. 메시지 구성

```bash
REPORT_URL=$(cat "$TMPDIR/report_url.txt" 2>/dev/null || echo "URL 조회 실패")
```

```
🤖 *기획서 품질 분석 완료*
티켓: *{TICKET_KEY}* — {title}
분석일: {analysis_date}

📊 *기획서 착수 가능성 판정*
✅ 착수가능: {N}건　⚠️ 확인필요: {N}건　🔴 착수불가: {N}건

❓ *Critical Questions (착수 전 기획자 확인 필요)*
{$CRITICAL_QUESTIONS — P0 항목 최대 3건. 없으면 "없음"}

🔴 *착수불가 항목*
{🔴 판정 AC 항목을 최대 5건, 각 줄에 `• [ID]: [내용] — [missing_info]` 형식으로. 없으면 "없음"}

🛠 *개발 구현 리스크 (High)*
{complexity=High impl_risks 항목, 없으면 "없음"}

📄 *분석 보고서*: {REPORT_URL}
```

### 7-2. Slack 채널 전송

`mcp__claude_ai_Slack__slack_send_message` 도구를 사용한다.

- `channel_id`: `C0AQTSRRFHC` (`#qa-ai-report` 채널)
- `message`: 위 7-1에서 구성한 메시지 (BagelPages URL 포함)

전송 후 메시지 링크를 출력한다.

---

## 완료 출력

```
✅ /vdt {TICKET_KEY} 분석 완료
- 보고서 URL: {REPORT_URL}  (사내 네트워크 전용)
- Slack: #qa-ai-report 전송 완료
- 기획서 품질: ✅착수가능:{N} ⚠️확인필요:{N} 🔴착수불가:{N}
```
