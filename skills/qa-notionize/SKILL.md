---
name: qa-notionize
description: 슬랙 메시지 링크(또는 raw 텍스트, 릴리스 번호)로 스킬 결과물을 입력받아 정제 후 Notion QA 자산 DB에 upsert한다. "/qa-notionize", "노션 저장", "QA 자산 저장" 요청 시 사용한다.
---

# /qa-notionize — QA 자산 Notion upsert

스킬 결과물(release-diff / ticket-diff / ticket-qa 출력)을 Notion DB에 자동 누적한다.
Notion MCP 대신 REST API(Bearer token)를 사용하므로 OAuth 인증 불필요.

## 고정 상수

```
DB_ID        = 33defacfc93281cb83bcd067b148ed29
NOTION_VER   = 2022-06-28
TOKEN_FILE   = ~/.bagelcode/notion.json
QA_CHANNEL   = C0AQTSRRFHC   (#qa-ai-report)
```

---

## STEP 0 — 사전 확인

**토큰 로드**

```bash
PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)
NOTION_TOKEN=$($PYTHON -c "
import json, os, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
d = json.load(open(os.path.expanduser('~/.bagelcode/notion.json'), encoding='utf-8'))
print(d['token'])
")
```

파일이 없거나 token 키가 없으면 아래 메시지 출력 후 **중단**:
```
~/.bagelcode/notion.json 파일이 없거나 token 키가 없습니다.
{"token": "ntn_..."} 형식으로 파일을 생성한 뒤 다시 실행해 주세요.
```

**입력 확인**

인자가 없으면 `AskUserQuestion`으로 묻는다:
```
question: "저장할 스킬 결과물을 어떻게 제공하시겠어요?"
options:
  - label: "릴리스 번호 (배치)"
    description: "릴리스 번호(예: 240)를 Other에 입력해 주세요."
  - label: "슬랙 메시지 링크"
    description: "슬랙 메시지 URL을 Other에 붙여넣어 주세요."
  - label: "텍스트 직접 붙여넣기"
    description: "Other에 스킬 결과물 전체를 붙여넣어 주세요."
```

릴리스 번호이면 → STEP 1C / 슬랙 URL이면 → STEP 1A / raw 텍스트이면 → STEP 1B

---

## STEP 1A — 슬랙 메시지 읽기

슬랙 URL 파싱:
- 형식: `https://[workspace].slack.com/archives/CHANNEL_ID/pTIMESTAMP`
- `CHANNEL_ID`: `/archives/` 뒤, `/p` 앞
- `TIMESTAMP`: `/p` 뒤 숫자 → 앞 10자리 + `.` + 나머지
  - 예: `p1709123456789012` → `1709123456.789012`

Slack MCP로 메시지 읽기:
```
slack_read_channel(channel_id=CHANNEL_ID, oldest=TS, latest=TS, limit=1)
```

읽은 본문 → `RAW_TEXT` 저장, `source_link` = 입력 URL. 실패 시 사용자에게 알리고 중단.

---

## STEP 1B — raw 텍스트 사용

사용자 입력 텍스트 → `RAW_TEXT` 저장. `source_link` = null.

---

## STEP 1C — 릴리스 배치 모드

릴리스 번호 N을 입력받아 release-diff + ticket-diff를 통합해 레코드 배열을 생성한다.

### 1C-1. release-diff 부모 메시지 수집

```
slack_search_public_and_private(query="릴리스 N in:#qa-ai-report", sort="timestamp", limit=20)
```

결과에서 릴리스 N 관련 release-diff 부모 메시지를 찾는다:
- 부모 메시지 조건: 메시지 본문에 "릴리스 N" + "[CVS-XXXXX]" 패턴 포함
- 각 부모의 `message_ts`를 `SPRINT_THREAD_TSS` 목록에 저장
- CVS 티켓 번호와 기능명을 `SPRINT_TICKETS` 목록으로 추출

### 1C-2. 각 release-diff 스레드의 분석 내용 읽기 (fallback 데이터)

각 CVS 티켓의 release-diff 부모 thread_ts로:
```
slack_read_thread(channel_id=QA_CHANNEL, message_ts=THREAD_TS)
```
→ 첫 번째 reply(분석 본문)를 release-diff 기반 레코드로 저장

### 1C-3. 티켓별 ticket-diff 검색 (우선 데이터)

**수정된 검색 방법**: 각 CVS 티켓에 대해 `CVS-XXXXX ticket-qa` 처럼 키워드를 추가하지 말고, 채널 내 전체 검색 후 release-diff 스레드를 제외한다.

```
slack_search_public_and_private(query="CVS-XXXXX in:#qa-ai-report", sort="timestamp", limit=10)
```

