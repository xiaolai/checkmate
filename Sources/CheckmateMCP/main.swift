import Foundation
import CheckmateMCPKit

@main struct CheckmateMCP {
    static func main() async {
        var file = Discovery.defaultURL
        let arguments = Array(CommandLine.arguments.dropFirst())
        if !arguments.isEmpty {
            guard arguments.count == 2, arguments[0] == "--connection-file" else {
                FileHandle.standardError.write(Data("Usage: CheckmateMCP [--connection-file path]\n".utf8)); exit(2)
            }
            file = URL(fileURLWithPath: arguments[1])
        }
        do { try await CompanionServer.run(connectionFile: file) }
        catch { FileHandle.standardError.write(Data("Checkmate companion stopped. Please reconnect.\n".utf8)); exit(1) }
    }
}
