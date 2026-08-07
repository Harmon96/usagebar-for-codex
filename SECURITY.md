# Security Policy

## 지원 범위

UsageBar는 아직 별도 바이너리 릴리스를 배포하지 않으므로 최신 `main` 브랜치의 소스만 지원합니다. 수정 사항은 이전 커밋에 별도로 backport하지 않습니다.

## 취약점 제보

보안 문제는 공개 이슈 대신 GitHub의 [private vulnerability reporting](https://github.com/Harmon96/usagebar-for-codex/security/advisories/new)을 사용해 주세요.

제보에는 가능한 범위에서 다음 정보를 포함해 주세요.

- 영향을 받는 commit 또는 코드 위치
- macOS 및 Codex CLI 버전
- 예상되는 보안 영향과 재현 단계
- 확인한 완화 방법 또는 수정 방향

Codex 인증 파일, API 키, access token, 브라우저 쿠키, Keychain 데이터, 개인 계정 정보 또는 원본 app-server 응답은 첨부하지 마세요. 재현 데이터가 필요하면 민감한 값을 제거한 최소 JSON 예시만 사용해 주세요.

일반적인 버그와 기능 제안은 공개 [GitHub Issues](https://github.com/Harmon96/usagebar-for-codex/issues)를 이용할 수 있습니다.
