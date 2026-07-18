import Foundation
import LimitBarCore

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "recovery", arguments.dropFirst().first == "import" {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    do {
        let checkpoint = try RecoveryCheckpointCodec.decode(input)
        let storeURL = ProcessInfo.processInfo.environment["LIMITBAR_RECOVERY_INBOX_FILE"]
            .map(URL.init(fileURLWithPath:))
        let store = try storeURL.map(RecoveryInboxStore.init(destination:)) ?? RecoveryInboxStore.production()
        let outcome = try store.submit(checkpoint)
        FileHandle.standardOutput.write(Data("{\"result\":\"\(outcome.rawValue)\"}\n".utf8))
        exit(outcome == .conflict ? 65 : 0)
    } catch let error as RecoveryCheckpointError {
        let reason: String = switch error {
        case .prohibitedField: "prohibited_field"
        case .unsupportedVersion: "unsupported_version"
        case .tooLarge: "too_large"
        case .malformed, .invalidValue: "invalid_checkpoint"
        }
        FileHandle.standardOutput.write(Data("{\"result\":\"rejected\",\"reason\":\"\(reason)\"}\n".utf8))
        exit(65)
    } catch {
        FileHandle.standardOutput.write(Data("{\"result\":\"unavailable\"}\n".utf8))
        exit(74)
    }
} else if arguments.first == "recovery", arguments.dropFirst().first == "fingerprint" {
    guard arguments.count == 4, arguments[2] == "--workspace" else {
        FileHandle.standardOutput.write(Data("{\"result\":\"invalid_invocation\"}\n".utf8))
        exit(64)
    }
    do {
        let locations = try LimitBarFileLocations.production()
        let keyURL = ProcessInfo.processInfo.environment["LIMITBAR_RECOVERY_FINGERPRINT_KEY_FILE"]
            .map(URL.init(fileURLWithPath:)) ?? locations.recoveryFingerprintKey
        let key = try RecoveryWorkspaceFingerprint.loadOrCreateKey(at: keyURL)
        let fingerprint = try RecoveryWorkspaceFingerprint.make(workspace: URL(fileURLWithPath: arguments[3]), key: key)
        FileHandle.standardOutput.write(Data((fingerprint + "\n").utf8))
        exit(0)
    } catch {
        FileHandle.standardOutput.write(Data("{\"result\":\"workspace_unavailable\"}\n".utf8))
        exit(66)
    }
} else {
    let publicationURL = ProcessInfo.processInfo.environment["LIMITBAR_CAPACITY_STATE_FILE"].map(URL.init(fileURLWithPath:))
    let result = CapacityCommand.run(arguments, defaultPublicationURL: publicationURL)
    FileHandle.standardOutput.write(Data((result.output + "\n").utf8))
    exit(result.exitCode)
}
