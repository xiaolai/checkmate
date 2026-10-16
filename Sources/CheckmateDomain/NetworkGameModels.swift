import Foundation
public enum NetworkSide:String,Codable,CaseIterable {
    case white="w",black="b"
    public var opponent:NetworkSide {self == .white ? .black:.white}
}
/// The host sheet's side choice; `random` is resolved once, with the injected randomness, when the game is made.
public enum NetworkSideChoice:String,Codable,CaseIterable {
    case white,black,random
    public func resolved(using random:NetworkRandom)->NetworkSide {switch self{case .white:return .white;case .black:return .black;case .random:return random.bytes(1)[0]&1==0 ? .white:.black}}
}
public enum NetworkGameResult:String,Codable,CaseIterable {
    case whiteWins="1-0",blackWins="0-1",draw="1/2-1/2"
    public static func win(for side:NetworkSide)->NetworkGameResult {side == .white ? .whiteWins:.blackWins}
}
/// How a network game ended (D5). A game whose host vanished before `ended` has none: it is interrupted.
public enum NetworkTermination:String,Codable,CaseIterable {
    case checkmate,stalemate,resignation,time,agreement,repetition,fiftyMoves,seventyFiveMoves,fivefold,insufficientMaterial,abandoned
    /// The PGN `Termination` value for the review record (D9).
    public var pgnValue:String {switch self{case .checkmate:return "Checkmate";case .stalemate:return "Stalemate";case .resignation:return "Resignation";case .time:return "Time forfeit";case .agreement:return "Draw by agreement";case .repetition:return "Threefold repetition";case .fiftyMoves:return "Fifty-move rule";case .seventyFiveMoves:return "Seventy-five-move rule";case .fivefold:return "Fivefold repetition";case .insufficientMaterial:return "Insufficient material";case .abandoned:return "Abandoned"}}
}
public struct NetworkOutcome:Codable,Equatable {
    public let result:NetworkGameResult,termination:NetworkTermination
    public init(result:NetworkGameResult,termination:NetworkTermination){self.result=result;self.termination=termination}
}
/// Both clocks on the wire, in whole milliseconds, never negative; `active` is the side whose clock runs, or nil while
/// paused, before the first move, or after the end. Cosmetic for receivers: they count down locally between messages.
public struct NetworkClocks:Codable,Equatable {
    public var white:Int,black:Int,active:NetworkSide?
    public init(white:Int,black:Int,active:NetworkSide?){self.white=white;self.black=black;self.active=active}
    public func remaining(_ side:NetworkSide)->Int {side == .white ? white:black}
    /// Generous enough for any increment total; it only bounds what a peer may send.
    static let maximumMilliseconds=1_000_000_000
    var valid:Bool {(0...Self.maximumMilliseconds).contains(white) && (0...Self.maximumMilliseconds).contains(black)}
}
/// An open draw offer. It lapses when the player it was made to moves (D5).
public struct NetworkDrawOffer:Codable,Equatable {
    public let offerID:NetworkID,by:NetworkSide
    public init(offerID:NetworkID,by:NetworkSide){self.offerID=offerID;self.by=by}
}
public enum NetworkTimeControl:String,Codable,CaseIterable {
    case untimed,threePlusTwo="3+2",fivePlusThree="5+3",tenPlusFive="10+5",fifteenPlusTen="15+10",thirtyPlusZero="30+0"
    /// Each side's starting time, or nil for an untimed game, which has no clocks at all (D4).
    public var initial:Duration? {switch self{case .untimed:return nil;case .threePlusTwo:return .seconds(180);case .fivePlusThree:return .seconds(300);case .tenPlusFive:return .seconds(600);case .fifteenPlusTen:return .seconds(900);case .thirtyPlusZero:return .seconds(1800)}}
    public var increment:Duration {switch self{case .untimed,.thirtyPlusZero:return .zero;case .threePlusTwo:return .seconds(2);case .fivePlusThree:return .seconds(3);case .tenPlusFive:return .seconds(5);case .fifteenPlusTen:return .seconds(10)}}
    /// The PGN `TimeControl` value: "-" when untimed, otherwise base+increment in seconds ("180+2").
    public var pgnValue:String {initial.map{"\($0.networkMilliseconds/1000)+\(increment.networkMilliseconds/1000)"} ?? "-"}
}
