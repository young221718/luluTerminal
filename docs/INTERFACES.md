# 모듈 경계와 구현 진입점

기준: 2026-10-26 현행 구현. [SPEC](SPEC.md)의 계약을 구현하는 코드 위치를 연결한다. 변경에 뒤처지기 쉬운 Swift 선언 전체 복제 대신 실제 선언을 정본으로 사용한다. 정리 전 선언과 기록은 [원문](history/INTERFACES-before-organization-2026-10-23.md)에 보존했다.

## InfraCore

| 책임 | 구현 | 경계 |
| --- | --- | --- |
| 프로필·계정·탭·상태 | [Models.swift](../Sources/InfraCore/Models.swift) | UUID identity, system/managedKey 인증, 버전 있는 Codable 상태, 누락된 kind/auth 기본값, legacy password→system 변환·credential 메타데이터 무시, 원자적 저장·손상 보존 |
| 셸·SSH/tmux 명령 | [SSHCommands.swift](../Sources/InfraCore/SSHCommands.swift) | ShellCommand는 executable/arguments/standardInput/environment. shellString은 모든 인자를 인용한다. cwd나 streaming 이벤트 필드는 없다. |
| 단기 실행 | [ProcessRunner.swift](../Sources/InfraCore/ProcessRunner.swift) | run 결과는 exitCode/stdout/stderr. 기본 timeout 8초, 합계 출력 1 MiB. 취소·timeout·출력 초과 때 프로세스 그룹 종료·직접 자식 회수. 장시간 작업 API로 사용하지 않는다. |
| 앱 생성 키 | [SSHManagedKeys.swift](../Sources/InfraCore/SSHManagedKeys.swift) | 참조·키 경로·자동 생성/등록/검증·기존 키 unlock 명령. requiresAgent는 기존 true/신규 자동 키 false. 비밀번호는 이 명령 모델에 포함하지 않는다. |
| 연결 실패 | [SSHConnectionFailure.swift](../Sources/InfraCore/SSHConnectionFailure.swift) | SSH 255를 network/authentication/hostKey/unknown으로 분류. network 외 실패는 자동 재시도를 막으며 네트워크 오류를 키 잠금 해제로 오인하지 않는다. |
| 측정값 | [Metrics.swift](../Sources/InfraCore/Metrics.swift) | 비율은 0…1 Double?, nil은 unknown. 개별 DiskReading/GPUReading/NetworkRate와 기존 요약을 구분. Parser와 Calculator는 수집·화면에서 분리. |
| 현재 Mac | [LocalMachine.swift](../Sources/InfraCore/LocalMachine.swift) | 예약 UUID, 기존 순서를 보존하는 ensureLocalMachine, 로컬 셸·CPU/RAM/마운트 수집. SSH builder는 local 거부. |

SSHCommandBuilder의 terminal/probe/monitor는 managedKeyAgentSocket 및 테스트용 managedKeyRootURL을 받는다. 모든 SSH 명령은 UseKeychain=no, AddKeysToAgent=no와 SSH_ASKPASS_REQUIRE=never를 적용한다. system 터미널은 대화형 인증을 허용하고 사전 확인·모니터링은 비대화형 키·agent 인증만 허용한다. 자동 복구는 해석된 SSH 설정을 먼저 확인하고 ProxyJump·ProxyCommand·HostKeyAlias 연결을 수동 재시도로 남긴다. 비대화형 복구를 위해 기존 SSH 경로·포워딩을 제거하지 않는다.

앱에는 비밀번호 저장소·Keychain context·인증 도우미·askpass 인터페이스가 없다. 과거 password 프로필의 credential 필드는 디코딩 때 읽지 않으며 새 상태에 인코딩하지 않는다. 이 변환은 계정·탭 identity를 보존하며 과거 키체인 항목 삭제를 증명하지 않는다.

[SSHPasswordRegistrationRunner.swift](../Sources/InfraCore/SSHPasswordRegistrationRunner.swift)는 비밀번호를 ShellCommand와 분리된 인자로 받고 결과 원문 없이 성공 또는 분류 오류만 반환한다. [InfraSSHPTY.c](../Sources/InfraSSHPTY/InfraSSHPTY.c)는 제어 터미널·분리된 표준 스트림·프로세스 그룹·직접 자식 회수를 소유하며 fork 이후 Swift/Foundation 코드를 실행하지 않는다. macOS 제어 터미널 유지용 slave descriptor는 부모가 작업 종료까지 보관한다.

## InfraTerminalUI

[AppModel.swift](../Sources/InfraTerminalUI/AppModel.swift)는 MainActor에서 프로필·탭·저장·인증·수집을 조정한다. 실행기·상태 URL은 테스트에서 주입한다. 잘못되거나 오래된 async 결과가 최신 프로필과 세션을 바꾸지 않도록 대상과 token을 재검증한다.

프로필 편집은 `saveProfile(_:)`, 서버 삭제는 `deleteServer(_:)`가 소유한다. 이름이 바뀐 계정에 새 UUID를 부여하고 이전 계정의 탭을 후보 상태에서 제거하므로 StateStore의 identity 검증을 우회하지 않는다. 후보 상태 저장 성공 뒤에만 연결·수집을 무효화하고 삭제된 참조를 정리한다. UI는 영향도 확인을 담당하며 저장 전에 기존 탭 ID를 포착해 성공 후 해당 터미널 표면을 해제한다. 삭제는 원격 명령이나 SSH 키 파일 삭제를 실행하지 않는다.

