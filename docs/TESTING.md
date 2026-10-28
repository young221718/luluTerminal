# 테스트 구조와 요구 추적

현재 기준은 [SPEC](SPEC.md), 실행 결과는 [VERIFICATION](VERIFICATION.md)이다. 이 문서는 검사 책임과 재실행 방법을 설명하며 테스트 선언 수를 통과 증거로 사용하지 않는다.

## 실행

앱·TerminalBridge 검사는 먼저 [Ghostty 1.4 빌드](GHOSTTY_BUILD.md)로 기본 로컬 엔진을 준비한다. 별도 경로를 사용하면 모든 검사·빌드에 같은 `LULU_GHOSTTY_PACKAGE`를 설정한다. 이전 원격 엔진으로 자동 전환하지 않는다.

저장소 루트에서 실행한다. UI·TerminalBridge 검사는 macOS와 Ghostty 의존성이 필요하며 UI 빌드는 macOS 27 SDK를 사용한다. 앱의 실행 최소 버전은 macOS 14다.

```bash
bash scripts/test.sh
bash scripts/test.sh --filter AppModelTests
bash scripts/test.sh --filter ProcessRunnerTests
INFRA_MEMORY_STRESS=1 bash scripts/test.sh --filter MemoryInvestigationTests
INFRA_CORE_ONLY=1 bash scripts/test.sh --scratch-path .build-core
bash scripts/build-app.sh
python3 scripts/test-build-app.py
python3 scripts/check-no-keychain.py --app 'dist/Infra Terminal.app'
```

`test-build-app.py`는 임시 fixture와 빌드·서명 대역으로 기본·명시 버전의 실제 Info.plist 값과 잘못된 메타데이터의 빌드 전 거부를 검사한다. 실제 앱 컴파일·라이선스·서명 검사는 `build-app.sh`로 별도 수행한다.

INFRA_CORE_ONLY 명령은 Core만 검사하므로 전체 검증을 대신하지 않는다. 빌드 후 check-no-keychain.py는 앱 패키지에 폐기한 비밀번호 도우미가 없고 실행파일에 금지한 Keychain API import가 없는지 확인한다. 이 검사는 실제 로그인·기존 키체인 항목 삭제를 증명하지 않는다. 테스트 스크립트는 현재 CLT의 Swift Testing framework·macro 경로를 설정한다. toolchain의 native SwiftPM 폐기 경고는 알려진 제한이다. 별도 worktree에서 복사한 module cache는 절대 경로가 달라 사용할 수 없으므로 새 scratch 경로 또는 해당 cache를 보존한 뒤 새로 생성한다. 작업 중인 다른 빌드 cache를 삭제하지 않는다.

## 검사 책임

