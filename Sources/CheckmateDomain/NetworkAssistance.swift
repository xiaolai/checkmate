import Foundation
/// What one player's own Mac may show them during a network game (assistance plan A1). Each level includes every one
/// below it; spectators always have `off`, whatever the terms.
public enum NetworkAssistanceLevel:String,Codable,CaseIterable,Comparable {
    case off,insight,hints,guided
    private var rank:Int {Self.allCases.firstIndex(of:self)!}
    public static func <(a:NetworkAssistanceLevel,b:NetworkAssistanceLevel)->Bool {a.rank<b.rank}
    /// The name the host sheet, the join sheet and the record use.
    public var title:String {switch self{case .off:return "Off";case .insight:return "Board insight";case .hints:return "Hints on request";case .guided:return "Guided"}}
    /// One letter per side in the TXT record's `assist` value (A3).
    public var letter:Character {switch self{case .off:return "o";case .insight:return "i";case .hints:return "h";case .guided:return "g"}}
    public init?(letter:Character){guard let level=Self.allCases.first(where:{$0.letter==letter}) else{return nil};self=level}
}
/// A network game's assistance terms (A2): one level for each side. The host fixes them when hosting; no message can
/// change them, and the guest accepts them before joining (A3).
public struct NetworkAssistance:Codable,Hashable,CustomStringConvertible {
    public var white:NetworkAssistanceLevel,black:NetworkAssistanceLevel
    public init(white:NetworkAssistanceLevel,black:NetworkAssistanceLevel){self.white=white;self.black=black}
    /// The same level for both sides: the default shape of the terms.
    public init(both level:NetworkAssistanceLevel){self.init(white:level,black:level)}
    public static let off=NetworkAssistance(both:.off)
    public func level(_ side:NetworkSide)->NetworkAssistanceLevel {side == .white ? white:black}
    /// Anything but the same level for both sides is a handicap, and the interface always calls it one (A2).
    public var symmetric:Bool {white==black}
    public var handicap:Bool {!symmetric}
    /// The TXT record's `assist` value (A3): "hh", "go". Display only; the key does not cover it.
    public var txt:String {String([white.letter,black.letter])}
    public init?(txt:String){
        let letters=Array(txt)
        guard letters.count==2,let white=NetworkAssistanceLevel(letter:letters[0]),let black=NetworkAssistanceLevel(letter:letters[1]) else{return nil}
        self.init(white:white,black:black)
    }
    /// The review record's `Assistance` tag value (A11): "White: Hints on request; Black: Off".
    public var recordValue:String {"White: \(white.title); Black: \(black.title)"}
    public var description:String {txt}
}
