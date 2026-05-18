---
name: spec-review
description: Jira 티켓에 연결된 Google Drive 기획서를 자동으로 읽어와 구현과 비교합니다. "/spec-review", "기획서 비교", "스펙 리뷰" 요청 시 사용합니다. ticket-qa 실행 후 같은 대화에서 연속 실행하면 ticket-qa 분석 결과와 함께 비교합니다.
---

# /spec-review — Google Drive 기획서 자동 읽기 + 구현 비교

> **실행 환경**: 이 스킬의 bash 명령은 Claude Code Bash 도구 기준으로 작성됐다. Windows에서는 Git Bash 환경에서 실행된다.

### 임시 파일 경로 (Windows 호환)

모든 임시 파일은 `$TMPDIR`을 사용한다. TICKET_KEY 확정 직후 초기화한다.

### Python 인코딩 가드 (전체 코드 공통)

모든 Python `-c` 블록 첫 줄에 삽입:
```python
import sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace'); sys.stderr.reconfigure(encoding='utf-8', errors='replace')
```
파일 `open()` 시 항상 `encoding='utf-8', errors='replace'` 지정. 이후 코드 블록에서 반복하지 않는다.

## 도구 확인

```bash
if ! command -v gws &>/dev/null; then
  echo "❌ 이 스킬은 gws CLI가 필요합니다."
  echo ""
  echo "   설치:  npm install -g @googleworkspace/cli"
  echo "   인증:  gws auth login"
  echo ""
  echo "   설치 후 다시 시도해 주세요."
fi
```

gws가 없으면 위 안내를 출력하고 **중단**한다.

---

## 실행 전 확인

인자가 없으면 `AskUserQuestion`으로 한 번 묻는다.

```
question: "분석할 Jira 티켓 키를 Other에 직접 입력해 주세요."
options:
  - label: "예시", description: "CVS-13353  ← Other에 이 형식으로 입력"
```

입력값이 `[A-Z]+-\d+` 형식이 아니면 같은 질문으로 한 번 더 묻는다.

---

## Jira 인증 설정

```bash
PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)
JIRA_JSON="$(cygpath -m "$HOME/.bagelcode/jira.json" 2>/dev/null || echo "$HOME/.bagelcode/jira.json")"
JIRA_DOMAIN=$($PYTHON -c "import json,sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace'); d=json.load(open(sys.argv[1], encoding='utf-8', errors='replace')); print(d['domain'])" "$JIRA_JSON")
JIRA_EMAIL=$($PYTHON -c "import json,sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace'); d=json.load(open(sys.argv[1], encoding='utf-8', errors='replace')); print(d['email'])" "$JIRA_JSON")
JIRA_TOKEN=$($PYTHON -c "import json,sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace'); d=json.load(open(sys.argv[1], encoding='utf-8', errors='replace')); print(d['token'])" "$JIRA_JSON")
JIRA_AUTH="$JIRA_EMAIL:$JIRA_TOKEN"
JIRA_BASE="https://$JIRA_DOMAIN"
```

파일이 없으면 아래 안내를 출력하고 **실행을 중단**한다.

```
~/.bagelcode/jira.json 파일이 없습니다. 아래 형식으로 파일을 생성한 뒤 다시 실행해 주세요:

{
  "domain": "yourcompany.atlassian.net",
  "email": "your.email@company.com",
  "token": "YOUR_JIRA_API_TOKEN"
}
```

---

## gws 초기화

```bash
GWS=$(command -v gws 2>/dev/null || echo "")
if [ -z "$GWS" ]; then
  echo "⚠️  gws CLI 미발견 — Google Drive 기획서를 읽을 수 없습니다."
  echo "설치: npm install -g @googleworkspace/cli"
  GWS_AVAILABLE=false
else
  GWS_AVAILABLE=true
fi
```

gws가 없어도 STEP 1(Jira 정보 수집)까지는 진행하고, STEP 2에서 fallback 처리한다.

---

## STEP 0: 초기화

