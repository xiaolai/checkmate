import CheckmateContent
import Foundation

/// What this Mac has for voice (V-5), read from the file system only: no process is started and nothing is sent.
/// Either the Codex app or a Codex sign-in file is enough to try; with neither, voice can only fail, so it is explained.
public struct VoiceCapability:Equatable,Sendable {
    public let codexInstalled:Bool,signInFileFound:Bool
    public init(codexInstalled:Bool,signInFileFound:Bool){self.codexInstalled=codexInstalled;self.signInFileFound=signInFileFound}
    public var usable:Bool {codexInstalled || signInFileFound}
    public static func current(home:URL=FileManager.default.homeDirectoryForCurrentUser,environment:[String:String]=ProcessInfo.processInfo.environment)->VoiceCapability {
        let signIn=VoiceGateway.credentialURL(environment:environment,home:home)
        return VoiceCapability(codexInstalled:CompanionInstallation.installedCodex(home:home,environment:environment) != nil,signInFileFound:FileManager.default.fileExists(atPath:signIn.path))
    }
}
