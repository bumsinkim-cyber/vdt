# Bagelcode QA Skills — 로컬 설치 스크립트 (Windows, Git Bash 환경)
# 실행: Git Bash에서 `bash setup.sh` 또는 PowerShell에서 `.\setup.ps1`
#
# ⚠️  이 스크립트는 Git Bash(MSYS2/Cygwin) 환경을 전제합니다.
#     PowerShell 단독으로는 스킬의 bash 명령이 동작하지 않습니다.
#     Git for Windows 설치 후 Git Bash에서 실행하세요.

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   Bagelcode QA Skills 설치 스크립트" -ForegroundColor Cyan
Write-Host "   (Windows — Git Bash 환경)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Home = $env:USERPROFILE

# ── 1. Git Bash 확인 ───────────────────────
Write-Host "── 1. Git Bash 확인" -ForegroundColor Blue
$gitBash = "C:\Program Files\Git\bin\bash.exe"
if (-not (Test-Path $gitBash)) {
    Write-Host "❌ Git for Windows가 없습니다." -ForegroundColor Red
    Write-Host "   설치: https://git-scm.com/download/win"
    Write-Host "   설치 후 Git Bash에서 이 스크립트를 다시 실행하세요."
    exit 1
}
Write-Host "✅ Git Bash 확인됨: $gitBash" -ForegroundColor Green

# ── 2. Claude Code CLI 확인 ────────────────
Write-Host "`n── 2. Claude Code CLI 확인" -ForegroundColor Blue
try {
    $claudeVersion = & claude --version 2>$null
    Write-Host "✅ Claude Code CLI: $claudeVersion" -ForegroundColor Green
} catch {
    Write-Host "❌ Claude Code CLI가 없습니다." -ForegroundColor Red
    Write-Host "   설치: npm install -g @anthropic-ai/claude-code"
    exit 1
}

# ── 3. 스킬 파일 설치 ──────────────────────
Write-Host "`n── 3. QA 스킬 설치" -ForegroundColor Blue
$skillsSrc = Join-Path $ScriptDir "skills"
$skillsDst = Join-Path $Home ".claude\skills"

if (-not (Test-Path $skillsDst)) { New-Item -ItemType Directory -Path $skillsDst -Force | Out-Null }

if (Test-Path $skillsSrc) {
    Copy-Item -Path "$skillsSrc\*" -Destination $skillsDst -Recurse -Force
    $count = (Get-ChildItem $skillsSrc -Directory).Count
    Write-Host "✅ 스킬 설치 완료: ${count}개 → $skillsDst" -ForegroundColor Green
} else {
    Write-Host "❌ .\skills 디렉토리가 없습니다. git clone을 확인하세요." -ForegroundColor Red
    exit 1
}

# ── 4. ~/.bagelcode 디렉토리 ───────────────
Write-Host "`n── 4. 자격증명 디렉토리 생성" -ForegroundColor Blue
$bagelcodeDir = Join-Path $Home ".bagelcode"
if (-not (Test-Path $bagelcodeDir)) { New-Item -ItemType Directory -Path $bagelcodeDir -Force | Out-Null }
Write-Host "✅ $bagelcodeDir 준비됨" -ForegroundColor Green

# ── 5. Jira 인증 ───────────────────────────
Write-Host "`n── 5. Jira 인증 설정" -ForegroundColor Blue
$jiraFile = Join-Path $bagelcodeDir "jira.json"

if (Test-Path $jiraFile) {
    Write-Host "✅ jira.json 이미 존재 (덮어쓰려면 파일 삭제 후 재실행)" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "Jira API 토큰 발급:"
    Write-Host "  1. https://id.atlassian.com/manage-profile/security/api-tokens 접속"
    Write-Host "  2. [Create API token] → 이름 입력 → 복사"
    Write-Host ""
    $jiraEmail  = Read-Host "  Jira 이메일"
    $jiraToken  = Read-Host "  Jira API 토큰" -AsSecureString
    $jiraTokenPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($jiraToken))
    $jiraDomain = Read-Host "  Jira 도메인 (예: bagelcode.atlassian.net)"

    $jiraJson = @{
        email  = $jiraEmail
        token  = $jiraTokenPlain
        domain = $jiraDomain
    } | ConvertTo-Json

    Set-Content -Path $jiraFile -Value $jiraJson -Encoding UTF8
    # 권한 제한 (소유자 읽기만)
    icacls $jiraFile /inheritance:r /grant:r "$($env:USERNAME):(R)" | Out-Null
    Write-Host "✅ jira.json 생성 완료" -ForegroundColor Green
}

# ── 6. GitHub CLI ──────────────────────────
Write-Host "`n── 6. GitHub CLI (gh) 확인" -ForegroundColor Blue
try {
    & gh auth status 2>$null
    Write-Host "✅ GitHub CLI 인증됨" -ForegroundColor Green
} catch {
    Write-Host "⚠️  gh CLI가 없거나 인증이 필요합니다." -ForegroundColor Yellow
    Write-Host "   설치: https://cli.github.com"
    Write-Host "   설치 후: gh auth login"
}

# ── 7. repob ──────────────────────────────
Write-Host "`n── 7. repob 확인" -ForegroundColor Blue
$repobCache = Join-Path $Home ".claude\plugins\cache\bagel-marketplace\repob"
if (Test-Path $repobCache) {
    $repobVer = (Get-ChildItem $repobCache | Sort-Object Name | Select-Object -Last 1).Name
    Write-Host "✅ repob $repobVer 설치됨" -ForegroundColor Green
} else {
    Write-Host "⚠️  repob가 없습니다." -ForegroundColor Yellow
    Write-Host "   Claude Code를 열고 실행: /install-plugin repob@bagel-marketplace"
}

# ── 8. Notion (선택) ───────────────────────
Write-Host "`n── 8. Notion 설정 (qa-notionize 전용 — 선택사항)" -ForegroundColor Blue
$notionFile = Join-Path $bagelcodeDir "notion.json"
if (Test-Path $notionFile) {
    Write-Host "✅ notion.json 이미 존재" -ForegroundColor Green
} else {
    $setupNotion = Read-Host "  qa-notionize 스킬을 사용할 예정인가요? (y/N)"
    if ($setupNotion -match "^[Yy]$") {
        Write-Host "  토큰 발급: https://www.notion.so/my-integrations"
        $notionToken = Read-Host "  Notion 통합 토큰" -AsSecureString
        $notionTokenPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($notionToken))
        @{ token = $notionTokenPlain } | ConvertTo-Json | Set-Content -Path $notionFile -Encoding UTF8
        Write-Host "✅ notion.json 생성 완료" -ForegroundColor Green
    }
}

# ── 완료 ───────────────────────────────────
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "✅ 설치 완료!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Claude Code에서 스킬을 사용하세요:"
Write-Host "  /build-check  239.0.3"
Write-Host "  /ticket-qa    CVS-12345"
Write-Host "  /release-diff 241"
Write-Host ""
Write-Host "문제가 있으면 README.md 트러블슈팅 섹션을 확인하세요."
Write-Host ""