```bash
TICKET_KEY={입력받은 티켓 키}   # 예: CVS-13353

export TMPDIR="$(cygpath -m /tmp 2>/dev/null || echo /tmp)/spec-review-${TICKET_KEY}"

# 재실행 시 수동 파일 보존 — rm -rf 전에 백업
_MANUAL_BACKUP=""
if [ -f "$TMPDIR/spec_manual.txt" ]; then
  _MANUAL_BACKUP="$(mktemp)"
  cp "$TMPDIR/spec_manual.txt" "$_MANUAL_BACKUP"
fi

rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"

# 수동 파일 복원
if [ -n "$_MANUAL_BACKUP" ] && [ -f "$_MANUAL_BACKUP" ]; then
  cp "$_MANUAL_BACKUP" "$TMPDIR/spec_manual.txt"
  rm -f "$_MANUAL_BACKUP"
  echo "spec_manual.txt 복원 완료"
fi

# ticket-qa 캐시 재사용 — 같은 티켓으로 ticket-qa가 먼저 실행됐으면 API 재호출 생략
TQA_DIR="$(cygpath -m /tmp 2>/dev/null || echo /tmp)/ticket-qa-${TICKET_KEY}"
if [ -f "$TQA_DIR/remotelinks.json" ]; then
  cp "$TQA_DIR/remotelinks.json" "$TMPDIR/remotelinks.json"
fi
for f in "$TQA_DIR"/_confluence_*.json; do
  [ -f "$f" ] && cp "$f" "$TMPDIR/"
done

# 환경변수 파일 (Bash 호출 간 유지)
cat > "$TMPDIR/_env.sh" <<EOF
export TMPDIR="$TMPDIR"
export PYTHON="$PYTHON"
export JIRA_AUTH="$JIRA_AUTH"
export JIRA_BASE="$JIRA_BASE"
export GWS_AVAILABLE="$GWS_AVAILABLE"
EOF
```

---

## STEP 1: 티켓 remotelink에서 Google Drive URL 수집

### 1-1. Jira remotelink fetch

```bash
source "$TMPDIR/_env.sh"

curl -s -u "$JIRA_AUTH" \
  "$JIRA_BASE/rest/api/2/issue/${TICKET_KEY}/remotelink" \
  -o "$TMPDIR/remotelinks.json"
```

### 1-2. Google Drive URL 추출 및 파일 ID 파싱

remotelink URL이 직접 Google Drive를 가리키는 경우와,
Confluence 페이지를 가리키고 그 안에 Drive가 임베드된 경우(2단계) 모두 처리한다.

```bash
source "$TMPDIR/_env.sh"

$PYTHON -c "
import json, re, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace'); sys.stderr.reconfigure(encoding='utf-8', errors='replace')

def extract_gdrive(url, title):
    if 'drive.google.com' not in url and 'docs.google.com' not in url:
        return None
    if '/presentation/d/' in url:
        export_mime = 'text/plain'
    elif '/document/d/' in url:
        export_mime = 'text/plain'
    elif '/spreadsheets/d/' in url:
        export_mime = 'text/csv'
    else:
        export_mime = 'text/plain'
    m = re.search(r'/(?:presentation|document|spreadsheets)/d/([a-zA-Z0-9_-]+)', url)
    if not m:
        m = re.search(r'/file/d/([a-zA-Z0-9_-]+)', url)
    if not m:
        m = re.search(r'[?&]id=([a-zA-Z0-9_-]+)', url)
    if not m:
        return None
    return (m.group(1), export_mime, url, title)

with open('$TMPDIR/remotelinks.json', encoding='utf-8', errors='replace') as f:
    links = json.load(f)

confluence_page_ids = []
for link in links:
    url = link.get('object', {}).get('url', '')
    title = link.get('object', {}).get('title', '') or 'untitled'
    result = extract_gdrive(url, title)
    if result:
        print('\t'.join(result))
    elif 'atlassian.net/wiki' in url or 'confluence' in url:
        # Confluence 페이지 — 내부에 Drive가 임베드됐을 수 있음
        m = re.search(r'pageId=(\d+)', url)
        if not m:
            m = re.search(r'/pages/(\d+)', url)
        if m:
            confluence_page_ids.append((m.group(1), title))

# Confluence 페이지 ID 목록을 별도 파일로 저장 (1-3에서 처리)
with open('$TMPDIR/confluence_to_scan.tsv', 'w', encoding='utf-8') as f:
    for pid, t in confluence_page_ids:
        f.write(f'{pid}\t{t}\n')
" > "$TMPDIR/gdrive_files.tsv"

echo "직접 Google Drive 링크: $(wc -l < "$TMPDIR/gdrive_files.tsv")개"
echo "Confluence 페이지 (내부 스캔 필요): $(wc -l < "$TMPDIR/confluence_to_scan.tsv")개"
```

