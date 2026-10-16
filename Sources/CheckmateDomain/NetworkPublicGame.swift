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
    public init(gameID:NetworkGameID,revision:Int,hostSide:NetworkSide,whiteName:String?,blackName:String?,timeControl:NetworkTimeControl,pgn:String,clocks:NetworkClocks?,openOffer:NetworkDrawOffer?,outcome:NetworkOutcome?){self.gameID=gameID;self.revision=revision;self.hostSide=hostSide;self.whiteName=whiteName;self.blackName=blackName;self.timeControl=timeControl;self.pgn=pgn;self.clocks=clocks;self.openOffer=openOffer;self.outcome=outcome}
    private enum CodingKeys:String,CodingKey {case gameID,revision,hostSide,whiteName,blackName,timeControl,pgn,clocks,openOffer,outcome}
    /// Validates like any other message: a peer's snapshot is untrusted until its record replays to its hash.
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        gameID=try c.decode(NetworkGameID.self,forKey:.gameID);revision=try c.decode(Int.self,forKey:.revision);hostSide=try c.decode(NetworkSide.self,forKey:.hostSide)
        whiteName=try c.decodeIfPresent(String.self,forKey:.whiteName);blackName=try c.decodeIfPresent(String.self,forKey:.blackName)
        timeControl=try c.decode(NetworkTimeControl.self,forKey:.timeControl);pgn=try c.decode(String.self,forKey:.pgn)
        clocks=try c.decodeIfPresent(NetworkClocks.self,forKey:.clocks);openOffer=try c.decodeIfPresent(NetworkDrawOffer.self,forKey:.openOffer);outcome=try c.decodeIfPresent(NetworkOutcome.self,forKey:.outcome)
        guard revision>=0,[whiteName,blackName].allSatisfy({$0.map{NetworkText.valid($0)} ?? true}),clocks?.valid ?? true,(clocks==nil)==(timeControl == .untimed) else{throw DecodingError.dataCorrupted(.init(codingPath:decoder.codingPath,debugDescription:"Invalid public game."))}
    }
    public func name(_ side:NetworkSide)->String? {side == .white ? whiteName:blackName}
    func encoded()throws -> Data {let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try encoder.encode(self)}
    /// The review record's tag pairs, in PGN order (D9). `date` is "YYYY.MM.DD"; the domain reads no calendar. An
    /// interrupted game (no outcome) has the result `*` and no Termination.
    public func recordHeaders(date:String)->[(name:String,value:String)] {
        var headers:[(name:String,value:String)]=[("Event","Checkmate network game"),("Site","?"),("Date",date),("Round","?"),("White",whiteName ?? "?"),("Black",blackName ?? "?"),("Result",outcome?.result.rawValue ?? "*"),("TimeControl",timeControl.pgnValue)]
        if let outcome {headers.append(("Termination",outcome.termination.pgnValue))}
        return headers
    }
}