managedKey 활성화는 독립 검증, 최신 대상 확인, 상태 저장이 모두 성공해야 한다. 설정 터미널 종료 자체는 성공 신호가 아니다. automaticallySetUpSSHKey는 일회성 비밀번호와 단계 콜백을 받아 생성·등록·검증·저장을 조정하며 비밀번호를 상태에 저장하지 않는다. 최초 등록은 주입 가능한 PasswordRegistrationExecutor로 분리한다. 키 암호가 있는 기존 키는 로그인 세션 agent에서 잠금을 해제한다.

연결 복구의 모델 경계는 configureConnectionRecovery(enabled:), connectionEnvironmentInterrupted(), beginConnectionRecovery()와 prepareConnection(... automaticRecovery:)다. 중단 전 연결 의도·탭·계정·프로필·token을 재확인하며 복구 허가는 한 번만 사용한다. 닫힌 탭·로컬·데모를 제외하고 기존 세션만 확인한다. 수동 해제·닫기·프로필 변경·설정 해제 뒤 오래된 결과를 버린다. 자동 복구는 대화형 인증과 키 잠금 해제를 허용하지 않는다.

| 책임 | 구현 | 경계 |
| --- | --- | --- |
| 복구 설정 | [ConnectionPreferences.swift](../Sources/InfraTerminalUI/ConnectionPreferences.swift) | automaticallyReconnect 기본 false. connection.automaticallyReconnect를 UserDefaults에 저장하며 workspace JSON과 분리. |
| 시스템 복귀 이벤트 | [ConnectionLifecycle.swift](../Sources/InfraTerminalUI/ConnectionLifecycle.swift) | NSWorkspace 절전/복귀와 NWPathMonitor 경로 이벤트를 합친다. 초기 정상 알림은 복구하지 않고 지연된 이벤트는 generation으로 무효화. 대상 판단은 AppModel 소유. |
| 현재 터미널 검색 | [TerminalSearchBar.swift](../Sources/InfraTerminalUI/TerminalSearchBar.swift) | Ghostty 검색 상태 표시·검색어·이전/다음·닫기와 입력 포커스. 검색 실행과 surface 수명은 TerminalHost 소유. |
| 빠른 이동 | [QuickSwitcher.swift](../Sources/InfraTerminalUI/QuickSwitcher.swift) | QuickSwitchTarget.server(UUID)/tab(UUID), QuickSwitchItem.entries(workspace:query:). 서버 순서와 열린 탭을 유지한 토큰 AND 검색. 열린 탭이 없는 계정은 서버 행으로 찾으며 모델 변경은 onSelect 콜백에 위임. |
| 메뉴·단축키 | [TerminalWorkspaceCommands.swift](../Sources/InfraTerminalUI/TerminalWorkspaceCommands.swift) | 활성 창의 focused actions로 ⌘F·⇧⌘P를 연결. 검색은 현재 실행 중인 탭, 빠른 이동은 서버·계정·열린 탭 대상. |

[InfraRootView.swift](../Sources/InfraTerminalUI/InfraRootView.swift)는 선택한 로컬 셸을 열 수 있지만 원격 새 세션은 명시적 동작에서만 만든다. 빠른 이동은 기존 selectServer/selectTab만 호출하며 UUID·연결·열린 surface를 유지한다. 복구 설정·이벤트를 연결하고 modal 표시 중에는 복구를 미룬다. 외관·모니터링·연결 복구 설정은 workspace JSON과 별도다. 비활성 Ansible 메뉴·안내는 제거했다. [ResourceInterpolation.swift](../Sources/InfraTerminalUI/ResourceInterpolation.swift)는 표시만 보간하며 새 수집 타이머를 만들지 않는다.

[SearchInputField.swift](../Sources/InfraTerminalUI/SearchInputField.swift)는 검색과 빠른 이동의 native NSTextField 입력을 공유한다. field editor delegate에서 방향키·Return·Escape를 처리하고 조합 중인 IME·수정키는 기본 편집기로 넘긴다. 새 포커스 요청은 창 부착·sheet·요청 token을 확인하고 한 번만 적용한다.

## TerminalBridge

[TerminalHost.swift](../Sources/TerminalBridge/TerminalHost.swift)의 연결 경계는 open(id:command:environment:), disconnect(id:), disconnectAll(), error, onExit, onOpenSettings다. TerminalPane(host:id:)가 해당 native view를 표시한다.

동일 UUID를 열면 surface·PTY·스크롤 기록을 재사용한다. 종료는 native callback 반환 뒤 해제하며 generation이 다르면 새 연결을 건드리지 않는다. 외관·폰트 변경은 기존 controller와 surface에 적용한다.

검색 경계는 search, searchFocusRequest, onSearchRequest(UUID), onQuickSwitch(), beginSearch(id:), updateSearchQuery(_:), navigateSearch(previous:), closeSearch(restoreFocus:), focus(id:)다. [TerminalSearchState.swift](../Sources/TerminalBridge/TerminalSearchState.swift)는 탭 UUID·검색어·선택 결과·합계를 보관한다. native search delegate와 Ghostty binding을 사용하고 탭 UUID·surface generation이 지난 결과를 버린다. 검색·빠른 이동으로 새 surface를 만들지 않으며 시트·검색 입력칸의 포커스를 지연된 TerminalPane 콜백이 빼앗지 않는다.

**onExit는 UUID만 전달하며 프로세스 종료 코드가 아니다.** SSH 실패 원인 분류는 AppModel의 사전 확인 결과와 오류 경계를 사용한다.

## 검사·예정 인터페이스

현재 API는 [TESTING](TESTING.md)의 자동 검사와 [VERIFICATION](VERIFICATION.md)의 수락 범위를 따른다. [Ansible 설계](ANSIBLE_DESIGN.md)의 JobPlan·supervisor·event adapter는 코드에 없는 제안이며 2026-10-23 사용자 결정으로 개발을 취소했다.