### 1-3. Confluence 페이지 본문에서 임베드된 Google Drive URL 스캔

```bash
source "$TMPDIR/_env.sh"

while IFS=$'\t' read -r PAGE_ID PAGE_TITLE; do
  [ -z "$PAGE_ID" ] && continue
  CONF_CACHE="$TMPDIR/_confluence_${PAGE_ID}.json"

  if [ ! -f "$CONF_CACHE" ]; then
    curl -s -u "$JIRA_AUTH" \
      "$JIRA_BASE/wiki/rest/api/content/${PAGE_ID}?expand=body.storage" \
      -o "$CONF_CACHE"
  fi

  $PYTHON -c "
import json, re, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace'); sys.stderr.reconfigure(encoding='utf-8', errors='replace')

d = json.load(open('$CONF_CACHE', encoding='utf-8', errors='replace'))
body = d.get('body', {}).get('storage', {}).get('value', '')
title = '$PAGE_TITLE'

# ac:parameter 태그 안 Google Drive URL 추출 (lref-gdrive-file 매크로 등)
urls = re.findall(r'https://(?:drive|docs)\.google\.com/[^\s\"<>]+', body)
for url in urls:
    if '/presentation/d/' in url:
        export_mime = 'text/plain'
    elif '/document/d/' in url:
        export_mime = 'text/plain'
    elif '/spreadsheets/d/' in url:
        export_mime = 'text/csv'
    else:
        export_mime = 'text/plain'
    m = re.search(r'/(?:presentation|document|spreadsheets)/d/([a-zA-Z0-9_-]+)', url)
    if not m:
        m = re.search(r'/file/d/([a-zA-Z0-9_-]+)', url)
    if not m:
        m = re.search(r'[?&]id=([a-zA-Z0-9_-]+)', url)
    if m:
        print(f\"{m.group(1)}\t{export_mime}\t{url}\t{title}\")
" >> "$TMPDIR/gdrive_files.tsv"

done < "$TMPDIR/confluence_to_scan.tsv"

# 중복 제거 (같은 FILE_ID가 여러 번 나올 수 있음)
sort -u "$TMPDIR/gdrive_files.tsv" -o "$TMPDIR/gdrive_files.tsv"

echo "최종 Google Drive 기획서: $(wc -l < "$TMPDIR/gdrive_files.tsv")개"
cat "$TMPDIR/gdrive_files.tsv"
```

Google Drive URL이 0개이면: "이 티켓에 연결된 Google Drive 기획서가 없습니다." 출력 후 중단

---

## STEP 2: gws로 Google Drive 기획서 텍스트 추출

Slides는 `gws slides presentations get`으로 전체 JSON을 받아 파싱한다.
도형·텍스트박스 안 텍스트까지 모두 포함되며, 슬라이드 번호 단위로 구조화된다.
Docs·Sheets는 기존대로 `drive files export`를 사용한다.

> **참고**: 이미지 안에 텍스트가 래스터로 박혀 있는 경우(스크린샷, 디자인 시안 등)는
> Slides API로도 추출 불가 — 해당 슬라이드는 "이미지 전용 슬라이드" 로 표기한다.

