#!/usr/bin/env bash
# VDT Skill 설치 스크립트
# 사용법: bash setup.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAGELCODE_DIR="$HOME/.bagelcode"
CLAUDE_SKILLS_DIR="$HOME/.claude/skills"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  VDT Skill 설치"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. Python 패키지 설치 ──
echo ""
echo "▶ Step 1. Python 패키지 설치 중..."
pip3 install \
  google-auth \
  google-auth-oauthlib \
  google-auth-httplib2 \
  google-api-python-client \
  python-pptx \
  --quiet
echo "  ✅ Python 패키지 설치 완료"

# ── 2. jq 확인 ──
echo ""
echo "▶ Step 2. jq 확인..."
if ! command -v jq &>/dev/null; then
  echo "  ⚠️  jq가 없습니다. 설치합니다..."
  if command -v brew &>/dev/null; then
    brew install jq
  else
    echo "  ❌ Homebrew가 없어 jq를 자동 설치할 수 없습니다."
    echo "     https://stedolan.github.io/jq/ 에서 수동 설치 후 재실행하세요."
    exit 1
  fi
fi
echo "  ✅ jq $(jq --version)"

# ── 3. ~/.bagelcode/ 디렉토리 구성 ──
echo ""
echo "▶ Step 3. ~/.bagelcode/ 인증 디렉토리 구성..."
mkdir -p "$BAGELCODE_DIR"

if [ ! -f "$BAGELCODE_DIR/jira.json" ]; then
  cp "$SCRIPT_DIR/config/jira.json.template" "$BAGELCODE_DIR/jira.json"
  chmod 600 "$BAGELCODE_DIR/jira.json"
  echo ""
  echo "  📝 Jira 인증 정보를 입력해주세요:"
  echo "     파일 위치: $BAGELCODE_DIR/jira.json"
  echo ""
  echo "     1. Jira API 토큰 발급: https://id.atlassian.com/manage-profile/security/api-tokens"
  echo "     2. 아래 파일을 편집:"
  echo "        {\"domain\": \"bagelcode.atlassian.net\", \"email\": \"your.name@bagelcode.com\", \"token\": \"발급한 토큰\"}"
  echo ""
  read -p "  Jira 설정을 완료했으면 Enter를 눌러주세요..."
else
  echo "  ✅ jira.json 이미 존재 — 스킵"
fi

if [ ! -f "$BAGELCODE_DIR/google_client.json" ]; then
  cp "$SCRIPT_DIR/config/google_client.json.template" "$BAGELCODE_DIR/google_client.json"
  chmod 600 "$BAGELCODE_DIR/google_client.json"
  echo ""
  echo "  📝 Google API 클라이언트 정보를 입력해주세요:"
  echo "     파일 위치: $BAGELCODE_DIR/google_client.json"
  echo ""
  echo "     bumsin.kim@bagelcode.com 에게 google_client.json 파일을 요청하세요."
  echo "     받은 파일을 $BAGELCODE_DIR/google_client.json 에 복사하면 됩니다."
  echo ""
  read -p "  google_client.json 설정을 완료했으면 Enter를 눌러주세요..."
else
  echo "  ✅ google_client.json 이미 존재 — 스킵"
fi

# ── 4. Google OAuth 인증 ──
echo ""
echo "▶ Step 4. Google OAuth 인증..."
if [ ! -f "$BAGELCODE_DIR/google_token.json" ]; then
  echo "  브라우저가 열리면 Google 계정으로 로그인해주세요."
  python3 "$SCRIPT_DIR/skills/vdt/vdt-auth.py"
else
  echo "  ✅ google_token.json 이미 존재 — 스킵"
fi

# ── 5. Claude Code 스킬 등록 ──
echo ""
echo "▶ Step 5. Claude Code 스킬 등록..."
mkdir -p "$CLAUDE_SKILLS_DIR"
ln -sfn "$SCRIPT_DIR/skills/vdt" "$CLAUDE_SKILLS_DIR/vdt"
echo "  ✅ 심볼릭 링크 생성: $CLAUDE_SKILLS_DIR/vdt → $SCRIPT_DIR/skills/vdt"

# ── 완료 ──
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ VDT Skill 설치 완료!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  사용법: Claude Code에서 'vdt CVS-XXXXX' 입력"
echo ""
echo "  문의: bumsin.kim@bagelcode.com"
