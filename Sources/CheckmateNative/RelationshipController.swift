import AppKit
import Combine
import CheckmateCore

@MainActor final class RelationshipController:ObservableObject {
    @Published private(set) var report:RelationshipInspection?
    @Published private(set) var selectedLabel:String?
    @Published private(set) var error:String?
    private(set) var mode:RelationshipMode?
    /// What the shown report was computed from: the FEN, or the diagram's pieces when there is none.
    private struct CacheKey:Equatable {let fen:String?,board:Position?,selected:String?,mode:RelationshipMode?}
    private var cacheKey:CacheKey?,positionIdentity=""
    /// One rules VM, reloaded for each report rather than built anew.
    private var rules:ChessRules?
    private(set) var square:String?
    func toggle(_ value:RelationshipMode,selected:String?){if mode==value{dismiss()}else{mode=value;square=selected;cacheKey=nil}}
    func select(_ value:String?){square=value;cacheKey=nil}
    @discardableResult func dismiss()->Bool {guard mode != nil else{return false};mode=nil;square=nil;report=nil;error=nil;cacheKey=nil;return true}
    func update(board:Position,fen:String?,selected:String?,identity:String){
        if positionIdentity != identity{dismiss();positionIdentity=identity}
        let selected=mode==nil ? selected:square
        let key=CacheKey(fen:fen,board:fen==nil ? board:nil,selected:selected,mode:mode)
        guard key != cacheKey else{return};cacheKey=key
        guard let selected=selected,let piece=board[selected] else{selectedLabel=nil;mode=nil;report=nil;error=nil;return}
        selectedLabel=RelationshipInspection.label(color:String(piece.prefix(1)),piece:String(piece.suffix(1)),square:selected)
        guard let mode=mode else{report=nil;error=nil;return}
        do{let rules=try self.rules ?? ChessRules();self.rules=rules;if let fen{try rules.load(fen)}else{try rules.reset()};report=try rules.relationships(selected,mode:mode,diagram:fen==nil ? board:nil);error=nil}
        catch{report=nil;self.error=String(localized:"This piece’s relationships could not be calculated.",bundle:.checkmate)}
    }
}

struct RelationshipConnector {
    let source:String,target:String,limited:Bool
}
