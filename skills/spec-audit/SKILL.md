---
name: spec-audit
description: 기획서 원문 또는 정리본을 입력받아 개발 시작 전 누락, 모호함, 충돌, 구현 차단 요소를 구조화한다. "/spec-audit", "기획서 감사", "개발 전 스펙 점검", "기획서 약점 분석" 요청 시 사용한다.
---

# Spec Audit

기획서를 QA 관점과 기획 관점에서 이중 분석하고, Braintrust 2-pass로 교차 검증하여
개발 시작 전 기획팀이 확인해야 할 항목을 구조화한다.

**모든 에이전트는 현재 세션 모델을 상속한다.**

## spec-review와의 차이
- **spec-audit** (이 스킬): 기획서 **단독** 감사. 개발 **전** 단계에서 기획서의 결함·모호·누락을 발굴.
- **spec-review**: 기획서 **vs 구현** 비교. 개발 **후** 단계에서 구현이 기획서를 준수했는지 확인.

---

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
question: "분석할 기획서를 지정해 주세요."
options:
  - label: "Jira 티켓 키",   description: "예: CVS-13353  (티켓에 연결된 Drive 기획서를 자동으로 읽음)"
  - label: "Google Drive URL", description: "예: https://docs.google.com/... (직접 URL 입력)"
```

---

## 공통 초기화

### Python / Jira 인증 설정

```bash
PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)
JIRA_JSON="$(cygpath -m "$HOME/.bagelcode/jira.json" 2>/dev/null || echo "$HOME/.bagelcode/jira.json")"

if [ ! -f "$JIRA_JSON" ]; then
  echo "~/.bagelcode/jira.json 파일이 없습니다."
  echo "Jira 티켓 연동이 필요한 경우 아래 형식으로 파일을 생성하세요:"
  echo '{ "domain": "yourcompany.atlassian.net", "email": "...", "token": "..." }'
  # Drive URL 직접 입력 모드라면 계속 진행 가능
fi

JIRA_DOMAIN=$($PYTHON -c "import json,sys; sys.stdout.reconfigure(encoding='utf-8',errors='replace'); d=json.load(open(sys.argv[1],encoding='utf-8',errors='replace')); print(d['domain'])" "$JIRA_JSON" 2>/dev/null || echo "")
JIRA_EMAIL=$($PYTHON  -c "import json,sys; sys.stdout.reconfigure(encoding='utf-8',errors='replace'); d=json.load(open(sys.argv[1],encoding='utf-8',errors='replace')); print(d['email'])"  "$JIRA_JSON" 2>/dev/null || echo "")
JIRA_TOKEN=$($PYTHON  -c "import json,sys; sys.stdout.reconfigure(encoding='utf-8',errors='replace'); d=json.load(open(sys.argv[1],encoding='utf-8',errors='replace')); print(d['token'])"  "$JIRA_JSON" 2>/dev/null || echo "")
JIRA_AUTH="$JIRA_EMAIL:$JIRA_TOKEN"
JIRA_BASE="https://$JIRA_DOMAIN"
```

### gws 초기화

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

### tmp 디렉토리 초기화

```bash
INPUT_KEY="{Jira 티켓 키 또는 'direct'}"   # 입력값에 따라 결정
export TMPDIR="$(cygpath -m /tmp 2>/dev/null || echo /tmp)/spec-audit-${INPUT_KEY}"

# spec_manual.txt 보존: 재실행 시 사용자가 저장해 둔 수동 파일을 먼저 백업
_MANUAL_BACKUP=""
if [ -f "$TMPDIR/spec_manual.txt" ]; then
  _MANUAL_BACKUP="$(mktemp)"
  cp "$TMPDIR/spec_manual.txt" "$_MANUAL_BACKUP"
  echo "ℹ️  이전 수동 입력 파일 발견 — 재실행 후에도 유지합니다."
fi

rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"

# 백업한 수동 파일 복원
if [ -n "$_MANUAL_BACKUP" ]; then
  mv "$_MANUAL_BACKUP" "$TMPDIR/spec_manual.txt"
fi

cat > "$TMPDIR/_env.sh" <<EOF
export TMPDIR="$TMPDIR"
export PYTHON="$PYTHON"
export JIRA_AUTH="$JIRA_AUTH"
export JIRA_BASE="$JIRA_BASE"
export JIRA_EMAIL="$JIRA_EMAIL"
export JIRA_TOKEN="$JIRA_TOKEN"
export GWS_AVAILABLE="$GWS_AVAILABLE"
EOF
```

---

## 경로 A: Jira 티켓 키 입력 (`[A-Z]+-\d+` 형식)

Jira 티켓의 remotelink에서 Google Drive URL을 자동 수집한다.
spec-review와 동일한 방식으로 Confluence 임베드 링크까지 스캔한다.

**Jira 인증 선제 검증**: 티켓 키 경로 진입 전, 인증 정보가 없으면 즉시 중단한다.

```bash
source "$TMPDIR/_env.sh"
_JIRA_MISSING=""
[ -z "$JIRA_BASE" ] || [ "$JIRA_BASE" = "https://" ] && _JIRA_MISSING="${_JIRA_MISSING} domain"
[ -z "$JIRA_EMAIL" ] && _JIRA_MISSING="${_JIRA_MISSING} email"
[ -z "$JIRA_TOKEN" ] && _JIRA_MISSING="${_JIRA_MISSING} token"
if [ -n "$_JIRA_MISSING" ]; then
  echo "❌ Jira 인증 정보가 없거나 불완전합니다 (누락 필드:${_JIRA_MISSING})"
  echo ""
  echo "해결 방법:"
  echo "  1. ~/.bagelcode/jira.json 생성 (모든 필드 필수):"
  echo '     { "domain": "yourcompany.atlassian.net", "email": "...", "token": "..." }'
  echo "  2. 또는 Google Drive URL을 직접 /spec-audit 에 전달하세요."
  exit 1
fi
```

### A-1. Remotelink fetch

```bash
source "$TMPDIR/_env.sh"
curl -s -u "$JIRA_AUTH" \
  "$JIRA_BASE/rest/api/2/issue/${INPUT_KEY}/remotelink" \
  -o "$TMPDIR/remotelinks.json"
```

### A-2. Google Drive URL 추출

```bash
source "$TMPDIR/_env.sh"

$PYTHON -c "
import json, re, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

