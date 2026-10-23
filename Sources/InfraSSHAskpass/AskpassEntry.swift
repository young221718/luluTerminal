import Foundation
import Darwin

@main enum InfraSSHAskpassEntry {
    static func main() {
        exit(SSHPasswordAuthentication.respondToAskpass(arguments: CommandLine.arguments,
                                                      environment: ProcessInfo.processInfo.environment))
    }
}
