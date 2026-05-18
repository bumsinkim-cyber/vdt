---
name: spec-watch
description: Google Drive 폴더를 감시해 기획서 변경을 감지하고, 변경 내용 요약 + 선택적 갭 분석을 수행합니다. "/spec-watch", "기획서 변경 감지", "기획 모니터링" 요청 시 사용합니다.
---

# /spec-watch — Google Drive 기획서 변경 감지 + 갭 분석

> **실행 환경**: 이 스킬의 bash 명령은 Claude Code Bash 도구 기준으로 작성됐다. Windows에서는 Git Bash 환경에서 실행된다.
> **설계 의도**: 각 Bash 코드 블록은 하나의 논리 단위다. 병렬화·최적화 목적으로 블록을 쪼개지 말 것.

## 실행 모드

| 모드 | 트리거 | 동작 |
|------|--------|------|
| **경량 (detect-only)** | 스케줄 자동 / `--detect-only` | Phase 1~2만: 변경 감지 + 변경 요약 → Slack 알림 |
| **전체** | 수동 `/spec-watch` (기본) | Phase 1~2 + Phase 3: 변경 감지 후 갭 분석 |

인자 없이 실행하면 **전체 모드**. `--detect-only` 옵션 시 경량 모드.

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

감시 대상 폴더가 `watch-targets.json`에 없으면 `AskUserQuestion`으로 묻는다.

```
question: "감시할 Google Drive 폴더 URL 또는 폴더 ID를 Other에 입력해 주세요."
options:
  - label: "예시", description: "https://drive.google.com/drive/folders/1abc...  또는 폴더 ID 직접 입력"
```

입력값에서 폴더 ID를 추출해 `watch-targets.json`에 추가한다.

---

## watch-targets.json

감시 대상 폴더 설정 파일. 스킬 디렉토리에 위치한다.

**경로**: `.claude/skills/spec-watch/watch-targets.json`

```json
{
  "folders": [
    {
      "id": "GOOGLE_DRIVE_FOLDER_ID",
      "label": "CVS 기획 문서",
      "recursive": true
    }
  ],
  "options": {
    "ignore_patterns": ["[백업]", "[삭제]", "~$"],
    "min_change_interval_hours": 1
  }
}
```

- `recursive`: true면 하위 폴더까지 재귀 탐색
- `ignore_patterns`: 파일명에 포함되면 무시
- `min_change_interval_hours`: 마지막 감지 이후 이 시간 이내 변경은 무시 (중복 알림 방지)

파일이 없으면 첫 실행 시 사용자에게 폴더 입력받아 자동 생성한다.

---

## 스냅샷 구조

변경 감지는 로컬 스냅샷과의 비교로 동작한다.

**경로**: `/tmp/spec-watch/snapshots/`

```
/tmp/spec-watch/
├── snapshots/
│   └── {FOLDER_ID}/
│       ├── _manifest.json          # 파일 목록 + modifiedTime
│       └── {FILE_ID}.txt           # 추출된 텍스트 (이전 버전)
└── reports/
    └── {YYYYMMDD_HHmmss}.md       # 리포트 아카이브
```

**_manifest.json 형식**:
```json
{
  "last_scan": "2026-04-13T10:00:00Z",
  "files": {
    "FILE_ID_1": {
      "name": "이벤트배너_v3",
      "mimeType": "application/vnd.google-apps.presentation",
      "modifiedTime": "2026-04-12T18:30:00Z",
      "textHash": "sha256hex..."
    }
  }
}
```

---

## 임시 파일 경로 (Windows 호환)

```bash
export TMPDIR="$(cygpath -m /tmp 2>/dev/null || echo /tmp)/spec-watch"
```

## Python 인코딩 가드 (전체 코드 공통)

모든 Python `-c` 블록 첫 줄에 삽입:
```python
import sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace'); sys.stderr.reconfigure(encoding='utf-8', errors='replace')
```
파일 `open()` 시 항상 `encoding='utf-8', errors='replace'` 지정. 이후 코드 블록에서 반복하지 않는다.

---

## 인증 설정

### Jira 인증 (Phase 3 갭 분석 시 필요)