```bash
source "$TMPDIR/_env.sh"

FETCH_FAILED_LIST=""

while IFS=$'\t' read -r FILE_ID EXPORT_MIME ORIGINAL_URL TITLE; do
  [ -z "$FILE_ID" ] && continue
  CACHE_FILE="$TMPDIR/spec_${FILE_ID}.txt"

  if [ "$GWS_AVAILABLE" = "false" ]; then
    echo "[FETCH_FAILED:GWS_NOT_INSTALLED]" > "$CACHE_FILE"
    FETCH_FAILED_LIST="${FETCH_FAILED_LIST}
- $TITLE ($ORIGINAL_URL)"
    continue
  fi

  if [ "$EXPORT_MIME" = "text/plain" ] && echo "$ORIGINAL_URL" | grep -q 'presentation'; then
    # --- Slides: Slides API로 전체 JSON 파싱 ---
    GWS_JSON_TMP="spec_slides_${FILE_ID}.json"
    gws slides presentations get \
      --params "{\"presentationId\":\"$FILE_ID\"}" \
      > "$GWS_JSON_TMP" 2>/dev/null

    $PYTHON -c "
import json, sys, re
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

with open('$GWS_JSON_TMP', encoding='utf-8', errors='replace') as f:
    lines = f.readlines()

# gws가 출력하는 'Using keyring backend: ...' 메시지 제거
content = ''.join(l for l in lines if not l.startswith('Using keyring'))
if not content.strip():
    print('[FETCH_FAILED:SLIDES_EMPTY_RESPONSE]')
    sys.exit(1)

try:
    d = json.loads(content)
except json.JSONDecodeError as e:
    print(f'[FETCH_FAILED:SLIDES_JSON_PARSE_ERROR:{e}]')
    sys.exit(1)

def collect_text(obj):
    texts = []
    if isinstance(obj, dict):
        if 'textRun' in obj:
            t = obj['textRun'].get('content', '').strip()
            if t and t != '\n':
                texts.append(t)
        for v in obj.values():
            texts.extend(collect_text(v))
    elif isinstance(obj, list):
        for item in obj:
            texts.extend(collect_text(item))
    return texts

for i, slide in enumerate(d.get('slides', []), 1):
    texts = collect_text(slide)
    texts = [t for t in texts if t]
    if texts:
        print(f'=== 슬라이드 {i} ===')
        print('\n'.join(texts))
    else:
        print(f'=== 슬라이드 {i} === [이미지 전용 슬라이드]')
" > "$CACHE_FILE" 2>/dev/null
    rm -f "$GWS_JSON_TMP"

  else
    # --- Docs / Sheets: drive export (text/plain 또는 text/csv) ---
    GWS_TMP="spec_gws_tmp_${FILE_ID}.txt"
    gws drive files export \
      --params "{\"fileId\":\"$FILE_ID\",\"mimeType\":\"$EXPORT_MIME\"}" \
      -o "$GWS_TMP" 2>/dev/null \
      && mv "$GWS_TMP" "$CACHE_FILE" 2>/dev/null \
      || rm -f "$GWS_TMP"
  fi

  # 실패 판단: 비어있거나 첫 줄이 [FETCH_FAILED:로 시작하는 경우 모두 실패
  _FIRST_LINE=$(head -1 "$CACHE_FILE" 2>/dev/null || echo "")
  _IS_FAILED=false
  if [ ! -s "$CACHE_FILE" ]; then
    echo "[FETCH_FAILED:EXPORT_ERROR]" > "$CACHE_FILE"
    _IS_FAILED=true
  elif echo "$_FIRST_LINE" | grep -q '^\[FETCH_FAILED:'; then
    _IS_FAILED=true
  fi

  if [ "$_IS_FAILED" = "true" ]; then
    FETCH_FAILED_LIST="${FETCH_FAILED_LIST}
- $TITLE ($ORIGINAL_URL)"
    echo "⚠️  추출 실패: $TITLE ($(head -1 "$CACHE_FILE"))"
  else
    echo "✅ 추출 완료: $TITLE → $CACHE_FILE ($(wc -c < "$CACHE_FILE") bytes)"
  fi
done < "$TMPDIR/gdrive_files.tsv"
```

### 실패 처리

다운로드 실패 파일이 있으면 출력:

```
⚠️  아래 기획서를 자동으로 읽지 못했습니다:
{FETCH_FAILED_LIST}

수동으로 읽으려면:
1. 위 URL을 브라우저에서 열어 파일 > 다운로드 > 일반 텍스트(.txt) 저장
2. 저장 경로: $TMPDIR/spec_manual.txt
3. /spec-review {TICKET_KEY} 재실행 (기존 $TMPDIR 유지됨)
```

수동 파일(`$TMPDIR/spec_manual.txt`)이 존재하면 자동으로 읽어서 분석에 포함한다.

---

## STEP 3: 기획서 내용 분석 + 구현 비교

### 3-1. 기획서 파일 유효성 확인 + 요약

STEP 3 시작 전, 읽을 파일 목록을 확정한다:

```bash
source "$TMPDIR/_env.sh"

$PYTHON -c "
import glob, sys, os
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
valid = []
invalid = []
# spec_manual.txt는 glob에서 제외하고 아래에서 별도 처리
for f in sorted(glob.glob('$TMPDIR/spec_*.txt')):
    if os.path.basename(f) == 'spec_manual.txt':
        continue
    with open(f, encoding='utf-8', errors='replace') as fh:
        first = fh.readline().strip()
    if first.startswith('[FETCH_FAILED:') or os.path.getsize(f) == 0:
        invalid.append(f)
    else:
        valid.append(f)
# spec_manual.txt 별도 처리 (중복 방지)
manual = '$TMPDIR/spec_manual.txt'
if os.path.isfile(manual) and os.path.getsize(manual) > 0:
    with open(manual, encoding='utf-8', errors='replace') as fh:
        first = fh.readline().strip()
    if not first.startswith('[FETCH_FAILED:'):
        valid.append(manual)
    else:
        invalid.append(manual)
print('VALID:' + '|'.join(valid))
print('INVALID:' + '|'.join(invalid))
"
```

