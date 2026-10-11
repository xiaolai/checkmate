import Foundation
public struct ChessPiece:Codable,Equatable {public let type:String;public let color:String;public let square:String?}
public struct MoveRecord:Codable,Equatable {public init(color:String,from:String,to:String,piece:String,flags:String,san:String,before:String,after:String,captured:String?,promotion:String?){self.color=color;self.from=from;self.to=to;self.piece=piece;self.flags=flags;self.san=san;self.before=before;self.after=after;self.captured=captured;self.promotion=promotion}

    public let color:String,from:String,to:String,piece:String,flags:String,san:String,before:String,after:String
    public let captured:String?,promotion:String?
    public var uci:String {from+to+(promotion ?? "")}
}
public struct PieceInspection:Codable,Equatable {public init(square:String,piece:String,color:String,attacks:[String],destinations:[String],legalNow:Bool,note:String){self.square=square;self.piece=piece;self.color=color;self.attacks=attacks;self.destinations=destinations;self.legalNow=legalNow;self.note=note}

    public let square:String,piece:String,color:String,attacks:[String],destinations:[String],legalNow:Bool,note:String
}