```bash
PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)
JIRA_JSON="$(cygpath -m "$HOME/.bagelcode/jira.json" 2>/dev/null || echo "$HOME/.bagelcode/jira.json")"

if [ -f "$JIRA_JSON" ]; then
  JIRA_DOMAIN=$($PYTHON -c "import json,sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace'); d=json.load(open(sys.argv[1], encoding='utf-8', errors='replace')); print(d['domain'])" "$JIRA_JSON")
  JIRA_EMAIL=$($PYTHON -c "import json,sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace'); d=json.load(open(sys.argv[1], encoding='utf-8', errors='replace')); print(d['email'])" "$JIRA_JSON")
  JIRA_TOKEN=$($PYTHON -c "import json,sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace'); d=json.load(open(sys.argv[1], encoding='utf-8', errors='replace')); print(d['token'])" "$JIRA_JSON")
  JIRA_AUTH="$JIRA_EMAIL:$JIRA_TOKEN"
  JIRA_BASE="https://$JIRA_DOMAIN"
  JIRA_AVAILABLE=true
else
  JIRA_AVAILABLE=false
  echo "⚠️  ~/.bagelcode/jira.json 없음 — Phase 3 갭 분석 불가 (변경 감지는 정상 진행)"
fi
```

### gws 초기화

```bash
GWS=$(command -v gws 2>/dev/null || echo "")
if [ -z "$GWS" ]; then
  echo "❌ gws CLI 미발견 — Google Drive 접근 불가. 설치: npm install -g @googleworkspace/cli"
  # gws 없으면 실행 불가 — 중단
  exit 1
fi
```

### 환경변수 저장

```bash
export TMPDIR="$(cygpath -m /tmp 2>/dev/null || echo /tmp)/spec-watch"
mkdir -p "$TMPDIR/snapshots" "$TMPDIR/reports"

SKILL_DIR="$(cygpath -m "C:/moco/.claude/skills/spec-watch" 2>/dev/null || echo "C:/moco/.claude/skills/spec-watch")"
TARGETS_FILE="$SKILL_DIR/watch-targets.json"

cat > "$TMPDIR/_env.sh" <<EOF
export TMPDIR="$TMPDIR"
export PYTHON="$PYTHON"
export JIRA_AUTH="$JIRA_AUTH"
export JIRA_BASE="$JIRA_BASE"
export JIRA_AVAILABLE="$JIRA_AVAILABLE"
export SKILL_DIR="$SKILL_DIR"
export TARGETS_FILE="$TARGETS_FILE"
EOF
```

---

## PHASE 1: 변경 감지

### 1-1. 감시 대상 폴더 로드 + Drive 파일 목록 조회

```bash
source "$TMPDIR/_env.sh"

# watch-targets.json 로드
if [ ! -f "$TARGETS_FILE" ]; then
  echo "TARGETS_NOT_FOUND"
  exit 0
fi

$PYTHON -c "
import json, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

with open('$TARGETS_FILE', encoding='utf-8', errors='replace') as f:
    cfg = json.load(f)

for folder in cfg.get('folders', []):
    fid = folder['id']
    label = folder.get('label', fid)
    recursive = '1' if folder.get('recursive', False) else '0'
    print(f'{fid}\t{label}\t{recursive}')
" > "$TMPDIR/folder_list.tsv"

echo "감시 대상 폴더: $(wc -l < "$TMPDIR/folder_list.tsv")개"
```

`TARGETS_NOT_FOUND` 출력 시 → AskUserQuestion으로 폴더 입력받아 watch-targets.json 생성 후 재실행.

### 1-2. 각 폴더 파일 목록 조회 (gws drive files list) + 재귀 탐색

> **설계 의도**: 공유 드라이브 폴더는 `supportsAllDrives` 필수. 하위 폴더 재귀 탐색은
> Python 스크립트 파일로 실행한다 (Windows cp949 인코딩 문제 회피 + 폴더명 이스케이프 안전).

