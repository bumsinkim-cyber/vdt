# VDT — 가상 개발팀 기획서 품질 분석

Jira 티켓 번호 하나만 입력하면 5개 AI 에이전트(기획/개발/아트/TA/QA)가 기획서를 분석해 HTML 보고서를 생성하고 Slack으로 전송합니다.

**사용 방법은 두 가지입니다:**

| | Slack 봇 | Claude Code 스킬 |
|---|---|---|
| **팀원 설치** | ❌ 불필요 | 6단계 설치 필요 |
| **사용법** | Slack에서 `/vdt CVS-XXXXX` | Claude Code에서 `vdt CVS-XXXXX` |
| **배포 주체** | 운영자 1회 서버 배포 | 팀원 개인 설치 |
| **권장 대상** | **팀 전체 사용 (권장)** | 개인 커스텀 필요 시 |

## 무엇을 해주나요?

`vdt CVS-13195` 한 줄 입력 시:

1. **Jira** 에서 티켓 정보 + 첨부 문서 자동 수집
2. **Confluence / Google Drive** 에서 기획서 텍스트 추출
3. **5개 에이전트** 병렬 분석
   - 🗂 Planner — AC 항목 추출
   - 💻 Developer — 구현 리스크 분석
   - 🎨 Artist — 에셋/UI 분석
   - ⚙️ TA — 기술 스펙 및 파이프라인 영향
   - 🔍 QA Pre-analyst — 기획서 착수 가능성 판정 + 테스트 예측
4. **팀 회의 시뮬레이션** — 5개 에이전트 합의 도출
5. **HTML 보고서** → GitHub Pages 배포
6. **Slack** `#qa-ai-report` 채널에 결과 전송

---

## 방법 1: Slack 봇 배포 (팀 전체, 설치 0단계)

### 운영자 1회 설정

**Step 1. Slack App 생성**

1. https://api.slack.com/apps → **Create New App** → From scratch
2. 앱 이름: `VDT Bot`, 워크스페이스: Bagelcode
3. **OAuth & Permissions** → Bot Token Scopes: `chat:write`, `commands` 추가 → **Install to Workspace**
4. `Bot User OAuth Token` (xoxb-...) 복사
5. **Basic Information** → `Signing Secret` 복사
6. **Slash Commands** → `/vdt` 추가, Request URL: `https://your-server.com/slack/events`

**Step 2. Google 토큰 준비**

```bash
# 로컬에서 OAuth 인증 후 base64로 인코딩
python3 skills/vdt/vdt-auth.py
base64 -i ~/.bagelcode/google_token.json | tr -d '\n'
# 출력된 긴 문자열을 GOOGLE_TOKEN_JSON 환경변수로 사용
```

**Step 3. 서버 배포**

```bash
git clone https://github.com/bumsinkim-cyber/vdt.git
cd vdt

# 환경변수 설정
cp .env.example .env
# .env 파일을 열어 각 값 입력

# 도커로 실행 (1줄)
docker compose up -d
```

**Step 4. Slack App Request URL 연결**

서버 주소를 Slash Command Request URL에 입력: `https://your-server.com/slack/events`

### 팀원 사용법 (설치 없음)

```
/vdt CVS-13195
```

Slack 채널에서 입력하면 끝. 약 3~5분 후 `#qa-ai-report`에 결과가 옵니다.

---

## 방법 2: Claude Code 스킬 (개인 설치)

### 사전 요구사항

- macOS (Apple Silicon / Intel 무관)
- Python 3.10 이상
- Claude Code CLI 설치됨
- Slack MCP, Atlassian MCP 연결됨 (Claude Code 설정에서 확인)

### 설치 방법

```bash
# 1. 레포 클론
git clone https://github.com/bumsinkim-cyber/vdt.git ~/bagelcode/vdt
cd ~/bagelcode/vdt

# 2. 설치 스크립트 실행
bash setup.sh
```

`setup.sh`가 자동으로 처리합니다:
- Python 패키지 설치 (`google-api-python-client`, `python-pptx` 등)
- `~/.bagelcode/jira.json` 생성 및 입력 안내
- `~/.bagelcode/google_client.json` 설정 안내
- Google OAuth 인증 (`~/.bagelcode/google_token.json` 생성)
- Claude Code 스킬 심볼릭 링크 등록 (`~/.claude/skills/vdt`)

### 인증 정보 설정

#### Jira API 토큰
1. https://id.atlassian.com/manage-profile/security/api-tokens 접속
2. **Create API token** 클릭
3. `~/.bagelcode/jira.json` 에 입력:
```json
{
  "domain": "bagelcode.atlassian.net",
  "email": "your.name@bagelcode.com",
  "token": "발급한 토큰"
}
```

#### Google API 클라이언트
`google_client.json` 파일은 bumsin.kim@bagelcode.com 에게 요청하세요.  
받은 파일을 `~/.bagelcode/google_client.json` 에 저장하면 됩니다.

### GitHub Pages 보고서 저장소 설정

보고서를 본인 GitHub Pages에 배포하려면 `SKILL.md` 상단의 변수를 수정하세요:

```bash
# skills/vdt/SKILL.md 내 아래 항목 수정
VDT_REPO_DIR="/tmp/vdt-reports-git"                          # 로컬 git 경로 (변경 불필요)
PAGES_URL="https://{your-github-id}.github.io/vdt-reports"  # 본인 GitHub Pages URL
```

그 다음 `{your-github-id}/vdt-reports` 이름으로 GitHub 레포를 생성하고  
`index.html` 을 포함한 초기 커밋을 올려두면 됩니다.

## 사용법

Claude Code를 열고:

```
vdt CVS-13195
```

또는

```
vdt 실행해줘 CVS-13045
```

## 디렉토리 구조

```
vdt/
├── server/
│   ├── main.py        # Slack 봇 서버 (Flask + slack-bolt)
│   ├── viewer.html    # HTML 보고서 템플릿 (web/viewer.html과 동기화)
│   ├── requirements.txt
│   └── Dockerfile
├── skills/
│   └── vdt/
│       ├── SKILL.md       # 스킬 메인 실행 지시 (Claude Code가 읽음)
│       └── vdt-auth.py    # Google OAuth 초기 인증 스크립트
├── agents/
│   ├── planner.md         # 기획 에이전트 프롬프트
│   ├── developer.md       # 개발 에이전트 프롬프트
│   ├── artist.md          # 아트 에이전트 프롬프트
│   ├── ta.md              # TA 에이전트 프롬프트
│   └── qa-preanalyst.md   # QA 에이전트 프롬프트
├── web/
│   └── viewer.html        # HTML 보고서 템플릿
├── config/
│   ├── jira.json.template
│   └── google_client.json.template
├── docker-compose.yml     # Slack 봇 배포용
├── .env.example           # 환경변수 템플릿
├── setup.sh               # Claude Code 스킬 설치 스크립트
└── README.md
```

## 문의

bumsin.kim@bagelcode.com
