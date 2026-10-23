# 검증 결과와 범위

현재 요구는 [SPEC](SPEC.md), 검사 책임·명령은 [TESTING](TESTING.md)을 따른다. 정리 전 전체 검증 기록은 [원문 이력](history/VERIFICATION-before-organization-2026-10-23.md)에 보존했다. 과거 관찰과 이번 실행을 구분한다.

## 2026-10-23 연결 복구·검색·빠른 이동

- 최종 `bash scripts/test.sh`: **168개 테스트 / 23개 suite 통과**, 3.297초. Core 49 / UI 96 / Bridge 23. 기존 128개를 보존하고 실패 분류·복구 경합·검색·빠른 이동·native 입력을 추가했다.
- 최초 검색 단축키·delegate 누락과, 반복 검색 포커스·Ghostty wrapper의 false 반환 처리 문제를 RED로 재현한 뒤 통과했다. 시스템 이벤트 검사는 고정 짧은 sleep 대신 콜백 도착을 제한 시간 안에 기다리도록 수정했다.
- 독립 읽기 전용 검토에서 대기 중 수동 연결을 자동 복구가 닫는 경합, managedKey 명시 재시도가 차단되는 문제, 반복 검색의 포커스 문제를 찾아 수정·재검토했다. 최종 범위에서 추가 actionable finding은 없었다.
- `bash scripts/build-app.sh` release 빌드, 21개 라이선스 고지 검사, `codesign --verify --deep --strict` 통과. 기존 Keychain API 및 native SwiftPM 폐기 경고는 남아 있다.
- 기존 `/Applications/luluTerminal.app`에만 적용했다. 이전 앱을 별도 ZIP으로 보존했고 설치본 56개 파일이 빌드본과 일치했다. 두 번의 설치 모두 실행 전 workspace JSON SHA-256이 설치 직후와 동일했다. 최종 실행파일 SHA-256: `f2d6f258f5e1b5b346a1019ddda06fecadc699edd72074f6f76d534a6dc89fc0`.
- 실제 설치 앱에서 첫 ⌘F의 입력 초점, 실제 출력 일치 강조와 `1 / 1` 결과, Return 이동, 터미널 클릭 후 반복 ⌘F의 검색어 보존·초점 복귀, Escape 닫기를 확인했다. 초기 SwiftUI 입력의 최초 포커스 누락은 native 필드로 교체한 최종 앱에서 재검사했다.
- 실제 빠른 이동 창에서 ⇧⌘P, 영문 서버 및 붙여 넣은 한글 검색어, 위·아래 방향키 선택, Return으로 기존 서버·열린 탭 이동을 확인했다. SwiftUI TextField가 방향키를 소비하던 현상을 발견해 native delegate로 수정한 뒤 재검사했다. 원격 탭 선택은 연결을 시작하지 않았으며 로컬 탭으로 돌아왔을 때 기존 출력이 유지됐다.
- 일반 설정에 연결 복구 스위치가 있고 기본 꺼짐인 것을 확인했다. 자동 복구는 키 기반 기존 세션만 대상으로 하며 저장 비밀번호·경유 SSH·HostKeyAlias 등 지원하지 않는 설정은 수동 연결을 유지한다. 실제 OS 절전·네트워크 전환·다중 서버 장시간 복구는 이번 검증에서 수행하지 않았다.
- 한글 검색어 일치와 marked-text 정책 검사는 실제 한국어 IME 후보 선택·조합 확정/취소 전체 수락을 대신하지 않는다. VoiceOver·Intel 기기·장시간 메모리 추이·Developer ID 공증은 이번 결과에 포함하지 않는다.

## 2026-10-23 테스트·문서 정리