def extract_gdrive(url, title):
    if 'drive.google.com' not in url and 'docs.google.com' not in url:
        return None
    if '/presentation/d/' in url:  export_mime = 'text/plain'
    elif '/document/d/' in url:    export_mime = 'text/plain'
    elif '/spreadsheets/d/' in url: export_mime = 'text/csv'
    else:                           export_mime = 'text/plain'
    m = re.search(r'/(?:presentation|document|spreadsheets)/d/([a-zA-Z0-9_-]+)', url)
    if not m: m = re.search(r'/file/d/([a-zA-Z0-9_-]+)', url)
    if not m: m = re.search(r'[?&]id=([a-zA-Z0-9_-]+)', url)
    if not m: return None
    return (m.group(1), export_mime, url, title)

with open('$TMPDIR/remotelinks.json', encoding='utf-8', errors='replace') as f:
    links = json.load(f)

confluence_page_ids = []
for link in links:
    url   = link.get('object', {}).get('url', '')
    title = link.get('object', {}).get('title', '') or 'untitled'
    result = extract_gdrive(url, title)
    if result:
        print('\t'.join(result))
    elif 'atlassian.net/wiki' in url or 'confluence' in url:
        m = re.search(r'pageId=(\d+)', url) or re.search(r'/pages/(\d+)', url)
        if m: confluence_page_ids.append((m.group(1), title))

with open('$TMPDIR/confluence_to_scan.tsv', 'w', encoding='utf-8') as f:
    for pid, t in confluence_page_ids:
        f.write(f'{pid}\t{t}\n')
" > "$TMPDIR/gdrive_files.tsv"
```

### A-3. Confluence 페이지 내부 Drive URL 스캔

```bash
source "$TMPDIR/_env.sh"

while IFS=$'\t' read -r PAGE_ID PAGE_TITLE; do
  [ -z "$PAGE_ID" ] && continue
  CONF_CACHE="$TMPDIR/_confluence_${PAGE_ID}.json"
  [ ! -f "$CONF_CACHE" ] && \
    curl -s -u "$JIRA_AUTH" \
      "$JIRA_BASE/wiki/rest/api/content/${PAGE_ID}?expand=body.storage" \
      -o "$CONF_CACHE"

  $PYTHON -c "
