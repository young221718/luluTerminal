# 작업 간 Swift 인터페이스

모든 Core 타입과 생성자는 public. 값 타입 Codable/Equatable/Sendable을 가능한 범위에서 채택한다.
비율은 0...1 Double?, nil은 unknown이며 0과 다르다. 핵심 구현자가 추가 필드를 넣어도 아래 이름은 유지한다.

```swift
struct SSHAccount: Identifiable, Codable, Equatable, Sendable {
  var id: UUID; var username: String
  var authMethod: SSHAuthenticationMethod; var credential: SSHPasswordReference?
  var managedKey: SSHManagedKeyReference?
  init(id: UUID = UUID(), username: String, authMethod: SSHAuthenticationMethod = .system, credential: SSHPasswordReference? = nil, managedKey: SSHManagedKeyReference? = nil)
}
enum ServerConnectionKind: String, Codable, Sendable { case ssh, local }
struct ServerProfile: Identifiable, Codable, Equatable, Sendable {
  var id: UUID; var name: String; var host: String; var port: Int; var kind: ServerConnectionKind
  var accounts: [SSHAccount]; var monitorAccountID: UUID?; var monitoringEnabled: Bool
  init(id: UUID = UUID(), name: String, host: String, port: Int = 22,
       accounts: [SSHAccount], monitorAccountID: UUID? = nil, monitoringEnabled: Bool = true, kind: ServerConnectionKind = .ssh)
  func validate() throws
}
struct TerminalTab: Identifiable, Codable, Equatable, Sendable {
  var id: UUID; var serverID: UUID; var accountID: UUID; var title: String; var isClosed: Bool
  init(id: UUID = UUID(), serverID: UUID, accountID: UUID, title: String, isClosed: Bool = false)
  var sessionName: String { get }
}
struct WorkspaceState: Codable, Equatable, Sendable {
  var schemaVersion: Int; var servers: [ServerProfile]; var tabs: [TerminalTab]
  var selectedServerID: UUID?; var selectedTabByServer: [UUID: UUID]
  init() // empty state
  mutating func ensureLocalMachine() // pin once; preserve existing remote choice/tabs
  mutating func select(serverID: UUID)
  mutating func select(tabID: UUID)
  mutating func close(tabID: UUID)
  mutating func reopen(tabID: UUID)
  mutating func add(tab: TerminalTab) throws
}
struct StateStore {
  init(url: URL)
  func load() throws -> WorkspaceState? // absent nil, corrupt throws without rewriting
  func save(_ state: WorkspaceState) throws
}
struct ShellCommand: Sendable {
  var executable: String; var arguments: [String]; var standardInput: String?; var environment: [String: String]
  init(executable: String, arguments: [String], standardInput: String? = nil, environment: [String: String] = [:])
  var shellString: String { get } // correctly quoted for Ghostty command
}
enum LocalMachine {
  static let serverID: UUID; static let accountID: UUID; static let initialTabID: UUID
  static var username: String { get }; static var loginShell: String { get }; static var homeDirectory: String { get }
  static var profile: ServerProfile { get }
  static func terminal(shell: String = loginShell, home: String = homeDirectory) throws -> ShellCommand
}
struct LocalCPUReading: Equatable, Sendable {
  var total: UInt64; var idle: UInt64
  init(total: UInt64, idle: UInt64)
}
struct LocalMetricsCollector: Sendable {
  init()
  static func cpuUsage(current: LocalCPUReading, previous: LocalCPUReading?) -> Double?
  mutating func collect(timestamp: Date = Date()) -> MetricsSnapshot
}
enum SSHCommandBuilder {
  static func terminal(server: ServerProfile, account: SSHAccount, tab: TerminalTab, create: Bool) throws -> ShellCommand
  static func monitor(server: ServerProfile, account: SSHAccount) throws -> ShellCommand
}
struct ProcessResult: Sendable { var exitCode: Int32; var stdout: String; var stderr: String }
struct ProcessRunner: Sendable {
  init()
  func run(_ command: ShellCommand, timeout: TimeInterval = 8) async throws -> ProcessResult
}
struct GPUReading: Equatable, Sendable {
  var name: String; var utilization: Double?; var memoryUsedBytes: Double?; var memoryTotalBytes: Double?
}
struct NetworkRate: Equatable, Sendable {
  var name: String; var receivedBytesPerSecond: Double?; var sentBytesPerSecond: Double?
}
struct MetricsSnapshot: Equatable, Sendable {
  var timestamp: Date
  var cpu: Double?; var ram: Double?; var disk: Double?; var gpu: Double?; var vram: Double?
  var memoryUsedBytes: Double?; var memoryTotalBytes: Double?
  var diskUsedBytes: Double?; var diskTotalBytes: Double?
  var gpus: [GPUReading]; var network: [NetworkRate]; var warnings: [String]
  func isStale(now: Date, interval: TimeInterval) -> Bool
}
struct RawMetrics: Sendable { /* collector fields owned by core */ }
enum MetricsParser { static func parse(_ output: String, timestamp: Date) throws -> RawMetrics }
enum MetricsCalculator { static func calculate(current: RawMetrics, previous: RawMetrics?) -> MetricsSnapshot }
```

