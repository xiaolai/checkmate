import Foundation
/// A consistent capture of the public game at one revision (D5), sent as `snapshotBegin`, Base64 parts of at most
/// 9 KiB raw, then `snapshotEnd`. Parts are made one at a time as the outbox asks for them.
public struct NetworkSnapshot:Equatable {
    public let snapshotID:NetworkID,revision:Int,hash:String,payload:Data
    public init(snapshotID:NetworkID,revision:Int,hash:String,payload:Data){self.snapshotID=snapshotID;self.revision=revision;self.hash=hash;self.payload=payload}
    public var partCount:Int {(payload.count+NetworkLimits.maximumSnapshotPartBytes-1)/NetworkLimits.maximumSnapshotPartBytes}
    /// Message `step` of the sequence: 0 is the begin, 1...partCount the parts, partCount+1 the end.
    public var messageCount:Int {partCount+2}
    public func message(_ step:Int)->NetworkMessage {
        switch step {
        case 0:return .snapshotBegin(snapshotID:snapshotID,revision:revision,hash:hash,totalBytes:payload.count,parts:partCount)
        case partCount+1:return .snapshotEnd(snapshotID:snapshotID)
        default:
            let start=payload.startIndex+(step-1)*NetworkLimits.maximumSnapshotPartBytes
            return .snapshotPart(snapshotID:snapshotID,index:step-1,data:payload.subdata(in:start..<min(start+NetworkLimits.maximumSnapshotPartBytes,payload.endIndex)))
        }
    }
    public var messages:[NetworkMessage] {(0..<messageCount).map(message)}
    /// The host's capture: the public game encoded, and the hash of the position it records.
    static func capture(_ game:NetworkPublicGame,fen:String,hashing:NetworkHashing,random:NetworkRandom)throws -> NetworkSnapshot {
        let payload=try game.encoded()
        guard payload.count<=NetworkLimits.maximumSnapshotBytes else{throw NetworkRulesError.unexpected("The game record is over the snapshot limit.")}
        return NetworkSnapshot(snapshotID:.random(using:random),revision:game.revision,hash:hashing.positionHash(fen:fen,revision:game.revision),payload:payload)
    }
}
public enum NetworkSnapshotError:Error,Equatable {
    /// Parts out of order, a wrong size, a second begin, an end too early, or a record that does not reach its hash:
    /// every one closes the connection with `bye(badSnapshot)`.
    case badSnapshot(String)
}
/// Reassembles one chunked snapshot on a receiver: at most 1 MiB (D7), parts strictly in order.
public struct NetworkSnapshotAssembler {
    public let snapshotID:NetworkID,revision:Int,hash:String,totalBytes:Int,parts:Int
    public private(set) var payload=Data()
    private var received=0
    public init(snapshotID:NetworkID,revision:Int,hash:String,totalBytes:Int,parts:Int)throws {
        guard (1...NetworkLimits.maximumSnapshotBytes).contains(totalBytes),parts==(totalBytes+NetworkLimits.maximumSnapshotPartBytes-1)/NetworkLimits.maximumSnapshotPartBytes else{throw NetworkSnapshotError.badSnapshot("size")}
        self.snapshotID=snapshotID;self.revision=revision;self.hash=hash;self.totalBytes=totalBytes;self.parts=parts
    }
    public mutating func add(snapshotID:NetworkID,index:Int,data:Data)throws {
        let expected=min(NetworkLimits.maximumSnapshotPartBytes,totalBytes-payload.count)
        guard snapshotID==self.snapshotID,index==received,index<parts,data.count==expected else{throw NetworkSnapshotError.badSnapshot("part")}
        payload.append(data);received+=1
    }
    public func finish(snapshotID:NetworkID)throws -> Data {
        guard snapshotID==self.snapshotID,received==parts,payload.count==totalBytes else{throw NetworkSnapshotError.badSnapshot("end")}
        return payload
    }
}
/// Installs a reassembled snapshot (D2): replay its record on a fresh game, check the result reaches the hash, and
/// only then hand back a game to replace the receiver's board. Any failure leaves the receiver's board untouched.
public enum NetworkSnapshotInstaller {
    /// `moves`: the record's moves in UCI, which replay from `start` to `fen`. `start`: the canonical start the record
    /// declares (mini-games plan D7), the standard start when it declares none; the receiver pins it.
    public struct Installed {public let game:NetworkPublicGame,rules:any NetworkChessRules,fen:String,moves:[String],start:String}
    public static func install(_ payload:Data,revision:Int,hash:String,gameID:NetworkGameID,rules factory:NetworkRulesFactory,hashing:NetworkHashing)throws -> Installed {
        let game:NetworkPublicGame
        do{game=try JSONDecoder().decode(NetworkPublicGame.self,from:payload)}catch{throw NetworkSnapshotError.badSnapshot("record")}
        guard game.gameID==gameID,game.revision==revision else{throw NetworkSnapshotError.badSnapshot("game")}
        // Making the scratch games is the receiver's own rules failing, not the snapshot's fault: it propagates.
        let rules=try factory.newGame(),start=try factory.newGame()
        // D7: the declared start is set up first, on the game the moves are played afresh on. One the rules refuse, or
        // write back otherwise (not canonical), is not a start any 1.2 host declares.
        if let declared=game.startFEN {
            do{try start.networkLoad(start:declared)}catch NetworkRulesError.illegalStart{throw NetworkSnapshotError.badSnapshot("start")}
            guard try start.networkFEN()==declared else{throw NetworkSnapshotError.badSnapshot("start")}
        }
        let opening=try start.networkMoves()
        // The work a replay costs is bounded before any is done (D7): no real game holds more than `maximumPlies`
        // moves, a record holds no more moves than its start's and its revision counts (D2), and its size is bounded by
        // that count, so a longer one is refused unread.
        guard revision<=NetworkLimits.maximumPlies+1,game.pgn.utf8.count<=NetworkLimits.maximumRecordBytes(moves:opening.count+revision),moveTokens(game.pgn,limit:opening.count+revision)<=opening.count+revision else{throw NetworkSnapshotError.badSnapshot("length")}
        let fen:String,moves:[String],recordStart:String
        do{try rules.networkLoad(pgn:game.pgn);fen=try rules.networkFEN();moves=try rules.networkMoves();recordStart=try rules.networkStartFEN()}catch{throw NetworkSnapshotError.badSnapshot("replay")}
        guard hashing.positionHash(fen:fen,revision:revision)==hash else{throw NetworkSnapshotError.badSnapshot("hash")}
        // The record's own start (its FEN header) is the declared one (D7): the standard start, with no header, when
        // none is declared. The record must extend the game set up there, and its moves played afresh from it must
        // reach the same position, so a record that sets up another start is not this game.
        guard recordStart==game.start else{throw NetworkSnapshotError.badSnapshot("start")}
        guard moves.count>=opening.count,Array(moves.prefix(opening.count))==opening else{throw NetworkSnapshotError.badSnapshot("start")}
        // The revision counts each move from the start and the end (D2), so it states how many moves the record holds;
        // one that disagrees would misplace every assisted ply (A7).
        guard revision==moves.count-opening.count+(game.outcome==nil ? 0:1) else{throw NetworkSnapshotError.badSnapshot("revision")}
        do{for move in moves.dropFirst(opening.count) {_ = try start.networkPlay(uci:move)};guard try start.networkFEN()==fen else{throw NetworkSnapshotError.badSnapshot("start")}}catch{throw NetworkSnapshotError.badSnapshot("start")}
        // The board kept is the one played afresh from the start, not the record's own: a record that sets up another
        // start can reach the same position by the same squares while claiming other captures, and those never reach
        // the board, the review record or the coach.
        return Installed(game:game,rules:start,fen:fen,moves:moves,start:game.start)
    }
    /// The move tokens in a record's movetext, counted up to `limit + 1`: every token outside tag pairs, comments and
    /// variations that is not a move number, a result or an annotation. A cheap upper bound on the moves a replay
    /// would play, so an overlong record is refused before the rules see it.
    static func moveTokens(_ pgn:String,limit:Int)->Int {
        var count=0,depth=0,comment=false
        for line in pgn.split(whereSeparator:\.isNewline) where !line.drop(while:{$0.isWhitespace}).hasPrefix("[") {
            for token in line.split(whereSeparator:\.isWhitespace) {
                var word=Substring(token)
                if comment {guard let close=word.firstIndex(of:"}") else{continue};comment=false;word=word[word.index(after:close)...]}
                if word.hasPrefix("{") {if !word.contains("}") {comment=true};continue}
                if word.hasPrefix(";") {break}
                if word.hasPrefix("(") {depth+=word.filter{$0=="("}.count-word.filter{$0==")"}.count;continue}
                if depth>0 {depth=max(0,depth+word.filter{$0=="("}.count-word.filter{$0==")"}.count);continue}
                let move=word.drop{$0.isNumber || $0=="."}
                guard !move.isEmpty,!["1-0","0-1","1/2-1/2","*"].contains(String(word)),!move.hasPrefix("$") else{continue}
                count+=1;if count>limit {return count}
            }
        }
        return count
    }
}
/// One peer's outbound queue (D5 ordering, D7 outbound). Frames reach the transport one at a time: the next is handed
/// over only when the previous one's send completes, so a chunked snapshot is paced by the peer itself.
///
/// While a snapshot is pending or in flight, every other message for the peer waits in the after-snapshot list and is
/// sent, in order, right after `snapshotEnd`. A second snapshot request meanwhile is coalesced: the snapshot in flight
/// plus the held messages already bring the peer up to date. Bytes count queued, held and handed-but-not-completed
/// messages, and the held list counts toward the cap.
public struct NetworkOutbox {
    public enum Admission:Equatable {case queued,held,coalesced,overflow}
    public let capacity:Int
    private var queue:[Data]=[],held:[Data]=[],inFlight:Data?
    private var snapshot:NetworkSnapshot?,snapshotStep=0
    public private(set) var bytes=0
    public init(capacity:Int=NetworkLimits.peerQueueBytes){self.capacity=capacity}
    public var snapshotPending:Bool {snapshot != nil}
    /// The capture this peer still has to send, if any. Its payload is the host's, shared by every peer given the
    /// same capture, so the host counts it once per capture rather than against this peer's queue (D7).
    public var pendingSnapshot:NetworkSnapshot? {snapshot}
    public var awaitingCompletion:Bool {inFlight != nil}
    public var isIdle:Bool {queue.isEmpty && held.isEmpty && inFlight==nil && snapshot==nil}
    /// Refuses (`overflow`) rather than queue past the cap; the caller then closes the peer.
    public mutating func enqueue(_ message:Data)->Admission {
        guard bytes+message.count<=capacity else{return .overflow}
        bytes+=message.count
        if snapshot != nil {held.append(message);return .held}
        queue.append(message);return .queued
    }
    /// The snapshot follows whatever is already queued; later messages are held behind it.
    public mutating func requestSnapshot(_ capture:NetworkSnapshot)->Admission {
        guard snapshot==nil else{return .coalesced}
        snapshot=capture;snapshotStep=0;return .queued
    }
    /// The next message to hand to the transport, or nil while a send is in flight or nothing is ready.
    public mutating func next()throws -> Data? {
        guard inFlight==nil else{return nil}
        let message:Data
        if !queue.isEmpty {message=queue.removeFirst()}
        else if let capture=snapshot {
            message=try NetworkCodec.encode(capture.message(snapshotStep));snapshotStep+=1;bytes+=message.count
            if snapshotStep==capture.messageCount {snapshot=nil;queue=held;held=[]}
        }else{return nil}
        inFlight=message;return message
    }
    /// The transport finished the send in flight.
    public mutating func completed(){if let message=inFlight {bytes-=message.count;inFlight=nil}}
}
