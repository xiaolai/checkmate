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
    public init(gameID:NetworkGameID,revision:Int,hostSide:NetworkSide,whiteName:String?,blackName:String?,timeControl:NetworkTimeControl,pgn:String,clocks:NetworkClocks?,openOffer:NetworkDrawOffer?,outcome:NetworkOutcome?,assistance:NetworkAssistance = .off,assistedPlies:[Int]=[]){self.gameID=gameID;self.revision=revision;self.hostSide=hostSide;self.whiteName=whiteName;self.blackName=blackName;self.timeControl=timeControl;self.pgn=pgn;self.clocks=clocks;self.openOffer=openOffer;self.outcome=outcome;self.assistance=assistance;self.assistedPlies=assistedPlies}
    private enum CodingKeys:String,CodingKey {case gameID,revision,hostSide,whiteName,blackName,timeControl,pgn,clocks,openOffer,outcome,assistance,assistedPlies}
    /// Validates like any other message: a peer's snapshot is untrusted until its record replays to its hash.
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        gameID=try c.decode(NetworkGameID.self,forKey:.gameID);revision=try c.decode(Int.self,forKey:.revision);hostSide=try c.decode(NetworkSide.self,forKey:.hostSide)
        whiteName=try c.decodeIfPresent(String.self,forKey:.whiteName);blackName=try c.decodeIfPresent(String.self,forKey:.blackName)
        timeControl=try c.decode(NetworkTimeControl.self,forKey:.timeControl);pgn=try c.decode(String.self,forKey:.pgn)
        clocks=try c.decodeIfPresent(NetworkClocks.self,forKey:.clocks);openOffer=try c.decodeIfPresent(NetworkDrawOffer.self,forKey:.openOffer);outcome=try c.decodeIfPresent(NetworkOutcome.self,forKey:.outcome)
        assistance=try c.decodeIfPresent(NetworkAssistance.self,forKey:.assistance) ?? .off;assistedPlies=try c.decodeIfPresent([Int].self,forKey:.assistedPlies) ?? []
        guard revision>=0,zip(assistedPlies,assistedPlies.dropFirst()).allSatisfy({$0<$1}),assistedPlies.allSatisfy({$0>=1 && $0<=revision}),[whiteName,blackName].allSatisfy({$0.map{NetworkText.valid($0)} ?? true}),clocks?.valid ?? true,(clocks==nil)==(timeControl == .untimed) else{throw DecodingError.dataCorrupted(.init(codingPath:decoder.codingPath,debugDescription:"Invalid public game."))}
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
    }
    public func name(_ side:NetworkSide)->String? {side == .white ? whiteName:blackName}
    /// How many of `side`'s moves were assisted (A7): White makes the odd plies, since every network game starts from
    /// the initial position.
    public func assistedMoves(by side:NetworkSide)->Int {assistedPlies.filter{($0%2==1)==(side == .white)}.count}
    func encoded()throws -> Data {let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try encoder.encode(self)}
    /// The review record's tag pairs, in PGN order (D9), with `Assistance` when either side had any (A11). `date` is "YYYY.MM.DD"; the domain reads no calendar. An
    /// interrupted game (no outcome) has the result `*` and no Termination.
    public func recordHeaders(date:String)->[(name:String,value:String)] {
        var headers:[(name:String,value:String)]=[("Event","Checkmate network game"),("Site","?"),("Date",date),("Round","?"),("White",whiteName ?? "?"),("Black",blackName ?? "?"),("Result",outcome?.result.rawValue ?? "*"),("TimeControl",timeControl.pgnValue)]
        if assistance != .off {headers.append(("Assistance",assistance.recordValue))}
        if let outcome {headers.append(("Termination",outcome.termination.pgnValue))}
        return headers
    }
}