| 타깃 / suite | 핵심 계약 |
| --- | --- |
| InfraCoreTests / ModelsAndCommandsTests | WS-01·03·04, TERM-02·03·04, SSH-01; 입력·세션 identity·상태 저장·명령 인용 |
| InfraCoreTests / MetricsTests | MON-02·03·05; parser·계산·nil/0·부분 실패 |
| InfraCoreTests / LocalMachineCoreTests | LOCAL-01·02, MON-04; 이전 JSON·local 라우팅·실제 로컬 측정 |
| InfraCoreTests / ProcessRunnerTests | MON-05; stdout/stderr·stdin·출력 상한·timeout·취소·프로세스 종료 |
| InfraCoreTests / SSHConnectionTests | SSH-01·02·03·04; legacy password JSON 변환·identity 보존·credential 메타데이터 제거·system SSH 정책 |
| InfraCoreTests / SSHManagedKeysTests | KEY-01·02·03·04, SSH-04; 지정 키·agent·등록 보존·임시 실제 키 fixture·Keychain/askpass 금지 |
| InfraCoreTests / SSHPendingKeyTests | SSH-05; pendingKey 직렬화·재로드, terminal/probe/monitor 및 대화형 명령 생성 거부 |
| InfraCoreTests / SSHAutomaticKeyTests | KEY-01·03·04; 실제 암호 없는 키 생성·권한·기존 경로/심볼릭 링크 보존·기존 JSON 호환·agent 없는 명령 |
| InfraCoreTests / SSHPasswordRegistrationTests | KEY-05; 분리된 인증 PTY·분할 프롬프트·원격 출력 위장·비밀값 전달 경계·입력 제한·취소/timeout·프로세스/FD 정리 |
| InfraCoreTests / SSHConnectionFailureTests | SSH-06; 네트워크·인증·호스트키·미분류 오류 구분 |
| InfraTerminalUITests / AppModelTests | 아래 책임별 파일 참조 |
| InfraTerminalUITests / AppearancePreferencesTests | UI-04; 기본 외관·저장 |
| InfraTerminalUITests / CustomAppearancePreferencesTests | UI-04·05; 색·폰트 검증·복원 |
| InfraTerminalUITests / MonitoringPreferencesTests | MON-01, UI-01·03; 설정 저장·터미널 보존 |
| InfraTerminalUITests / LocalMacTests | LOCAL-01·02, DEMO-01; 초기화·로드·연결·수집·재실행 |
| InfraTerminalUITests / ProfileEditorTests | WS-05·06, SSH-05; 계정 변경·삭제 영향도, 탭 수, native 기존 계정 입력 가능, 새 계정 고정 인증 행·pendingKey 저장, 기존 계정 호환, 비밀번호 입력 필드 제거 |
| InfraTerminalUITests / ProfileSSHKeySheetsTests | SSH-05, UI-09; 새 서버·추가·이름 변경의 저장된 계정 ID, 다중 계정 순서, 성공/취소, 저장 실패·기존 계정·데모 제외, 편집 입력·저장 문맥 비교, 반복 갱신 후 외관·입력·저장과 실제 sheet 자동 설정 진입 |
| InfraTerminalUITests / MemoryInvestigationTests | UI-09; 별도 실행하는 native 편집 시트의 2,000회 부모 갱신과 malloc 증가 상한 |
| InfraTerminalUITests / SSHKeySetupViewTests | SSH-05; 일회성 보안 입력 필드·포커스·입력·자동 설정 화면 |
| InfraTerminalUITests / HexColorInputTests | UI-04; 색 입력 검증 |
| InfraTerminalUITests / PanelLayoutTests | UI-03; 좁은 창·드래그·접기·복원 |
| InfraTerminalUITests / ResourceInterpolationTests | UI-06; 보간 시간·중간 숫자·미측정 |
| InfraTerminalUITests / ServerActivityStatusTests | UI-01; 터미널 없는 최근 수집, 꺼짐·실패 캐시·계정 누락, 3주기 경계, 열린/닫힌 탭, 원격 데모·실제 로컬 수집 |
| InfraTerminalUITests / ServerOrderTests | WS-02; 순서·무효 이동·실패 보존·native 단일 행 이동의 대상 매핑 |
| InfraTerminalUITests / ConnectionLifecycleTests | REC-01·02; opt-in 저장·초기 경로 무시·절전/경로 이벤트 병합·중단 |
| InfraTerminalUITests / QuickSwitcherTests | UI-08; 토큰 검색·한글·계정·열린 탭·identity·선택 시 연결 보존·native 방향키/IME 정책/포커스 |
| TerminalBridgeTests / TerminalSearchTests | TERM-06; 기존 surface 검색·결과·세대·닫기·모달·단축키·반복 포커스 요청 |
| TerminalBridgeTests / TerminalHostTests | TERM-01·05, UI-03·04·05·07; surface 재사용·해제·재연결 경합·입력 |
| scripts/check-no-keychain.py | SSH-04; 배포 앱의 폐기 도우미·금지 Keychain API import 검사 |

위 연결은 해당 요구의 모든 UI·하드웨어·실서버 조건이 자동 검사로 증명됐다는 의미가 아니다. 수락 범위는 아래와 VERIFICATION에서 구분한다.

## AppModelTests 파일 구분

동일한 `@Suite @MainActor AppModelTests`를 파일별 extension으로 나눈다. 인증 제거 후 현재 suite·검사 수와 실제 결과는 VERIFICATION의 실행별 기록을 따른다. 제거한 SSHPasswordTests·KeychainAccessTests·PasswordInputWarningTests는 현재 검사 대상이 아니다.

| 파일 | 책임 |
| --- | --- |
| AppModelTests.swift | 저장 상태·계정 identity·탭·세션 재접속 |
| AccountManagementTests.swift | WS-05·06, LOCAL-01; 계정 이름 변경·키 바인딩 분리·계정 삭제·서버 삭제·모니터링/선택 정합성·저장 실패 보존·진행 중 연결/수집/키 설정 무효화 |
| AppModelAuthenticationMigrationTests.swift | SSH-02·03·05; legacy password JSON 변환·identity와 휴면 관리 키 메타데이터 보존·저장 시 credential 제거·수동 터미널 fallback·원자적 저장 실패·인증 경합·취소 |
| AppModelAutomaticKeyTests.swift | KEY-01·03·05; 자동 순서·pendingKey 성공 전환과 실패/취소 보존·저장 실패·직전 대상 재확인·변경·삭제·비밀번호 미직렬화·기존 연결 보존 |
| AppModelPendingKeyTests.swift | SSH-05; pendingKey 재실행 후 터미널·대화형 요청·수집·자동 복구 차단, 실행기 미호출 |
| AppModelManagedKeyTests.swift | KEY-01·02·03·04; 관리 키 활성화·취소·stale 대상·agent·모니터링 |
| AppModelMonitoringTests.swift | 수집 슬롯·중복 방지·기아 방지·이력 무효화·unknown |
| AppModelConnectionRecoveryTests.swift | 실패 분류·정책·무인 기존 세션 연결·경유 설정 제외·수동 재시도·취소/편집/닫기/비활성화·대기 탭 보호 |
| AppModelTestSupport.swift | 공유 server/tempURL/waitUntil, SuspendedCollector |