**필터링 규칙**:
1. `message_ts` 또는 `thread_ts`가 `SPRINT_THREAD_TSS` 목록에 있는 메시지 → release-diff 관련 → 제외
2. 부모 메시지 본문이 "릴리스 N" 으로 시작하는 스레드 → release-diff → 제외
3. 남은 메시지 중 가장 최신 것 → ticket-diff/ticket-qa 후보
4. ticket-diff 후보가 확인 포인트, 테스트 방법, 영향 범위 중 하나라도 포함하면 → 해당 스레드 전체 읽기

**우선순위**: ticket-diff 데이터가 있으면 → release-diff fallback 대신 ticket-diff 사용

### 1C-4. 레코드 배열 빌드

각 티켓에 대해 STEP 2 추출 원칙을 적용해 레코드를 구성하고 STEP 3으로 전달.

---

## STEP 2 — 정제 (필드 추출)

`RAW_TEXT`에서 아래 필드를 추출한다.

### 추출 원칙 (엄수)
1. 원문에 명시된 것만 추출 — 추론·보충·해석 금지
2. 값 불명확 또는 없음 → `null`
3. `related_bugs`: `CVS-\d+` 패턴만, 쉼표 구분 문자열. 없으면 `null`
4. `feature_name_raw`: 원문 표현 그대로 (정제·변환 금지)
5. `feature_type` 허용값: `신규` / `개선` / `프레임워크` / `버그픽스` — 해당 없으면 `null`
6. `확인 포인트`: 원문의 확인 포인트/테스트 방법 항목들을 줄바꿈으로 연결. 없으면 `null`
7. `source_excerpt`: 추출 근거가 된 원문 구절 1줄 (직접/간접 영향 범위 포함 시 우선 발췌)

### 추출 대상 필드

| 필드 | 타입 | 설명 |
|------|------|------|
| `sprint` | number | 릴리스 번호 (예: 240) |
| `feature_name_raw` | string | 원문 기능명 (upsert 키) |
| `feature_type` | string\|null | 4종 중 택1 |
| `impact_direct` | string\|null | 직접 영향 범위 |
| `impact_indirect` | string\|null | 간접 영향 범위 |
| `확인 포인트` | string\|null | 확인 항목 줄바꿈 연결 |
| `related_bugs` | string\|null | CVS-xxxxx, 쉼표 구분 |
| `source_link` | string\|null | 슬랙 URL |
| `source_excerpt` | string\|null | 추출 근거 1줄 |

여러 기능이 포함된 경우 각각을 별도 레코드로 추출한다.
추출 결과를 JSON 배열로 정리 후 STEP 3으로 전달.

---

## STEP 3 — upsert 루프

각 레코드에 대해 순서대로 처리:

### 3-0. 신규 릴리스 감지 및 구분선 생성

upsert 루프 시작 전, 현재 sprint 번호의 기존 레코드가 DB에 있는지 확인한다.

```python
import json, urllib.request, sys, os
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

token  = os.environ['NOTION_TOKEN']
db_id  = '33defacfc93281cb83bcd067b148ed29'
sprint = float(os.environ['SPRINT'])

headers = {
    'Authorization': f'Bearer {token}',
    'Notion-Version': '2022-06-28',
    'Content-Type': 'application/json',
}

payload = json.dumps({'filter': {
    'property': 'sprint', 'number': {'equals': sprint}
}}).encode('utf-8')
req = urllib.request.Request(
    f'https://api.notion.com/v1/databases/{db_id}/query',
    data=payload, headers=headers, method='POST'
)
with urllib.request.urlopen(req) as r:
    res = json.loads(r.read())
existing_count = len(res.get('results', []))
```

기존 레코드가 **0건** (신규 릴리스)이면 구분선 페이지를 먼저 생성한다:

```python
if existing_count == 0:
    sep_payload = json.dumps({
        'parent': {'database_id': db_id},
        'properties': {
            'feature_name_raw': {'title': [{'text': {'content': ''}}]},
            'sprint': {'number': sprint},
        },
    }).encode('utf-8')
    req = urllib.request.Request(
        'https://api.notion.com/v1/pages',
        data=sep_payload, headers=headers, method='POST'
    )
    with urllib.request.urlopen(req) as r:
        sep_res = json.loads(r.read())
    # 구분선 생성 완료 — 이후 실제 레코드 upsert 진행
```

**정렬 전제**: Notion DB 뷰에서 `sprint` 필드를 **내림차순(Descending)** 정렬로 설정하면 릴리스 번호가 높을수록 위에, 낮을수록 아래에 표시된다. 구분선 행은 동일 sprint 번호를 가지므로 해당 릴리스 그룹 내에 자동 포함된다.

---

### 3-1. upsert 키 검증

`sprint`, `feature_name_raw` 중 하나라도 null이면 해당 레코드 건너뜀 → 결과 보고에 명시.

### 3-2. 중복 검색

아래 Python 코드를 Bash로 실행한다 (`$NOTION_TOKEN`, `$SPRINT`, `$FEATURE_RAW` 변수 사용):

