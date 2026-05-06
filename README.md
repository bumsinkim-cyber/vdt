# Bagelcode QA Skills

Bagelcode QA팀의 Claude Code 스킬 모음입니다.
Jira 티켓 분석, 빌드 체크, 릴리스 QA, 기획서 감사 등을 자동화합니다.

---

## 빠른 설치 (권장)

### 방법 A — 터미널 원커맨드 (Mac / Linux)

터미널에 아래 명령어 하나만 실행하세요:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bumsinkim-cyber/vdt/main/setup.sh)
```

설치 완료 후 Claude Code에서 바로 스킬 사용 가능합니다.

---

### 방법 B — Claude Code 프롬프트에서 설치

**1단계:** 터미널에서 마켓플레이스 등록 (최초 1회)

```bash
claude plugin marketplace add bumsinkim-cyber/vdt
```

**2단계:** Claude Code 프롬프트에서 설치

```
/install-plugin vdt-qa
```

**3단계:** Claude Code 프롬프트에서 초기 설정 (자격증명 마법사)

```
/vdt-setup
```

---

## 사전 요구사항

| 도구 | 용도 | 필수 여부 |
|------|------|---------|
| [Claude Code CLI](https://claude.ai/code) | 스킬 실행 주체 | **필수** |
| Jira API 토큰 | Jira 데이터 조회 | **필수** |
| [GitHub CLI (gh)](https://cli.github.com) | PR 조회 | 필수 (대부분 스킬) |
| repob (`/install-plugin repob@bagel-marketplace`) | 사내 코드 탐색 | 필수 (코드 분석 스킬) |
| Notion 통합 토큰 | QA 자산 저장 | qa-notionize만 |
| [gws CLI](https://www.npmjs.com/package/@googleworkspace/cli) | Google Drive 기획서 읽기 | spec-review/spec-watch만 |

---

## 스킬 목록

| 스킬 | 사용법 | 설명 | 필요 도구 |
|------|--------|------|---------|
| `/vdt-setup` | `/vdt-setup` | 초기 설정 마법사 (최초 1회) | — |
| `/ticket-qa` | `/ticket-qa CVS-12345` | 티켓 단일 QA 딥다이브 | jira, gh, repob |
| `/build-check` | `/build-check 239.0.3` | 빌드 경량 체크 (신규/리버트) | jira, gh |
| `/build-diff` | `/build-diff 239.0.0~239.0.3` | 빌드 변경점 QA 분석 | jira, gh, repob |
| `/release-diff` | `/release-diff 241` | 릴리스 QA 체크리스트 | jira, gh, repob |
| `/spec-audit` | `/spec-audit CVS-12345` | 기획서 감사 (개발 전) | jira, gws |
| `/spec-review` | `/spec-review CVS-12345` | 기획서 vs 구현 비교 | jira, gws, repob |
| `/spec-watch` | `/spec-watch` | Google Drive 기획서 변경 감지 | gws |
| `/ontology-map` | `/ontology-map` | 교차 영향 분석 | 없음 (이전 결과 필요) |
| `/qa-notionize` | `/qa-notionize` | QA 자산 Notion 저장 | notion |
| `/vdt` | `/vdt CVS-12345` | VDT 전체 팀 시뮬레이션 분석 | jira, gh, repob |

---

## 수동 설치 (스크립트 없이)

### 1. 스킬 파일 복사

```bash
git clone https://github.com/bumsinkim-cyber/vdt.git
cp -r vdt/plugins/vdt-qa/skills/* ~/.claude/skills/
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

**Jira API 토큰 발급:** → [상세 가이드](docs/jira-token-guide.md)

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

### 6. gws CLI (spec-review / spec-watch 사용 시)

```bash
npm install -g @googleworkspace/cli
gws auth login
```

---

## 사용 예시

```
/ticket-qa CVS-13421
→ PR 조회 → 코드 분석 → 테스트 체크리스트 생성

/build-check 239.0.3
→ 이전 빌드 대비 신규 티켓 및 리버트 목록 출력

/release-diff 241
→ 릴리스 241의 전체 QA 영향 분석 + 체크리스트
```

---

## 업데이트

```bash
# 방법 A (마켓플레이스): Claude Code에서
/update-plugin vdt-qa

# 방법 B (setup.sh): 터미널에서
bash <(curl -fsSL https://raw.githubusercontent.com/bumsinkim-cyber/vdt/main/setup.sh)
```

---

## 트러블슈팅

### `~/.bagelcode/jira.json 파일이 없습니다`

Claude Code에서 `/vdt-setup` 실행 — 자격증명 마법사가 안내합니다.

### `command not found: repob`

Claude Code에서 `/install-plugin repob@bagel-marketplace`를 실행하세요.

### `gh: command not found`

`brew install gh` 후 `gh auth login`을 실행하세요.

### `gws CLI 미발견`

spec-review / spec-watch 전용 도구입니다. 해당 스킬을 사용하지 않으면 무시 가능합니다.
사용한다면: `npm install -g @googleworkspace/cli` 후 `gws auth login`

### Jira 401 Unauthorized

- `~/.bagelcode/jira.json`의 email / token 값을 확인하세요.
- 토큰 만료 시 재발급 후 `/vdt-setup` 재실행.

### Windows에서 실행

Windows는 Git Bash 환경이 필요합니다. `setup.ps1`을 사용하거나 Git Bash에서 `bash setup.sh`를 실행하세요.

---

## 문의

QA팀 Slack 채널: `#qa-ai-report`
리포: https://github.com/bumsinkim-cyber/vdt
