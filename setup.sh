#!/bin/bash
# Bagelcode QA Skills — 로컬 설치 스크립트 (Mac / Linux)
# 실행: bash <(curl -fsSL https://raw.githubusercontent.com/bumsinkim-cyber/vdt/main/setup.sh)
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✅ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; }
info() { echo -e "${BLUE}$1${NC}"; }

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

# ── 2. 마켓플레이스 등록 ───────────────────
info "\n── 2. vdt-qa 마켓플레이스 등록"
if claude plugin marketplace list 2>/dev/null | grep -q "bumsinkim-cyber/vdt"; then
  ok "vdt-qa 마켓플레이스 이미 등록됨"
else
  claude plugin marketplace add bumsinkim-cyber/vdt 2>/dev/null && \
    ok "vdt-qa 마켓플레이스 등록 완료" || \
    warn "마켓플레이스 등록 실패 — 수동 등록: claude plugin marketplace add bumsinkim-cyber/vdt"
fi

# ── 3. 플러그인 설치 ───────────────────────
info "\n── 3. vdt-qa 플러그인 설치"
if [ -d "$HOME/.claude/plugins/cache/vdt-qa" ] || \
   claude plugin list 2>/dev/null | grep -q "vdt-qa"; then
  ok "vdt-qa 이미 설치됨"
else
  claude plugin install vdt-qa 2>/dev/null && \
    ok "vdt-qa 플러그인 설치 완료" || {
    warn "플러그인 자동 설치 실패 — 스킬 파일 직접 복사로 전환합니다"
    # Fallback: direct file copy
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    SKILLS_SRC=""
    [ -d "$SCRIPT_DIR/plugins/vdt-qa/skills" ] && SKILLS_SRC="$SCRIPT_DIR/plugins/vdt-qa/skills"
    [ -z "$SKILLS_SRC" ] && [ -d "$SCRIPT_DIR/skills" ] && SKILLS_SRC="$SCRIPT_DIR/skills"
    if [ -n "$SKILLS_SRC" ]; then
      mkdir -p "$HOME/.claude/skills"
      cp -r "$SKILLS_SRC/"* "$HOME/.claude/skills/"
      ok "스킬 직접 복사 완료 → $HOME/.claude/skills/"
    else
      fail "스킬 소스 디렉토리를 찾을 수 없습니다."
      exit 1
    fi
  }
fi

# ── 4. ~/.bagelcode 디렉토리 ───────────────
info "\n── 4. 자격증명 디렉토리 생성"
BAGELCODE_DIR="$HOME/.bagelcode"
mkdir -p "$BAGELCODE_DIR"
ok "$BAGELCODE_DIR 준비됨"

# ── 5. Jira 인증 ───────────────────────────
info "\n── 5. Jira 인증 설정"
JIRA_FILE="$BAGELCODE_DIR/jira.json"

if [ -f "$JIRA_FILE" ]; then
  ok "~/.bagelcode/jira.json 이미 존재 (재설정: 파일 삭제 후 재실행)"
else
  echo ""
  echo "Jira API 토큰 발급 방법:"
  echo "  1. https://id.atlassian.com/manage-profile/security/api-tokens 접속"
  echo "  2. [Create API token] 클릭 → 이름 입력 (예: claude-qa) → 토큰 복사"
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

# ── 6. GitHub CLI ──────────────────────────
info "\n── 6. GitHub CLI (gh) 확인"
if ! command -v gh &>/dev/null; then
  warn "gh CLI가 없습니다. build-check / ticket-qa / release-diff 스킬에 필요합니다."
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

# ── 7. repob (bagel-marketplace 플러그인) ──
info "\n── 7. repob 확인"
REPOB_CACHE="$HOME/.claude/plugins/cache/bagel-marketplace/repob"
if [ -d "$REPOB_CACHE" ]; then
  REPOB_VER=$(ls "$REPOB_CACHE" | sort -V | tail -1)
  ok "repob $REPOB_VER 설치됨"
else
  warn "repob가 없습니다. build-diff / ticket-qa / release-diff / spec-review 스킬에 필요합니다."
  echo ""
  echo "   Claude Code에서 아래 명령을 실행하세요:"
  echo ""
  echo "     /install-plugin repob@bagel-marketplace"
  echo ""
fi

# ── 8. Notion (선택) ───────────────────────
info "\n── 8. Notion 설정 (qa-notionize 스킬 전용 — 선택사항)"
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

# ── 9. gws (선택) ──────────────────────────
info "\n── 9. Google Workspace CLI (spec-review / spec-watch 전용 — 선택사항)"
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
echo "Claude Code에서 바로 사용하세요:"
echo ""
echo "  /ticket-qa    CVS-12345   — Jira 티켓 QA 분석"
echo "  /build-check  239.0.3     — 빌드 경량 체크"
echo "  /build-diff   239~239.0.3 — 빌드 변경점 분석"
echo "  /release-diff 241         — 릴리스 QA 체크리스트"
echo "  /spec-audit               — 기획서 감사"
echo "  /spec-review  CVS-12345   — 기획서 vs 구현 비교"
echo "  /ontology-map             — 교차 영향 분석"
echo "  /qa-notionize             — QA 자산 Notion 저장"
echo "  /vdt          CVS-12345   — VDT 전체 분석"
echo ""
echo "문제가 있으면 README.md의 트러블슈팅 섹션을 확인하세요."
echo "리포: https://github.com/bumsinkim-cyber/vdt"
echo ""