```bash
source "$TMPDIR/_env.sh"

# Python 스캔 스크립트 생성 — 루트 + 하위 폴더 재귀 탐색
cat > "$TMPDIR/_scan_drive.py" << 'PYEOF'
import json, sys, subprocess, os
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
sys.stderr.reconfigure(encoding='utf-8', errors='replace')

tmpdir = os.environ.get('TMPDIR', '/tmp/spec-watch')
targets_file = os.environ.get('TARGETS_FILE', '')
env = os.environ.copy()
env['PYTHONUTF8'] = '1'

with open(targets_file, encoding='utf-8', errors='replace') as f:
    cfg = json.load(f)

ignore_list = cfg.get('options', {}).get('ignore_patterns', [])

def gws_list_files(folder_id):
    """Drive API로 폴더 내 파일 목록 조회 (공유 드라이브 지원)"""
    query = f"'{folder_id}' in parents and trashed = false"
    params = json.dumps({
        "q": query,
        "fields": "files(id,name,mimeType,modifiedTime)",
        "pageSize": 100,
        "supportsAllDrives": True,
        "includeItemsFromAllDrives": True,
        "corpora": "allDrives"
    })
    try:
        result = subprocess.run(
            ['gws.cmd', 'drive', 'files', 'list', '--params', params],
            capture_output=True, timeout=30, shell=True, env=env
        )
        stdout = result.stdout.decode('utf-8', errors='replace')
        output = '\n'.join(l for l in stdout.splitlines() if not l.startswith('Using keyring'))
        if not output.strip():
            return []
        return json.loads(output).get('files', [])
    except Exception as e:
        print(f'  ⚠️ gws 오류: {e}', file=sys.stderr)
        return []

all_docs = []
for folder_cfg in cfg.get('folders', []):
    folder_id = folder_cfg['id']
    folder_label = folder_cfg.get('label', folder_id)
    recursive = folder_cfg.get('recursive', False)

    print(f'--- 폴더 스캔: {folder_label} ({folder_id}) ---')

    # 루트 폴더 스캔
    files = gws_list_files(folder_id)
    subfolders = []
    for f in files:
        mime = f.get('mimeType', '')
        name = f.get('name', '')
        if 'folder' in mime:
            if recursive:
                subfolders.append((f['id'], name))
            continue
        if any(p in name for p in ignore_list if p):
            continue
        fid = f['id']
        mod = f.get('modifiedTime', '')
        all_docs.append(f'{fid}\t{name}\t{mime}\t{mod}\t{folder_id}\t{folder_label}')

    print(f'  루트 문서: {len(all_docs)}개, 하위 폴더: {len(subfolders)}개')

    # 하위 폴더 재귀 (1단계만)
    if recursive and subfolders:
        for i, (sub_id, sub_name) in enumerate(subfolders):
            sub_files = gws_list_files(sub_id)
            for f in sub_files:
                mime = f.get('mimeType', '')
                name = f.get('name', '')
                if 'folder' in mime:
                    continue
                if any(p in name for p in ignore_list if p):
                    continue
                fid = f['id']
                mod = f.get('modifiedTime', '')
                all_docs.append(f'{fid}\t{name} ({sub_name})\t{mime}\t{mod}\t{folder_id}\t{folder_label}')
            if (i + 1) % 10 == 0:
                print(f'  하위 폴더 스캔 중... {i+1}/{len(subfolders)}')

# 결과 저장
out_path = os.path.join(tmpdir, 'drive_files_all.tsv')
with open(out_path, 'w', encoding='utf-8') as out:
    for line in all_docs:
        out.write(line + '\n')

print(f'전체 문서 수: {len(all_docs)}개')
PYEOF

$PYTHON "$TMPDIR/_scan_drive.py"
```

### 1-3. 스냅샷 비교 — 변경된 파일만 필터링