- **VALID 파일이 0개**이면: "분석 가능한 기획서 파일이 없습니다." 출력 후 STEP 3-2~3 전체를 건너뛰고 STEP 4에서 "기획서 미확인" 단일 행만 출력한다.
- **INVALID 파일**은 분석에서 완전히 제외한다. 요약/비교에 포함하지 않는다.
- 이후 모든 분석은 **VALID 파일에서 읽은 내용만** 사용한다.

**금지 사항**: 기획서에 명시되지 않은 내용을 Claude가 보완·추론해 추가하는 것은 금지한다. 각 섹션은 기획서 원문에 해당 내용이 있는 경우에만 출력하고, 없으면 해당 섹션을 생략한다.

```
## 기획서 요약: {파일 제목}

### 목적/배경
{기획서 원문에서 직접 추출 — 없으면 이 섹션 생략}

### 주요 기능/요구사항
1. {기획서 원문 항목}
2. {기획서 원문 항목}

### UI/UX 변경사항
{기획서에 명시된 경우에만 — 없으면 이 섹션 생략}

### 예외/엣지케이스
{기획서에 명시된 경우에만 — 없으면 이 섹션 생략. Claude가 일반 지식으로 추가하지 않는다}
```

### 3-2. 구현 정보 수집

구현 근거는 **파일에서만** 읽는다. 대화 컨텍스트의 이전 답변 내용을 직접 재인용하지 않는다.

```bash
source "$TMPDIR/_env.sh"

curl -s -u "$JIRA_AUTH" \
  "$JIRA_BASE/rest/api/2/issue/${TICKET_KEY}?fields=summary,description,fixVersions,status,priority,assignee,issuetype" \
  -o "$TMPDIR/ticket_basic.json"

# ticket-qa evidence.json 파일 기반 재사용 (대화 기억 의존 금지)
TQA_DIR="$(cygpath -m /tmp 2>/dev/null || echo /tmp)/ticket-qa-${TICKET_KEY}"
if [ -f "$TQA_DIR/evidence.json" ]; then
  cp "$TQA_DIR/evidence.json" "$TMPDIR/evidence.json"
  TQA_AVAILABLE=true
  echo "ticket-qa evidence.json 로드 완료"
else
  TQA_AVAILABLE=false
  echo "ticket-qa evidence.json 없음 — 코드 근거 없이 실행"
fi
```

**ticket-qa 결과 재사용 규칙:**
- `$TMPDIR/evidence.json`이 있으면 → 해당 파일의 `evidence_files`, `evidence_tag`, `prs` 항목만 참조한다
- 파일이 없으면 → 이전 대화에서 ticket-qa 결과를 기억하고 있더라도 그 내용을 구현 근거로 사용하지 않는다
- **금지**: 대화 컨텍스트에서 이전에 출력된 파일명·함수명·판정을 기억으로 재인용하는 것

### 3-3. 기획서 vs 구현 비교

기획서 요구사항 각 항목을 구현 내용과 대조한다.

**판정 기준 (엄격 적용):**
- `✅ 일치` — ticket-qa Evidence 또는 PR diff에서 해당 기능의 코드를 직접 확인한 경우에만 사용
- `⚠️ 불일치` — 기획서 내용과 코드가 다름을 코드 근거와 함께 명시할 수 있는 경우에만 사용
- `❓ 미확인` — ticket-qa 미실행이거나 해당 기능의 코드를 확인하지 못한 경우 (기본값)
- `➕ 추가구현` — ticket-qa Evidence에서 기획서에 없는 코드 변경이 확인된 경우에만 사용

**금지 사항**: Jira description, 기획서 내용, 혹은 일반 지식으로 구현 상태를 추론해 ✅ 또는 ⚠️ 를 부여하는 것은 절대 금지한다.

