# Contributing

UsageBar에 관심을 가져주셔서 감사합니다. 버그 제보와 작은 개선 제안을 환영합니다.

## 이슈를 등록하기 전에

- 최신 `main`에서 같은 문제가 재현되는지 확인해 주세요.
- Codex CLI가 설치되어 있고 `codex --version`이 정상 동작하는지 확인해 주세요.
- 버그 이슈에는 macOS 버전, Swift 버전, Codex CLI 버전, 재현 단계와 기대 결과를 적어 주세요.
- 인증 파일, API 키, access token, 개인 계정 정보 또는 원본 app-server 응답은 첨부하지 마세요.
- 보안 취약점은 공개 이슈 대신 [SECURITY.md](./SECURITY.md)의 비공개 제보 절차를 이용해 주세요.

## 로컬 개발

요구 사항은 macOS 15 이상, Swift 6.2 이상, 설치 및 로그인된 Codex CLI입니다.

```sh
git clone https://github.com/Harmon96/usagebar-for-codex.git
cd usagebar-for-codex
swift test
zsh ./scripts/build-app.sh
open ./dist/CodexUsageMenuBar.app
```

Swift 소스는 저장소의 `.swift-format` 설정을 사용합니다.

```sh
xcrun swift-format format --configuration .swift-format --in-place --recursive Sources Tests Package.swift
xcrun swift-format lint --configuration .swift-format --recursive Sources Tests Package.swift --strict
```

## 변경 원칙

- 한 PR은 하나의 명확한 문제만 해결해 주세요.
- UI 또는 사용량 계산 동작을 바꾸면 변경 전후 동작과 검증 방법을 함께 설명해 주세요.
- `account/rateLimits/read` 응답 처리를 바꾸면 개인 데이터가 제거된 최소 JSON fixture와 회귀 테스트를 추가해 주세요.
- 새로운 외부 의존성은 필요성과 유지관리 비용을 먼저 설명해 주세요.
- 생성물인 `.build/`, `dist/`와 개인 설정 파일은 커밋하지 마세요.

## 검증

PR을 열기 전에 다음 명령이 통과해야 합니다.

```sh
xcrun swift-format lint --configuration .swift-format --recursive Sources Tests Package.swift --strict
swift test
zsh ./scripts/build-app.sh
```

GitHub Actions에서도 같은 형식 검사, 테스트, 앱 번들 빌드를 수행합니다.

## 라이선스

기여한 코드는 이 저장소의 [MIT License](./LICENSE)에 따라 배포되는 것에 동의한 것으로 간주합니다.
