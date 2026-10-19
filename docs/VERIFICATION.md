# 검증 안내

## 로컬 검사와 빌드

macOS 14 이상, Swift 6.2 이상과 Command Line Tools가 필요하다. arm64 macOS 27.0.1·Swift 6.4 환경에서 개발했다. 처음 의존성을 받을 때는 네트워크가 필요하다.

```bash
bash scripts/test.sh
bash -n scripts/build-app.sh scripts/make-icon.sh scripts/test.sh
bash scripts/build-app.sh
codesign --verify --deep --strict 'dist/Infra Terminal.app'
open 'dist/Infra Terminal.app'
```

자동 검사는 계정별 세션 격리, SSH 인자 인용과 입력 검증, 생성/재접속 분리, 상태 저장, 로컬 라우팅, 지표 계산, 수집 스케줄, 프로세스 제한과 터미널 컨테이너 소유권을 다룬다. 실제 SSH 서버나 사용자의 저장 데이터에 접속하지 않는 fixture 검사와 로컬 프로세스 검사를 사용한다.

아이콘은 `Resources/AppIcon.png`에서 macOS `sips`·`iconutil`로 재생성한다. 패키지의 고정된 바이너리 체크섬과 의존성 잠금 파일을 유지한다. 임시 iconset, 빌드 캐시와 앱 번들은 Git에 포함하지 않는다.

## 실제 화면 확인

- 기본 로컬 Mac 한 개와 로컬 셸 자동 시작, 작은 도넛 숫자·미수집 표시·그라데이션 확인.
- 서버/계정 탭 전환, 창 크기 변경, 복사/붙여넣기와 키보드 입력 확인.
- 승인된 Linux 서버에서만 새 전용 tmux 탭 생성, 연결 해제 및 기존 세션 재접속 확인.
- 모니터링 실패와 실제 0을 구분하고 수집 시각·오류를 확인.
- 앱 종료는 원격 tmux 세션을 종료하지 않지만 서버 재부팅·tmux 종료·로컬 셸 지속을 보장하지 않는다.

소스 검사, 앱 빌드, 실제 서버 확인, CI, 서명·공증과 배포는 서로 다른 검증 단계다. 한국어 IME 전체 조합, VoiceOver, 장시간 10대 수집, 네트워크 장애와 Intel Mac 실기기 검증은 아직 완료되지 않았다.