- macOS 27.0.1 arm64 / Apple Swift 6.4에서 `bash scripts/test.sh`를 실행했다. 빌드 완료 후 **128개 테스트 / 19개 suite 전체 통과**, 테스트 실행 3.308초를 관찰했다. Core 46 / UI 71 / Bridge 11이다. 새 worktree에 복사된 module cache는 원래 경로를 보존한 뒤 새로 생성했다.
- 36개 AppModel 테스트 이름·본문과 기존 assertion을 보존했다. 책임별 파일은 8/13/8/7개와 공유 support로 분리했다. 프로덕션 소스·패키지·빌드 스크립트 변경은 없다.
- 보강한 취소·timeout 검사에서 실제 부모·sleep 자식과 전용 프로세스 그룹을 확인했다. 직접 자식은 종료와 waitpid 회수, 손자는 종료 또는 orphan zombie를 구분해 확인했다. 이 결과는 원격 작업 중지나 rollback 증거가 아니다.
- SPEC·INTERFACES·VERIFICATION의 정리 전 원문이 기준 커밋의 파일과 byte 단위로 동일함을 확인했다. 현행 문서의 상대 링크와 `git diff --check`가 통과했다.
- 별도 읽기 전용 검토로 테스트 분리·프로세스 fixture·설계의 현재/예정 경계를 점검했다. 기존 탭의 명시적 새 세션 생성, 비밀번호 교체·계정 제거 후 참조 정리, 차분 지표의 첫 표본 조건을 현행 코드에 맞게 문서에서 바로잡았다.
- 기존 Keychain 폐기 예정 API·native SwiftPM build mode·TerminalHostTests의 weak 변수 경고는 남아 있다. 이번 변경으로 경고 제거를 주장하지 않는다. CI 결과, release 앱 재빌드·재설치·실서버 수락은 이번 증거에 포함하지 않는다.

- 이번 범위는 테스트와 문서다. Ansible 설치·실행·원격 변경, 새 앱 배포·설치·native UI 재수락은 포함하지 않는다.

## 직전 앱 변경의 관찰 기록

아래는 앱 생성 SSH 키와 surface 해제를 반영한 `1bfaca4` 이전 작업의 기록이며 이번 문서 정리에서 재실행한 결과가 아니다.

| 검증 | 기록된 결과 | 해석 범위 |
| --- | --- | --- |
| 전체 자동 검사 | 128개 / 19 suites 통과 | 그 시점 소스·도구 환경 |
| 앱 패키징 | release, 21개 라이선스, 엄격한 중첩 ad-hoc 서명, 독립 도우미 신원 검사 통과 | Developer ID·공증 아님 |
| 설치 | 기존 앱 백업 후 /Applications/luluTerminal.app 한 개에 적용, 56개 번들 파일 일치 | 설치 전후 상태 보존 확인 |
| SSH 키 UI | native 키 암호 안내까지 열고 입력 없이 취소, 자식 프로세스 없음 | 실제 서버 키 등록·인증 전환 미확인 |
| native 반복 | 2,000줄 출력·종료 10회, 종료 후 자식 프로세스 측정값 매회 0 | 짧은 로컬 셸 반복 |
| RSS | 1회 162.70 MiB, 5회 164.02 MiB, 10회 160.38 MiB | 이 반복에서 누적 증가 미관찰, 모든 native/Metal 누수 부재 증명 아님 |

설치 앱의 기존 서버·계정·탭은 보존했다. 반복 검사 이후 JSON 차이는 selectedTabByServer UUID 사전의 직렬화 순서만 달라진 것으로, 항목 쌍의 순열로 이전 전체 파일 SHA와 일치함을 확인한 기록이 있다.

## 별도 수락이 필요한 항목

- 실제 서버의 최초 공개 키 등록·지정 키 인증, 로그인·agent 초기화 후 잠금 해제와 장시간 수집.
- 한국어 IME 조합 입력, VoiceOver, Intel 실기기, 네트워크 장애·긴 실행의 복구.
- 기존 password 경로의 실제 macOS 허용/항상 허용/거부/잠김 수명. 주입 API 검사로 OS 동작을 단정하지 않는다.
- CI·Developer ID·공증·자동 업데이트 및 Ansible 실행기. 각각 실제 결과가 생긴 시점에 추가한다.

## 재검증 진입점

```bash
bash scripts/test.sh
bash scripts/build-app.sh
python3 scripts/test-askpass-helper.py --app 'dist/Infra Terminal.app'
```

자동 검사는 임시 fixture를 사용한다. release 빌드와 도우미 검사는 코드·패키징 변경 때 수행하며 테스트·문서만 정리할 때 새 앱 설치를 요구하지 않는다. 실서버 접속은 명시적으로 승인된 대상과 범위를 따른다.
