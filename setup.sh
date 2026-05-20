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

# ── 6. Google Drive 인증 ──────────────────
info "\n── 6. Google Drive 인증 (기획서 읽기용 — /vdt 스킬 필요)"
GOOGLE_CLIENT="$BAGELCODE_DIR/google_client.json"
GOOGLE_TOKEN="$BAGELCODE_DIR/google_token.json"

if [ -f "$GOOGLE_TOKEN" ]; then
  ok "~/.bagelcode/google_token.json 이미 존재"
elif [ ! -f "$GOOGLE_CLIENT" ]; then
  warn "~/.bagelcode/google_client.json 파일이 없습니다."
  echo ""
  echo "   /vdt가 Google Drive 기획서를 읽으려면 이 파일이 필요합니다."
  echo "   bumsin.kim@bagelcode.com 에게 google_client.json 파일을 받아"
  echo "   아래 경로에 저장한 뒤 이 스크립트를 다시 실행하세요:"
  echo ""
  echo "   $GOOGLE_CLIENT"
  echo ""
  warn "Google 인증 건너뜀 — 나중에 파일 받은 뒤 스크립트 재실행하면 자동 완료됩니다."
else
  PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)
  if [ -z "$PYTHON" ]; then
    warn "Python3가 없습니다. 'brew install python3' 후 재실행하세요."
  else
    info "  Python 의존성 설치 중 (google-auth)..."
    $PYTHON -m pip install -q --upgrade \
      google-auth-oauthlib google-auth google-api-python-client 2>/dev/null && \
      ok "의존성 설치 완료" || \
      warn "pip 설치 실패 — 수동으로: pip3 install google-auth-oauthlib google-api-python-client"

    VDT_AUTH_TMP=$(mktemp /tmp/vdt-auth-XXXX.py)
    curl -fsSL \
      "https://raw.githubusercontent.com/bumsinkim-cyber/vdt/main/plugins/vdt-qa/skills/vdt/vdt-auth.py" \
      -o "$VDT_AUTH_TMP" 2>/dev/null
    if [ -f "$VDT_AUTH_TMP" ] && [ -s "$VDT_AUTH_TMP" ]; then
      echo ""
      echo "   브라우저가 열립니다. Bagelcode Google 계정으로 로그인 후 권한을 허용하세요."
      echo ""
      $PYTHON "$VDT_AUTH_TMP" && ok "Google 인증 완료 — ~/.bagelcode/google_token.json 저장됨" || \
        warn "Google 인증 실패 — 나중에 수동으로 재시도하세요."
      rm -f "$VDT_AUTH_TMP"
    else
      warn "vdt-auth.py 다운로드 실패 — 네트워크 상태를 확인하세요."
      rm -f "$VDT_AUTH_TMP"
    fi
  fi
fi

# ── 7. GitHub CLI ──────────────────────────
info "\n── 7. GitHub CLI (gh) 확인"
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

# ── 완료 ───────────────────────────────────
echo ""
echo "========================================"
ok "설치 완료! Claude Code를 열고 바로 시작하세요."
echo "========================================"
echo ""
echo "▶ 기획팀 — 가상 개발팀 분析:"
echo ""
echo "  /vdt CVS-12345   — 기획서 리스크 분析 + 팀 시뮬레이션 보고서 생성"
echo ""
echo "▶ QA팀 — 전체 스킬:"
echo ""
echo "  /ticket-qa    CVS-12345   — Jira 티켓 QA 분析"
echo "  /build-check  239.0.3     — 빌드 경량 체크"
echo "  /build-diff   239~239.0.3 — 빌드 변경점 분析"
echo "  /release-diff 241         — 릴리스 QA 체크리스트"
echo "  /spec-audit               — 기획서 감사"
echo "  /spec-review  CVS-12345   — 기획서 vs 구현 비교"
echo ""
echo "문의: bumsin.kim@bagelcode.com | #cvs-qp"
echo "리포: https://github.com/bumsinkim-cyber/vdt"
echo ""
