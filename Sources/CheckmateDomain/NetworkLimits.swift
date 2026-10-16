import Foundation
/// A host monotonic instant: the time since an origin the Application fixes, read from `ContinuousClock`. The domain
/// never reads a clock itself, so every timing rule is a function of the instants it is handed (D6).
public struct NetworkInstant:Comparable,Hashable,CustomStringConvertible {
    public let sinceOrigin:Duration
    public init(_ sinceOrigin:Duration){self.sinceOrigin=sinceOrigin}
    public static let origin=NetworkInstant(.zero)
    public static func <(a:NetworkInstant,b:NetworkInstant)->Bool {a.sinceOrigin<b.sinceOrigin}
    public static func +(a:NetworkInstant,b:Duration)->NetworkInstant {NetworkInstant(a.sinceOrigin+b)}
    public static func -(a:NetworkInstant,b:NetworkInstant)->Duration {a.sinceOrigin-b.sinceOrigin}
    public var description:String {"t+\(sinceOrigin)"}
}
extension Duration {
    /// Whole milliseconds, truncated toward zero: the wire unit of every clock.
    var networkMilliseconds:Int {let (seconds,attoseconds)=components;return Int(seconds)*1000+Int(attoseconds/1_000_000_000_000_000)}
}
/// The protocol a message speaks. A major mismatch closes the connection with a readable reason; a minor bump may
/// add fields (which older peers ignore), never message types.
public struct NetworkProtocolVersion:Codable,Hashable,CustomStringConvertible {
    public let major:Int,minor:Int
    public init(major:Int,minor:Int){self.major=major;self.minor=minor}
    public static let current=NetworkProtocolVersion(major:1,minor:0)
    public var description:String {"\(major).\(minor)"}
}
/// Every bound of D5 and D7, fixed in advance. Tests assert these values.
public enum NetworkLimits {
    /// One message, JSON overhead included. The check on the complete encoded message is the authority (R4-3).
    public static let maximumMessageBytes=16*1024
    /// Every free string on the wire (names, app version), in UTF-8 bytes.
    public static let maximumNameBytes=64
    /// Raw bytes in one snapshot part: 12 KiB once Base64-encoded, leaving 4 KiB for the envelope.
    public static let maximumSnapshotPartBytes=9*1024
    /// One snapshot, and so one receiver's reassembly buffer (about 114 parts).
    public static let maximumSnapshotBytes=1024*1024
    public static let maximumSnapshotParts=(maximumSnapshotBytes+maximumSnapshotPartBytes-1)/maximumSnapshotPartBytes
    public static let maximumSANBytes=16,maximumHashBytes=128
    public static let maximumSpectators=8
    /// Outbound queue caps: bytes queued, held behind a snapshot, or handed to the transport and not yet completed.
    public static let peerQueueBytes=64*1024,spectatorQueuesBytes=512*1024
    public static let handshakesPerListener=4,pendingConnectionsPerListener=4
    public static let handshakeDeadline=Duration.seconds(5),admissionDeadline=Duration.seconds(5),partialFrameDeadline=Duration.seconds(5)
    public static let failedHandshakesPerAddress=5,failedHandshakeWindow=Duration.seconds(60)
    public static let inboundMessagesPerWindow=20,inboundWindow=Duration.seconds(1)
    public static let pingInterval=Duration.seconds(2),maximumOutstandingPings=2,pongDeadline=Duration.seconds(6)
    public static let storedReceipts=64
    public static let reservationDuration=Duration.seconds(30),holdDuration=Duration.seconds(120)
    public static let clockMessageInterval=Duration.seconds(1)
}
/// Free strings on the wire: 1 to 64 bytes of UTF-8 with no control characters (no newlines in a name tag). Public so
/// the host sheet refuses a name by the same rule the host and receivers apply.
public enum NetworkText {
    public static func valid(_ text:String,maximumBytes:Int=NetworkLimits.maximumNameBytes)->Bool {
        !text.isEmpty && text.utf8.count<=maximumBytes && !text.unicodeScalars.contains{$0.properties.generalCategory == .control}
    }
}
