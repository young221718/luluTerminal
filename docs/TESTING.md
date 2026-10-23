# 테스트 구조와 요구 추적

현재 기준은 [SPEC](SPEC.md), 실행 결과는 [VERIFICATION](VERIFICATION.md)이다. 이 문서는 검사 책임과 재실행 방법을 설명하며 테스트 선언 수를 통과 증거로 사용하지 않는다.

## 실행

저장소 루트에서 실행한다. UI·TerminalBridge 검사는 macOS와 Ghostty 의존성이 필요하다.

```bash
bash scripts/test.sh
bash scripts/test.sh --filter AppModelTests
bash scripts/test.sh --filter ProcessRunnerTests
INFRA_CORE_ONLY=1 bash scripts/test.sh --scratch-path .build-core
```

마지막 명령은 Core만 검사하므로 전체 검증을 대신하지 않는다. 테스트 스크립트는 현재 CLT의 Swift Testing framework·macro 경로를 설정한다. toolchain의 native SwiftPM 폐기 경고와 기존 Keychain API 경고는 알려진 제한이다. 별도 worktree에서 복사한 module cache는 절대 경로가 달라 사용할 수 없으므로 새 scratch 경로 또는 해당 cache를 보존한 뒤 새로 생성한다. 작업 중인 다른 빌드 cache를 삭제하지 않는다.

## 검사 책임

| 타깃 / suite | 선언 수 | 핵심 계약 |
| --- | ---: | --- |
| InfraCoreTests / ModelsAndCommandsTests | 9 | WS-01·03·04, TERM-02·03·04, SSH-01; 입력·세션 identity·상태 저장·명령 인용 |
| InfraCoreTests / MetricsTests | 9 | MON-02·03·05; parser·계산·nil/0·부분 실패 |
| InfraCoreTests / LocalMachineCoreTests | 7 | LOCAL-01·02, MON-04; 이전 JSON·local 라우팅·실제 로컬 측정 |
| InfraCoreTests / ProcessRunnerTests | 7 | MON-05; stdout/stderr·stdin·출력 상한·timeout·취소·프로세스 종료 |
| InfraCoreTests / SSHPasswordTests | 6 | SSH-02·03·04; 대상 바인딩·askpass·환경 |
| InfraCoreTests / SSHManagedKeysTests | 6 | KEY-01·02·03·04; 지정 키·agent·등록 보존·임시 실제 키 fixture |
| InfraCoreTests / KeychainAccessTests | 2 | SSH-04; 주입 API로 조회 UI 정책·권한 오류 |
| InfraTerminalUITests / AppModelTests | 36 | 아래 책임별 파일 참조 |
| InfraTerminalUITests / AppearancePreferencesTests | 2 | UI-04; 기본 외관·저장 |
| InfraTerminalUITests / CustomAppearancePreferencesTests | 4 | UI-04·05; 색·폰트 검증·복원 |
| InfraTerminalUITests / MonitoringPreferencesTests | 7 | MON-01, UI-01·03; 설정 저장·터미널 보존 |
| InfraTerminalUITests / LocalMacTests | 6 | LOCAL-01·02, DEMO-01; 초기화·로드·연결·수집·재실행 |
| InfraTerminalUITests / ProfileEditorTests | 1 | SSH-05; native secure field 클릭 영역 |
| InfraTerminalUITests / PasswordInputWarningTests | 4 | SSH-05; 포커스·한글 입력기·문자 안내 |
| InfraTerminalUITests / HexColorInputTests | 2 | UI-04; 색 입력 검증 |
| InfraTerminalUITests / PanelLayoutTests | 3 | UI-03; 좁은 창·드래그·접기·복원 |
| InfraTerminalUITests / ResourceInterpolationTests | 3 | UI-06; 보간 시간·중간 숫자·미측정 |
| InfraTerminalUITests / ServerOrderTests | 3 | WS-02; 순서·무효 이동·실패 보존 |
| TerminalBridgeTests / TerminalHostTests | 11 | TERM-01·05, UI-03·04·05·07; surface 재사용·해제·재연결 경합·입력 |
| 합계 | 128 | 19 suites, Core 46 / UI 71 / Bridge 11 |

위 연결은 해당 요구의 모든 UI·하드웨어·실서버 조건이 자동 검사로 증명됐다는 의미가 아니다. 수락 범위는 아래와 VERIFICATION에서 구분한다.

## AppModelTests 파일 구분

동일한 `@Suite @MainActor AppModelTests`를 파일별 extension으로 나눈다. 기존 필터·36개 메서드 이름과 assertion을 유지한다.

| 파일 | 검사 수 | 책임 |
| --- | ---: | --- |
| AppModelTests.swift | 8 | 저장 상태·계정 identity·탭·세션 재접속 |
| AppModelPasswordTests.swift | 13 | 비밀번호 참조·저장 실패·Keychain 정책·인증 경합 |
| AppModelManagedKeyTests.swift | 8 | 관리 키 활성화·취소·stale 대상·agent·모니터링 |
| AppModelMonitoringTests.swift | 7 | 수집 슬롯·중복 방지·기아 방지·이력 무효화·unknown |
| AppModelTestSupport.swift | 0 | 공유 server/tempURL/waitUntil, SuspendedCollector, TestPasswordStore |

fixture는 실제로 공유되는 범위에서만 internal로 열고 도메인 recorder는 소유 파일에 둔다. 프로덕션 추상화나 새 테스트 프레임워크를 추가하지 않는다.

## 격리·증거 기준

- 모델 검사는 임시 저장소와 주입된 실행기·자격 증명 저장소를 사용한다. 실사용 workspace JSON·Keychain·서버를 수정하지 않는다.
- 관리 키 검사는 임시 agent·PTY·키 디렉터리·로컬 원격 파일 fixture를 사용한다. 실제 사용자 키의 내용이나 비밀번호를 출력하지 않는다.
- 프로세스 검사는 실제 로컬 부모·sleep 자식 PID와 전용 프로세스 그룹을 확인한 뒤 timeout/취소한다. 직접 자식은 waitpid 회수까지 확인한다. 손자 프로세스는 종료를 검사하되 orphan zombie를 OS가 수거하는 시점은 보장하지 않는다.
- 메모리 안정성을 테스트 통과나 단일 RSS 숫자로 단정하지 않는다. native surface 해제 회귀 검사와 실제 반복 RSS·자식 프로세스 관찰은 각각 기록한다.
- 실제 SSH 로그인·키 등록, macOS 권한 창의 허용 수명, IME 조합·VoiceOver, 장시간 수집은 별도 native/실서버 수락 검사다.

## 남은 검사 공백

관리 키 검증 응답이 지연되는 동안 취소, 검증 성공 직후 상태 저장 실패, 입력 SSH 별칭은 같지만 해석 대상이 바뀌는 경우, 상속 socket이 없어 launchctl에서 agent를 찾는 경우를 후속 보강 후보로 남긴다. 현재 검사로 모두 검증됐다고 주장하지 않는다.

Ansible 개발은 2026-10-23 사용자 결정으로 취소됐다. [이전 설계의 수락 행렬](ANSIBLE_DESIGN.md#수락-검사-계획)은 이력이며 활성 검사 TODO가 아니다. Ansible 검사는 구현·실행하지 않았고 이번 128개 결과에도 포함하지 않는다.
