# 작업 간 Swift 인터페이스

모든 Core 타입과 생성자는 public. 값 타입 Codable/Equatable/Sendable을 가능한 범위에서 채택한다.
비율은 0...1 Double?, nil은 unknown이며 0과 다르다. 핵심 구현자가 추가 필드를 넣어도 아래 이름은 유지한다.

```swift
struct SSHAccount: Identifiable, Codable, Equatable, Sendable {
  var id: UUID; var username: String
  init(id: UUID = UUID(), username: String)
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
  var executable: String; var arguments: [String]; var standardInput: String?
  init(executable: String, arguments: [String], standardInput: String? = nil)
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
  public func open(id: UUID, command: String) // preserve existing surface for same id
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
