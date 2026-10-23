# 모듈 경계와 구현 진입점

기준: 2026-10-23 현행 구현. [SPEC](SPEC.md)의 계약을 구현하는 코드 위치를 연결한다. 변경에 뒤처지기 쉬운 Swift 선언 전체 복제 대신 실제 선언을 정본으로 사용한다. 정리 전 선언과 기록은 [원문](history/INTERFACES-before-organization-2026-10-23.md)에 보존했다.

## InfraCore

| 책임 | 구현 | 경계 |
| --- | --- | --- |
| 프로필·계정·탭·상태 | [Models.swift](../Sources/InfraCore/Models.swift) | UUID identity, 버전 있는 Codable 상태, 누락된 kind/auth 기본값, 원자적 저장·손상 보존 |
| 셸·SSH/tmux 명령 | [SSHCommands.swift](../Sources/InfraCore/SSHCommands.swift) | ShellCommand는 executable/arguments/standardInput/environment. shellString은 모든 인자를 인용한다. cwd나 streaming 이벤트 필드는 없다. |
| 단기 실행 | [ProcessRunner.swift](../Sources/InfraCore/ProcessRunner.swift) | run 결과는 exitCode/stdout/stderr. 기본 timeout 8초, 합계 출력 1 MiB. 취소·timeout·출력 초과 때 프로세스 그룹 종료·직접 자식 회수. 장시간 작업 API로 사용하지 않는다. |
| 저장 비밀번호 | [SSHPasswordAuthentication.swift](../Sources/InfraCore/SSHPasswordAuthentication.swift), [KeychainCredentialStore.swift](../Sources/InfraCore/KeychainCredentialStore.swift) | resolveTarget/context가 해석된 대상과 참조를 검증. PasswordCredentialStore는 테스트 주입 경계. 비밀 원문은 JSON·argv·환경에 넣지 않는다. |
| 앱 생성 키 | [SSHManagedKeys.swift](../Sources/InfraCore/SSHManagedKeys.swift) | 참조·키 경로·setup/unlock/verification 명령. 입력/해석된 대상 바인딩과 검증된 agent socket 사용. 암호는 native 터미널에서만 입력. |
| 측정값 | [Metrics.swift](../Sources/InfraCore/Metrics.swift) | 비율은 0…1 Double?, nil은 unknown. 개별 DiskReading/GPUReading/NetworkRate와 기존 요약을 구분. Parser와 Calculator는 수집·화면에서 분리. |
| 현재 Mac | [LocalMachine.swift](../Sources/InfraCore/LocalMachine.swift) | 예약 UUID, 기존 순서를 보존하는 ensureLocalMachine, 로컬 셸·CPU/RAM/마운트 수집. SSH builder는 local 거부. |

SSHCommandBuilder의 terminal/probe/monitor는 optional authentication, manualAuthentication, managedKeyAgentSocket 및 테스트용 managedKeyRootURL을 받는다. managedKey의 격리 정책을 임의 Ansible inventory에 그대로 적용하면 경유·별칭 설정이 사라지므로 후속 연동이 이 builder를 일반 Ansible 인증기로 재사용해서는 안 된다.

Keychain context의 allowsKeychainInteraction 기본값은 false다. 비밀 없는 정책 LULUTERMINAL_KEYCHAIN_UI=allow|fail을 독립 도우미에 전달한다. 명시 연결의 probe와 terminal만 true, 모니터링은 false다. keychainAccessRequired와 비밀 없는 stderr marker로 일반 인증 실패를 구분한다. 도우미는 자신의 프로세스에서만 UI 정책을 적용하고 종료한다.

## InfraTerminalUI

[AppModel.swift](../Sources/InfraTerminalUI/AppModel.swift)는 MainActor에서 프로필·탭·저장·인증·수집을 조정한다. 실행기·credential store·상태 URL은 테스트에서 주입한다. 잘못되거나 오래된 async 결과가 최신 프로필과 세션을 바꾸지 않도록 대상과 token을 재검증한다.

managedKey 활성화는 독립 검증, 최신 대상 확인, 상태 저장이 모두 성공해야 한다. 설정 터미널 종료 자체는 성공 신호가 아니다. 기존 password 참조는 휴면 상태로 보존하고 managedKey 경로에서 읽지 않는다.

[InfraRootView.swift](../Sources/InfraTerminalUI/InfraRootView.swift)는 선택한 로컬 셸을 열 수 있지만 원격 새 세션은 명시적 동작에서만 만든다. 외관·모니터링 설정은 workspace JSON과 별도다. [ResourceInterpolation.swift](../Sources/InfraTerminalUI/ResourceInterpolation.swift)는 표시만 보간하며 새 수집 타이머를 만들지 않는다.

## TerminalBridge

[TerminalHost.swift](../Sources/TerminalBridge/TerminalHost.swift)의 public 경계는 open(id:command:environment:), disconnect(id:), disconnectAll(), error, onExit, onOpenSettings다. TerminalPane(host:id:)가 해당 native view를 표시한다.

동일 UUID를 열면 surface·PTY·스크롤 기록을 재사용한다. 종료는 native callback 반환 뒤 해제하며 generation이 다르면 새 연결을 건드리지 않는다. 외관·폰트 변경은 기존 controller와 surface에 적용한다.

**onExit는 UUID만 전달하며 프로세스 종료 코드가 아니다.** 후속 Ansible 실행 성공 판단에 사용하지 않는다. 별도 작업 supervisor의 waitpid 결과가 필요하며 기존 SSH 탭 모델과 작업 실행 모델을 분리한다.

## 검사·예정 인터페이스

현재 API는 [TESTING](TESTING.md)의 자동 검사와 [VERIFICATION](VERIFICATION.md)의 수락 범위를 따른다. [Ansible 설계](ANSIBLE_DESIGN.md)의 JobPlan·supervisor·event adapter는 아직 코드에 없는 제안이다. 이번 정리로 public API를 변경하지 않았다.
