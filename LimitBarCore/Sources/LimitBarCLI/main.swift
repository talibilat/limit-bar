import Foundation
import LimitBarCore

let publicationURL = ProcessInfo.processInfo.environment["LIMITBAR_CAPACITY_STATE_FILE"].map(URL.init(fileURLWithPath:))
let result = CapacityCommand.run(
    Array(CommandLine.arguments.dropFirst()),
    defaultPublicationURL: publicationURL
)
FileHandle.standardOutput.write(Data((result.output + "\n").utf8))
exit(result.exitCode)
