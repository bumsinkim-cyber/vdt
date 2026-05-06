#!/usr/bin/env python3
"""
vdt-auth.py — Google OAuth 인증 (최초 1회 실행)
저장 위치: ~/.bagelcode/google_token.json
"""
import os, sys, json
from pathlib import Path
from google_auth_oauthlib.flow import InstalledAppFlow
from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials

SCOPES = [
    "https://www.googleapis.com/auth/drive.readonly",
    "https://www.googleapis.com/auth/presentations.readonly",
]

CLIENT_FILE = Path.home() / ".bagelcode" / "google_client.json"
TOKEN_FILE  = Path.home() / ".bagelcode" / "google_token.json"

def main():
    if not CLIENT_FILE.exists():
        print(f"[ERROR] {CLIENT_FILE} 없음. google_client.json을 먼저 설정하세요.")
        sys.exit(1)

    creds = None
    if TOKEN_FILE.exists():
        creds = Credentials.from_authorized_user_file(str(TOKEN_FILE), SCOPES)

    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
            print("토큰 갱신 완료")
        else:
            flow = InstalledAppFlow.from_client_secrets_file(str(CLIENT_FILE), SCOPES)
            creds = flow.run_local_server(port=0)
            print("Google 인증 완료")

        TOKEN_FILE.write_text(creds.to_json())
        TOKEN_FILE.chmod(0o600)

    print(f"[OK] 인증 토큰 저장됨: {TOKEN_FILE}")

if __name__ == "__main__":
    main()