```bash
source "$TMPDIR/_env.sh"

$PYTHON -c "
import json, sys, os, hashlib
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

changed = []
new_files = []

with open('$TMPDIR/drive_files_all.tsv', encoding='utf-8', errors='replace') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        parts = line.split('\t')
        if len(parts) < 6:
            continue
        fid, name, mime, mod_time, folder_id, folder_label = parts[:6]

        # 기존 manifest 로드
        manifest_path = os.path.join('$TMPDIR', 'snapshots', folder_id, '_manifest.json')
        manifest = {}
        if os.path.exists(manifest_path):
            with open(manifest_path, encoding='utf-8', errors='replace') as mf:
                manifest = json.load(mf)

        prev = manifest.get('files', {}).get(fid)
        if prev is None:
            # 신규 파일
            new_files.append((fid, name, mime, mod_time, folder_id, folder_label, 'NEW'))
        elif prev.get('modifiedTime') != mod_time:
            # 수정된 파일
            changed.append((fid, name, mime, mod_time, folder_id, folder_label, 'MODIFIED'))
        # 동일하면 무시

all_changes = changed + new_files
if not all_changes:
    print('NO_CHANGES')
else:
    for item in all_changes:
        print('\t'.join(item))
" > "$TMPDIR/changed_files.tsv"

if grep -q "NO_CHANGES" "$TMPDIR/changed_files.tsv"; then
  echo "변경 감지: 0건 — 변경된 기획서 없음"
else
  echo "변경 감지: $(wc -l < "$TMPDIR/changed_files.tsv")건"
  cat "$TMPDIR/changed_files.tsv"
fi
```

`NO_CHANGES` 시: "변경된 기획서가 없습니다." 출력 후 Slack에 간단 알림만 보내고 종료.

---

## PHASE 2: 변경 내용 추출 + diff

변경/신규 파일에 대해서만 텍스트 추출 후, 이전 스냅샷과 비교한다.

### 2-1. 변경 파일 텍스트 추출

> **설계 의도**: 업로드된 .pptx는 Drive export 불가(403). 다운로드(`alt:media`) 후
> python-pptx로 로컬 파싱한다. Google Slides 네이티브는 Slides API 사용.
> Windows에서 subprocess cp949 문제 방지를 위해 Python 스크립트 파일로 실행.

