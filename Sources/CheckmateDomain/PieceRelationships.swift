import CheckmateAssets
import Foundation

public enum RelationshipMode:String,Codable,CaseIterable {
    case protected,attacked
    public var title:String {self == .protected ? String(localized:"Protected by",bundle:.checkmate):String(localized:"Attacked by",bundle:.checkmate)}
    public var shortcut:String {self == .protected ? "P":"A"}
}
public struct CaptureReply:Codable,Equatable {
    public let attackerSquare:String,attackerPiece:String,captureSAN:String,destination:String,canRecapture:Bool
    public let recaptures:[String]
}
public struct PieceRelationship:Codable,Equatable {
    public let square:String,piece:String,color:String,status:String,coverage:Bool,enPassant:Bool
    public let responses:[CaptureReply]
    public var limited:Bool {status == "restricted" || status == "conditional"}
    public var label:String {RelationshipInspection.label(color:color,piece:piece,square:square)}
    public func explanation(mode:RelationshipMode,legalContext:Bool,king:Bool)->String {
        if !legalContext{return String(localized:"Covers this square in the diagram. Legal captures cannot be established from this diagram alone.",bundle:.checkmate)}
        if king{return String(localized:"Controls the king’s square. Kings are checked, never captured.",bundle:.checkmate)}
        if mode == .attacked {
            if status == "restricted" {return String(localized:"Covers this square, but cannot legally capture this piece in this position. Capturing here would leave its own king in check.",bundle:.checkmate)}
            guard enPassant else{return String(localized:"Could legally capture this piece if \(PieceName.side(color)) were to move in this position.",bundle:.checkmate)}
            guard let landing=responses.first?.destination else{return String(localized:"Can capture this pawn en passant, landing on the passed square.",bundle:.checkmate)}
            return String(localized:"Can capture this pawn en passant, landing on \(landing).",bundle:.checkmate)
        }
        if !responses.isEmpty {
            return Sentences.join(responses.map {r in
                let piece=PieceName.of(r.attackerPiece)
                return r.canRecapture ? String(localized:"Can recapture on \(r.destination) after the \(piece) on \(r.attackerSquare) plays \(r.captureSAN).",bundle:.checkmate):String(localized:"Cannot recapture after the \(piece) on \(r.attackerSquare) plays \(r.captureSAN); that recapture would leave its own king in check.",bundle:.checkmate)
            })
        }
        return status == "restricted" ? String(localized:"Covers this square, but moving onto it would leave its own king in check. A future recapture depends on the capturing move.",bundle:.checkmate):String(localized:"Covers this square. No opposing piece has a legal capture here in the current position; a future recapture depends on how the position changes.",bundle:.checkmate)
    }
}
public struct RelationshipInspection:Codable,Equatable {
    public static let pieceNames=["p":"pawn","n":"knight","b":"bishop","r":"rook","q":"queen","k":"king"]
    public let square:String,piece:String,color:String,mode:RelationshipMode,legalContext:Bool
    public let relations:[PieceRelationship]
    public var selectedLabel:String {Self.label(color:color,piece:piece,square:square)}
    /// "White knight on f3": a piece by side, kind and square, as the relationship list and the board name it.
    public static func label(color:String,piece:String,square:String)->String {String(localized:"\(PieceName.side(color)) \(PieceName.of(piece)) on \(square)",bundle:.checkmate,comment:"A piece by side, kind and square, such as White knight on f3")}
    public var emptyMessage:String {mode == .protected ? String(localized:"No friendly piece covers this piece’s square or can recapture a current legal capture.",bundle:.checkmate):String(localized:"No opposing piece attacks this piece in the displayed position.",bundle:.checkmate)}
    public var note:String {
        if !legalContext{return String(localized:"Diagram coverage only: this board does not supply a full legal position and turn.",bundle:.checkmate)}
        if piece == "k"{return String(localized:"These are square-control relationships. Kings cannot be captured or recaptured.",bundle:.checkmate)}
        return mode == .protected ? String(localized:"Protection does not guarantee safety. Solid lines show coverage or an available recapture; dashed lines show restricted or conditional recaptures.",bundle:.checkmate):String(localized:"Captures are checked with the attacking side to move. Solid lines indicate a legal capture; dashed lines show geometric attacks restricted by king safety. This does not predict the opponent’s choice.",bundle:.checkmate)
    }
}
