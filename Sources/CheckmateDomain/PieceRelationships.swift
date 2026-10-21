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
    public var label:String {"\(color == "w" ? "White":"Black") \(RelationshipInspection.pieceNames[piece,default:"piece"]) on \(square)"}
    public func explanation(mode:RelationshipMode,legalContext:Bool,king:Bool)->String {
        if !legalContext{return String(localized:"Covers this square in the diagram. Legal captures cannot be established from this diagram alone.",bundle:.checkmate)}
        if king{return String(localized:"Controls the king’s square. Kings are checked, never captured.",bundle:.checkmate)}
        if mode == .attacked {
            if status == "restricted" {return String(localized:"Covers this square, but cannot legally capture this piece in this position. Capturing here would leave its own king in check.",bundle:.checkmate)}
            return enPassant ? String(localized:"Can capture this pawn en passant, landing on \(responses.first?.destination ?? "the passed square").",bundle:.checkmate):String(localized:"Could legally capture this piece if \(color == "w" ? "White":"Black") were to move in this position.",bundle:.checkmate)
        }
        if !responses.isEmpty {
            return responses.map {r in
                let piece=RelationshipInspection.pieceNames[r.attackerPiece,default:"piece"]
                return r.canRecapture ? String(localized:"Can recapture on \(r.destination) after the \(piece) on \(r.attackerSquare) plays \(r.captureSAN).",bundle:.checkmate):String(localized:"Cannot recapture after the \(piece) on \(r.attackerSquare) plays \(r.captureSAN); that recapture would leave its own king in check.",bundle:.checkmate)
            }.joined(separator:" ")
        }
        return status == "restricted" ? String(localized:"Covers this square, but moving onto it would leave its own king in check. A future recapture depends on the capturing move.",bundle:.checkmate):String(localized:"Covers this square. No opposing piece has a legal capture here in the current position; a future recapture depends on how the position changes.",bundle:.checkmate)
    }
}
public struct RelationshipInspection:Codable,Equatable {
    public static let pieceNames=["p":"pawn","n":"knight","b":"bishop","r":"rook","q":"queen","k":"king"]
    public let square:String,piece:String,color:String,mode:RelationshipMode,legalContext:Bool
    public let relations:[PieceRelationship]
    public var selectedLabel:String {"\(color == "w" ? "White":"Black") \(Self.pieceNames[piece,default:"piece"]) on \(square)"}
    public var emptyMessage:String {mode == .protected ? String(localized:"No friendly piece covers this piece’s square or can recapture a current legal capture.",bundle:.checkmate):String(localized:"No opposing piece attacks this piece in the displayed position.",bundle:.checkmate)}
    public var note:String {
        if !legalContext{return String(localized:"Diagram coverage only: this board does not supply a full legal position and turn.",bundle:.checkmate)}
        if piece == "k"{return String(localized:"These are square-control relationships. Kings cannot be captured or recaptured.",bundle:.checkmate)}
        return mode == .protected ? String(localized:"Protection does not guarantee safety. Solid lines show coverage or an available recapture; dashed lines show restricted or conditional recaptures.",bundle:.checkmate):String(localized:"Captures are checked with the attacking side to move. Solid lines indicate a legal capture; dashed lines show geometric attacks restricted by king safety. This does not predict the opponent’s choice.",bundle:.checkmate)
    }
}
