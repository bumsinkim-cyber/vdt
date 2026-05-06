# Jira API 토큰 발급 가이드

Claude Code QA 스킬이 Jira 티켓 정보를 읽으려면 **개인 API 토큰**이 필요합니다.
토큰은 비밀번호 대신 사용하는 인증 키로, 발급 후 `~/.bagelcode/jira.json`에 저장됩니다.

---

## 1단계 — Atlassian 계정 설정 페이지 접속

브라우저에서 아래 URL로 접속하세요.

```
https://id.atlassian.com/manage-profile/security/api-tokens
```

> 로그인 안 되어 있으면 `bumsin.kim@bagelcode.com` 계정으로 로그인하세요.

접속하면 아래와 같은 화면이 나옵니다.

```
Security  >  API tokens

API tokens
Use an API token to authenticate with Atlassian products.

  [Create API token]
```

---

## 2단계 — 새 토큰 만들기

**[Create API token]** 버튼을 클릭합니다.

팝업이 뜨면 토큰 이름을 입력합니다. 나중에 어디서 쓰는지 구별할 수 있는 이름으로 짓는 걸 추천합니다.

```
Label: claude-qa
```

**[Create]** 버튼을 클릭합니다.

---

## 3단계 — 토큰 복사

생성 직후 아래와 같이 토큰 값이 화면에 한 번만 표시됩니다.

```
Your new API token

ATATT3xFfGF0...생략...abcde1234

[Copy]   [Close]
```

> ⚠️ **이 창을 닫으면 토큰을 다시 볼 수 없습니다.**
> 반드시 **[Copy]** 버튼을 눌러 복사한 뒤 다음 단계로 진행하세요.

---

## 4단계 — setup.sh에 입력

터미널에서 `setup.sh`를 실행하면 아래 입력창이 순서대로 나옵니다.

```
Jira API 토큰 발급 방법:
  1. https://id.atlassian.com/manage-profile/security/api-tokens 접속
  2. [Create API token] 클릭 → 이름 입력 (예: claude-qa) → 토큰 복사

  Jira 이메일: your.email@bagelcode.com    ← 회사 이메일 입력
  Jira API 토큰:                           ← 복사한 토큰 붙여넣기 (입력 시 안 보임)
  Jira 도메인 (예: bagelcode.atlassian.net): bagelcode.atlassian.net
```

각 항목을 채우면 `~/.bagelcode/jira.json`이 자동으로 생성됩니다.

---

## 생성된 파일 확인

설치 완료 후 아래 명령으로 파일이 제대로 만들어졌는지 확인할 수 있습니다.

```bash
cat ~/.bagelcode/jira.json
```

출력 예시:
```json
{
  "email": "your.email@bagelcode.com",
  "token": "ATATT3xFfGF0...",
  "domain": "bagelcode.atlassian.net"
}
```

파일 권한도 확인하세요 (600 = 본인만 읽기 가능):
```bash
ls -la ~/.bagelcode/jira.json
# -rw------- 1 yourname staff 85 ...
```

---

## 토큰 만료 / 재발급

Atlassian API 토큰은 **만료 기간이 없습니다.** (직접 삭제하기 전까지 유효)

단, 아래 상황에서는 재발급이 필요합니다.
- Atlassian 계정 설정에서 수동으로 토큰을 삭제한 경우
- 보안 사고로 토큰이 노출된 경우

**재발급 방법:**
1. `~/.bagelcode/jira.json` 삭제: `rm ~/.bagelcode/jira.json`
2. `setup.sh` 재실행 또는 Claude Code에서 `/vdt-setup` 실행

---

## 자주 묻는 질문

**Q. 토큰 입력 시 화면에 아무것도 안 보여요**
정상입니다. 보안을 위해 입력 중 표시되지 않습니다. 붙여넣기 후 Enter를 누르세요.

**Q. `401 Unauthorized` 에러가 나와요**
이메일 또는 토큰 값이 잘못된 것입니다. `jira.json` 파일을 삭제하고 다시 발급하세요.

**Q. `bagelcode.atlassian.net`이 맞나요?**
네. Bagelcode의 Jira 도메인은 `bagelcode.atlassian.net`입니다.

**Q. 토큰을 다른 사람과 공유해도 되나요?**
절대 안 됩니다. 토큰은 내 계정 권한과 동일하게 동작합니다. 개인별로 각자 발급해야 합니다.

---

문의: QA팀 Slack `#qa-ai-report`
