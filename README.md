# UsageBar

UsageBar는 설치된 Codex CLI의 주간 잔여 사용률을 macOS 메뉴바에 보여주는 독립적인 유틸리티입니다. 게이지와 퍼센트, 리셋 시각, 사용 속도, 플랜 및 CLI 버전을 한눈에 확인할 수 있습니다.

> [!IMPORTANT]
> UsageBar는 OpenAI와 제휴하거나 OpenAI가 승인·후원한 공식 제품이 아닙니다. OpenAI와 Codex는 각 권리자의 상표이며, 이 저장소에는 OpenAI 로고 자산이 포함되지 않습니다.

## 주요 기능

- 주간 잔여 사용률을 `게이지 + %`, `게이지만`, `%만` 중 하나로 표시
- Adaptive 또는 1·2·5·15분 간격 자동 갱신
- 메뉴바를 열거나 Mac이 잠자기에서 복귀했을 때 오래된 값 재검증
- 조회 실패 시 마지막 정상 값을 유지하고 stale 상태 및 오류 원인 표시
- 주간 리셋 시각, 소비 속도, 리셋 크레딧, 모델별 제한, 플랜 및 CLI 버전 표시
- 사용자가 명시적으로 켠 경우에만 macOS 로그인 항목 등록

## 동작 방식

UsageBar는 로컬에서 `codex app-server --stdio`를 실행한 뒤, Codex의 공개된 app-server 프로토콜인 `account/rateLimits/read`를 호출합니다. 응답의 `usedPercent`를 `100 - usedPercent`로 계산해 Codex 사용 화면과 같은 의미의 **잔여율**로 표시합니다.

- UsageBar 자체는 외부 API에 직접 요청하지 않습니다. 설치된 Codex CLI가 기존 로그인 상태를 사용해 필요한 통신을 담당합니다.
- UsageBar는 Codex 인증 파일, 브라우저 쿠키, Keychain 항목 또는 API 키를 직접 조회하거나 자체 저장하지 않습니다.
- `Usage 열기`를 누를 때만 기본 브라우저로 `https://chatgpt.com/codex/settings/usage`를 엽니다.

프로토콜 설명은 [OpenAI Codex app-server 문서](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md)에서 확인할 수 있습니다.

## 요구 사항

- macOS 15 이상
- Swift 6.2 이상
- 설치 및 로그인된 Codex CLI

앱은 `~/.hermes/node/bin`, `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`과 현재 프로세스의 `PATH`에서 `codex` 실행 파일을 찾습니다.

## 빌드 및 실행

```sh
zsh ./scripts/build-app.sh
open ./dist/CodexUsageMenuBar.app
```

빌드 스크립트는 릴리스 바이너리를 컴파일하고, 새 앱 번들을 만든 뒤 로컬 실행용 ad-hoc 서명과 무결성 검증을 수행합니다. 생성된 `.build/`와 `dist/`는 Git에서 제외됩니다.

이 저장소는 소스 배포를 전제로 합니다. GitHub Release에 미리 빌드한 `.app`을 배포하려면 본인 소유의 bundle identifier, Apple Developer ID 서명 및 notarization 절차가 별도로 필요합니다. 현재 기본 bundle identifier는 `app.usagebar.menubar`입니다.

## 개인정보 및 로컬 데이터

- 앱 자체 telemetry, analytics, 광고 SDK 또는 원격 로그 전송은 없습니다.
- Codex 하위 프로세스에는 사용자의 현재 프로세스 환경이 전달됩니다. 공식 Codex CLI를 신뢰할 수 있는 경로에 설치해 사용해야 합니다.
- 원본 app-server 응답은 디스크에 기록하지 않습니다.
- 마지막 정상 잔여율, 리셋 시각, 사용 속도, 플랜, CLI 버전, 리셋 크레딧, 모델별 제한과 UI 설정은 macOS `UserDefaults`에 로컬 캐시합니다.

앱을 종료하고 로그인 시 자동 실행을 먼저 끈 뒤, 로컬 설정과 캐시를 초기화하려면 다음 명령을 사용할 수 있습니다.

```sh
defaults delete app.usagebar.menubar
```

## 제한 사항

- Codex CLI의 app-server 응답 형식이 변경되면 앱 업데이트가 필요할 수 있습니다.
- 현재 빌드는 macOS 15 이상만 지원합니다.
- 로컬 빌드의 ad-hoc 서명은 GitHub에서 내려받은 바이너리 배포에 필요한 Developer ID 서명이나 notarization을 대신하지 않습니다.

## 공개 저장소 체크리스트

최초 커밋 전에 다음처럼 생성 파일이 제외됐는지 확인하세요.

```sh
git status --short
git ls-files
```

`.build/`, `dist/`, `.DS_Store`, `.env*`, 서명 인증서와 provisioning profile은 커밋하지 마세요.

## 라이선스

이 프로젝트는 MIT 라이선스입니다. 자세한 내용은 [LICENSE](./LICENSE)를 참고하세요.
