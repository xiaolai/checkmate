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
    /// 1.1 adds the assistance terms and the assisted flags (assistance plan A4); a 1.0 peer ignores them. 1.2 adds the
    /// capabilities on `hello` and `resume` and a declared start (mini-games plan D7, `docs/network-protocol-1.2.md`);
    /// a 1.1 peer ignores them, and a game it could not replay refuses it before anything is sent.
    public static let current=NetworkProtocolVersion(major:1,minor:2)
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
    /// The highest revision a peer may state. Each move and the end advance it by one (D2), and the 75-move rule and
    /// fivefold repetition end every game well under 20,000 plies, so this leaves room while keeping `revision+1`, and
    /// every count derived from a revision, far from overflow whatever a peer sends.
    public static let maximumRevision=1_000_000
    /// The most moves a network game can hold. The host's rules end every game automatically at the 75-move rule: 150
    /// plies with no capture and no pawn move. A game has at most 126 plies that capture or move a pawn (30 captures,
    /// two kings never taken; 16 pawns of at most 6 moves each), so at most 127 stretches of under 150 plies: fewer
    /// than 127 × 150 = 19,050 plies. 20,000 adds a margin. A snapshot claiming more is refused before any replay, so
    /// the work one snapshot can cost a receiver is bounded by a game that could really be played.
    public static let maximumPlies=20_000
    /// The longest record a snapshot of `moves` plies may carry. The host's record is its rules' own export: movetext of
    /// move numbers and SAN, at most about 12 bytes a ply ("1234. Qa1xh8+ Qh8xa1+" is 21 bytes for two), with no tag
    /// pairs of its own. 16 bytes a ply plus 4 KiB for tags is a margin over any record a host writes, and it bounds the
    /// replay's work by size, whatever the layout: movetext hidden on a tag line or in a comment counts too.
    public static func maximumRecordBytes(moves:Int)->Int {4096+16*moves}
    /// Snapshots a receiver did not ask for (D5: a spectator's refresh when the guest's name changes) in any window of
    /// `unsolicitedSnapshotWindow`. A refresh is rare, so a host replaying snapshots at a receiver is cut off.
    public static let unsolicitedSnapshotsPerWindow=4,unsolicitedSnapshotWindow=Duration.seconds(10)
    public static let maximumSpectators=8
    /// Outbound queue caps: bytes queued, held behind a snapshot, or handed to the transport and not yet completed.
    public static let peerQueueBytes=64*1024,spectatorQueuesBytes=512*1024
    /// D7: everything the host buffers stays under this: queues, sends in flight, partial inbound frames and the
    /// records held for snapshots (`NetworkHostLimits.retainedCaptureBytes` is what is left for those).
    public static let hostBufferBytes=1024*1024
    public static let handshakesPerListener=4,pendingConnectionsPerListener=4
    public static let handshakeDeadline=Duration.seconds(5),admissionDeadline=Duration.seconds(5),partialFrameDeadline=Duration.seconds(5)
    public static let failedHandshakesPerAddress=5,failedHandshakeWindow=Duration.seconds(60)
    public static let inboundMessagesPerWindow=20,inboundWindow=Duration.seconds(1)
    public static let pingInterval=Duration.seconds(2),maximumOutstandingPings=2,pongDeadline=Duration.seconds(6)
    public static let storedReceipts=64
    public static let reservationDuration=Duration.seconds(30),holdDuration=Duration.seconds(120)
    public static let clockMessageInterval=Duration.seconds(1)
}
/// Free strings on the wire: 1 to 64 bytes of UTF-8 with no control characters and no line or paragraph separators
/// (no line breaks in a name tag, U+2028 and U+2029 included). Public so
/// the host sheet refuses a name by the same rule the host and receivers apply.
public enum NetworkText {
    public static func valid(_ text:String,maximumBytes:Int=NetworkLimits.maximumNameBytes)->Bool {
        !text.isEmpty && text.utf8.count<=maximumBytes && !text.unicodeScalars.contains{[.control,.lineSeparator,.paragraphSeparator].contains($0.properties.generalCategory)}
    }
}
