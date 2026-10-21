import CheckmateAssets
import Foundation
/// Why a connection is closed. Sent in `bye`; an unknown reason from a newer peer reads as `unknown`.
public enum NetworkByeReason:String,Codable,CaseIterable {
    case seatTaken,badSnapshot,slow,protocolVersion,malformed,timeout,rateLimited,notAllowed,full,busy,replaced,badCredential,gameOver,hostLeft,leaving
    /// The guest accepted other assistance terms than the game's (assistance plan A3). A 1.0 peer reads it as `unknown`.
    case assistanceChanged
    case unknown
    public init(from decoder:Decoder)throws {self=NetworkByeReason(rawValue:try decoder.singleValueContainer().decode(String.self)) ?? .unknown}
}
/// Why a command was refused (D2, D5). Sent in `rejected`; an unknown reason from a newer peer reads as `unknown`.
public enum NetworkRejectReason:String,Codable,CaseIterable {
    /// The command was made at another revision; a chunked snapshot follows.
    case stale
    case notYourTurn,illegal,notClaimable,noOffer
    /// The sender already has an open offer.
    case offerPending
    case gameOver
    /// The game is not running: the seat is reserved and not yet acknowledged, or the guest is away.
    case notRunning
    /// The command named another game.
    case wrongGame
    case unknown
    public init(from decoder:Decoder)throws {self=NetworkRejectReason(rawValue:try decoder.singleValueContainer().decode(String.self)) ?? .unknown}
}
/// A move the host applied, as every receiver sees it. `receiptFor` names the guest command it answers and goes only to
/// the guest; spectators never see it.
public struct NetworkMoved:Equatable {
    public let revision:Int,uci:String,san:String,hash:String
    public let clocks:NetworkClocks?,receiptFor:NetworkID?
    /// The mover said a hint was shown to them this turn (assistance plan A7). Goes to the guest and to spectators.
    public let assisted:Bool
    public init(revision:Int,uci:String,san:String,hash:String,clocks:NetworkClocks?,receiptFor:NetworkID?,assisted:Bool=false){self.revision=revision;self.uci=uci;self.san=san;self.hash=hash;self.clocks=clocks;self.receiptFor=receiptFor;self.assisted=assisted}
    func withoutReceipt()->NetworkMoved {NetworkMoved(revision:revision,uci:uci,san:san,hash:hash,clocks:clocks,receiptFor:nil,assisted:assisted)}
}
/// The only result a network game has (D5). It advances `revision`, like an applied move.
public struct NetworkEnded:Equatable {
    public let outcome:NetworkOutcome,revision:Int,clocks:NetworkClocks?
    public init(outcome:NetworkOutcome,revision:Int,clocks:NetworkClocks?){self.outcome=outcome;self.revision=revision;self.clocks=clocks}
}
/// Every message of D5's table. Guest/spectator → host first, then host → guest/spectator.
public enum NetworkMessage:Equatable {
    /// A spectator's carries no `claimID`; a guest's always does. A 1.1 guest also states the assistance terms it
    /// accepted (assistance plan A3); a 1.0 guest and a spectator state none. A 1.2 guest or spectator states its
    /// capabilities in every `hello` and `resume` (mini-games plan D7); a 1.1 one states none.
    case hello(name:String,appVersion:String,claimID:NetworkSecret?,assistance:NetworkAssistance?=nil,capabilities:NetworkCapabilities?=nil)
    case seatedAck
    case resume(gameID:NetworkGameID,credential:NetworkSecret,capabilities:NetworkCapabilities?=nil)
    case resync
    /// `assisted`: a hint was shown to the mover this turn (A7).
    case move(gameID:NetworkGameID,commandID:NetworkID,revision:Int,uci:String,assisted:Bool=false)
    /// Valid at any revision, so it carries none.
    case resign(gameID:NetworkGameID,commandID:NetworkID)
    case drawOffer(gameID:NetworkGameID,commandID:NetworkID,revision:Int)
    /// Names the offer it answers, so it carries no revision.
    case drawAnswer(gameID:NetworkGameID,commandID:NetworkID,offerID:NetworkID,accept:Bool)
    case claimDraw(gameID:NetworkGameID,commandID:NetworkID,revision:Int)
    case pong(nonce:NetworkID)
    case bye(NetworkByeReason)
    case seated(credential:NetworkSecret)
    case resumed
    case watching
    case snapshotBegin(snapshotID:NetworkID,revision:Int,hash:String,totalBytes:Int,parts:Int)
    case snapshotPart(snapshotID:NetworkID,index:Int,data:Data)
    case snapshotEnd(snapshotID:NetworkID)
    case moved(NetworkMoved)
    case rejected(commandID:NetworkID,reason:NetworkRejectReason)
    case drawOffered(NetworkDrawOffer)
    case drawDeclined(offerID:NetworkID)
    case clock(NetworkClocks)
    case ended(NetworkEnded)
    case ping(nonce:NetworkID)
    /// The `type` discriminator on the wire.
    public var type:String {
        switch self {
        case .hello:return "hello";case .seatedAck:return "seatedAck";case .resume:return "resume";case .resync:return "resync";case .move:return "move";case .resign:return "resign";case .drawOffer:return "drawOffer";case .drawAnswer:return "drawAnswer";case .claimDraw:return "claimDraw";case .pong:return "pong";case .bye:return "bye"
        case .seated:return "seated";case .resumed:return "resumed";case .watching:return "watching";case .snapshotBegin:return "snapshotBegin";case .snapshotPart:return "snapshotPart";case .snapshotEnd:return "snapshotEnd";case .moved:return "moved";case .rejected:return "rejected";case .drawOffered:return "drawOffered";case .drawDeclined:return "drawDeclined";case .clock:return "clock";case .ended:return "ended";case .ping:return "ping"
        }
    }
}
public enum NetworkCodecError:Error,Equatable,CustomStringConvertible {
    /// Over 16 KiB: refused before parsing, and never sent.
    case tooLarge(Int)
    /// The peer speaks another major version; `description` is the readable reason shown to the person.
    case protocolMismatch(peer:NetworkProtocolVersion)
    case malformed(String)
    /// The reason a receiver gives when it closes over this error.
    public var byeReason:NetworkByeReason {if case .protocolMismatch=self{return .protocolVersion};return .malformed}
    public var description:String {
        switch self {
        case .tooLarge(let bytes):return String(localized:"A network message of \(bytes) bytes is over the \(NetworkLimits.maximumMessageBytes)-byte limit.",bundle:.checkmate)
        case .protocolMismatch(let peer):return String(localized:"The other Mac uses Checkmate network protocol \(String(describing:peer)); this one uses \(String(describing:NetworkProtocolVersion.current)). Update Checkmate on both Macs to play together.",bundle:.checkmate)
        case .malformed(let detail):return String(localized:"A malformed network message: \(detail).",bundle:.checkmate)
        }
    }
}
/// JSON with a `type` discriminator and a `protocol` version on every message (D5). Unknown fields are ignored. Both
/// directions apply the same checks, so nothing is sent that a peer would refuse, and the 16 KiB check on the
/// complete encoded message is the authority.
public enum NetworkCodec {
    public static func encode(_ message:NetworkMessage)throws -> Data {
        let wire=Wire(message)
        _ = try wire.message()
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        let data=try encoder.encode(wire)
        guard data.count<=NetworkLimits.maximumMessageBytes else{throw NetworkCodecError.tooLarge(data.count)}
        return data
    }
    public static func decode(_ data:Data)throws -> NetworkMessage {
        guard data.count<=NetworkLimits.maximumMessageBytes else{throw NetworkCodecError.tooLarge(data.count)}
        // The version is read on its own first: a newer major may change any other field, and must still produce a
        // readable mismatch rather than a parse error.
        let header:Header
        do{header=try JSONDecoder().decode(Header.self,from:data)}catch{throw NetworkCodecError.malformed(String(localized:"no protocol version",bundle:.checkmate))}
        guard header.protocol.major==NetworkProtocolVersion.current.major else{throw NetworkCodecError.protocolMismatch(peer:header.protocol)}
        let wire:Wire
        do{wire=try JSONDecoder().decode(Wire.self,from:data)}catch{throw NetworkCodecError.malformed("invalid field")}
        return try wire.message()
    }
    private struct Header:Decodable {let `protocol`:NetworkProtocolVersion}
    /// The flat wire object: every field any message uses, each optional, so the synthesised coding ignores unknown
    /// keys and refuses a known key of the wrong type.
    private struct Wire:Codable {
        var type:String
        var `protocol`=NetworkProtocolVersion.current
        var name,appVersion,uci,san,hash,data:String?
        var claimID,credential:NetworkSecret?
        var gameID:NetworkGameID?
        var commandID,offerID,snapshotID,nonce,receiptFor:NetworkID?
        var revision,totalBytes,parts,index:Int?
        var accept:Bool?
        /// 1.1 (A4): written only when they say something, so a message without assistance has the 1.0 shape.
        var assistance:NetworkAssistance?
        var assisted:Bool?
        /// 1.2 (D7): written only when non-empty, sorted; bounded on decoding.
        var capabilities:[String]?
        var by:NetworkSide?
        var clocks:NetworkClocks?
        var reason:String?
        var result:NetworkGameResult?
        var termination:NetworkTermination?
        init(type:String){self.type=type}
        init(_ message:NetworkMessage){
            self.init(type:message.type)
            switch message {
            case .hello(let name,let appVersion,let claimID,let assistance,let capabilities):self.name=name;self.appVersion=appVersion;self.claimID=claimID;self.assistance=assistance;self.capabilities=Self.wire(capabilities)
            case .seatedAck,.resync,.resumed,.watching:break
            case .resume(let gameID,let credential,let capabilities):self.gameID=gameID;self.credential=credential;self.capabilities=Self.wire(capabilities)
            case .move(let gameID,let commandID,let revision,let uci,let assisted):self.gameID=gameID;self.commandID=commandID;self.revision=revision;self.uci=uci;self.assisted=assisted ? true:nil
            case .resign(let gameID,let commandID):self.gameID=gameID;self.commandID=commandID
            case .drawOffer(let gameID,let commandID,let revision),.claimDraw(let gameID,let commandID,let revision):self.gameID=gameID;self.commandID=commandID;self.revision=revision
            case .drawAnswer(let gameID,let commandID,let offerID,let accept):self.gameID=gameID;self.commandID=commandID;self.offerID=offerID;self.accept=accept
            case .pong(let nonce),.ping(let nonce):self.nonce=nonce
            case .bye(let reason):self.reason=reason.rawValue
            case .seated(let credential):self.credential=credential
            case .snapshotBegin(let snapshotID,let revision,let hash,let totalBytes,let parts):self.snapshotID=snapshotID;self.revision=revision;self.hash=hash;self.totalBytes=totalBytes;self.parts=parts
            case .snapshotPart(let snapshotID,let index,let data):self.snapshotID=snapshotID;self.index=index;self.data=data.base64EncodedString()
            case .snapshotEnd(let snapshotID):self.snapshotID=snapshotID
            case .moved(let moved):revision=moved.revision;uci=moved.uci;san=moved.san;hash=moved.hash;clocks=moved.clocks;receiptFor=moved.receiptFor;assisted=moved.assisted ? true:nil
            case .rejected(let commandID,let reason):self.commandID=commandID;self.reason=reason.rawValue
            case .drawOffered(let offer):offerID=offer.offerID;by=offer.by
            case .drawDeclined(let offerID):self.offerID=offerID
            case .clock(let clocks):self.clocks=clocks
            case .ended(let ended):result=ended.outcome.result;termination=ended.outcome.termination;revision=ended.revision;clocks=ended.clocks
            }
        }
        private static func wire(_ capabilities:NetworkCapabilities?)->[String]? {capabilities.flatMap{$0.tokens.isEmpty ? nil:$0.tokens}}
        private func capabilitiesValue()throws -> NetworkCapabilities? {
            guard let capabilities else{return nil}
            guard let value=NetworkCapabilities(capabilities) else{throw NetworkCodecError.malformed("invalid capabilities")}
            return value
        }
        private func need<T>(_ value:T?,_ field:String)throws -> T {guard let value else{throw NetworkCodecError.malformed("missing \(field)")};return value}
        private func check(_ condition:Bool,_ field:String)throws {guard condition else{throw NetworkCodecError.malformed("invalid \(field)")}}
        private func revisionValue()throws -> Int {let value=try need(revision,"revision");try check((0...NetworkLimits.maximumRevision).contains(value),"revision");return value}
        private func uciValue()throws -> String {let value=try need(uci,"uci");try check(ChessNotation.validUCI(value),"uci");return value}
        private func clocksValue()throws -> NetworkClocks? {try check(clocks?.valid ?? true,"clocks");return clocks}
        private func hashValue()throws -> String {let value=try need(hash,"hash");try check(!value.isEmpty && value.utf8.count<=NetworkLimits.maximumHashBytes && value.utf8.allSatisfy{(0x21...0x7E).contains($0)},"hash");return value}
        func message()throws -> NetworkMessage {
            switch type {
            case "hello":
                let name=try need(self.name,"name"),appVersion=try need(self.appVersion,"appVersion");try check(NetworkText.valid(name),"name");try check(NetworkText.valid(appVersion),"appVersion")
                return .hello(name:name,appVersion:appVersion,claimID:claimID,assistance:assistance,capabilities:try capabilitiesValue())
            case "seatedAck":return .seatedAck
            case "resume":return .resume(gameID:try need(gameID,"gameID"),credential:try need(credential,"credential"),capabilities:try capabilitiesValue())
            case "resync":return .resync
            case "move":return .move(gameID:try need(gameID,"gameID"),commandID:try need(commandID,"commandID"),revision:try revisionValue(),uci:try uciValue(),assisted:assisted ?? false)
            case "resign":return .resign(gameID:try need(gameID,"gameID"),commandID:try need(commandID,"commandID"))
            case "drawOffer":return .drawOffer(gameID:try need(gameID,"gameID"),commandID:try need(commandID,"commandID"),revision:try revisionValue())
            case "drawAnswer":return .drawAnswer(gameID:try need(gameID,"gameID"),commandID:try need(commandID,"commandID"),offerID:try need(offerID,"offerID"),accept:try need(accept,"accept"))
            case "claimDraw":return .claimDraw(gameID:try need(gameID,"gameID"),commandID:try need(commandID,"commandID"),revision:try revisionValue())
            case "pong":return .pong(nonce:try need(nonce,"nonce"))
            case "bye":return .bye(NetworkByeReason(rawValue:try need(reason,"reason")) ?? .unknown)
            case "seated":return .seated(credential:try need(credential,"credential"))
            case "resumed":return .resumed
            case "watching":return .watching
            case "snapshotBegin":
                let total=try need(totalBytes,"totalBytes"),count=try need(parts,"parts")
                try check((1...NetworkLimits.maximumSnapshotBytes).contains(total),"totalBytes");try check(count==(total+NetworkLimits.maximumSnapshotPartBytes-1)/NetworkLimits.maximumSnapshotPartBytes,"parts")
                return .snapshotBegin(snapshotID:try need(snapshotID,"snapshotID"),revision:try revisionValue(),hash:try hashValue(),totalBytes:total,parts:count)
            case "snapshotPart":
                let position=try need(index,"index"),text=try need(data,"data")
                try check((0..<NetworkLimits.maximumSnapshotParts).contains(position),"index")
                guard let bytes=Data(base64Encoded:text),!bytes.isEmpty,bytes.count<=NetworkLimits.maximumSnapshotPartBytes else{throw NetworkCodecError.malformed("invalid data")}
                return .snapshotPart(snapshotID:try need(snapshotID,"snapshotID"),index:position,data:bytes)
            case "snapshotEnd":return .snapshotEnd(snapshotID:try need(snapshotID,"snapshotID"))
            case "moved":
                let san=try need(self.san,"san");try check(NetworkText.valid(san,maximumBytes:NetworkLimits.maximumSANBytes),"san")
                return .moved(NetworkMoved(revision:try revisionValue(),uci:try uciValue(),san:san,hash:try hashValue(),clocks:try clocksValue(),receiptFor:receiptFor,assisted:assisted ?? false))
            case "rejected":return .rejected(commandID:try need(commandID,"commandID"),reason:NetworkRejectReason(rawValue:try need(reason,"reason")) ?? .unknown)
            case "drawOffered":return .drawOffered(NetworkDrawOffer(offerID:try need(offerID,"offerID"),by:try need(by,"by")))
            case "drawDeclined":return .drawDeclined(offerID:try need(offerID,"offerID"))
            case "clock":guard let clocks=try clocksValue() else{throw NetworkCodecError.malformed("missing clocks")};return .clock(clocks)
            case "ended":return .ended(NetworkEnded(outcome:NetworkOutcome(result:try need(result,"result"),termination:try need(termination,"termination")),revision:try revisionValue(),clocks:try clocksValue()))
            case "ping":return .ping(nonce:try need(nonce,"nonce"))
            default:throw NetworkCodecError.malformed("unknown type")
            }
        }
    }
}
/// The length prefix around each message (D5): a 4-byte big-endian length, then the JSON. The transport frames and
/// decodes with this on its own queue, not through an `NWProtocolFramer`; nothing here depends on Network.framework.
public enum NetworkFraming {
    public static let headerBytes=4
    public static func frame(_ message:Data)throws -> Data {
        guard (1...NetworkLimits.maximumMessageBytes).contains(message.count) else{throw NetworkFramingError.badLength(message.count)}
        let length=UInt32(message.count);return Data([UInt8(length>>24),UInt8(length>>16&0xFF),UInt8(length>>8&0xFF),UInt8(length&0xFF)])+message
    }
}
public enum NetworkFramingError:Error,Equatable {
    /// A declared length of zero or over 16 KiB: refused from the header alone, before any body is buffered.
    case badLength(Int)
}
/// Turns a peer's byte stream back into messages. It holds at most one partial frame, so at most 16 KiB plus a header
/// per peer (D7), and remembers when that frame began: a partial frame must complete within 5 s.
public struct NetworkFrameDecoder {
    private var buffer:[UInt8]=[]
    public private(set) var partialSince:NetworkInstant?
    public init(){}
    public var bufferedBytes:Int {buffer.count}
    public var partialFrameDeadline:NetworkInstant? {partialSince.map{$0+NetworkLimits.partialFrameDeadline}}
    public func partialFrameExpired(at now:NetworkInstant)->Bool {partialFrameDeadline.map{now>=$0} ?? false}
    /// Every frame the bytes complete, in order. A bad declared length throws, and the connection must close.
    public mutating func append(_ bytes:Data,at now:NetworkInstant)throws -> [Data] {
        var frames:[Data]=[],offset=0
        buffer.append(contentsOf:bytes)
        while buffer.count-offset>=NetworkFraming.headerBytes {
            let length=buffer[offset..<offset+4].reduce(0){$0<<8|Int($1)}
            guard (1...NetworkLimits.maximumMessageBytes).contains(length) else{buffer=[];partialSince=nil;throw NetworkFramingError.badLength(length)}
            guard buffer.count-offset-4>=length else{break}
            frames.append(Data(buffer[offset+4..<offset+4+length]));offset+=4+length
        }
        buffer.removeFirst(offset)
        if buffer.isEmpty {partialSince=nil}else if !frames.isEmpty || partialSince==nil {partialSince=now}
        return frames
    }
}