fixture는 실제로 공유되는 범위에서만 internal로 열고 도메인 recorder는 소유 파일에 둔다. 프로덕션 추상화나 새 테스트 프레임워크를 추가하지 않는다.

## 격리·증거 기준

- 계정 추가 후 자동 설정 검사는 앱과 같은 ProfileSSHKeySheets를 임시 모델·native 창에 연결한다. 신규 계정의 pendingKey 저장·sheet 닫힘·보안 입력칸 표시까지 확인하며 실제 서버나 비밀번호를 사용하지 않는다.
- 모델 검사는 임시 상태 저장소와 주입된 실행기를 사용한다. 실사용 workspace JSON·Keychain·서버를 수정하지 않는다. 계정·서버 삭제는 합성 프로필로 검증하고 실제 앱에서는 확인 창 취소와 편집 취소만 검사한다.
- 관리 키 검사는 임시 agent·PTY·키 디렉터리·로컬 원격 파일 fixture를 사용한다. 실제 사용자 키의 내용이나 비밀번호를 출력하지 않는다.
- 프로세스 검사는 실제 로컬 부모·sleep 자식 PID와 전용 프로세스 그룹을 확인한 뒤 timeout/취소한다. 직접 자식은 waitpid 회수까지 확인한다. 손자 프로세스는 종료를 검사하되 orphan zombie를 OS가 수거하는 시점은 보장하지 않는다.
- 메모리 안정성을 테스트 통과나 단일 RSS 숫자로 단정하지 않는다. native surface 해제 회귀 검사와 실제 반복 RSS·자식 프로세스 관찰은 각각 기록한다.
- 메모리 회귀 검사는 위 `INFRA_MEMORY_STRESS=1` 명령으로 새 프로세스에서 별도 실행한다. 실제 ProfileSSHKeySheets를 임시 모델·투명 native 창에 연결하고, 준비 갱신 100회 후 기본 2,000회의 model.tick 갱신이 루트에 전달됐는지 확인한다. malloc 사용량의 최종 증가 상한은 1MiB이며 physical footprint도 별도로 기록한다. 기본 전체 검사에서는 이 측정만 건너뛴다. 원본 inline 편집 경로를 복원했을 때 상한 실패가 확인됐다. 이는 관찰된 편집 시트 누적 경로의 검사이며 모든 native·Metal 할당이나 장시간 실사용을 보증하지 않는다.
- 실제 SSH 비밀번호 로그인·키 등록, 재시작 후 agent 잠금 해제, IME 조합·VoiceOver, 장시간 수집은 별도 native/실서버 수락 검사다. 과거 키체인 항목 정리는 별도 승인·실행·readback이 필요하며 앱 코드·패키지 검사로 대체하지 않는다.

## 남은 검사 공백

서버 순서 매핑·저장 검사는 macOS 27의 실제 드래그 애니메이션·삽입 위치·취소를 대체하지 않는다. 실제 마우스로 정방향·역방향 이동, Escape·밖에 놓기, 긴 목록 자동 스크롤과 저장 실패 시 화면 복원을 확인한다. macOS 14–26의 행 미리보기·동작 줄이기 역시 해당 OS 수락이 별도로 필요하다.

자동 설정의 지연 중 취소·검증 후 저장 실패·별칭 대상 변경은 합성 실행기로 검사한다. 실제 NAS의 password 정책·호스트 신뢰·홈 권한·공개 키 허용과 최종 자원 수집은 사용자 직접 인증 후 별도 확인한다. 기존 암호화 키에서 상속 socket이 없어 launchctl에서 agent를 찾는 환경과 VoiceOver·다양한 IME는 전체 실환경 수락이 끝난 것으로 주장하지 않는다.

Ansible 개발은 2026-10-23 사용자 결정으로 취소됐다. [이전 설계의 수락 행렬](ANSIBLE_DESIGN.md#수락-검사-계획)은 이력이며 활성 검사 TODO가 아니다. Ansible 검사는 구현·실행하지 않으며 현재 자동 검사 범위에 포함하지 않는다.
