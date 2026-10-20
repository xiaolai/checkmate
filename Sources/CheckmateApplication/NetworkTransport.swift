import CheckmateDomain
import Foundation
/// Where a listener can be reached. Opaque here: each transport makes its own, from a listener or a discovery result,
/// and reads back only its own. `description` is for logs and tests.
public struct NetworkEndpoint:Hashable,CustomStringConvertible {
    public let value:AnyHashable
    public let description:String
    public init(_ value:AnyHashable,description:String){self.value=value;self.description=description}
}
/// What keys one listener (D3). The pre-shared key is HKDF-SHA256 with the code as input key material, the game ID as
/// salt and `info` naming the role; the PSK identity is the game ID. A wrong code, game or role makes another key, so
/// the handshake fails closed. The code is never described.
public struct NetworkAccessKey:Equatable,CustomStringConvertible {
    public let gameID:NetworkGameID,role:NetworkListenerRole,code:NetworkCode
    public init(gameID:NetworkGameID,role:NetworkListenerRole,code:NetworkCode){self.gameID=gameID;self.role=role;self.code=code}
    /// HKDF's `info`: "checkmate-lan v1 seat" or "checkmate-lan v1 watch".
    public var info:String {"checkmate-lan v1 \(role.rawValue)"}
    public var description:String {"NetworkAccessKey(\(gameID), \(role.rawValue), code redacted)"}
}
/// D7's transport bounds and the connect deadline. Always `standard` in the app; tests shorten the deadlines.
public struct NetworkTransportLimits:Equatable {
    /// TLS handshakes in progress per listener; a connection beyond them is dropped before TLS.
    public var handshakesPerListener=NetworkLimits.handshakesPerListener
    public var handshakeDeadline=NetworkLimits.handshakeDeadline
    /// Failed or timed-out handshakes per remote address within the window; past them its connections are dropped.
    public var failedHandshakesPerAddress=NetworkLimits.failedHandshakesPerAddress
    public var failedHandshakeWindow=NetworkLimits.failedHandshakeWindow
    /// A frame begun must complete within this, or the connection closes with `bye(timeout)`.
    public var partialFrameDeadline=NetworkLimits.partialFrameDeadline
    /// How long an outbound connection may take to become ready. macOS can refuse one silently, leaving it preparing
    /// for ever (spike finding (c)); at the deadline it fails as `timedOut`.
    public var connectDeadline=Duration.seconds(10)
    /// How long a closing connection waits for its farewell `bye` to be taken before it is cancelled anyway.
    public var farewellDeadline=Duration.seconds(1)
    public init(){}
    public static let standard=NetworkTransportLimits()
}
/// One hosted game's listeners (D3): the seat listener keyed from the play code and, when spectators are allowed, the
/// watch listener keyed from the watch code, each advertised with TXT `game=<id>`, `role=seat|watch` and the
/// assistance terms as `assist=<w><b>` (assistance plan A3; display only).
public struct NetworkHostingConfiguration:Equatable {
    public let gameID:NetworkGameID
    public let seatCode:NetworkCode
    /// Nil when spectators are not allowed: then no watch listener opens.
    public let watchCode:NetworkCode?
    /// The seat instance's Bonjour name ("Ana's game"); the watch instance adds " · watch". Untrusted on the other
    /// side, where games are told apart by game ID.
    public let serviceName:String
    /// The game's terms, published for the list to show. The key does not cover them, so they decide nothing (A3).
    public let assistance:NetworkAssistance
    /// A mini-game's ruleset descriptor (protocol 1.3), published as `variant` for the list's label only; nil for chess,
    /// whose TXT entries stay exactly 1.2's. The key does not cover it, so it decides nothing.
    public let variant:String?
    public init(gameID:NetworkGameID,seatCode:NetworkCode,watchCode:NetworkCode?,serviceName:String,assistance:NetworkAssistance = .off,variant:String?=nil){self.gameID=gameID;self.seatCode=seatCode;self.watchCode=watchCode;self.serviceName=serviceName;self.assistance=assistance;self.variant=variant}
    /// Every TXT entry one listener publishes.
    public func txt(_ role:NetworkListenerRole)->[String:String] {var entries=["game":gameID.text,"role":role.rawValue,"assist":assistance.txt];entries["variant"]=variant;return entries}
    public var roles:[NetworkListenerRole] {watchCode==nil ? [.seat]:[.seat,.watch]}
    public func key(_ role:NetworkListenerRole)->NetworkAccessKey? {
        switch role {case .seat:return NetworkAccessKey(gameID:gameID,role:.seat,code:seatCode);case .watch:return watchCode.map{NetworkAccessKey(gameID:gameID,role:.watch,code:$0)}}
    }
    public static let watchSuffix=" · watch"
    /// Bonjour instance names are at most 63 bytes of UTF-8; the name is cut at a character so the suffix fits.
    public func serviceName(for role:NetworkListenerRole)->String {
        let suffix=role == .watch ? Self.watchSuffix:""
        var name=serviceName.isEmpty ? "Checkmate game":serviceName
        while name.utf8.count+suffix.utf8.count>63 {name.removeLast()}
        return name+suffix
    }
}
/// One connection as the transport knows it. Numbers are never reused within one hosting, so an event for a number the
/// runner has let go of is recognisably stale (D4).
public struct NetworkTransportConnection:Hashable,CustomStringConvertible {
    public let number:UInt64
    public init(number:UInt64){self.number=number}
    public var description:String {"transport connection \(number)"}
}
public enum NetworkHostingEvent:Equatable {
    /// Every listener is ready at these endpoints (a loopback test or an injected discovery source connects to them).
    case listening([NetworkListenerRole:NetworkEndpoint])
    /// A listener failed; the hosting cannot take connections.
    case listenerFailed(NetworkListenerRole,String)
    /// TLS 1.2 at the pinned suite completed on that role's listener; the role comes from the listener alone (D3).
    case accepted(NetworkTransportConnection,NetworkListenerRole)
    /// One frame's payload, in arrival order.
    case received(NetworkTransportConnection,Data)
    /// The send handed over last on this connection was taken by the system.
    case sent(NetworkTransportConnection)
    /// The connection closed by itself: the peer left, the link failed, or the peer broke a framing bound (D7). It is
    /// the connection's last event.
    case closed(NetworkTransportConnection)
}
/// Why an outbound connection ended. Before `ready` it never connected; after `ready` it ends as `lost`.
public enum NetworkLinkFailure:Error,Equatable {
    /// Not ready within the connect deadline. D11 allows no guess at the cause: "couldn't reach".
    case timedOut
    /// Refused, reset or unresolved before TLS.
    case unreachable
    /// TLS failed. Usually a wrong code; the host also drops an address after too many failures (D7).
    case handshakeFailed
    /// TLS completed at something other than TLS 1.2 with suite 0xCCAC, so it was closed.
    case insecure
    /// After `ready`: the peer closed, the link failed, or the peer broke a framing bound.
    case lost
}
public enum NetworkLinkEvent:Equatable {
    /// macOS denied local-network access (TN3179, D11). The connection keeps waiting and goes on by itself once access
    /// is granted; the connect deadline restarts then.
    case denied
    case ready
    case received(Data)
    case sent
    /// The link is over; nothing follows.
    case closed(NetworkLinkFailure)
}
/// The network as the runners see it (D13). Network.framework implements it in CheckmateMacPlatform and
/// `NetworkMemoryTransport` in memory; both honour the same contracts:
/// - every event arrives on the transport's scheduler, never during a call into the transport;
/// - one send at a time per connection: the next only after its `sent`; a second is a programming error and traps;
/// - a send to a connection that has closed is dropped, and its `closed` event is or was delivered;
/// - after a local `close`, no event for that connection;
/// - an outbound connection ends in `ready` or `closed` within the connect deadline, except while `denied`.
public protocol NetworkTransport:AnyObject {
    func startHosting(_ configuration:NetworkHostingConfiguration,events:@escaping (NetworkHostingEvent)->Void)throws -> any NetworkHosting
    func connect(to endpoint:NetworkEndpoint,key:NetworkAccessKey,events:@escaping (NetworkLinkEvent)->Void)->any NetworkLink
}
public protocol NetworkHosting:AnyObject {
    /// Frames one encoded message (4-byte big-endian length) and sends it.
    func send(_ message:Data,on connection:NetworkTransportConnection)
    /// Sends `farewell` (an encoded `bye`) if the connection can still take it, then cancels it.
    func close(_ connection:NetworkTransportConnection,farewell:Data?)
    /// Closes the listeners, and their Bonjour records with them. Accepted connections stay until closed.
    func stopListening()
    /// Closes the listeners and cancels every open connection; connections already closing finish their farewell. No
    /// event follows.
    func shutdown()
    /// Transport buffer bytes held now (D7): inbound partial frames, plus outbound bytes handed to the system and not
    /// yet taken.
    var bufferedBytes:Int {get}
}
public protocol NetworkLink:AnyObject {
    func send(_ message:Data)
    func close(farewell:Data?)
    var bufferedBytes:Int {get}
}