**ticket-qa 없이 단독 실행 시**: 비교 테이블의 "구현 상태" 칸을 모두 `—` 로 채우고 판정을 모두 `❓ 미확인 (ticket-qa 미실행)` 으로 표기한다. ✅·⚠️·➕ 판정은 사용하지 않는다.

```
## 기획서 비교 결과

| 항목 | 기획서 내용 | 구현 상태 | 판정 |
|------|------------|---------|------|
| {항목명} | {기획서 원문 요약} | {코드/PR 확인 내용 또는 —} | ✅ 일치 / ⚠️ 불일치 / ❓ 미확인 / ➕ 추가구현 |

### 불일치 ⚠️ 상세
- {항목}: 기획서는 {X}인데 코드는 {Y} — 근거: {파일명/함수명}

### 미확인 (기획서에 있으나 코드 확인 불가 — 구현 누락 확정 아님)
- {항목}: {기획서 원문} — 미확인 이유: {ticket-qa 미실행 / Evidence 없음 / 해당 기능 파일 미탐지}

### 추가 구현 (기획서에 없으나 코드에 존재)
- {항목}: {코드 위치}
```

---

## STEP 4: 최종 출력

```
# /spec-review {TICKET_KEY} 결과

## 기획서 파일
- {파일명} → {절대 경로}   ← Finder에서 바로 열 수 있도록 절대 경로 명시

## 기획서 요약
{STEP 3-1 결과}

## 기획서 비교 결과
{STEP 3-3 결과}

## 추가 QA 확인 항목 (불일치·미확인 기반)
[ ] {확인 포인트} — 근거: 기획서 {섹션} / 판정: {⚠️ 불일치 또는 ❓ 미확인}
[ ] {확인 포인트} — 근거: 기획서 {섹션} / 판정: {⚠️ 불일치 또는 ❓ 미확인}
```

---

## STEP 5: Slack 전송 (선택)

기본 채널은 `#qa-ai-report` (ID: `C0AQTSRRFHC`).

AskUserQuestion으로 Slack 전송 여부를 확인한다.

```
question: "분석 결과를 Slack에 전송할까요?"
options:
  - label: "전송",  description: "#qa-ai-report 채널에 전송합니다"
  - label: "건너뛰기",  description: "Slack 전송 없이 종료합니다"
```

**"전송" 선택 시:** 기본 채널 `#qa-ai-report` (C0AQTSRRFHC)로 바로 전송한다. 별도 채널 질문 없이 진행한다.

### Slack 전송 형식

**부모 메시지** (채널에 노출):
```
_spec-review_
*[{TICKET_KEY}]* {티켓 제목}
타입: {타입} | 우선순위: {우선순위} | 담당: {담당자}
기획서: {기획서 파일명}
{JIRA_BASE}/browse/{TICKET_KEY}
```

**스레드 답글은 2개를 순서대로 전송한다.**

**[스레드 1] 확인 필요 항목** (테스터 액션 중심):
```
*기획서 비교 — 확인 필요 항목*

⚠️ 불일치 ({N}건)
• {항목}: 기획서 {X} / 코드 {Y}

*추가 QA 확인 항목 (불일치·미확인 기반)*
[ ] {확인 포인트} — 근거: 기획서 {섹션} / {⚠️ 불일치 또는 ❓ 미확인}
[ ] {확인 포인트} — 근거: 기획서 {섹션} / {⚠️ 불일치 또는 ❓ 미확인}
```

불일치가 0건이면 `⚠️ 불일치` 섹션을 아래로 대체한다:
```
✅ 불일치 항목 없음 (확인된 항목 범위 내 — ❓ 미확인 항목은 별도 확인 필요)
```
"불일치 없음"은 "문제없음 확정"이 아니라 "확인된 범위에서 불일치 없음"임을 명시한다.

**[스레드 2] 기획서 비교 전체 항목** (판정 요약, 구현 상태 제외):
```
*기획서 비교 전체 항목*

✅ 일치 ({N}건)
• {항목} — {기획서 내용 한 줄 요약}

❓ 미확인 ({N}건)
• {항목} — {기획서 내용 + 미확인 이유}

⚠️ 불일치 ({N}건)
• {항목} — 기획서: {X} / 코드: {Y}
```

**두 스레드 모두 포함하지 않는 항목:**
- 구현 상태 (코드 파일 경로·함수명) — 테스터 불필요
- ➕ 추가 구현 상세 — 생략
- 기획서 전체 요약 (목적/배경, 주요 기능 전체) — 생략
