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
    /// What this Mac states in every `hello` and `resume` (mini-games plan D7).
    public let capabilities:NetworkCapabilities
    /// The start the first installed snapshot declared (D7), canonical; every later snapshot must declare the same one.
    /// Kept across reconnects, like the board.
    public private(set) var pinnedStart:String?
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
    /// This connection was let in: `seated`, `resumed` or `watching` arrived. The host sends a snapshot only after one
    /// of them (D5), so a snapshot before it breaks the protocol.
    private var admitted=false
    /// This connection's snapshot is installed. The host sends a newly admitted peer its snapshot before anything else
    /// about the game (D5), so game news before it, on a connection whose earlier board is only remembered, is refused.
    private var synced=false
    /// The host's messages that neither advance the game nor answer this Mac: at most D7's 20 a second, so a host
    /// cannot flood this Mac with valid but pointless frames (clocks, duplicates) that each cost a status, a record
    /// export and a delivery. A move or result that can advance the game is bounded by the game itself, and the answer
    /// to a pending move or a snapshot this Mac asked for by what it asked; a burst of them is ordinary, such as the
    /// moves held behind a snapshot arriving together after it. An admission comes once per connection.
    private var inboundRate=NetworkRateWindow()
    /// Snapshots this Mac did not ask for: each costs a full replay, so they have their own, much smaller, bound.
    private var unsolicitedSnapshots=NetworkRateWindow(limit:NetworkLimits.unsolicitedSnapshotsPerWindow,window:NetworkLimits.unsolicitedSnapshotWindow)
    private var clockSync:(clocks:NetworkClocks,at:NetworkInstant)?
    public init(gameID:NetworkGameID,role:NetworkReceiverRole,name:String,appVersion:String,rules:NetworkRulesFactory,hashing:NetworkHashing,random:NetworkRandom = .system,accepting accepted:NetworkAssistance = .off,capabilities:NetworkCapabilities = .supported){self.gameID=gameID;self.role=role;self.name=name;self.appVersion=appVersion;factory=rules;self.hashing=hashing;self.random=random;self.accepted=accepted;self.capabilities=capabilities}
    /// The guest's side, once a snapshot says which side the host took.
    public var side:NetworkSide? {guard case .guest=role else{return nil};return installed?.hostSide.opponent}
    /// The first message on every new connection: a guest holding a credential always resumes (R4-4); otherwise it
    /// claims with its `claimID`. A spectator says hello without one.
    public func opening()->NetworkMessage {
        switch role {
        case .guest(let claimID):return credential.map{.resume(gameID:gameID,credential:$0,capabilities:stated)} ?? .hello(name:name,appVersion:appVersion,claimID:claimID,assistance:accepted,capabilities:stated)
        case .spectator:return .hello(name:name,appVersion:appVersion,claimID:nil,capabilities:stated)
        }
    }
    /// None is written as no field at all, as a 1.1 peer sends.
    private var stated:NetworkCapabilities? {capabilities.tokens.isEmpty ? nil:capabilities}
    /// The connection is gone. A reconnect clears the pending move; the board stays until the next snapshot. The host
    /// pauses the clocks when it loses this peer (D6), so given `now` the clocks freeze at their reading then: however
    /// long the reconnecting takes, and whichever runner does it, they show that reading until a snapshot replaces it.
    public func connectionLost(at now:NetworkInstant?=nil){
        if let now,var frozen=clocks(at:now) {frozen.active=nil;clockSync=(frozen,now)}
        pendingMove=nil;assembler=nil;resyncRequested=false;acknowledgeAfterSnapshot=false;admitted=false;synced=false
    }
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
        guard !counted(message) || inboundRate.admit(at:now) else{output.close = .rateLimited;return output}
        if case .snapshotBegin=message,assembler==nil,synced,!resyncRequested,!unsolicitedSnapshots.admit(at:now) {output.close = .rateLimited;return output}
        // Game news belongs to the board this connection's snapshot installed (D5); before it, the host broke the order.
        switch message {
        case .moved,.ended,.drawOffered,.drawDeclined,.clock,.rejected:guard synced else{output.close = .malformed;return output}
        default:break
        }
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
            guard case .guest=role,!admitted,self.credential==nil || self.credential!.matches(credential) else{output.close = .malformed;break}
            self.credential=credential;acknowledgeAfterSnapshot=true;admitted=true;output.events.append(.seated)
        case .resumed:guard case .guest=role,!admitted,credential != nil else{output.close = .malformed;break};admitted=true;output.events.append(.resumed)
        case .watching:guard role == .spectator,!admitted else{output.close = .malformed;break};admitted=true;output.events.append(.watching)
        case .snapshotBegin(let snapshotID,let revision,let hash,let totalBytes,let parts):
            guard admitted else{output.close = .malformed;break}
            do{assembler=try NetworkSnapshotAssembler(snapshotID:snapshotID,revision:revision,hash:hash,totalBytes:totalBytes,parts:parts)}catch{output.close = .badSnapshot}
        case .snapshotPart,.snapshotEnd:output.close = .badSnapshot
        case .moved(let moved):guard clocksFit(moved.clocks) else{output.close = .malformed;break};try apply(moved,at:now,&output)
        case .ended(let ended):
            guard let current=revision else{requestResync(&output);break}
            // A game ends once: the same result again is a duplicate; any other result at or before the current revision,
            // a further result, or clocks the game's time control has no place for, is not this game.
            if ended.revision<=current {if ended.revision != current || ended.outcome != outcome {output.close = .malformed};break}
            guard outcome==nil,clocksFit(ended.clocks) else{output.close = .malformed;break}
            guard ended.revision==current+1 else{requestResync(&output);break}
            revision=ended.revision;outcome=ended.outcome;openOffer=nil;pendingMove=nil
            if let clocks=ended.clocks {clockSync=(clocks,now)}
            output.events.append(.ended(ended.outcome))
        case .drawOffered(let offer):guard revision != nil,outcome==nil else{break};openOffer=offer;output.events.append(.offered(offer))
        case .drawDeclined(let offerID):if openOffer?.offerID==offerID {openOffer=nil;output.events.append(.offerCleared(offerID))}
        case .clock(let clocks):guard clocksFit(clocks) else{output.close = .malformed;break};clockSync=(clocks,now)
        case .rejected(let commandID,let reason):
            if pendingMove?.commandID==commandID {pendingMove=nil}
            output.events.append(.rejected(commandID:commandID,reason:reason))
        case .ping(let nonce):output.send.append(.pong(nonce:nonce))
        case .hello,.seatedAck,.resume,.resync,.move,.resign,.drawOffer,.drawAnswer,.claimDraw,.pong,.bye:output.close = .malformed
        }
        return output
    }
    /// Whether `message` counts toward the inbound rate: everything that neither advances the game nor answers this Mac.
    private func counted(_ message:NetworkMessage)->Bool {
        switch message {
        case .seated,.resumed,.watching,.snapshotBegin,.snapshotPart,.snapshotEnd:return false
        case .moved(let moved):return !advances(moved.revision)
        case .ended(let ended):return !advances(ended.revision)
        case .rejected(let commandID,_):return pendingMove?.commandID != commandID
        default:return true
        }
    }
    /// Whether a move or result at `next` would advance this board now: only those are bounded by the game itself.
    private func advances(_ next:Int)->Bool {synced && !resyncRequested && outcome==nil && revision.map{next == $0+1} == true}
    /// Clocks exactly when the installed game is timed (D4: an untimed game has none), the rule a public game decodes by.
    private func clocksFit(_ clocks:NetworkClocks?)->Bool {(clocks==nil)==(installed?.timeControl == .untimed)}
    private func requestResync(_ output:inout NetworkReceiverOutput){guard !resyncRequested else{return};resyncRequested=true;output.send.append(.resync)}
    private func finishSnapshot(_ snapshotID:NetworkID,at now:NetworkInstant,_ output:inout NetworkReceiverOutput)throws {
        let assembled=assembler!;assembler=nil
        let result:NetworkSnapshotInstaller.Installed
        do{result=try NetworkSnapshotInstaller.install(try assembled.finish(snapshotID:snapshotID),revision:assembled.revision,hash:assembled.hash,gameID:gameID,rules:factory,hashing:hashing)}
        catch is NetworkSnapshotError{output.close = .badSnapshot;return}
        // A3: a guest plays only under the terms it accepted. Other terms are never installed, and a claim is never
        // acknowledged under them, so the reservation lapses (D4).
        if case .guest=role,result.game.assistance != accepted {acknowledgeAfterSnapshot=false;output.close = .assistanceChanged;return}
        // The seats and the moves already shown never change: a later snapshot that swaps the host's side (and with it
        // the guest's, and its agreed level) or goes back to an earlier revision is not this game.
        // The terms (A2) and the time control are fixed when the game is hosted, for every receiver, spectators too.
        if let installed,result.game.hostSide != installed.hostSide || result.game.timeControl != installed.timeControl || result.game.assistance != installed.assistance {output.close = .malformed;return}
        if let current=revision,result.game.revision<current {output.close = .malformed;return}
        // D7: the start is pinned by the first snapshot installed; any other start, at any revision, is another game.
        if let pinnedStart,result.start != pinnedStart {output.close = .malformed;return}
        // A game ends once: after its result, a snapshot repeats that game exactly, never another result or more moves.
        if let outcome,result.game.outcome != outcome || result.game.revision != revision {output.close = .malformed;return}
        // What this Mac already verified stays as it was: the new record extends the moves shown, never replaces them,
        // and keeps the assisted flags of those moves (A7).
        if let rules {
            let shown=try rules.networkMoves()
            guard result.moves.count>=shown.count,Array(result.moves.prefix(shown.count))==shown,result.game.assistedPlies.filter({$0<=shown.count})==assistedPlies.filter({$0<=shown.count}) else{output.close = .malformed;return}
        }
        pinnedStart=result.start;installed=result.game;assistedPlies=result.game.assistedPlies;rules=result.rules;fen=result.fen;revision=result.game.revision;synced=true
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
    private var playable:Bool {if case .guest=role,synced,revision != nil,outcome==nil,assembler==nil,!resyncRequested {return true};return false}
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
