import SwiftUI
import CheckmateCore

/// The captured pieces and the material lead of a board (B-10), read from its placement alone: no engine, no history.
/// A side's captures are the other side's pieces missing from a full set; a piece beyond its full-set count is a
/// promoted pawn, so it stands in for that pawn rather than counting as a capture.
struct MaterialBalance:Equatable {
    /// Most valuable first, as the row shows them.
    static let order:[Character]=["q","r","b","n","p"]
    private static let fullSet:[Character:Int]=["q":1,"r":2,"b":2,"n":2,"p":8]
    private let counts:[String:[Character:Int]]
    init(board:Position){var counts:[String:[Character:Int]]=["w":[:],"b":[:]];for piece in board.values where piece.count==2{counts[String(piece.prefix(1)),default:[:]][piece.last!,default:0]+=1};self.counts=counts}
    init?(fen:String){guard let board=TrainingMaterial.board(fen:fen) else{return nil};self.init(board:board)}
    /// The other side's pieces that `side` ("w" or "b") has captured, most valuable first.
    func captured(by side:String)->[Character] {
        let lost=counts[side=="w" ? "b":"w"] ?? [:],promoted=Self.order.dropLast().reduce(0){$0+max(0,(lost[$1] ?? 0)-Self.fullSet[$1]!)}
        return Self.order.flatMap{kind->[Character] in let present=(lost[kind] ?? 0)+(kind=="p" ? promoted:0);return Array(repeating:kind,count:max(0,Self.fullSet[kind]!-present))}
    }
    private func material(_ side:String)->Int {(counts[side] ?? [:]).reduce(0){$0+TrainingMaterial.value(String($1.key))*$1.value}}
    /// How far `side` is ahead in material (queen 9, rook 5, bishop and knight 3, pawn 1); 0 when it is not ahead.
    func lead(for side:String)->Int {max(0,material(side)-material(side=="w" ? "b":"w"))}
    var isEmpty:Bool {captured(by:"w").isEmpty && captured(by:"b").isEmpty && lead(for:"w")==0 && lead(for:"b")==0}
}

/// Each side's captured pieces, drawn small, with "+N" beside the side ahead. Practice, review and the network game
/// show it under the board's heading; it is counted from the board shown, so a review step or an earlier practice
/// position shows that position's material.
struct MaterialRow:View {
    let balance:MaterialBalance
    /// The side whose pieces sit at the bottom of the board; its captures go on the lower row.
    var blackAtBottom=false
    static let pieceSide:CGFloat=18
    /// The rows in board order, top to bottom: the side at the top of the board first.
    static func sides(blackAtBottom:Bool)->[String] {blackAtBottom ? ["w","b"]:["b","w"]}
    /// A count of captured pieces of one kind, through the catalog's plural variations: "1 knight", "2 pawns".
    private static func counted(_ count:Int,_ kind:Character)->String {
        switch kind {
        case "q":String(localized:"\(count) queens",bundle:.checkmate,comment:"Captured pieces of one kind, in a list read by VoiceOver: White captured 1 queen and 2 pawns")
        case "r":String(localized:"\(count) rooks",bundle:.checkmate,comment:"Captured pieces of one kind, in a list read by VoiceOver: White captured 2 rooks and 1 pawn")
        case "b":String(localized:"\(count) bishops",bundle:.checkmate,comment:"Captured pieces of one kind, in a list read by VoiceOver: White captured 1 bishop and 2 pawns")
        case "n":String(localized:"\(count) knights",bundle:.checkmate,comment:"Captured pieces of one kind, in a list read by VoiceOver: White captured 1 knight and 2 pawns")
        default:String(localized:"\(count) pawns",bundle:.checkmate,comment:"Captured pieces of one kind, in a list read by VoiceOver: White captured 1 knight and 2 pawns")
        }
    }
    /// What VoiceOver reads for one side: "White captured 1 knight and 2 pawns, ahead by 3".
    static func summary(_ balance:MaterialBalance,side:String)->String {
        let captured=balance.captured(by:side),kinds=MaterialBalance.order.filter(captured.contains)
        let list=Plural.list(kinds.map{kind in counted(captured.filter{$0==kind}.count,kind)})
        let what=switch (side=="w",kinds.isEmpty) {
        case (true,true):String(localized:"White captured nothing",bundle:.checkmate,comment:"Read by VoiceOver beside the board when White has taken no pieces")
        case (false,true):String(localized:"Black captured nothing",bundle:.checkmate,comment:"Read by VoiceOver beside the board when Black has taken no pieces")
        case (true,false):String(localized:"White captured \(list)",bundle:.checkmate,comment:"Read by VoiceOver beside the board: White captured 1 knight and 2 pawns")
        case (false,false):String(localized:"Black captured \(list)",bundle:.checkmate,comment:"Read by VoiceOver beside the board: Black captured 1 knight and 2 pawns")
        }
        let lead=balance.lead(for:side)
        return lead>0 ? String(localized:"\(what), ahead by \(lead)",bundle:.checkmate,comment:"A side's captures and its material lead in points, read by VoiceOver: White captured 1 knight, ahead by 3"):what
    }
    /// Nothing until a piece has been captured or promoted, so a fresh board stays uncluttered.
    var body:some View {
        if !balance.isEmpty {VStack(alignment:.leading,spacing:2){ForEach(Self.sides(blackAtBottom:blackAtBottom),id:\.self){side in row(side)}}
            .accessibilityElement(children:.contain).accessibilityIdentifier("material-balance")}
    }
    private func row(_ side:String)->some View {
        let lead=balance.lead(for:side),other=side=="w" ? "b":"w",pieces:[String]=balance.captured(by:side).map{other+String($0)}
        return HStack(spacing:-4){
            ForEach(Array(pieces.enumerated()),id:\.offset){item in piece(item.element)}
            if lead>0{Text(verbatim:"+\(lead)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).padding(.leading,8)}
        }.frame(minHeight:Self.pieceSide).accessibilityElement(children:.ignore).accessibilityLabel(Self.summary(balance,side:side)).accessibilityIdentifier("material-"+side)
    }
    private func piece(_ code:String)->some View {Image(nsImage:PieceArtwork.image(code,side:Self.pieceSide)).accessibilityHidden(true)}
}

/// The practice drawer's row: the board shown, which is an earlier position while the learner browses the moves.
struct PracticeMaterial:View {
    @ObservedObject var session:GameSession
    @ObservedObject var history:PracticeHistory
    var body:some View {
        let game=PracticeHistory.Game(generation:session.gameGeneration,position:session.position,history:session.rules.history)
        let earlier=session.displayView=="game" ? history.ply(in:game).flatMap{TrainingMaterial.board(fen:session.rules.records[$0].before)}:nil
        MaterialRow(balance:MaterialBalance(board:earlier ?? session.displayBoard),blackAtBottom:session.humanSide=="b")
    }
}
