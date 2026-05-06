#!/bin/bash
# Bagelcode QA Skills — 로컬 설치 스크립트 (Mac / Linux)
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✅ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; }
info() { echo -e "${BLUE}$1${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "========================================"
echo "   Bagelcode QA Skills 설치 스크립트"
echo "========================================"
echo ""

# ── 1. Claude Code CLI ─────────────────────
info "── 1. Claude Code CLI 확인"
if ! command -v claude &>/dev/null; then
  fail "Claude Code CLI가 없습니다."
  echo "   설치: npm install -g @anthropic-ai/claude-code"
  echo "   설치 후 이 스크립트를 다시 실행하세요."
  exit 1
fi
ok "Claude Code CLI: $(claude --version 2>/dev/null | head -1)"

# ── 2. 스킬 파일 설치 ──────────────────────
info "\n── 2. QA 스킬 설치"
SKILLS_DIR="$HOME/.claude/skills"
mkdir -p "$SKILLS_DIR"

if [ -d "$SCRIPT_DIR/skills" ] && [ "$(ls -A "$SCRIPT_DIR/skills")" ]; then
  cp -r "$SCRIPT_DIR/skills/"* "$SKILLS_DIR/"
  ok "스킬 설치 완료: $(ls "$SCRIPT_DIR/skills" | wc -l | tr -d ' ')개 → $SKILLS_DIR"
else
  fail "./skills 디렉토리가 비어 있거나 없습니다. git clone을 다시 확인하세요."
  exit 1
fi

# ── 3. ~/.bagelcode 디렉토리 ───────────────
info "\n── 3. 자격증명 디렉토리 생성"
BAGELCODE_DIR="$HOME/.bagelcode"
mkdir -p "$BAGELCODE_DIR"
ok "$BAGELCODE_DIR 준비됨"

# ── 4. Jira 인증 ───────────────────────────
info "\n── 4. Jira 인증 설정"
JIRA_FILE="$BAGELCODE_DIR/jira.json"

if [ -f "$JIRA_FILE" ]; then
  ok "~/.bagelcode/jira.json 이미 존재 (덮어쓰려면 파일을 삭제 후 재실행)"
else
  echo ""
  echo "Jira API 토큰 발급 방법:"
  echo "  1. https://id.atlassian.com/manage-profile/security/api-tokens 접속"
  echo "  2. [Create API token] 클릭 → 이름 입력 → 토큰 복사"
  echo ""
  read -p "  Jira 이메일: " JIRA_EMAIL
  read -sp "  Jira API 토큰: " JIRA_TOKEN
  echo ""
  read -p "  Jira 도메인 (예: bagelcode.atlassian.net): " JIRA_DOMAIN

  cat > "$JIRA_FILE" <<EOF
{
  "email": "$JIRA_EMAIL",
  "token": "$JIRA_TOKEN",
  "domain": "$JIRA_DOMAIN"
}
EOF
  chmod 600 "$JIRA_FILE"
  ok "~/.bagelcode/jira.json 생성 완료"
fi

# ── 5. GitHub CLI ──────────────────────────
info "\n── 5. GitHub CLI (gh) 확인"
if ! command -v gh &>/dev/null; then
  warn "gh CLI가 없습니다. build-check / build-diff / ticket-qa / release-diff 스킬에 필요합니다."
  echo "   설치 (Mac): brew install gh"
  echo "   설치 후: gh auth login"
else
  if gh auth status &>/dev/null 2>&1; then
    ok "GitHub CLI 인증됨"
  else
    warn "gh CLI는 있으나 인증이 필요합니다."
    read -p "  지금 'gh auth login'을 실행할까요? (y/N): " RUN_GH
    if [[ "$RUN_GH" =~ ^[Yy]$ ]]; then
      gh auth login
    else
      echo "   나중에 터미널에서 'gh auth login'을 실행하세요."
    fi
  fi
fi

# ── 6. repob (bagel-marketplace 플러그인) ──
info "\n── 6. repob 확인"
REPOB_CACHE="$HOME/.claude/plugins/cache/bagel-marketplace/repob"
if [ -d "$REPOB_CACHE" ]; then
  REPOB_VER=$(ls "$REPOB_CACHE" | sort -V | tail -1)
  ok "repob $REPOB_VER 설치됨"
else
  warn "repob가 없습니다. build-diff / ticket-qa / release-diff / spec-review 스킬에 필요합니다."
  echo ""
  echo "   Claude Code를 열고 아래 명령을 실행하세요:"
  echo ""
  echo "     /install-plugin repob@bagel-marketplace"
  echo ""
fi

# ── 7. Notion (선택) ───────────────────────
info "\n── 7. Notion 설정 (qa-notionize 스킬 전용 — 선택사항)"
NOTION_FILE="$BAGELCODE_DIR/notion.json"
if [ -f "$NOTION_FILE" ]; then
  ok "~/.bagelcode/notion.json 이미 존재"
else
  read -p "  qa-notionize 스킬을 사용할 예정인가요? (y/N): " SETUP_NOTION
  if [[ "$SETUP_NOTION" =~ ^[Yy]$ ]]; then
    echo "  Notion 토큰 발급: https://www.notion.so/my-integrations"
    read -sp "  Notion 통합 토큰: " NOTION_TOKEN
    echo ""
    printf '{\n  "token": "%s"\n}\n' "$NOTION_TOKEN" > "$NOTION_FILE"
    chmod 600 "$NOTION_FILE"
    ok "~/.bagelcode/notion.json 생성 완료"
  fi
fi

# ── 8. gws (선택) ──────────────────────────
info "\n── 8. Google Workspace CLI (spec-review / spec-watch 전용 — 선택사항)"
if command -v gws &>/dev/null; then
  ok "gws CLI 설치됨"
else
  read -p "  spec-review 또는 spec-watch 스킬을 사용할 예정인가요? (y/N): " SETUP_GWS
  if [[ "$SETUP_GWS" =~ ^[Yy]$ ]]; then
    warn "gws CLI가 없습니다."
    echo "   설치: npm install -g @googleworkspace/cli"
    echo "   설치 후: gws auth login"
  fi
fi

# ── 완료 ───────────────────────────────────
echo ""
echo "========================================"
ok "설치 완료!"
echo "========================================"
echo ""
echo "사용 가능한 스킬 (Claude Code에서 실행):"
echo "  /build-check  239.0.3          — 빌드 경량 체크"
echo "  /build-diff   239.0.0~239.0.3  — 빌드 변경점 QA 분석"
echo "  /ticket-qa    CVS-12345        — 티켓 단일 QA 분석"
echo "  /release-diff 241              — 릴리스 QA 체크리스트"
echo "  /spec-audit                    — 기획서 감사"
echo "  /spec-review  CVS-12345        — 기획서 vs 구현 비교"
echo "  /ontology-map                  — 교차 영향 분석"
echo "  /qa-notionize                  — QA 자산 Notion 저장"
echo ""
echo "문제가 있으면 README.md의 트러블슈팅 섹션을 확인하세요."
echo ""
