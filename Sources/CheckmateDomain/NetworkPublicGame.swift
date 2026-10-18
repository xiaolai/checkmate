import Foundation
/// Everything a guest or spectator may know about a network game (D5), and the only game state a snapshot carries.
/// A dedicated type built field by field, so a seat credential, a `claimID`, the host's run epoch or any app state can
/// never ride along: there is no field to hold one.
public struct NetworkPublicGame:Codable,Equatable {
    public var gameID:NetworkGameID
    public var revision:Int
    public var hostSide:NetworkSide
    /// Nil until someone takes that side's seat.
    public var whiteName:String?,blackName:String?
    public var timeControl:NetworkTimeControl
    public var pgn:String
    /// Nil for an untimed game.
    public var clocks:NetworkClocks?
    public var openOffer:NetworkDrawOffer?
    /// Nil while the game goes on.
    public var outcome:NetworkOutcome?
    /// The terms both players accepted (assistance plan A2). A 1.0 record has none: `off` for both sides.
    public var assistance:NetworkAssistance
    /// The plies, counted from 1, after which the mover said a hint was shown that turn (A7), in order. Self-reported.
    /// Kept beside the record, not in it, so the PGN still replays to the position hash.
    public var assistedPlies:[Int]
    /// The declared start (mini-games plan D7), canonical as the host's rules write it; nil for the standard start,
    /// which is never written, so a standard-start record has the 1.1 shape. Fixed for the whole game: a receiver pins
    /// it at its first snapshot.
    public var startFEN:String?
    /// The mini-game ruleset's descriptor (protocol 1.3, `docs/network-protocol-1.3.md`); nil for chess, which is never
    /// written, so a chess record has the 1.2 shape. Fixed for the whole game and pinned like the start; `pgn` then
    /// holds the ruleset's record, not PGN. Read as written: whether this build supports it is the receiver's check.
    public var ruleset:String?
    public init(gameID:NetworkGameID,revision:Int,hostSide:NetworkSide,whiteName:String?,blackName:String?,timeControl:NetworkTimeControl,pgn:String,clocks:NetworkClocks?,openOffer:NetworkDrawOffer?,outcome:NetworkOutcome?,assistance:NetworkAssistance = .off,assistedPlies:[Int]=[],startFEN:String?=nil,ruleset:String?=nil){self.gameID=gameID;self.revision=revision;self.hostSide=hostSide;self.whiteName=whiteName;self.blackName=blackName;self.timeControl=timeControl;self.pgn=pgn;self.clocks=clocks;self.openOffer=openOffer;self.outcome=outcome;self.assistance=assistance;self.assistedPlies=assistedPlies;self.startFEN=startFEN;self.ruleset=ruleset}
    private enum CodingKeys:String,CodingKey {case gameID,revision,hostSide,whiteName,blackName,timeControl,pgn,clocks,openOffer,outcome,assistance,assistedPlies,startFEN,ruleset}
    /// Validates like any other message: a peer's snapshot is untrusted until its record replays to its hash.
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        gameID=try c.decode(NetworkGameID.self,forKey:.gameID);revision=try c.decode(Int.self,forKey:.revision);hostSide=try c.decode(NetworkSide.self,forKey:.hostSide)
        whiteName=try c.decodeIfPresent(String.self,forKey:.whiteName);blackName=try c.decodeIfPresent(String.self,forKey:.blackName)
        timeControl=try c.decode(NetworkTimeControl.self,forKey:.timeControl);pgn=try c.decode(String.self,forKey:.pgn)
        clocks=try c.decodeIfPresent(NetworkClocks.self,forKey:.clocks);openOffer=try c.decodeIfPresent(NetworkDrawOffer.self,forKey:.openOffer);outcome=try c.decodeIfPresent(NetworkOutcome.self,forKey:.outcome)
        assistance=try c.decodeIfPresent(NetworkAssistance.self,forKey:.assistance) ?? .off;assistedPlies=try c.decodeIfPresent([Int].self,forKey:.assistedPlies) ?? []
        startFEN=try c.decodeIfPresent(String.self,forKey:.startFEN);ruleset=try c.decodeIfPresent(String.self,forKey:.ruleset)
        // The revision is a peer's number: it is range-checked before anything is derived from it. Moves and `ended`
        // each advance it (D2), so the moves played are the revision less one once ended.
        guard (0...NetworkLimits.maximumRevision).contains(revision),outcome==nil || revision>=1 else{throw DecodingError.dataCorrupted(.init(codingPath:decoder.codingPath,debugDescription:"Invalid public game revision."))}
        let plies=revision-(outcome==nil ? 0:1)
        guard zip(assistedPlies,assistedPlies.dropFirst()).allSatisfy({$0<$1}),assistedPlies.allSatisfy({$0>=1 && $0<=plies}),[whiteName,blackName].allSatisfy({$0.map{NetworkText.valid($0)} ?? true}),clocks?.valid ?? true,(clocks==nil)==(timeControl == .untimed),startFEN.map({NetworkStart.wellFormed($0) && $0 != NetworkStart.standard}) ?? true,ruleset.map(Self.rulesetShaped) ?? true,startFEN==nil || ruleset==nil else{throw DecodingError.dataCorrupted(.init(codingPath:decoder.codingPath,debugDescription:"Invalid public game."))}
    }
    /// The 1.0 shape when nothing is assisted: the 1.1 keys are written only when they say something (A4).
    public func encode(to encoder:Encoder)throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(gameID,forKey:.gameID);try c.encode(revision,forKey:.revision);try c.encode(hostSide,forKey:.hostSide)
        try c.encodeIfPresent(whiteName,forKey:.whiteName);try c.encodeIfPresent(blackName,forKey:.blackName)
        try c.encode(timeControl,forKey:.timeControl);try c.encode(pgn,forKey:.pgn)
        try c.encodeIfPresent(clocks,forKey:.clocks);try c.encodeIfPresent(openOffer,forKey:.openOffer);try c.encodeIfPresent(outcome,forKey:.outcome)
        if assistance != .off {try c.encode(assistance,forKey:.assistance)}
        if !assistedPlies.isEmpty {try c.encode(assistedPlies,forKey:.assistedPlies)}
        try c.encodeIfPresent(startFEN,forKey:.startFEN);try c.encodeIfPresent(ruleset,forKey:.ruleset)
    }
    /// A descriptor's shape on the wire: 1 to 32 printable ASCII bytes. Which descriptors are supported is not a decoding
    /// question: a receiver refuses an unsupported one as `badSnapshot`, before any replay.
    static func rulesetShaped(_ text:String)->Bool {(1...32).contains(text.utf8.count) && text.utf8.allSatisfy{(0x21...0x7E).contains($0)}}
    public func name(_ side:NetworkSide)->String? {side == .white ? whiteName:blackName}
    /// The start the record replays from: the declared one, a ruleset's own (named by its descriptor: the kind fixes
    /// it), or the standard start. Receivers pin it, so pinning the start pins the ruleset too.
    public var start:String {startFEN ?? ruleset ?? NetworkStart.standard}
    /// How many of `side`'s moves were assisted (A7): the start's side to move makes the odd plies (D7).
    public func assistedMoves(by side:NetworkSide)->Int {assistedPlies.filter{($0%2==1)==(side==NetworkStart.side(start))}.count}
    func encoded()throws -> Data {let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try encoder.encode(self)}
    /// The review record's tag pairs, in PGN order (D9), with `SetUp` and `FEN` for a declared start (mini-games plan
    /// D7) and `Assistance` when either side had any (A11). `date` is "YYYY.MM.DD"; the domain reads no calendar. An
    /// interrupted game (no outcome) has the result `*` and no Termination.
    public func recordHeaders(date:String)->[(name:String,value:String)] {
        var headers:[(name:String,value:String)]=[("Event","Checkmate network game"),("Site","?"),("Date",date),("Round","?"),("White",whiteName ?? "?"),("Black",blackName ?? "?"),("Result",outcome?.result.rawValue ?? "*")]
        // Review replays from a declared start; a standard-start record has neither tag, as in 1.1.
        if let startFEN {headers+=[("SetUp","1"),("FEN",startFEN)]}
        headers.append(("TimeControl",timeControl.pgnValue))
        if assistance != .off {headers.append(("Assistance",assistance.recordValue))}
        if let outcome {headers.append(("Termination",outcome.termination.pgnValue))}
        return headers
    }
}