```bash
source "$TMPDIR/_env.sh"

if grep -q "NO_CHANGES" "$TMPDIR/changed_files.tsv"; then
  echo "SKIP — 변경 없음"
  exit 0
fi

cat > "$TMPDIR/_extract_changed.py" << 'PYEOF'
import json, sys, subprocess, os
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
sys.stderr.reconfigure(encoding='utf-8', errors='replace')

tmpdir = os.environ.get('TMPDIR')
env = os.environ.copy()
env['PYTHONUTF8'] = '1'

def gws_slides_api(fid):
    """Google Slides 네이티브 → Slides API"""
    params = json.dumps({"presentationId": fid})
    result = subprocess.run(
        ['gws.cmd', 'slides', 'presentations', 'get', '--params', params],
        capture_output=True, timeout=30, shell=True, env=env
    )
    raw = result.stdout.decode('utf-8', errors='replace')
    raw = '\n'.join(l for l in raw.splitlines() if not l.startswith('Using keyring'))
    if not raw.strip():
        return ''
    d = json.loads(raw)
    texts = []
    def collect(obj):
        if isinstance(obj, dict):
            if 'textRun' in obj:
                t = obj['textRun'].get('content', '').strip()
                if t and t != '\n':
                    texts.append(t)
            for v in obj.values():
                collect(v)
        elif isinstance(obj, list):
            for item in obj:
                collect(item)
    for si, slide in enumerate(d.get('slides', []), 1):
        texts.append(f'=== 슬라이드 {si} ===')
        collect(slide)
    return '\n'.join(texts)

def gws_download_pptx(fid):
    """업로드된 pptx → 다운로드 후 python-pptx 파싱"""
    dl_path = os.path.join(tmpdir, f'dl_{fid}.pptx')
    params = json.dumps({"fileId": fid, "supportsAllDrives": True, "alt": "media"})
    subprocess.run(
        ['gws.cmd', 'drive', 'files', 'get', '--params', params, '-o', dl_path],
        capture_output=True, timeout=60, shell=True, env=env
    )
    if not os.path.exists(dl_path) or os.path.getsize(dl_path) == 0:
        return ''
    try:
        from pptx import Presentation
        prs = Presentation(dl_path)
        texts = []
        for si, slide in enumerate(prs.slides, 1):
            slide_texts = []
            for shape in slide.shapes:
                if shape.has_text_frame:
                    for para in shape.text_frame.paragraphs:
                        t = para.text.strip()
                        if t:
                            slide_texts.append(t)
            if slide_texts:
                texts.append(f'=== 슬라이드 {si} ===')
                texts.extend(slide_texts)
            else:
                texts.append(f'=== 슬라이드 {si} === [이미지 전용]')
        return '\n'.join(texts)
    except Exception as e:
        return ''
    finally:
        if os.path.exists(dl_path):
            os.remove(dl_path)

def gws_export(fid, mime_type):
    """Google Docs/Sheets 네이티브 → export"""
    params = json.dumps({"fileId": fid, "mimeType": mime_type})
    result = subprocess.run(
        ['gws.cmd', 'drive', 'files', 'export', '--params', params],
        capture_output=True, timeout=30, shell=True, env=env
    )
    content = result.stdout.decode('utf-8', errors='replace')
    content = '\n'.join(l for l in content.splitlines() if not l.startswith('Using keyring'))
    if content.strip().startswith('{') and '"error"' in content:
        return ''
    return content

# 변경 파일 목록 로드
results = []
with open(os.path.join(tmpdir, 'changed_files.tsv'), encoding='utf-8', errors='replace') as f:
    for line in f:
        parts = line.strip().split('\t')
        if len(parts) >= 7:
            results.append(parts)

print(f'{len(results)}개 변경 파일 텍스트 추출')
extract_out = []

for i, parts in enumerate(results):
    fid, name, mime = parts[0], parts[1], parts[2]
    change_type = parts[6]
    folder_id, folder_label = parts[4], parts[5]
    new_path = os.path.join(tmpdir, f'new_{fid}.txt')
    content = ''
    
    try:
        if 'google-apps.presentation' in mime:
            content = gws_slides_api(fid)
        elif 'presentation' in mime:
            content = gws_download_pptx(fid)
        elif 'google-apps.document' in mime:
            content = gws_export(fid, 'text/plain')
        elif 'spreadsheet' in mime:
            content = gws_export(fid, 'text/csv')
        else:
            content = gws_export(fid, 'text/plain')
        
        if content.strip():
            with open(new_path, 'w', encoding='utf-8') as out:
                out.write(content)
            status = 'OK'
            print(f'  ✅ [{i+1}] {name} ({len(content)} chars)')
        else:
            status = 'FAIL'
            print(f'  ⚠️ [{i+1}] {name} — 추출 실패')
    except Exception as e:
        status = 'FAIL'
        print(f'  ❌ [{i+1}] {name}: {e}')
    
    extract_out.append(f'{fid}\t{name}\t{folder_id}\t{folder_label}\t{change_type}\t{status}')

with open(os.path.join(tmpdir, 'extract_results.tsv'), 'w', encoding='utf-8') as f:
    for line in extract_out:
        f.write(line + '\n')
PYEOF

$PYTHON "$TMPDIR/_extract_changed.py"
```

### 2-2. 이전 스냅샷과 diff 생성

