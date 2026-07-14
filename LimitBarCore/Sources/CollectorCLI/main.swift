import Foundation
import LimitBarCore

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    print(try CollectorCommand.run(arguments))
} catch let error as CollectorCommandError {
    FileHandle.standardError.write(Data((error.description + "\n").utf8))
    exit(64)
} catch {
    FileHandle.standardError.write(Data(("Collector rejected event: \(error)\n").utf8))
    exit(65)
}
