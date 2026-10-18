import Foundation
/// Which systems show Play on Network (LAN-play plan D10): `minimumMacOS` and every later major, plus each older major
/// in `verifiedOlderMajors`. A major joins only when spike (e) has passed in a virtual machine of that version: macOS
/// 26.6.2 and 14.6.1 passed it (loopback TLS, the pinned suite, Bonjour browse and a Bonjour-resolved join). macOS 15
/// needs its own run. Later majors are assumed compatible and checked when the test hosts upgrade.
public enum NetworkPolicy {
    public static let minimumMacOS=26
    public static let verifiedOlderMajors:Set<Int>=[14]
    public static func available(onMajor major:Int)->Bool {major>=minimumMacOS || verifiedOlderMajors.contains(major)}
    /// A host may choose a game-library position to start from (mini-games plan D7, L1): `CHECKMATE_NETWORK_POSITIONS=1`.
    /// Off by default, so hosting uses the standard start exactly as protocol 1.1 does. Joining and watching a game
    /// from a declared start need no flag: every 1.2 build replays one.
    public static var positionsEnabled:Bool {ProcessInfo.processInfo.environment["CHECKMATE_NETWORK_POSITIONS"]=="1"}
    public static var availableHere:Bool {available(onMajor:ProcessInfo.processInfo.operatingSystemVersion.majorVersion)}
}