```bash
source "$TMPDIR/_env.sh"

if grep -q "NO_CHANGES" "$TMPDIR/changed_files.tsv"; then
  exit 0
fi

$PYTHON -c "
import sys, os, hashlib, difflib
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

results = []
with open('$TMPDIR/extract_results.tsv', encoding='utf-8', errors='replace') as f:
    for line in f:
        parts = line.strip().split('\t')
        if len(parts) < 6 or parts[5] != 'OK':
            continue
        file_id, name, folder_id, folder_label, change_type = parts[:5]
        
        new_path = os.path.join('$TMPDIR', f'new_{file_id}.txt')
        old_path = os.path.join('$TMPDIR', 'snapshots', folder_id, f'{file_id}.txt')
        
        new_text = open(new_path, encoding='utf-8', errors='replace').read()
        
        if change_type == 'NEW' or not os.path.exists(old_path):
            # 신규 파일 — diff 없이 전문 요약 대상
            print(f'### [{change_type}] {name}')
            print(f'폴더: {folder_label}')
            print(f'전체 내용 ({len(new_text)} chars) — 신규 문서이므로 전문 분석 대상')
            print()
        else:
            old_text = open(old_path, encoding='utf-8', errors='replace').read()
            old_lines = old_text.splitlines(keepends=True)
            new_lines = new_text.splitlines(keepends=True)
            
            diff = list(difflib.unified_diff(old_lines, new_lines, 
                                             fromfile=f'{name} (이전)', 
                                             tofile=f'{name} (현재)',
                                             n=3))
            
            if diff:
                print(f'### [MODIFIED] {name}')
                print(f'폴더: {folder_label}')
                # 추가/삭제 라인 수 계산
                added = sum(1 for l in diff if l.startswith('+') and not l.startswith('+++'))
                removed = sum(1 for l in diff if l.startswith('-') and not l.startswith('---'))
                print(f'변경: +{added} / -{removed} 라인')
                print()
                for d in diff[:200]:  # diff가 너무 길면 200줄까지만
                    print(d, end='')
                if len(diff) > 200:
                    print(f'\n... (이하 {len(diff)-200}줄 생략)')
                print()
            else:
                print(f'### [UNCHANGED] {name} — modifiedTime 변경됐으나 텍스트 내용 동일')
                print()
" > "$TMPDIR/diff_report.md"

echo "=== diff 리포트 생성 완료 ==="
cat "$TMPDIR/diff_report.md"
```

### 2-3. 변경 요약 생성 + 스냅샷 갱신

diff_report.md를 읽고 변경 내용을 **자연어로 요약**한다. 이때 LLM이 diff를 해석한다.

요약 형식:
```
## 기획서 변경 요약 ({날짜})

### {문서명} [{NEW|MODIFIED}]
- {변경 포인트 1}: {이전} → {이후}
- {변경 포인트 2}: {추가된 내용 설명}
- 영향 예상: {어떤 기능/화면에 영향 있을지 추정}
```

그 후 스냅샷을 갱신한다:

```bash
source "$TMPDIR/_env.sh"

# 스냅샷 갱신: 새 텍스트를 스냅샷으로 복사, manifest 업데이트
$PYTHON -c "
import json, sys, os, hashlib
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

# 전체 파일 목록 로드
all_files = {}
with open('$TMPDIR/drive_files_all.tsv', encoding='utf-8', errors='replace') as f:
    for line in f:
        parts = line.strip().split('\t')
        if len(parts) < 6:
            continue
        fid, name, mime, mod_time, folder_id, folder_label = parts[:6]
        if folder_id not in all_files:
            all_files[folder_id] = {}
        all_files[folder_id][fid] = {
            'name': name,
            'mimeType': mime,
            'modifiedTime': mod_time
        }

# 변경 파일 텍스트 → 스냅샷 복사
with open('$TMPDIR/extract_results.tsv', encoding='utf-8', errors='replace') as f:
    for line in f:
        parts = line.strip().split('\t')
        if len(parts) < 6 or parts[5] != 'OK':
            continue
        file_id, name, folder_id = parts[0], parts[1], parts[2]
        
        snap_dir = os.path.join('$TMPDIR', 'snapshots', folder_id)
        os.makedirs(snap_dir, exist_ok=True)
        
        new_path = os.path.join('$TMPDIR', f'new_{file_id}.txt')
        snap_path = os.path.join(snap_dir, f'{file_id}.txt')
        
        import shutil
        shutil.copy2(new_path, snap_path)

# manifest 갱신 (폴더별)
from datetime import datetime, timezone
for folder_id, files in all_files.items():
    snap_dir = os.path.join('$TMPDIR', 'snapshots', folder_id)
    os.makedirs(snap_dir, exist_ok=True)
    manifest_path = os.path.join(snap_dir, '_manifest.json')
    
    # 기존 manifest 로드
    manifest = {}
    if os.path.exists(manifest_path):
        with open(manifest_path, encoding='utf-8', errors='replace') as mf:
            manifest = json.load(mf)
    
    manifest['last_scan'] = datetime.now(timezone.utc).isoformat()
    if 'files' not in manifest:
        manifest['files'] = {}
    
    for fid, info in files.items():
        snap_text = os.path.join(snap_dir, f'{fid}.txt')
        text_hash = ''
        if os.path.exists(snap_text):
            with open(snap_text, 'rb') as tf:
                text_hash = hashlib.sha256(tf.read()).hexdigest()
        manifest['files'][fid] = {
            'name': info['name'],
            'mimeType': info['mimeType'],
            'modifiedTime': info['modifiedTime'],
            'textHash': text_hash
        }
    
    with open(manifest_path, 'w', encoding='utf-8') as mf:
        json.dump(manifest, mf, ensure_ascii=False, indent=2)

print('스냅샷 갱신 완료')
"
```

