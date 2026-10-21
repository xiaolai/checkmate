import AppKit
import SwiftUI
import CheckmateCore
/// A read-only look at an earlier position of the practice game (B-9). It belongs to the exact game position it was
/// opened over, so any move, reply, take-back or new game returns the board to the live position by itself. The game,
/// its saved progress and what an agent sees as the displayed view are never changed by it.
@MainActor final class PracticeHistory:ObservableObject {
    struct Game:Equatable {let generation:Int,position:Int,history:[String]}
    /// The game it was opened over and how many of its moves the shown board has played.
    @Published private(set) var shown:(game:Game,ply:Int)?
    /// The move list's choice, answered by the window that owns the board.
    var choose:(Int)->Void={_ in}
    /// The ply shown in `game`, or nil at the live position, including when the game has changed since it was opened.
    func ply(in game:Game)->Int? {guard let shown,shown.game==game,shown.ply<game.history.count else{return nil};return shown.ply}
    /// Shows the board after `ply` moves; the full game is the live position.
    func show(_ ply:Int,in game:Game){shown=(0..<game.history.count).contains(ply) ? (game,ply):nil}
    func close(){if shown != nil{shown=nil}}
}
/// The practice game's moves, each a button that shows the board after it, with the earlier-position marker.
struct PracticeMoveList:View {
    @ObservedObject var session:GameSession
    @ObservedObject var history:PracticeHistory
    /// "1. e4", "1... e5": numbered from the game's starting move number and side to move, as the saved move text is.
    static func labels(_ records:[MoveRecord])->[String] {
        guard let first=records.first else{return []};var number=Int(first.before.split(separator:" ").last ?? "1") ?? 1,labels:[String]=[]
        for record in records {labels.append(record.color=="w" ? "\(number). \(record.san)":"\(number)... \(record.san)");if record.color=="b"{number+=1}}
        return labels
    }
    /// One row per move number: its White move and its Black move, either of which may be missing at the ends.
    static func rows(_ records:[MoveRecord])->[(number:String,white:Int?,black:Int?)] {
        var rows:[(number:String,white:Int?,black:Int?)]=[]
        for (index,label) in labels(records).enumerated() {let number=String(label.prefix{$0 != "."});if records[index].color=="w" || rows.last?.number != number || rows.last?.black != nil{rows.append((number,nil,nil))};if records[index].color=="w"{rows[rows.count-1].white=index}else{rows[rows.count-1].black=index}}
        return rows
    }
    var body:some View {
        Text("Moves").sectionHeading()
        if session.rules.history.isEmpty {Text("Your story starts with one move.")}
        else {
            let records=session.rules.records,labels=Self.labels(records),game=PracticeHistory.Game(generation:session.gameGeneration,position:session.position,history:session.rules.history),shown=history.ply(in:game)
            if let shown {
                VStack(alignment:.leading,spacing:Metrics.smallGap){
                    Label(shown==0 ? String(localized:"Starting position",bundle:.checkmate):String(localized:"Earlier position, after \(labels[shown-1])",bundle:.checkmate),symbol:.earlierPosition).font(.callout.bold())
                    Text("You can look, but moves can't be played here.").foregroundStyle(.secondary)
                    Button("Back to Game"){history.close()}.accessibilityIdentifier("practice-history-back")
                }.padding(Metrics.smallGap).frame(maxWidth:.infinity,alignment:.leading).background(RoundedRectangle(cornerRadius:6).fill(Color.accentColor.opacity(0.12))).accessibilityElement(children:.contain).accessibilityIdentifier("practice-history-marker")
            }
            let current=(shown ?? records.count)-1
            Grid(alignment:.leading,horizontalSpacing:Metrics.smallGap,verticalSpacing:2){
                ForEach(Array(Self.rows(records).enumerated()),id:\.offset){_,row in
                    GridRow{Text(row.number+".").foregroundStyle(.secondary).accessibilityHidden(true);move(row.white,records,labels,current);move(row.black,records,labels,current)}
                }
            }
        }
    }
    @ViewBuilder private func move(_ index:Int?,_ records:[MoveRecord],_ labels:[String],_ current:Int)->some View {
        if let index {
            Button(records[index].san){history.choose(index)}.buttonStyle(.borderless).fontWeight(index==current ? .bold:.regular)
                .accessibilityLabel(labels[index]).accessibilityAddTraits(index==current ? .isSelected:[]).help("Show the board after \(labels[index])")
        } else {Text("")}
    }
}
extension GameWindow {
    var historyGame:PracticeHistory.Game {let game=practiceGame;return PracticeHistory.Game(generation:game.generation,position:game.position,history:game.history)}
    /// The practice game's own board with at least one move, outside a review: the only board whose moves can be browsed.
    var historyBrowsable:Bool {let s=model.session;return s.mode == .practice && s.displayView=="game" && !model.review.active && !model.reviewWorkspace && !s.rules.history.isEmpty}
    /// How many moves the shown earlier position has played, or nil at the live position.
    var shownHistoryPly:Int? {historyBrowsable ? history.ply(in:historyGame):nil}
    /// Shows the board after the move at `index` of the game; the last move is the live position.
    func showPracticeMove(_ index:Int){guard historyBrowsable else{return};history.show(index+1,in:historyGame);refresh();announceHistory()}
    /// One move back or forward; false at either end.
    @discardableResult func stepHistory(_ delta:Int)->Bool {
        guard historyBrowsable else{return false};let game=historyGame,current=history.ply(in:game) ?? game.history.count,next=max(0,min(game.history.count,current+delta))
        guard next != current else{return false};history.show(next,in:game);refresh();announceHistory();return true
    }
    /// Left and Right Arrow step through the moves only when nothing nearer wants them: the focused board explores its
    /// squares, a text field moves its caret, and a modifier makes the keys a shortcut. A practice game with moves only.
    static func historyArrow(keyCode:UInt16,modifiers:NSEvent.ModifierFlags,boardFocused:Bool,textFocused:Bool,browsable:Bool)->Int? {
        guard browsable,!boardFocused,!textFocused,modifiers.intersection([.command,.control,.option,.shift]).isEmpty else{return nil}
        switch keyCode {case 123:return -1;case 124:return 1;default:return nil}
    }
    /// A key the window received because nothing focused handled it.
    func historyKey(_ event:NSEvent)->Bool {
        let responder=window?.firstResponder
        guard let delta=Self.historyArrow(keyCode:event.keyCode,modifiers:event.modifierFlags,boardFocused:responder === board,textFocused:responder is NSText,browsable:historyBrowsable) else{return false}
        stepHistory(delta);return true
    }
    /// What VoiceOver hears as the shown position changes.
    func announceHistory(){
        let records=model.session.rules.records,labels=PracticeMoveList.labels(records)
        let text=shownHistoryPly.map{$0==0 ? String(localized:"Starting position. Moves can't be played here.",bundle:.checkmate):String(localized:"After \(labels[$0-1]). Earlier position; moves can't be played here.",bundle:.checkmate)} ?? String(localized:"Back to the game.",bundle:.checkmate)
        NSAccessibility.post(element:board,notification:.announcementRequested,userInfo:[.announcement:text,.priority:NSAccessibilityPriorityLevel.high.rawValue])
    }
    static let earlierPositionRefusal=String(localized:"This is an earlier position. Choose Back to Game to play.",bundle:.checkmate)
    /// A click on the board of an earlier position explains why nothing happens.
    func refuseHistoryMove(){NSAccessibility.post(element:board,notification:.announcementRequested,userInfo:[.announcement:Self.earlierPositionRefusal,.priority:NSAccessibilityPriorityLevel.high.rawValue])}
}
