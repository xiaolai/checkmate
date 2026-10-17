import Foundation
/// The guest's one pending move (D2): the piece is lifted, the target marked, "Sending…" shown, and further presses
/// are ignored until `moved` with its receipt, `rejected`, a snapshot or a reconnect clears it.
public struct NetworkPendingMove:Equatable {
    public let commandID:NetworkID,uci:String,revision:Int
    public var from:String {String(uci.prefix(2))}
    public var to:String {String(uci.dropFirst(2).prefix(2))}
}
/// What happened, for the interface (VoiceOver, sounds, banners). The receiver's state already reflects each one.
public enum NetworkReceiverEvent:Equatable {
    case seated,resumed,watching
    case installed(revision:Int)
    case applied(NetworkMoved,by:NetworkSide)
    case ended(NetworkOutcome)
    case offered(NetworkDrawOffer)
    case offerCleared(NetworkID)
    case rejected(commandID:NetworkID,reason:NetworkRejectReason)
    case closedByHost(NetworkByeReason)
}
/// The receiver's answer to one message: messages to send to the host, in order, and whether to close the connection
/// (with `bye(close)`).
public struct NetworkReceiverOutput:Equatable {
    public var send:[NetworkMessage]=[]
    public var close:NetworkByeReason?
    public var events:[NetworkReceiverEvent]=[]
    public init(){}
}
public enum NetworkReceiverRole:Equatable {
    /// A guest keeps its `claimID` in memory for the whole game (D4).
    case guest(claimID:NetworkSecret)
    case spectator
}
/// A guest's or spectator's view of a network game (D2, D5). The board changes only through a verified snapshot or the
/// next applied `moved`; it never moves optimistically.
///
/// Revisions are checked against the current applied revision (R5-1): a `moved` at or below it is a duplicate and only
/// clears a pending move whose receipt it carries; exactly one above is applied; further above is a gap, discarded,
/// and answered with one `resync` until a snapshot arrives.
public final class NetworkReceiver {
    public let gameID:NetworkGameID,role:NetworkReceiverRole
    private let name:String,appVersion:String,factory:NetworkRulesFactory,hashing:NetworkHashing,random:NetworkRandom
    /// The terms a guest accepted before joining (assistance plan A3), stated in `hello` and checked against every
    /// snapshot. A spectator accepts nothing: it never gets assistance.
    public let accepted:NetworkAssistance
    /// The record as last installed; the live position is `rules`, and `revision`, `openOffer`, `outcome` are current.
    public private(set) var installed:NetworkPublicGame?
    private var rules:(any NetworkChessRules)?
    public private(set) var revision:Int?,fen:String?
    public private(set) var openOffer:NetworkDrawOffer?,outcome:NetworkOutcome?
    public private(set) var pendingMove:NetworkPendingMove?
    /// The plies whose mover said a hint was shown that turn (A7), as installed and then applied.
    public private(set) var assistedPlies:[Int]=[]
    /// The guest's seat credential, from `seated`. Held in memory only; redacted in every description.
    public private(set) var credential:NetworkSecret?
    private var assembler:NetworkSnapshotAssembler?,resyncRequested=false,acknowledgeAfterSnapshot=false
    private var clockSync:(clocks:NetworkClocks,at:NetworkInstant)?
    public init(gameID:NetworkGameID,role:NetworkReceiverRole,name:String,appVersion:String,rules:NetworkRulesFactory,hashing:NetworkHashing,random:NetworkRandom = .system,accepting accepted:NetworkAssistance = .off){self.gameID=gameID;self.role=role;self.name=name;self.appVersion=appVersion;factory=rules;self.hashing=hashing;self.random=random;self.accepted=accepted}
    /// The guest's side, once a snapshot says which side the host took.
    public var side:NetworkSide? {guard case .guest=role else{return nil};return installed?.hostSide.opponent}
    /// The first message on every new connection: a guest holding a credential always resumes (R4-4); otherwise it
    /// claims with its `claimID`. A spectator says hello without one.
    public func opening()->NetworkMessage {
        switch role {
        case .guest(let claimID):return credential.map{.resume(gameID:gameID,credential:$0)} ?? .hello(name:name,appVersion:appVersion,claimID:claimID,assistance:accepted)
        case .spectator:return .hello(name:name,appVersion:appVersion,claimID:nil)
        }
    }
    /// The connection is gone. A reconnect clears the pending move; the board stays until the next snapshot.
    public func connectionLost(){pendingMove=nil;assembler=nil;resyncRequested=false;acknowledgeAfterSnapshot=false}
    /// The live record, for the review hand-off and the crash file.
    public func publicGame(at now:NetworkInstant)throws -> NetworkPublicGame? {
        guard var game=installed,let rules,let revision else{return nil}
        game.revision=revision;game.pgn=try rules.networkPGN();game.clocks=clocks(at:now);game.openOffer=openOffer;game.outcome=outcome;game.assistedPlies=assistedPlies
        return game
    }
    /// Both clocks counting down locally from the last value the host sent (cosmetic, D6).
    public func clocks(at now:NetworkInstant)->NetworkClocks? {
        guard var clocks=clockSync?.clocks,let at=clockSync?.at else{return nil}
        if let side=clocks.active,now>at {let left=max(0,clocks.remaining(side)-(now-at).networkMilliseconds);if side == .white {clocks.white=left}else{clocks.black=left}}
        return clocks
    }
    /// One framed message's payload. A message that does not decode closes the connection with its reason.
    public func receive(_ data:Data,at now:NetworkInstant)throws -> NetworkReceiverOutput {
        let message:NetworkMessage
        do{message=try NetworkCodec.decode(data)}catch let error as NetworkCodecError{var output=NetworkReceiverOutput();output.close=error.byeReason;return output}
        return try receive(message:message,at:now)
    }
    /// A rules failure on this Mac's own scratch game throws; everything the host sent wrong closes or resyncs.
    public func receive(message:NetworkMessage,at now:NetworkInstant)throws -> NetworkReceiverOutput {
        var output=NetworkReceiverOutput()
        if case .bye(let reason)=message {output.events.append(.closedByHost(reason));return output}
        // Every other message for this peer waits behind the snapshot's end at the host, so anything else arriving
        // mid-snapshot breaks the protocol.
        if assembler != nil {
            switch message {
            case .snapshotPart(let snapshotID,let index,let data):
                do{try assembler!.add(snapshotID:snapshotID,index:index,data:data)}catch{output.close = .badSnapshot}
            case .snapshotEnd(let snapshotID):try finishSnapshot(snapshotID,at:now,&output)
            default:output.close = .badSnapshot
            }
            return output
        }
        switch message {
        case .seated(let credential):
            guard case .guest=role,self.credential==nil || self.credential!.matches(credential) else{output.close = .malformed;break}
            self.credential=credential;acknowledgeAfterSnapshot=true;output.events.append(.seated)
        case .resumed:guard case .guest=role,credential != nil else{output.close = .malformed;break};output.events.append(.resumed)
        case .watching:guard role == .spectator else{output.close = .malformed;break};output.events.append(.watching)
        case .snapshotBegin(let snapshotID,let revision,let hash,let totalBytes,let parts):
            do{assembler=try NetworkSnapshotAssembler(snapshotID:snapshotID,revision:revision,hash:hash,totalBytes:totalBytes,parts:parts)}catch{output.close = .badSnapshot}
        case .snapshotPart,.snapshotEnd:output.close = .badSnapshot
        case .moved(let moved):try apply(moved,at:now,&output)
        case .ended(let ended):
            guard let current=revision else{requestResync(&output);break}
            if ended.revision<=current {break}
            guard ended.revision==current+1 else{requestResync(&output);break}
            revision=ended.revision;outcome=ended.outcome;openOffer=nil;pendingMove=nil
            if let clocks=ended.clocks {clockSync=(clocks,now)}
            output.events.append(.ended(ended.outcome))
        case .drawOffered(let offer):guard revision != nil,outcome==nil else{break};openOffer=offer;output.events.append(.offered(offer))
        case .drawDeclined(let offerID):if openOffer?.offerID==offerID {openOffer=nil;output.events.append(.offerCleared(offerID))}
        case .clock(let clocks):clockSync=(clocks,now)
        case .rejected(let commandID,let reason):
            if pendingMove?.commandID==commandID {pendingMove=nil}
            output.events.append(.rejected(commandID:commandID,reason:reason))
        case .ping(let nonce):output.send.append(.pong(nonce:nonce))
        case .hello,.seatedAck,.resume,.resync,.move,.resign,.drawOffer,.drawAnswer,.claimDraw,.pong,.bye:output.close = .malformed
        }
        return output
    }
    private func requestResync(_ output:inout NetworkReceiverOutput){guard !resyncRequested else{return};resyncRequested=true;output.send.append(.resync)}
    private func finishSnapshot(_ snapshotID:NetworkID,at now:NetworkInstant,_ output:inout NetworkReceiverOutput)throws {
        let assembled=assembler!;assembler=nil
        let result:NetworkSnapshotInstaller.Installed
        do{result=try NetworkSnapshotInstaller.install(try assembled.finish(snapshotID:snapshotID),revision:assembled.revision,hash:assembled.hash,gameID:gameID,rules:factory,hashing:hashing)}
        catch is NetworkSnapshotError{output.close = .badSnapshot;return}
        // A3: a guest plays only under the terms it accepted. Other terms are never installed, and a claim is never
        // acknowledged under them, so the reservation lapses (D4).
        if case .guest=role,result.game.assistance != accepted {acknowledgeAfterSnapshot=false;output.close = .assistanceChanged;return}
        installed=result.game;assistedPlies=result.game.assistedPlies;rules=result.rules;fen=result.fen;revision=result.game.revision
        openOffer=result.game.openOffer;outcome=result.game.outcome;pendingMove=nil;resyncRequested=false
        clockSync=result.game.clocks.map{($0,now)}
        output.events.append(.installed(revision:result.game.revision))
        if acknowledgeAfterSnapshot {acknowledgeAfterSnapshot=false;output.send.append(.seatedAck)}
    }
    private func apply(_ moved:NetworkMoved,at now:NetworkInstant,_ output:inout NetworkReceiverOutput)throws {
        guard let current=revision,let rules else{requestResync(&output);return}
        if moved.revision<=current {
            if let receipt=moved.receiptFor,pendingMove?.commandID==receipt {pendingMove=nil}
            return
        }
        // Waiting for the snapshot a resync asked for: it holds these moves, and the local rules may already disagree.
        guard !resyncRequested else{return}
        guard moved.revision==current+1,outcome==nil else{requestResync(&output);return}
        let mover=try rules.networkSideToMove(),before=try rules.networkPGN()
        do{_ = try rules.networkPlay(uci:moved.uci)}catch NetworkRulesError.illegalMove{requestResync(&output);return}
        let fen=try rules.networkFEN()
        // A position that disagrees with the host's is never shown, nor kept in the record: the rules go back to the
        // last agreed game until the snapshot the resync brings replaces it.
        guard hashing.positionHash(fen:fen,revision:moved.revision)==moved.hash else{try rules.networkLoad(pgn:before);requestResync(&output);return}
        self.fen=fen;revision=moved.revision
        if moved.assisted {assistedPlies.append(moved.revision)}
        if let offer=openOffer,offer.by != mover {openOffer=nil}
        if let receipt=moved.receiptFor,pendingMove?.commandID==receipt {pendingMove=nil}
        if let clocks=moved.clocks {clockSync=(clocks,now)}
        output.events.append(.applied(moved,by:mover))
    }
    // Guest commands: each carries the game, a fresh 128-bit commandID and the current revision (D2).
    private var playable:Bool {if case .guest=role,revision != nil,outcome==nil,assembler==nil,!resyncRequested {return true};return false}
    /// The move to send, or nil when the press is ignored: a move is already pending, it is not the guest's turn, or
    /// there is no game to play.
    /// `assisted`: a hint was shown to this player during this turn (A7).
    public func submitMove(uci:String,assisted:Bool=false)throws -> NetworkMessage? {
        guard playable,pendingMove==nil,ChessNotation.validUCI(uci),let revision,let rules,let side,try rules.networkSideToMove()==side else{return nil}
        let commandID=NetworkID.random(using:random);pendingMove=NetworkPendingMove(commandID:commandID,uci:uci,revision:revision)
        return .move(gameID:gameID,commandID:commandID,revision:revision,uci:uci,assisted:assisted)
    }
    public func resign()->NetworkMessage? {guard playable else{return nil};return .resign(gameID:gameID,commandID:.random(using:random))}
    public func offerDraw()->NetworkMessage? {guard playable,let revision else{return nil};return .drawOffer(gameID:gameID,commandID:.random(using:random),revision:revision)}
    /// Answers the open offer the opponent made; nil when there is none.
    public func answerDraw(accept:Bool)->NetworkMessage? {guard playable,let offer=openOffer,offer.by != side else{return nil};return .drawAnswer(gameID:gameID,commandID:.random(using:random),offerID:offer.offerID,accept:accept)}
    public func claimDraw()->NetworkMessage? {guard playable,let revision else{return nil};return .claimDraw(gameID:gameID,commandID:.random(using:random),revision:revision)}
}
