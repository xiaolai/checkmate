import AppKit
import Combine
import CheckmateCore

@MainActor final class RelationshipController:ObservableObject {
    @Published private(set) var report:RelationshipInspection?
    @Published private(set) var selectedLabel:String?
    @Published private(set) var error:String?
    private(set) var mode:RelationshipMode?
    private var cacheKey="",positionIdentity=""
    private(set) var square:String?
    func toggle(_ value:RelationshipMode,selected:String?){if mode==value{dismiss()}else{mode=value;square=selected;cacheKey=""}}
    func select(_ value:String?){square=value;cacheKey=""}
    @discardableResult func dismiss()->Bool {guard mode != nil else{return false};mode=nil;square=nil;report=nil;error=nil;cacheKey="";return true}
    func update(board:Position,fen:String?,selected:String?,identity:String){
        if positionIdentity != identity{dismiss();positionIdentity=identity}
        let selected=mode==nil ? selected:square
        let key=(fen ?? board.keys.sorted().map{$0+":"+board[$0]!}.joined(separator:";"))+":"+(selected ?? "")+":"+(mode?.rawValue ?? "")
        guard key != cacheKey else{return};cacheKey=key
        guard let selected=selected,let piece=board[selected] else{selectedLabel=nil;mode=nil;report=nil;error=nil;return}
        selectedLabel="\(piece.first=="w" ? "White":"Black") \(RelationshipInspection.pieceNames[String(piece.suffix(1)),default:"piece"]) on \(selected)"
        guard let mode=mode else{report=nil;error=nil;return}
        do{let rules=try ChessRules(fen:fen);report=try rules.relationships(selected,mode:mode,diagram:fen==nil ? board:nil);error=nil}
        catch{report=nil;self.error="This piece’s relationships could not be calculated."}
    }
}

struct RelationshipConnector {
    let source:String,target:String,limited:Bool
}
