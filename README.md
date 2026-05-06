# Bagelcode QA Skills

Bagelcode QA팀의 Claude Code 스킬 모음입니다.
Jira 티켓 분석, 빌드 체크, 릴리스 QA, 기획서 감사 등을 자동화합니다.

---

## 사전 요구사항

| 도구 | 용도 | 필수 여부 |
|------|------|---------|
| [Claude Code CLI](https://claude.ai/code) | 스킬 실행 주체 | **필수** |
| [GitHub CLI (gh)](https://cli.github.com) | PR 조회 | 필수 (대부분 스킬) |
| repob (bagel-marketplace) | 사내 코드 탐색 | 필수 (코드 분석 스킬) |
| Jira API 토큰 | Jira 데이터 조회 | **필수** |
| Notion 통합 토큰 | QA 자산 저장 | qa-notionize만 |
| [gws CLI](https://www.npmjs.com/package/@googleworkspace/cli) | Google Drive 기획서 읽기 | spec-review/spec-watch만 |

---

## 설치 방법

### Mac / Linux

```bash
git clone https://github.com/bagelcode/qa-skills.git
cd qa-skills
chmod +x setup.sh
./setup.sh
```

### Windows (Git Bash)

```bash
git clone https://github.com/bagelcode/qa-skills.git
cd qa-skills
bash setup.sh
```

또는 PowerShell:

```powershell
.\setup.ps1
```

> ⚠️ Windows에서는 Git Bash 환경이 필요합니다. PowerShell 단독으로는 스킬의 bash 명령이 동작하지 않습니다.

---

## 수동 설치 (스크립트 없이)

### 1. 스킬 파일 복사

```bash
cp -r ./skills/* ~/.claude/skills/
```

### 2. Jira 인증 파일 생성

```bash
mkdir -p ~/.bagelcode
cat > ~/.bagelcode/jira.json << 'EOF'
{
  "email": "your.email@bagelcode.com",
  "token": "YOUR_JIRA_API_TOKEN",
  "domain": "bagelcode.atlassian.net"
}
EOF
chmod 600 ~/.bagelcode/jira.json
```

**Jira API 토큰 발급:**
1. https://id.atlassian.com/manage-profile/security/api-tokens 접속
2. **Create API token** 클릭
3. 이름 입력 후 토큰 복사

### 3. GitHub CLI 인증

```bash
# 설치 (Mac)
brew install gh

# 인증
gh auth login
```

### 4. repob 설치

Claude Code를 열고:
```
/install-plugin repob@bagel-marketplace
```

### 5. Notion 토큰 (qa-notionize 사용 시)

```bash
cat > ~/.bagelcode/notion.json << 'EOF'
{
  "token": "YOUR_NOTION_INTEGRATION_TOKEN"
}
EOF
chmod 600 ~/.bagelcode/notion.json
```

**Notion 통합 토큰 발급:**
1. https://www.notion.so/my-integrations 접속
2. **New integration** 생성
3. 토큰 복사

### 6. gws CLI (spec-review / spec-watch 사용 시)

```bash
npm install -g @googleworkspace/cli
gws auth login
```

---

## 스킬 목록

| 스킬 | 사용법 | 설명 | 필요 도구 |
|------|--------|------|---------|
| `/build-check` | `/build-check 239.0.3` | 빌드 경량 체크 (신규/리버트) | jira, gh |
| `/build-diff` | `/build-diff 239.0.0~239.0.3` | 빌드 변경점 QA 분석 | jira, gh, repob |
| `/ticket-qa` | `/ticket-qa CVS-12345` | 티켓 단일 QA 딥다이브 | jira, gh, repob |
| `/release-diff` | `/release-diff 241` | 릴리스 QA 체크리스트 | jira, gh, repob |
| `/spec-audit` | `/spec-audit CVS-12345` | 기획서 감사 (개발 전) | jira, gws |
| `/spec-review` | `/spec-review CVS-12345` | 기획서 vs 구현 비교 | jira, gws, repob |
| `/spec-watch` | `/spec-watch` | Google Drive 기획서 변경 감지 | gws |
| `/ontology-map` | `/ontology-map` | 교차 영향 분석 | 없음 (이전 결과 필요) |
| `/qa-notionize` | `/qa-notionize` | QA 자산 Notion 저장 | notion |

---

## 사용 예시

```
# Claude Code 실행 후:

/ticket-qa CVS-13421
→ PR 조회 → 코드 분석 → 테스트 체크리스트 생성

/build-check 239.0.3
→ 이전 빌드 대비 신규 티켓 및 리버트 목록 출력

/release-diff 241
→ 릴리스 241의 전체 QA 영향 분석 + 체크리스트
```

---

## 트러블슈팅

### `~/.bagelcode/jira.json 파일이 없습니다`

Jira 인증 파일이 없습니다. [수동 설치 2번](#2-jira-인증-파일-생성)을 참고하세요.

### `command not found: repob`

repob가 설치되지 않았습니다. Claude Code에서 `/install-plugin repob@bagel-marketplace`를 실행하세요.

### `gh: command not found`

GitHub CLI가 없습니다. `brew install gh` 후 `gh auth login`을 실행하세요.

### `gws CLI 미발견`

spec-review / spec-watch 전용 도구입니다. 해당 스킬을 사용하지 않는다면 무시해도 됩니다.
사용한다면: `npm install -g @googleworkspace/cli` 후 `gws auth login`

### Jira 401 Unauthorized

- `~/.bagelcode/jira.json`의 email / token 값을 확인하세요.
- 토큰이 만료됐다면 재발급 후 파일을 업데이트하세요.

### Windows에서 Python 인코딩 에러

스킬 실행 시 `UnicodeEncodeError`가 나오면 Git Bash 환경인지 확인하세요.
PowerShell 단독 실행은 지원하지 않습니다.

---

## 업데이트

스킬 파일이 업데이트됐을 때:

```bash
git pull
./setup.sh
```

setup.sh는 기존 credential 파일을 덮어쓰지 않으므로 안전하게 재실행 가능합니다.

---

## 문의

QA팀 Slack 채널: `#qa-ai-report`
