# vdt-setup — Bagelcode QA 초기 설정 마법사

## 목적
`vdt-qa` 플러그인 설치 후 필요한 자격증명(Jira, Notion)과 CLI 도구(gh, repob)를 대화형으로 설정한다.

## 트리거
- `/vdt-setup` 명령어 입력 시 자동 실행

## 실행 절차

### STEP 0 — 환경 확인
아래 항목을 확인하고 결과를 표 형태로 보여준다.

```bash
echo "=== Claude Code CLI ===" && claude --version 2>/dev/null || echo "NOT FOUND"
echo "=== gh CLI ===" && gh auth status 2>&1 | head -3
echo "=== repob ===" && ls "$HOME/.claude/plugins/cache/bagel-marketplace/repob" 2>/dev/null || echo "NOT INSTALLED"
echo "=== jira.json ===" && [ -f "$HOME/.bagelcode/jira.json" ] && echo "EXISTS" || echo "MISSING"
echo "=== notion.json ===" && [ -f "$HOME/.bagelcode/notion.json" ] && echo "EXISTS" || echo "MISSING"
```

결과를 아래 형태로 출력:
| 항목 | 상태 |
|------|------|
| Claude Code CLI | ✅ / ❌ |
| GitHub CLI (gh) | ✅ 인증됨 / ⚠️ 미인증 / ❌ 미설치 |
| repob | ✅ {버전} / ❌ 미설치 |
| Jira 인증 | ✅ 존재 / ❌ 없음 |
| Notion 인증 | ✅ 존재 / - 생략 |

---

### STEP 1 — ~/.bagelcode 디렉토리 생성
```bash
mkdir -p "$HOME/.bagelcode"
```

---

### STEP 2 — Jira 인증 설정
`~/.bagelcode/jira.json`이 없으면 사용자에게 다음을 안내하고 입력받아 생성한다.

**안내 메시지:**
```
Jira API 토큰 발급 방법:
1. https://id.atlassian.com/manage-profile/security/api-tokens 접속
2. [Create API token] 클릭 → 이름 입력 (예: claude-qa) → 토큰 복사

아래 3가지를 알려주세요:
- Jira 이메일 주소 (예: your.email@bagelcode.com)
- Jira API 토큰
- Jira 도메인 (예: bagelcode.atlassian.net)
```

입력받은 값으로 아래 파일을 생성한다:
```bash
cat > "$HOME/.bagelcode/jira.json" <<EOF
{
  "email": "JIRA_EMAIL",
  "token": "JIRA_TOKEN",
  "domain": "JIRA_DOMAIN"
}
EOF
chmod 600 "$HOME/.bagelcode/jira.json"
```

파일 생성 후 "✅ Jira 인증 설정 완료" 출력.

---

### STEP 3 — GitHub CLI 인증 확인
`gh auth status`가 실패하면 아래 안내:
```
GitHub CLI 인증이 필요합니다.
터미널에서 실행: gh auth login
또는 아래 단계:
1. 터미널을 열고 'gh auth login' 입력
2. GitHub.com 선택 → HTTPS → 브라우저 인증
```

---

### STEP 4 — repob 설치 확인
`~/.claude/plugins/cache/bagel-marketplace/repob`이 없으면:
```
repob가 설치되지 않았습니다.
Claude Code에서 아래 명령어를 실행하세요:
/install-plugin repob@bagel-marketplace
```

---

### STEP 5 — Notion 설정 (선택)
`~/.bagelcode/notion.json`이 없을 때 물어본다:
```
qa-notionize 스킬 (QA 결과 Notion 저장)을 사용할 예정인가요?
사용 예정이면 Notion 통합 토큰을 알려주세요.
토큰 발급: https://www.notion.so/my-integrations
```

입력받으면:
```bash
cat > "$HOME/.bagelcode/notion.json" <<EOF
{
  "token": "NOTION_TOKEN"
}
EOF
chmod 600 "$HOME/.bagelcode/notion.json"
```

건너뛰면 넘어간다.

---

### STEP 6 — 완료 보고
```
========================================
✅ vdt-qa 설정 완료!
========================================

이제 아래 스킬을 사용할 수 있습니다:

  /ticket-qa    CVS-12345   — Jira 티켓 QA 분석
  /build-check  239.0.3     — 빌드 경량 체크
  /build-diff   239~239.0.3 — 빌드 변경점 분석
  /release-diff 241         — 릴리스 QA 체크리스트
  /spec-audit               — 기획서 감사
  /spec-review  CVS-12345   — 기획서 vs 구현 비교
  /ontology-map             — 교차 영향 분석
  /qa-notionize             — QA 자산 Notion 저장
  /vdt          CVS-12345   — VDT 전체 분석

문제가 있으면 README를 확인하세요:
https://github.com/bumsinkim-cyber/vdt
```

## 주의사항
- 이 스킬은 설치 후 **최초 1회만** 실행하면 된다.
- 재설정이 필요하면 `~/.bagelcode/jira.json`을 삭제 후 `/vdt-setup` 재실행.
- 토큰은 파일 시스템에만 저장되며, Claude 메모리나 외부로 전송되지 않는다.