---

## PHASE 3: 갭 분석 (선택적)

> **실행 조건**: 전체 모드(`--detect-only`가 아닌 경우) + Jira 인증 사용 가능 + 변경 파일 존재
> **방식**: 변경된 기획서 → Jira 티켓 역검색 → `/spec-review` 스킬 호출

### 3-1. 변경 기획서 → Jira 티켓 역검색

변경된 각 파일의 Google Drive URL로 Jira에서 연결된 티켓을 찾는다.

```bash
source "$TMPDIR/_env.sh"

if [ "$JIRA_AVAILABLE" != "true" ]; then
  echo "JIRA_UNAVAILABLE — 갭 분석 건너뜀"
  exit 0
fi

> "$TMPDIR/ticket_mapping.tsv"

while IFS=$'\t' read -r FILE_ID NAME MIME MOD_TIME FOLDER_ID FOLDER_LABEL CHANGE_TYPE; do
  [ -z "$FILE_ID" ] && continue

  # JQL: remotelink URL에 FILE_ID 포함된 티켓 검색
  JQL="issue in linkedIssues() AND status != Done"
  
  # Jira remotelink 기반 검색은 JQL로 직접 불가 → 대안: 텍스트 검색
  SEARCH_RESULT=$(curl -s -u "$JIRA_AUTH" \
    "$JIRA_BASE/rest/api/2/search?jql=description~\"$FILE_ID\"+OR+comment~\"$FILE_ID\"&fields=key,summary&maxResults=5" \
    2>/dev/null)

  # 결과 파싱
  $PYTHON -c "
import json, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
try:
    d = json.loads('''$SEARCH_RESULT''')
    for issue in d.get('issues', []):
        key = issue['key']
        summary = issue['fields']['summary']
        print(f'$FILE_ID\t$NAME\t{key}\t{summary}')
except:
    pass
" >> "$TMPDIR/ticket_mapping.tsv"

done < "$TMPDIR/changed_files.tsv"

MAPPED=$(wc -l < "$TMPDIR/ticket_mapping.tsv")
echo "티켓 매핑: ${MAPPED}건"
cat "$TMPDIR/ticket_mapping.tsv"
```

### 3-2. spec-review 연계 호출

매핑된 티켓별로 `/spec-review` 호출 여부를 결정한다.

- 매핑된 티켓이 **3건 이하**: 각각 `/spec-review` 실행
- 매핑된 티켓이 **4건 이상**: AskUserQuestion으로 분석할 티켓 선택
- 매핑된 티켓이 **0건**: 갭 분석 건너뜀, 변경 요약만 리포트

```
question: "변경 감지된 기획서에 연결된 티켓이 {N}건입니다. 갭 분석할 티켓을 선택하세요."
options:
  - label: "전체 분석", description: "{티켓 목록}"
  - label: "상위 3건만", description: "{상위 3건}"
  - label: "건너뛰기", description: "갭 분석 없이 변경 요약만 리포트"
multiSelect: false
```

선택된 티켓에 대해 `/spec-review {TICKET_KEY}` 실행.

> **주의**: spec-review는 토큰을 상당히 소비한다. 변경 파일이 많으면 상위 우선순위 티켓만 선별.

### 3-3. 갭 분석 미실행 시 표기

Phase 3를 건너뛴 경우:
```
### 갭 분석
⏭️ 갭 분석 미실행 — 개별 티켓 분석이 필요하면 `/spec-review {TICKET_KEY}`를 직접 실행하세요.
```

---

## PHASE 4: 리포트 + Slack 전송