```python
import json, urllib.request, sys, os
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

token   = os.environ['NOTION_TOKEN']
db_id   = '33defacfc93281cb83bcd067b148ed29'
sprint  = float(os.environ['SPRINT'])
feature = os.environ['FEATURE_RAW']

headers = {
    'Authorization': f'Bearer {token}',
    'Notion-Version': '2022-06-28',
    'Content-Type': 'application/json',
}

payload = json.dumps({'filter': {'and': [
    {'property': 'sprint',           'number':    {'equals': sprint}},
    {'property': 'feature_name_raw', 'title':     {'equals': feature}},
]}}).encode('utf-8')

req = urllib.request.Request(
    f'https://api.notion.com/v1/databases/{db_id}/query',
    data=payload, headers=headers, method='POST'
)
with urllib.request.urlopen(req) as r:
    res = json.loads(r.read())

pages = res.get('results', [])
if pages:
    print('UPDATE:' + pages[0]['id'])
else:
    print('CREATE')
```

출력이 `UPDATE:PAGE_ID` → STEP 4A / `CREATE` → STEP 4B

### 3-3. 프로퍼티 JSON 빌드 헬퍼

아래 형식으로 Notion 프로퍼티 JSON을 구성한다:

```python
def rt(v):   # rich_text
    return {'rich_text': [{'text': {'content': v}}]} if v else {'rich_text': []}

def build_props(rec):
    props = {
        'feature_name_raw': {'title': [{'text': {'content': rec['feature_name_raw']}}]},
    }
    if rec.get('sprint') is not None:
        props['sprint'] = {'number': rec['sprint']}
    if rec.get('feature_type'):
        props['feature_type'] = {'select': {'name': rec['feature_type']}}
    else:
        props['feature_type'] = {'select': None}
    props['impact_direct']   = rt(rec.get('impact_direct'))
    props['impact_indirect'] = rt(rec.get('impact_indirect'))
    props['확인 포인트']      = rt(rec.get('확인 포인트'))
    props['related_bugs']    = rt(rec.get('related_bugs'))
    props['source_excerpt']  = rt(rec.get('source_excerpt'))
    if rec.get('source_link'):
        props['source_link'] = {'url': rec['source_link']}
    else:
        props['source_link'] = {'url': None}
    return props
```

---

## STEP 4A — UPDATE

```python
import json, urllib.request, os, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

token   = os.environ['NOTION_TOKEN']
page_id = os.environ['PAGE_ID']   # STEP 3-2에서 추출한 ID

headers = {
    'Authorization': f'Bearer {token}',
    'Notion-Version': '2022-06-28',
    'Content-Type': 'application/json',
}

payload = json.dumps({'properties': build_props(rec)}).encode('utf-8')
req = urllib.request.Request(
    f'https://api.notion.com/v1/pages/{page_id}',
    data=payload, headers=headers, method='PATCH'
)
with urllib.request.urlopen(req) as r:
    res = json.loads(r.read())
print('updated:', res['id'])
```

---

## STEP 4B — CREATE

```python
import json, urllib.request, os, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

token = os.environ['NOTION_TOKEN']
db_id = '33defacfc93281cb83bcd067b148ed29'

headers = {
    'Authorization': f'Bearer {token}',
    'Notion-Version': '2022-06-28',
    'Content-Type': 'application/json',
}

payload = json.dumps({
    'parent': {'database_id': db_id},
    'properties': build_props(rec),
}).encode('utf-8')
req = urllib.request.Request(
    'https://api.notion.com/v1/pages',
    data=payload, headers=headers, method='POST'
)
with urllib.request.urlopen(req) as r:
    res = json.loads(r.read())
print('created:', res['id'])
```

---

## STEP 5 — 결과 보고

```
## QA 자산 저장 완료

| 기능명 (raw) | 동작 | sprint | 데이터 출처 |
|-------------|------|--------|------------|
| XXX | 신규 생성 | 240 | ticket-diff |
| YYY | 업데이트  | 240 | release-diff |

건너뜀 (upsert 키 불완전):
- ZZZ: sprint 누락

Notion DB: https://www.notion.so/33defacfc93281cb83bcd067b148ed29
```

---

## 에러 핸들링

| 상황 | 처리 |
|------|------|
| TOKEN_FILE 없음 | 안내 출력 후 전체 중단 |
| 슬랙 읽기 실패 | 오류 출력 후 중단 |
| upsert 키 누락 레코드 | 건너뜀, 결과 보고에 명시 |
| Notion API HTTPError | 오류 코드·메시지 출력, 해당 레코드만 건너뜀 |
| feature_type 허용값 외 | null 처리 |
| ticket-diff 검색 결과 없음 | release-diff fallback 사용, 결과 보고에 "(release-diff 기반)" 표기 |
