import Foundation

public enum RelationshipMode:String,Codable,CaseIterable {
    case protected,attacked
    public var title:String {self == .protected ? "Protected by":"Attacked by"}
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
        if !legalContext{return "Covers this square in the diagram. Legal captures cannot be established from this diagram alone."}
        if king{return "Controls the king’s square. Kings are checked, never captured."}
        if mode == .attacked {
            if status == "restricted" {return "Covers this square, but cannot legally capture this piece in this position. Capturing here would leave its own king in check."}
            return enPassant ? "Can capture this pawn en passant, landing on \(responses.first?.destination ?? "the passed square").":"Could legally capture this piece if \(color == "w" ? "White":"Black") were to move in this position."
        }
        if !responses.isEmpty {
            return responses.map {r in
                let piece=RelationshipInspection.pieceNames[r.attackerPiece,default:"piece"]
                return r.canRecapture ? "Can recapture on \(r.destination) after the \(piece) on \(r.attackerSquare) plays \(r.captureSAN).":"Cannot recapture after the \(piece) on \(r.attackerSquare) plays \(r.captureSAN); that recapture would leave its own king in check."
            }.joined(separator:" ")
        }
        return status == "restricted" ? "Covers this square, but moving onto it would leave its own king in check. A future recapture depends on the capturing move.":"Covers this square. No opposing piece has a legal capture here in the current position; a future recapture depends on how the position changes."
    }
}
public struct RelationshipInspection:Codable,Equatable {
    public static let pieceNames=["p":"pawn","n":"knight","b":"bishop","r":"rook","q":"queen","k":"king"]
    public let square:String,piece:String,color:String,mode:RelationshipMode,legalContext:Bool
    public let relations:[PieceRelationship]
    public var selectedLabel:String {"\(color == "w" ? "White":"Black") \(Self.pieceNames[piece,default:"piece"]) on \(square)"}
    public var emptyMessage:String {mode == .protected ? "No friendly piece covers this piece’s square or can recapture a current legal capture.":"No opposing piece attacks this piece in the displayed position."}
    public var note:String {
        if !legalContext{return "Diagram coverage only: this board does not supply a full legal position and turn."}
        if piece == "k"{return "These are square-control relationships. Kings cannot be captured or recaptured."}
        return mode == .protected ? "Protection does not guarantee safety. Solid lines show coverage or an available recapture; dashed lines show restricted or conditional recaptures.":"Captures are checked with the attacking side to move. Solid lines indicate a legal capture; dashed lines show geometric attacks restricted by king safety. This does not predict the opponent’s choice."
    }
}