TerminalBridge module interface supplied by root:
```swift
@MainActor public final class TerminalHost: ObservableObject {
  public init()
  public var error: String? { get }
  public func open(id: UUID, command: String, environment: [String: String] = [:]) // preserve existing surface for same id
  public func disconnect(id: UUID) // releases local surface only
  public func disconnectAll()
}
public struct TerminalPane: NSViewRepresentable {
  public init(host: TerminalHost, id: UUID)
}
```
UI owns `@MainActor AppModel: ObservableObject`, `public struct InfraRootView: View` init() with state, scheduler, persistence.
`InfraRootView` owns `TerminalHost` and opens remote terminal commands only on explicit open/reconnect; app launch must not create new remote sessions silently. The selected local tab may start its local shell immediately.
UI module entry `InfraRootView()` exposed public; App main calls it. Settings can be in root view sheets.

연결 라우팅: `kind`가 없는 기존 v1 프로필은 `ssh`로 decode한다. `local`은 예약된 단일 Mac 프로필에만 허용하며 SSH builder는 모두 거부한다. AppModel은 로컬 셸과 지표를 직접 라우팅하고 선택한 로컬 탭만 자동으로 셸을 연다. 원격 SSH/tmux 세션은 명시적인 사용자 동작에서만 연다.

로컬 셸의 홈·실행 경로는 고정 스크립트의 위치 인자로 전달한다. 로컬 CPU는 두 표본 차분, RAM은 캐시를 포함한 active+inactive+wired+compressed 페이지, 디스크는 홈의 단일 볼륨 용량이다. APFS 공유 용량을 여러 볼륨에서 합산하지 않는다. 로컬 GPU/VRAM/네트워크는 nil 또는 빈 배열로 미지원 상태를 유지한다.


저장 비밀번호 인증은 `SSHPasswordAuthentication.resolveTarget`으로 SSH 별칭을 확인하고, `context`로 저장 대상 일치를 검증한 뒤 `SSHCommandBuilder`의 `authentication` 인자로 전달한다. `manualAuthentication: true`는 기존 대화형 인증 경로다. `PasswordCredentialStore`는 키체인 저장·읽기·삭제의 테스트 경계이며 JSON 모델은 비밀번호를 포함하지 않는다. `ShellCommand.environment`는 비밀 없는 askpass 경로와 대상 참조만 전달한다. 번들의 `luluTerminalAskPass` wrapper가 독립 `luluTerminalKeychain --ssh-askpass` 도우미를 실행한다. 앱 실행파일의 기존 진입점은 호환성을 위해 유지한다. `SSHAuthenticationContext(... allowsKeychainInteraction: Bool = false)`와 `context`의 같은 인자는 비밀 없는 `LULUTERMINAL_KEYCHAIN_UI=allow|fail` 정책을 전달한다. 기본은 fail이며 사용자 명시 연결에서만 true를 전달한다. 사전 확인과 실제 터미널은 별도 SSH 프로세스라서 둘 다 명시 정책을 유지한다. 수집은 항상 기본값 false다. 도우미는 전역 Keychain UI 설정을 자신의 프로세스에만 적용하며 한 번 조회 후 종료한다. `KeychainCredentialStore.read(reference:)`도 기본적으로 UI를 금지한다. 권한 오류는 `SSHPasswordError.keychainAccessRequired` 및 비밀 없는 stderr marker로 전달하며, SSH 255에서 일반 비밀번호 오류와 구분한다. 기존 항목 키·payload·대상 검증은 바꾸지 않는다.


앱 생성 키 인증은 `SSHAuthenticationMethod.managedKey`와 선택적 `SSHAccount.managedKey`를 사용한다. `SSHManagedKeyReference(id: UUID = UUID(), target: SSHPasswordTarget)`는 비밀 없는 계정/대상 바인딩이다. `SSHManagedKeys`는 `keyURL(for:rootURL:)`, `validate(reference:server:account:)`, `setupCommand(server:account:reference:agentSocket:rootURL:)`, `unlockCommand(reference:agentSocket:rootURL:)`, `verificationCommand(server:account:reference:agentSocket:rootURL:)`를 제공한다. 명령은 ShellCommand이며 암호를 인자나 환경으로 받지 않는다.

SSH terminal/probe/monitor builder에는 선택적 `managedKeyAgentSocket`과 테스트용 `managedKeyRootURL`을 전달한다. AppModel은 별칭을 다시 해석하고 원래 target과 일치하는지 검증한 뒤 동일한 agent socket을 전달한다. 생성/잠금 해제 시트의 터미널 종료는 성공 신호가 아니며, 독립 검증 성공과 대상 재확인·상태 저장 성공이 인증 전환 조건이다. 기존 비밀번호 참조는 휴면 상태로 보존하며 managedKey 경로에서는 읽지 않는다.