### 4-1. 최종 리포트 생성

```
# 기획서 변경 감지 리포트 ({날짜})

## 감시 폴더
{폴더 목록}

## 변경 감지 결과: {N}건

| 문서명 | 폴더 | 변경 유형 | 변경 시각 | 연결 티켓 |
|--------|------|----------|----------|----------|
| {name} | {folder_label} | NEW/MODIFIED | {modifiedTime} | {ticket_key} 또는 (미연결) |

## 변경 내용 요약
{Phase 2에서 생성한 자연어 요약}

## 갭 분석 결과 (실행된 경우)
{Phase 3 spec-review 결과 요약 — 불일치/누락만 하이라이트}
```

### 4-2. Slack 전송

기본 채널: `#qa-ai-report` (ID: `C0AQTSRRFHC`). 채널 질문 없이 진행한다.

스케줄 모드에서는 자동 전송. 수동 모드에서는 AskUserQuestion으로 전송 여부 확인.

```
question: "변경 감지 결과를 Slack에 전송할까요?"
options:
  - label: "전송", description: "#qa-ai-report 채널에 전송합니다"
  - label: "건너뛰기", description: "Slack 전송 없이 종료합니다"
```

#### Slack 메시지 형식

**부모 메시지** (채널에 노출):
```
📋 _spec-watch_ 기획서 변경 감지 ({날짜})
감시 폴더: {폴더 라벨}
변경: {N}건 (신규 {X} / 수정 {Y})
```

**[스레드 1] 변경 요약**:
```
*변경 문서 목록*

{MODIFIED} *이벤트배너_v3*  (04-12 18:30)
  → 배너 표시 조건: 레벨 5 → 레벨 10 변경
  → 타이머 표시 항목 추가
  → 연결 티켓: CVS-13421

{NEW} *로비UI_개편*  (04-13 09:10)
  → 신규 기획 문서
  → 연결 티켓: (미연결)
```

**[스레드 2] 갭 분석 (Phase 3 실행 시)**:
```
*갭 분석 결과*

*CVS-13421 — 이벤트배너_v3*
⚠️ 불일치 (2건)
• 배너 표시 조건: 기획 "레벨 10 이상" / 코드 "레벨 5 이상"
• 타이머 표시: 기획에 추가됨 / 구현 미확인

갭 분석 미실행 문서: {목록}
→ 개별 분석: /spec-review {TICKET_KEY}
```

변경 0건일 때:
```
✅ _spec-watch_ 기획서 변경 없음 ({날짜})
감시 폴더: {폴더 라벨} | 문서 {N}건 확인
```

### 4-3. 리포트 아카이브

```bash
source "$TMPDIR/_env.sh"
REPORT_FILE="$TMPDIR/reports/$(date +%Y%m%d_%H%M%S).md"
# 최종 리포트 내용을 파일로 저장 (LLM이 위 형식으로 작성)
```

---

## 실패 모드 처리

| 실패 | 처리 |
|------|------|
| `watch-targets.json` 없음 | AskUserQuestion으로 폴더 입력 → 자동 생성 |
| gws CLI 없음 | 설치 안내 후 중단 |
| gws 인증 만료 | "gws auth login 재실행 필요" 안내 후 중단 |
| Drive API rate limit | 재시도 1회 후 실패 시 해당 파일 SKIP, 리포트에 명시 |
| Jira 인증 없음 | Phase 1~2만 실행, Phase 3 건너뜀 |
| 텍스트 추출 실패 | 해당 파일 FAIL 표기, 리포트에 URL 포함 (수동 확인용) |
| 스냅샷 디렉토리 없음 | 첫 실행으로 간주 — 전체 파일을 NEW로 처리, 스냅샷 초기화 |

---

## 첫 실행 시 동작

스냅샷이 없는 최초 실행에서는:
1. 전체 파일을 `NEW`로 감지
2. 모든 텍스트 추출 후 스냅샷 초기화
3. diff는 없으므로 "초기 스냅샷 생성 완료 — 다음 실행부터 변경 감지 시작" 메시지 출력
4. Slack에는 초기화 알림만 전송 (변경 리포트 아님)