import json, re, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
d = json.load(open('$CONF_CACHE', encoding='utf-8', errors='replace'))
body = d.get('body',{}).get('storage',{}).get('value','')
for url in re.findall(r'https://(?:drive|docs)\.google\.com/[^\s\"<>]+', body):
    if   '/presentation/d/' in url: mime = 'text/plain'
    elif '/document/d/'     in url: mime = 'text/plain'
    elif '/spreadsheets/d/' in url: mime = 'text/csv'
    else:                           mime = 'text/plain'
    m = re.search(r'/(?:presentation|document|spreadsheets)/d/([a-zA-Z0-9_-]+)', url)
    if not m: m = re.search(r'/file/d/([a-zA-Z0-9_-]+)', url)
    if m: print(f\"{m.group(1)}\t{mime}\t{url}\t$PAGE_TITLE\")
" >> "$TMPDIR/gdrive_files.tsv"

  # lref-gdrive-file 매크로 및 ri:url 패턴 추가 스캔
  $PYTHON -c "
import json, re, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
d = json.load(open('$CONF_CACHE', encoding='utf-8', errors='replace'))
body = d.get('body',{}).get('storage',{}).get('value','')
seen = set()
for macro in re.finditer(r'ac:name=.lref-gdrive-file.(.*?)</ac:structured-macro>', body, re.DOTALL):
    mb = macro.group(1)
    fid_m = re.search(r'ac:name=.fileId.[^>]*>([a-zA-Z0-9_-]{15,})', mb)
    mt_m  = re.search(r'ac:name=.mimeType.[^>]*>([^<]{5,60})', mb)
    if fid_m:
        fid = fid_m.group(1)
        if fid in seen: continue
        seen.add(fid)
        raw_mt = mt_m.group(1).strip() if mt_m else ''
        mime = 'text/csv' if 'spreadsheet' in raw_mt else 'text/plain'
        url  = f'https://drive.google.com/file/d/{fid}'
        print(f'{fid}\t{mime}\t{url}\t$PAGE_TITLE')
for m in re.finditer(r'ri:value=.(https://(?:drive|docs)\.google\.com/[^\s>\"]+)', body):
    url = m.group(1).rstrip('/')
    fm = re.search(r'/(?:presentation|document|spreadsheets)/d/([a-zA-Z0-9_-]+)', url)
    if not fm: fm = re.search(r'/file/d/([a-zA-Z0-9_-]+)', url)
    if fm and fm.group(1) not in seen:
        seen.add(fm.group(1))
        mime = 'text/csv' if '/spreadsheets/' in url else 'text/plain'
        print(f'{fm.group(1)}\t{mime}\t{url}\t$PAGE_TITLE')
" >> "$TMPDIR/gdrive_files.tsv"
done < "$TMPDIR/confluence_to_scan.tsv"

LC_ALL=C sort -u "$TMPDIR/gdrive_files.tsv" -o "$TMPDIR/gdrive_files.tsv"
echo "Google Drive 기획서: $(wc -l < "$TMPDIR/gdrive_files.tsv")개"
```

Drive URL이 0개이면 "이 티켓에 연결된 Google Drive 기획서가 없습니다." 출력 후 중단.

---

## 경로 B: Google Drive URL 직접 입력

입력값이 `https://docs.google.com/` 또는 `https://drive.google.com/` 로 시작하는 경우.

```bash
source "$TMPDIR/_env.sh"

INPUT_URL="{입력받은 URL}"

$PYTHON -c "
import re, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
url = '$INPUT_URL'
if   '/presentation/d/' in url: mime = 'text/plain'
elif '/document/d/'     in url: mime = 'text/plain'
elif '/spreadsheets/d/' in url: mime = 'text/csv'
else:                           mime = 'text/plain'
m = re.search(r'/(?:presentation|document|spreadsheets)/d/([a-zA-Z0-9_-]+)', url)
if not m: m = re.search(r'/file/d/([a-zA-Z0-9_-]+)', url)
if not m: m = re.search(r'[?&]id=([a-zA-Z0-9_-]+)', url)
if m: print(f\"{m.group(1)}\t{mime}\t{url}\t기획서\")
else: print('URL에서 파일 ID를 추출할 수 없습니다.', file=sys.stderr); sys.exit(1)
" > "$TMPDIR/gdrive_files.tsv"
```

---

## gws 다운로드 (경로 A·B 공통)

```bash
source "$TMPDIR/_env.sh"
FETCH_FAILED_LIST=""

# .pptx 추출 헬퍼 스크립트 생성 (native Slides API 실패 시 fallback용)
cat > "$TMPDIR/_pptx_extract.py" << 'PYEOF'
import zipfile, re, os, sys, xml.etree.ElementTree as ET, json
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
file_id, out_path, pptx_path = sys.argv[1], sys.argv[2], sys.argv[3]
TMPDIR = os.environ['TMPDIR']
NS = 'http://schemas.openxmlformats.org/drawingml/2006/main'
image_only = []
try:
    with zipfile.ZipFile(pptx_path, 'r') as z:
        slides = sorted(
            [n for n in z.namelist() if re.match(r'ppt/slides/slide\d+\.xml', n)],
            key=lambda x: int(re.search(r'(\d+)', os.path.basename(x)).group(1))
        )
        lines = []
        for i, sname in enumerate(slides, 1):
            root = ET.fromstring(z.read(sname))
            texts = [e.text.strip() for e in root.iter(f'{{{NS}}}t')
                     if e.text and e.text.strip() and e.text.strip() != '\n']
            lines.append(f'=== 슬라이드 {i} ===')
            if texts:
                lines.append('\n'.join(texts))
            else:
                lines.append('[이미지 전용 슬라이드]')
                image_only.append(i)
    with open(out_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))
    io_path = os.path.join(TMPDIR, 'image_only_slides.json')
    existing = {}
    if os.path.exists(io_path):
        try:
            with open(io_path) as f: existing = json.load(f)
        except Exception: pass
    existing[file_id] = image_only
    with open(io_path, 'w', encoding='utf-8') as f:
        json.dump(existing, f)
    print(f'[PPTX] {len(slides)}개 슬라이드 추출 (이미지 전용: {len(image_only)}개)')
except Exception as e:
    with open(out_path, 'w', encoding='utf-8') as f:
        f.write('[FETCH_FAILED:PPTX_EXTRACT_ERROR]')
    print(f'[PPTX] 추출 실패: {e}', file=sys.stderr)
PYEOF

while IFS=$'\t' read -r FILE_ID EXPORT_MIME ORIGINAL_URL TITLE; do
  [ -z "$FILE_ID" ] && continue
  CACHE_FILE="$TMPDIR/spec_${FILE_ID}.txt"

  if [ "$GWS_AVAILABLE" = "false" ]; then
    echo "[FETCH_FAILED:GWS_NOT_INSTALLED]" > "$CACHE_FILE"
    FETCH_FAILED_LIST="${FETCH_FAILED_LIST}\n- $TITLE ($ORIGINAL_URL)"
    continue
  fi

  if echo "$ORIGINAL_URL" | grep -q 'presentation'; then
    # Slides: API JSON 파싱
    GWS_JSON_TMP="$TMPDIR/slides_${FILE_ID}.json"
    gws slides presentations get \
      --params "{\"presentationId\":\"$FILE_ID\"}" \
      > "$GWS_JSON_TMP" 2>/dev/null

    $PYTHON -c "
import json, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
with open('$GWS_JSON_TMP', encoding='utf-8', errors='replace') as f:
    lines = [l for l in f if not l.startswith('Using keyring')]
content = ''.join(lines)
if not content.strip(): print('[FETCH_FAILED:SLIDES_EMPTY]'); sys.exit(1)
try:    d = json.loads(content)
except: print('[FETCH_FAILED:SLIDES_JSON_PARSE]'); sys.exit(1)

def collect(obj):
    texts = []
    if isinstance(obj, dict):
        if 'textRun' in obj:
            t = obj['textRun'].get('content','').strip()
            if t and t != '\n': texts.append(t)
        for v in obj.values(): texts.extend(collect(v))
    elif isinstance(obj, list):
        for item in obj: texts.extend(collect(item))
    return texts

# 미사용 슬라이드 필터: 벤치마크 키워드가 포함된 슬라이드 제외
SKIP_KEYWORDS = {'벤치마크', 'benchmark'}

def is_unused(slide):
    texts = [t.strip().lower() for t in collect(slide) if t.strip()]
    return any(t in SKIP_KEYWORDS for t in texts)

for i, slide in enumerate(d.get('slides',[]), 1):
    if is_unused(slide):
        continue
    texts = [t for t in collect(slide) if t]
    print(f'=== 슬라이드 {i} ===')
    print('\n'.join(texts) if texts else '[이미지 전용 슬라이드]')
" > "$CACHE_FILE" 2>/dev/null

    # .pptx 바이너리 fallback: native Slides API 실패 시 (업로드된 .pptx 파일 대응)
    _SLIDES_FIRST=$(head -1 "$CACHE_FILE" 2>/dev/null || echo "")
    if [ ! -s "$CACHE_FILE" ] || echo "$_SLIDES_FIRST" | grep -q '^\[FETCH_FAILED:'; then
      PPTX_PATH="$TMPDIR/spec_${FILE_ID}.pptx"
      echo "⚠️  native Slides API 실패 — .pptx 바이너리 다운로드 시도: $TITLE"
      gws drive files get \
        --params "{\"fileId\":\"$FILE_ID\",\"alt\":\"media\"}" \
        -o "$PPTX_PATH" 2>/dev/null
      if [ -s "$PPTX_PATH" ]; then
        $PYTHON "$TMPDIR/_pptx_extract.py" "$FILE_ID" "$CACHE_FILE" "$PPTX_PATH"
      fi
    fi
  else
    # Docs / Sheets
    GWS_TMP="$TMPDIR/gws_tmp_${FILE_ID}.txt"
    gws drive files export \
      --params "{\"fileId\":\"$FILE_ID\",\"mimeType\":\"$EXPORT_MIME\"}" \
      -o "$GWS_TMP" 2>/dev/null \
      && mv "$GWS_TMP" "$CACHE_FILE" 2>/dev/null \
      || rm -f "$GWS_TMP"
  fi

  _FIRST=$(head -1 "$CACHE_FILE" 2>/dev/null || echo "")
  if [ ! -s "$CACHE_FILE" ] || echo "$_FIRST" | grep -q '^\[FETCH_FAILED:'; then
    [ ! -s "$CACHE_FILE" ] && echo "[FETCH_FAILED:EXPORT_ERROR]" > "$CACHE_FILE"
    FETCH_FAILED_LIST="${FETCH_FAILED_LIST}\n- $TITLE ($ORIGINAL_URL)"
    echo "⚠️  추출 실패: $TITLE"
  else
    echo "✅ 추출 완료: $TITLE ($(wc -c < "$CACHE_FILE") bytes)"
  fi
done < "$TMPDIR/gdrive_files.tsv"

# FETCH_FAILED 항목을 audit_limitations.md 집계 단계에서 사용할 수 있도록 기록
if [ -n "$FETCH_FAILED_LIST" ]; then
  printf '%b\n' "$FETCH_FAILED_LIST" > "$TMPDIR/fetch_failed.md"
fi
```

### Slides 이미지 추출

gws 다운로드 루프 완료 후, `slides_*.json` 파일이 존재하면 Slides API 응답에서 슬라이드별 썸네일을 추출한다.
(`slides_${FILE_ID}.json`은 gws 다운로드 루프에서 보존되어 있다.)

```bash
source "$TMPDIR/_env.sh"

$PYTHON - <<'PYEOF'
import json, os, subprocess, sys, glob, zlib, struct
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

TMPDIR = os.environ['TMPDIR']
SLIDE_IMG_DIR = os.path.join(TMPDIR, 'slide_imgs')
os.makedirs(SLIDE_IMG_DIR, exist_ok=True)

json_files = glob.glob(os.path.join(TMPDIR, 'slides_*.json'))
if not json_files:
    print('Slides JSON 없음 — 이미지 추출 건너뜀')
    with open(os.path.join(TMPDIR, 'slide_img_map.json'), 'w') as f:
        json.dump({}, f)
    with open(os.path.join(TMPDIR, 'slide_dark_list.json'), 'w') as f:
        json.dump([], f)
    sys.exit(0)

DARK_THRESHOLD = 80  # 평균 밝기 80 미만 → 음영처리 슬라이드

def png_avg_brightness(path):
    """PNG 평균 밝기 추정 (stdlib only). 0=어두움, 255=밝음."""
    try:
        with open(path, 'rb') as f:
            if f.read(8) != b'\x89PNG\r\n\x1a\n': return 255
            idat, width, height, ch = b'', 0, 0, 3
            while True:
                n = struct.unpack('>I', f.read(4))[0]
                t = f.read(4); d = f.read(n); f.read(4)
                if t == b'IHDR':
                    width, height = struct.unpack('>II', d[:8])
                    ch = {0:1,2:3,3:1,4:2,6:4}.get(d[9], 3)
                elif t == b'IDAT': idat += d
                elif t == b'IEND': break
        raw = zlib.decompress(idat)
        stride = 1 + width * ch
        prev = bytearray(width * ch)
        total, count = 0, 0
        for ri in range(height):
            rs = ri * stride
            if rs >= len(raw): break
            filt = raw[rs]
            row = bytearray(raw[rs+1:rs+stride])
            if filt == 1:  # Sub
                for i in range(ch, len(row)): row[i] = (row[i] + row[i-ch]) & 0xFF
            elif filt == 2:  # Up
                for i in range(len(row)): row[i] = (row[i] + prev[i]) & 0xFF
            # 20픽셀마다 첫 채널 샘플링
            for p in range(0, len(row), ch * 20):
                total += row[p]; count += 1
            prev = row
        return total // max(count, 1)
    except Exception:
        return 255

slide_map = {}
dark_slides = []  # 음영처리로 감지된 슬라이드 키 목록

for json_path in json_files:
    # 파일 ID: slides_{FILE_ID}.json → FILE_ID
    file_id = os.path.basename(json_path)[len('slides_'):-len('.json')]

    with open(json_path, encoding='utf-8', errors='replace') as f:
        lines = [l for l in f if not l.startswith('Using keyring')]
    content = ''.join(lines)
    try:
        d = json.loads(content)
    except Exception as e:
        print(f'⚠️  JSON 파싱 실패: {json_path} ({e})')
        continue

    pres_id = d.get('presentationId', '')
    slides   = d.get('slides', [])

    for i, slide in enumerate(slides, 1):
        # 이미지 요소가 없으면 건너뜀
        has_image = any('image' in elem for elem in slide.get('pageElements', []))
        if not has_image:
            continue

        page_obj_id = slide.get('objectId', '')
        if not page_obj_id or not pres_id:
            continue

        # 파일명과 키 모두 file_id를 포함 — 다중 프레젠테이션 충돌 방지
        out_path = os.path.join(SLIDE_IMG_DIR, f'{file_id}_slide_{i}.png')

        # gws thumbnail API로 썸네일 URL 가져오기
        result = subprocess.run(
            ['gws', 'slides', 'presentations', 'pages', 'getThumbnail',
             '--params', json.dumps({
                 'presentationId': pres_id,
                 'pageObjectId': page_obj_id,
                 'thumbnailProperties.mimeType': 'PNG',
                 'thumbnailProperties.thumbnailSize': 'LARGE'
             })],
            capture_output=True, text=True
        )

        thumb_url = ''
        if result.returncode == 0:
            try:
                resp_lines = [l for l in result.stdout.split('\n') if not l.startswith('Using keyring')]
                thumb_resp = json.loads('\n'.join(resp_lines))
                thumb_url  = thumb_resp.get('contentUrl', '')
            except Exception:
                pass

        # fallback: pageElements 내 image.contentUrl 사용
        if not thumb_url:
            for elem in slide.get('pageElements', []):
                img_info = elem.get('image', {})
                thumb_url = img_info.get('contentUrl') or img_info.get('sourceUrl') or ''
                if thumb_url:
                    break

        if not thumb_url:
            print(f'⚠️  슬라이드 {i}: 이미지 URL 없음 — 건너뜀')
            continue

        dl = subprocess.run(['curl', '-s', '-L', thumb_url, '-o', out_path], capture_output=True)
        if dl.returncode == 0 and os.path.exists(out_path) and os.path.getsize(out_path) > 100:
            # 키: "{file_id}:{slide_number}" — Phase 0.5에서 어느 문서의 몇 번째 슬라이드인지 식별
            slide_key = f'{file_id}:{i}'
            slide_map[slide_key] = out_path
            # 음영처리 감지: 평균 밝기가 임계값 미만이면 dark list에 기록
            brightness = png_avg_brightness(out_path)
            if brightness < DARK_THRESHOLD:
                dark_slides.append(slide_key)
                print(f'🌑 [{file_id}] 슬라이드 {i}: 음영처리 감지 (밝기={brightness}) → 분석 제외')
            else:
                print(f'✅ [{file_id}] 슬라이드 {i}: 이미지 추출 완료 → {file_id}_slide_{i}.png')
        else:
            if os.path.exists(out_path):
                os.remove(out_path)
            print(f'⚠️  [{file_id}] 슬라이드 {i}: 이미지 다운로드 실패')

with open(os.path.join(TMPDIR, 'slide_img_map.json'), 'w') as f:
    json.dump(slide_map, f)
with open(os.path.join(TMPDIR, 'slide_dark_list.json'), 'w') as f:
    json.dump(dark_slides, f)

if slide_map:
    print(f'✅ 이미지 추출 완료: {len(slide_map)}개 슬라이드 (음영처리 제외: {len(dark_slides)}개)')
else:
    print('ℹ️  이미지가 있는 슬라이드 없음 (또는 모두 추출 실패)')
PYEOF
```

### 다운로드 실패 처리

실패 파일이 있으면:
```
⚠️  아래 기획서를 자동으로 읽지 못했습니다:
{FETCH_FAILED_LIST}

수동으로 진행하려면:
1. 위 URL을 브라우저에서 열어 파일 > 다운로드 > 일반 텍스트(.txt) 저장
2. 저장 경로: $TMPDIR/spec_manual.txt
3. /spec-audit 재실행
```

수동 파일(`$TMPDIR/spec_manual.txt`)이 존재하면 자동으로 분석에 포함한다.

### 기획서 텍스트 병합

유효한 `spec_*.txt` 파일과 `spec_manual.txt`를 하나로 병합하여 `$TMPDIR/input.md`에 저장한다.
유효 파일이 0개이면 중단한다.

```bash
source "$TMPDIR/_env.sh"

$PYTHON - <<'PYEOF'
import glob, os, sys, json, re
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

TMPDIR = os.environ['TMPDIR']

# 음영처리 슬라이드 dark list 로드
dark_list_path = os.path.join(TMPDIR, 'slide_dark_list.json')
dark_set = set()
if os.path.exists(dark_list_path):
    try:
        with open(dark_list_path) as f:
            dark_set = set(json.load(f))
    except Exception:
        pass

def filter_dark_slides(content, file_id):
    """spec_*.txt 내 음영처리 슬라이드 섹션을 제거한다."""
    if not dark_set or not file_id:
        return content, 0
    parts = re.split(r'(=== 슬라이드 \d+ ===\n?)', content)
    result, skipped = [], 0
    i = 0
    while i < len(parts):
        m = re.match(r'=== 슬라이드 (\d+) ===', parts[i]) if i < len(parts) else None
        if m:
            slide_num = int(m.group(1))
            body = parts[i+1] if i+1 < len(parts) else ''
            if f'{file_id}:{slide_num}' in dark_set:
                skipped += 1
                i += 2
                continue
            result.append(parts[i])
            if i+1 < len(parts): result.append(parts[i+1])
            i += 2
        else:
            result.append(parts[i])
            i += 1
    return ''.join(result), skipped

# FETCH_FAILED 마커가 없는 유효 파일만 수집
txt_files = sorted(glob.glob(os.path.join(TMPDIR, 'spec_*.txt')))
valid_files = []
for f in txt_files:
    try:
        with open(f, encoding='utf-8', errors='replace') as fh:
            first = fh.readline().strip()
        if not first.startswith('[FETCH_FAILED:'):
            valid_files.append(f)
    except Exception:
        pass

manual_file = os.path.join(TMPDIR, 'spec_manual.txt')
has_manual = os.path.exists(manual_file) and os.path.getsize(manual_file) > 0

if not valid_files and not has_manual:
    print('❌ 분석 가능한 기획서 파일이 없습니다. 중단합니다.')
    sys.exit(1)

# 입력 유형 판정: 자동 파일이 없고 수동 파일만 있으면 정리본
input_type   = '정리본' if (has_manual and not valid_files) else '원본'
input_source = ', '.join(os.path.basename(f) for f in valid_files) or 'spec_manual.txt'
normalization_note = (
    '⚠️ 정리본 입력 — 원문 일부가 누락되었을 수 있습니다.'
    ' 정리본에 없는 항목이 기획서 결함처럼 해석될 위험이 있습니다.'
    ' 감사 한계에 반드시 명시하세요.'
) if has_manual else ''

header = (
    f'---\n'
    f'input_type: {input_type}\n'
    f'input_source: {input_source}\n'
    f'normalization_note: {normalization_note}\n'
    f'---\n\n'
)

total_dark_skipped = 0
parts = [header]
for f in valid_files:
    fname = os.path.basename(f)
    file_id = fname[len('spec_'):-len('.txt')] if fname.startswith('spec_') and fname.endswith('.txt') else None
    with open(f, encoding='utf-8', errors='replace') as fh:
        content = fh.read()
    filtered, skipped = filter_dark_slides(content, file_id)
    total_dark_skipped += skipped
    parts.append(filtered)
    parts.append('\n\n')

if has_manual:
    with open(manual_file, encoding='utf-8', errors='replace') as fh:
        parts.append('\n\n[수동 입력 파일]\n')
        parts.append(fh.read())
        parts.append('\n\n')

with open(os.path.join(TMPDIR, 'input.md'), 'w', encoding='utf-8') as f:
    f.write(''.join(parts))

print(f'✅ input.md 생성 완료: 자동 {len(valid_files)}개'
      f' + {"수동 파일 포함" if has_manual else "수동 파일 없음"}')
print(f'   input_type: {input_type}')
if total_dark_skipped:
    print(f'   음영처리 슬라이드 제외: {total_dark_skipped}개')
PYEOF
```

---

## Phase 0: 문서 구조 정규화

`$TMPDIR/input.md` 텍스트에서 섹션/표/용어/TBD 위치를 추출하여 `$TMPDIR/doc_structure.md`를 생성한다.
이 파일은 Phase 1 에이전트가 발견 항목의 위치를 정확히 기록할 때 참조한다.

```bash
source "$TMPDIR/_env.sh"

$PYTHON - <<'PYEOF'
import re, sys, os
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

TMPDIR = os.environ['TMPDIR']
with open(f'{TMPDIR}/input.md', encoding='utf-8', errors='replace') as f:
    content = f.read()

lines = content.split('\n')
sections = []
tables = []
tbd_markers = []
terms = {}
current_section = '(문서 시작)'
in_table = False
table_start = None
table_headers = None

TBD_PAT = re.compile(
    r'\bTBD\b|미정|추후\s*결정|추가\s*예정|~할\s*예정|\[내용\]|N/A|추후\s*논의',
    re.IGNORECASE
)

for i, line in enumerate(lines, 1):
    slide_m = re.match(r'^===\s*슬라이드\s*(\d+)\s*===', line)
    head_m  = re.match(r'^(#{1,3})\s+(.+)$', line)
    if slide_m:
        current_section = f'슬라이드 {slide_m.group(1)}'
        sections.append({'name': current_section, 'line': i})
    elif head_m:
        current_section = head_m.group(2).strip()
        sections.append({'name': current_section, 'line': i, 'level': len(head_m.group(1))})

    if '|' in line and re.match(r'^\s*\|', line):
        if not in_table:
            in_table = True
            table_start = i
            table_headers = line
    else:
        if in_table:
            tables.append({'headers': table_headers, 'start': table_start, 'end': i-1, 'section': current_section})
            in_table = False

    if TBD_PAT.search(line):
        tbd_markers.append({'line': i, 'content': line.strip()[:120], 'section': current_section})

    for term in re.findall(r'\*\*([^*]{2,30})\*\*', line):
        t = term.strip()
        if t not in terms:
            terms[t] = {'first_line': i, 'count': 0}
        terms[t]['count'] += 1

if in_table:
    tables.append({'headers': table_headers, 'start': table_start, 'end': len(lines), 'section': current_section})

out = ['# 문서 구조 분석\n\n이 파일은 에이전트가 source_location 기록 시 참조한다.\n']

out.append('\n## 섹션 맵\n')
out.append('| 섹션 | 시작 줄 |\n|------|--------|')
for s in sections:
    out.append(f"| {s['name']} | {s['line']}줄 |")

out.append('\n\n## TBD / 미정 항목\n')
if tbd_markers:
    out.append('| 줄 | 섹션 | 원문 |\n|----|----|------|')
    for t in tbd_markers:
        out.append(f"| {t['line']} | {t['section']} | {t['content'].replace('|','\\|')} |")
else:
    out.append('_없음_')

out.append('\n\n## 표 목록\n')
if tables:
    out.append('| 위치 | 섹션 | 헤더 미리보기 |\n|------|------|-----------| ')
    for t in tables:
        hdrs = (t['headers'] or '')[:60].replace('|','·')
        out.append(f"| {t['start']}~{t['end']}줄 | {t['section']} | {hdrs} |")
else:
    out.append('_없음_')

out.append('\n\n## 반복 등장 용어 (2회 이상)\n')
repeated = sorted([(k,v) for k,v in terms.items() if v['count']>1], key=lambda x:-x[1]['count'])[:20]
if repeated:
    out.append('| 용어 | 최초 등장 | 빈도 |\n|------|---------|------|')
    for term, info in repeated:
        out.append(f"| {term} | {info['first_line']}줄 | {info['count']}회 |")
else:
    out.append('_없음_')

with open(f'{TMPDIR}/doc_structure.md', 'w', encoding='utf-8') as f:
    f.write('\n'.join(out))
print(f"✅ 문서 구조 정규화 완료: {len(sections)}개 섹션, {len(tbd_markers)}개 TBD, {len(tables)}개 표")
PYEOF
```

### 용어 사전 추출 (`terms.md`)

일관성 검증 및 Cross-Doc 분석의 근거 데이터를 자동 생성한다.

```bash
source "$TMPDIR/_env.sh"

$PYTHON - <<'PYEOF'
import re, os, sys
from collections import defaultdict
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

TMPDIR = os.environ['TMPDIR']
with open(f'{TMPDIR}/input.md', encoding='utf-8', errors='replace') as f:
    text = f.read()

# 후보: 1) bold/강조 2) 영어 CamelCase·Pascal 3) 한글 2~8자 명사(대괄호·따옴표 안)
terms = defaultdict(list)
for m in re.finditer(r'\*\*([^*\n]{2,40})\*\*', text):
    terms[m.group(1).strip()].append(m.start())
for m in re.finditer(r'\b([A-Z][a-zA-Z]{2,30}(?:[A-Z][a-zA-Z]+)*)\b', text):
    terms[m.group(1)].append(m.start())
for m in re.finditer(r'[「\[]([^」\]\n]{2,30})[」\]]', text):
    terms[m.group(1).strip()].append(m.start())

# 별칭 후보: 공통 접두/접미·영한 대응 추정
keys = sorted(terms.keys())
alias_candidates = []
lower_map = defaultdict(list)
for k in keys:
    lower_map[k.lower()].append(k)
for low, names in lower_map.items():
    if len(names) > 1:
        alias_candidates.append(names)

out = ['# 용어 사전\n',
       '자동 추출 결과이므로 오탐이 있을 수 있다. Design Analyst는 원문으로 최종 판단한다.\n',
       '\n## 등장 용어 (빈도순, 상위 50개)\n',
       '| 용어 | 빈도 |\n|------|------|']
for k, v in sorted(terms.items(), key=lambda x: -len(x[1]))[:50]:
    out.append(f'| {k} | {len(v)}회 |')

out.append('\n\n## 별칭 후보 (대소문자만 다른 동일 표기)\n')
if alias_candidates:
    for names in alias_candidates[:20]:
        out.append(f'- {" / ".join(names)}')
else:
    out.append('_없음_')

with open(f'{TMPDIR}/terms.md', 'w', encoding='utf-8') as f:
    f.write('\n'.join(out))
print(f"✅ 용어 사전 생성: {len(terms)}개 후보")
PYEOF
```

### 수치 사전 추출 (`numerics.md`)

```bash
source "$TMPDIR/_env.sh"

$PYTHON - <<'PYEOF'
import re, os, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

TMPDIR = os.environ['TMPDIR']
with open(f'{TMPDIR}/input.md', encoding='utf-8', errors='replace') as f:
    lines = f.readlines()

# 수치 + 단위 패턴 (초/분/시간/일/원/개/%/회/배/점/초당)
NUM_PAT = re.compile(
    r'(\d+(?:\.\d+)?)\s*(초|분|시간|일|원|개|%|회|배|점|명|건|ms|초당|sec|min|hour|day)',
    re.IGNORECASE
)

items = []  # (line_no, context, value, unit)
for i, line in enumerate(lines, 1):
    for m in NUM_PAT.finditer(line):
        context = line.strip()[:80]
        items.append((i, context, m.group(1), m.group(2)))

# 동일 컨텍스트 키워드로 묶어 불일치 후보 도출
# 컨텍스트에서 앞뒤 명사 3어절 추출
def extract_keyword(ctx, val):
    idx = ctx.find(val)
    before = ctx[max(0, idx-30):idx].strip()
    after = ctx[idx:idx+30].strip()
    return (before[-20:] + ' ' + after[:20]).strip()

groups = {}
for line_no, ctx, val, unit in items:
    kw = extract_keyword(ctx, val)
    groups.setdefault(kw, []).append((line_no, val, unit, ctx))

conflicts = []
for kw, entries in groups.items():
    vals = set((v, u.lower()) for _, v, u, _ in entries)
    if len(vals) > 1 and len(entries) >= 2:
        conflicts.append((kw, entries))

out = ['# 수치 사전\n',
       '자동 추출. 단위 환산 및 실제 동일 항목 여부는 Design Analyst가 최종 판단한다.\n',
       '\n## 추출된 수치 (상위 80건)\n',
       '| 줄 | 값 | 단위 | 문맥 |\n|----|-----|------|------|']
for line_no, ctx, val, unit in items[:80]:
    out.append(f'| {line_no} | {val} | {unit} | {ctx.replace("|","·")} |')

out.append('\n\n## 동일 항목 수치 불일치 후보\n')
if conflicts:
    for kw, entries in conflicts[:20]:
        out.append(f'\n### {kw}')
        for line_no, val, unit, ctx in entries:
            out.append(f'- {line_no}줄: **{val}{unit}** — {ctx[:60]}')
else:
    out.append('_없음_')

with open(f'{TMPDIR}/numerics.md', 'w', encoding='utf-8') as f:
    f.write('\n'.join(out))
print(f"✅ 수치 사전 생성: {len(items)}건 추출, {len(conflicts)}건 불일치 후보")
PYEOF
```

### 문서 헤더 표준 체크 (`doc_header.md`)

Status / Version / Last Updated / 관련 문서 필드 존재 여부. 누락 시 완결성 결함 신호.

```bash
source "$TMPDIR/_env.sh"

$PYTHON - <<'PYEOF'
import re, os, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

TMPDIR = os.environ['TMPDIR']
with open(f'{TMPDIR}/input.md', encoding='utf-8', errors='replace') as f:
    text = f.read()

HEADER_FIELDS = {
    'Status': r'(?i)\bstatus\b',
    'Version': r'(?i)\bversion\b|\bv\d',
    'Last Updated': r'(?i)last\s*updated|최종\s*수정|업데이트',
    '관련 문서': r'관련\s*문서|related\s*docs?|references?',
    '작성자': r'(?i)\bauthor\b|작성자|담당',
}

head_region = text[:2000]
result = {}
for name, pat in HEADER_FIELDS.items():
    result[name] = bool(re.search(pat, head_region))

missing = [k for k, v in result.items() if not v]

out = ['# 문서 헤더 체크\n',
       '표준 헤더(Status / Version / Last Updated / 관련 문서 / 작성자) 존재 여부.\n',
       '\n## 결과\n',
       '| 필드 | 존재 |\n|------|------|']
for k, v in result.items():
    out.append(f"| {k} | {'✅' if v else '❌'} |")

out.append(f'\n\n## 누락 필드: {len(missing)}개')
if missing:
    out.append('누락된 필드: ' + ', '.join(missing))
    out.append('\n→ Design Analyst는 이를 **완결성** 결함 후보로 간주한다.')

with open(f'{TMPDIR}/doc_header.md', 'w', encoding='utf-8') as f:
    f.write('\n'.join(out))
print(f"✅ 문서 헤더 체크: 누락 {len(missing)}건")
PYEOF
```

---

## Phase 0.5: 비전 분석 (슬라이드 이미지)

`$TMPDIR/slide_img_map.json`을 읽어 이미지가 있는 슬라이드 목록을 확인한다.
이미지가 있는 슬라이드가 1개 이상이면 아래 절차를 실행한다.

**이 단계는 Claude가 직접 Read tool로 이미지 파일을 읽어 처리한다. 별도 Agent 호출 없음.**

**사전 단계: input.md 백업 (필수)**

비전 분석 중 파일 손상을 방지하기 위해, Phase 0.5 시작 직전 `input.md`를 백업한다.
```bash
source "$TMPDIR/_env.sh"
cp "$TMPDIR/input.md" "$TMPDIR/input.backup.md"
```
비전 분석 단계에서 오류가 발생하면 `cp "$TMPDIR/input.backup.md" "$TMPDIR/input.md"`로 복원한다.

1. `slide_img_map.json`을 읽는다. 키 형식은 `"{file_id}:{slide_number}"`, 값은 이미지 파일 경로.
2. 각 항목에 대해 `input.md`의 해당 슬라이드 섹션(`=== 슬라이드 N ===`) 텍스트 단어 수를 확인한다. **30단어 이상이면 건너뛴다** — 텍스트가 충분한 슬라이드는 비전 분석이 중복이다. 30단어 미만인 경우만 Read tool로 이미지 파일(예: `slide_imgs/{file_id}_slide_N.png`)을 읽는다.
3. 해당 이미지에서 기획 분석에 유의미한 내용을 한국어로 설명한다:
   - UI 화면 구성 / 와이어프레임 레이아웃
   - 플로우차트·다이어그램·시퀀스 다이어그램
   - 표·매트릭스·비교 그리드
   - 아이콘·레이블·버튼 등 UI 요소
   - 텍스트만으로 전달되지 않는 시각적 맥락
   - 이미지가 단순 장식(배경·로고·구분선)이면 `[장식 이미지]`로 표기하고 생략
4. 설명을 `$TMPDIR/input.md`의 해당 `=== 슬라이드 N ===` 섹션 **텍스트 내용 바로 뒤**에 아래 형식으로 삽입한다:
   (복수 프레젠테이션이 있으면 file_id 기준으로 어느 문서의 슬라이드인지 매칭한다.)

```
[비전 분석]
{이미지에서 읽은 내용 설명}
```

4. 모든 슬라이드 처리 후 `input.md`를 저장한다.
5. 이미지가 없는 슬라이드는 건너뛴다.

슬라이드 수가 많을 경우(20개 이상) 이미지 밀도가 높은 슬라이드(이미지 3개 이상)를 우선 처리하고, 나머지는 이미지 1개 이상인 슬라이드 순으로 처리한다.

---

## Phase 0.7: 감사 한계 집계

Phase 1 시작 전, 이번 감사에서 자동 수집된 한계(다크 슬라이드 제외, 정리본 입력, 가져오기 실패 등)를 한 파일로 모은다.
Final Synthesizer가 최종 리포트의 "감사 한계" 섹션을 작성할 때 이 파일을 참조한다.

```bash
source "$TMPDIR/_env.sh"
python3 - <<'PY'
import json, os
TMPDIR = os.environ['TMPDIR']
lines = ["# Audit Limitations", ""]

# 1) 다크 슬라이드 제외
dark_path = os.path.join(TMPDIR, 'slide_dark_list.json')
if os.path.exists(dark_path):
    try:
        dark = json.load(open(dark_path))
    except Exception:
        dark = []
    if dark:
        lines.append(f"## 다크 슬라이드 제외 ({len(dark)}건)")
        for d in dark:
            lines.append(f"- {d}")
        lines.append("")

# 2) 정리본 입력 여부
input_path = os.path.join(TMPDIR, 'input.md')
if os.path.exists(input_path):
    with open(input_path, encoding='utf-8') as f:
        head = f.read(2000)
    if 'input_type: 정리본' in head or 'normalization_note: 정리본' in head:
        lines.append("## 입력 유형")
        lines.append("- 정리본(normalized) 입력 — 원문 대비 생략·재구성이 있을 수 있음")
        lines.append("")

# 3) 가져오기 실패
fetch_log = os.path.join(TMPDIR, 'fetch_failed.md')
if os.path.exists(fetch_log):
    with open(fetch_log, encoding='utf-8') as f:
        body = f.read().strip()
    if body:
        lines.append("## 가져오기 실패 문서")
        lines.append(body)
        lines.append("")

# 4) 이미지 전용 슬라이드 (.pptx 추출 경로에서 기록됨)
io_path = os.path.join(TMPDIR, 'image_only_slides.json')
if os.path.exists(io_path):
    try:
        io_data = json.load(open(io_path))
    except Exception:
        io_data = {}
    total_io = sum(len(v) for v in io_data.values())
    if total_io:
        lines.append(f"## 이미지 전용 슬라이드 (분석 제외, {total_io}건)")
        for fid, nums in io_data.items():
            if nums:
                lines.append(f"- {fid}: 슬라이드 {', '.join(str(n) for n in nums)}")
        lines.append("")

with open(os.path.join(TMPDIR, 'audit_limitations.md'), 'w', encoding='utf-8') as f:
    f.write("\n".join(lines))
PY
```

`fetch_failed.md`는 Phase 0의 fetch 루프에서 `FETCH_FAILED_LIST`를 기록한 파일이 있으면 그대로 사용한다(없으면 이 섹션은 생략됨).

---

## Phase 1: 병렬 초안 생성

QA Analyst와 Design Analyst를 **동시에(병렬로)** 호출한다.
두 에이전트 모두 `$TMPDIR/input.md`(원문)와 `$TMPDIR/doc_structure.md`(구조 맵)를 읽어 분석한다.

### Agent 1 — QA Analyst
- 프롬프트: `agents/qa-analyst.md` 내용을 읽어 agent prompt로 사용
- 역할: QA 관점에서 기획서의 모호함·누락·예외상태·테스트 불가 항목 발굴
- 산출물: `$TMPDIR/draft_qa.md`

### Agent 2 — Design Analyst
- 프롬프트: `agents/design-analyst.md` 내용을 읽어 agent prompt로 사용
- 역할: 기획 관점에서 실행가능성·완결성·명확성·일관성 결함 탐지
- 산출물: `$TMPDIR/draft_design.md`

---

## Phase 1.5: Cross-Doc Analyzer (조건부)

Jira 티켓에 Google Drive 기획서가 **2개 이상** 딸린 경우에만 호출한다.
문서 간 용어·수치·설계 의도 충돌과 참조 누락을 전용으로 잡는다.

```bash
source "$TMPDIR/_env.sh"
DOCS_COUNT=$(wc -l < "$TMPDIR/gdrive_files.tsv" 2>/dev/null || echo 0)
if [ "$DOCS_COUNT" -ge 2 ]; then
  echo "[Phase 1.5] 문서 $DOCS_COUNT개 감지 → Cross-Doc Analyzer 실행"
else
  echo "[Phase 1.5] 문서 $DOCS_COUNT개 → Cross-Doc Analyzer 생략"
fi
```

### Agent 3 — Cross-Doc Analyzer *(조건부, model: sonnet)*
- 프롬프트: `agents/cross-doc-analyzer.md`
- 입력: `input.md`, `terms.md`, `numerics.md`
- 역할: 문서 간 용어 충돌, 수치 충돌, 설계 의도 충돌, 참조 누락 탐지
- 산출물: `$TMPDIR/cross_doc_report.md`

문서가 1개면 이 Phase는 건너뛴다.

---

## Phase 2: 통합 합성 (단독 패스)

### Final Synthesizer
- 프롬프트: `agents/final-synthesizer.md`
- 입력:
  - `draft_qa.md` + `draft_design.md` — QA/Design 원본 초안 (교차 도전 포함)
  - `cross_doc_report.md` (Phase 1.5 실행 시에만 존재)
  - `audit_limitations.md`
- 역할: QA/Design 초안 교차 도전 + 통합 + 확정/불확실/미해결 분류 + 심각도 판정 + 최종 리포트 생성
- 산출물: `$TMPDIR/spec-audit-report.md`

---

## 출력 스키마 참조

- 항목 필드 정의: `references/output-schema.md`
- 최종 리포트 템플릿: `references/report-template.md`
- Design Analyst 평가 기준: `references/design-evaluation-criteria.md`

---

## 완료 보고

Final Synthesizer 완료 후 아래 형식으로 요약 출력:

```
spec-audit 완료
---
개발 차단: N건
리스크: N건
확인 권장: N건
미해결: N건
---
[개발 차단 항목이 있을 경우 제목 목록]
리포트: $TMPDIR/spec-audit-report.md
```

개발 차단 항목이 0건이면 "개발 차단 항목 없음. 기획팀 확인 후 개발 시작 가능."을 출력한다.

---

## 핵심 원칙

1. **추론은 허용하되 레이블 필수**: 모든 발견 항목에 근거 타입(사실/추론/가정)을 표시한다.
2. **평탄화 금지**: 미해결 항목은 미해결인 채로 유지한다. 억지 결론 금지.
3. **원본 보존**: Challenger는 QA/Design 원본 초안을 직접 읽는다. 중간 병합 결과만 받으면 뉘앙스가 희석된다.
4. **독립성 유지**: Phase 1의 두 에이전트는 서로의 결과를 보지 않는다.
