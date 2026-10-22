import SwiftUI
import Charts
import CheckmateCore
/// Pure formatting for the review pane, kept apart from the views so each rule is unit-tested.
enum ReviewFormat {
    /// One row of the move table: White's and Black's move of a full move, as node IDs. A record starting with Black
    /// to move has no White move in its first row.
    struct MoveRow:Equatable {let number:Int;var white:Int?,black:Int?}
    /// Rows from each node's own move number and side, never from its index in the line.
    static func rows(_ d:GameDocument,line:[Int])->[MoveRow] {
        var rows:[MoveRow]=[]
        for id in line {let n=d.nodes[id]
            if n.side=="b",let last=rows.last,last.number==n.fullmove,last.black==nil{rows[rows.count-1].black=id}
            else if n.side=="b"{rows.append(MoveRow(number:n.fullmove,white:nil,black:id))}else{rows.append(MoveRow(number:n.fullmove,white:id,black:nil))}
        }
        return rows
    }
    /// One line of the move list (R-8): a row of the main line, a recorded variation (`depth` 1 replaces a main-line
    /// move, 2 a move of a variation, and so on) or a kept idea, each under the row of the move it replaces.
    enum Entry:Equatable,Identifiable {case row(MoveRow),line([Int],depth:Int),idea(ReviewBranch)
        /// What the line shows, so its identity survives lines added above it: a row by its first move, a variation by
        /// its first move (each move starts at most one), an idea by its own ID.
        enum ID:Hashable {case row(Int),line(Int),idea(UUID)}
        var id:ID {switch self{case .row(let row):return .row(row.white ?? row.black ?? -1);case .line(let ids,_):return .line(ids.first ?? -1);case .idea(let branch):return .idea(branch.id)}}
    }
    @MainActor static func entries(_ d:GameDocument,ideas:[ReviewBranch])->[Entry] {
        // A variation runs along the record's first choices; the alternatives inside it, then the ideas played from its
        // positions, follow it. An idea from the end of a line follows that line too.
        func lines(replacing id:Int,depth:Int)->[Entry] {
            guard let parent=d.nodes[id].parent else{return []}
            return d.nodes[parent].children.dropFirst().flatMap{start->[Entry] in
                var line=[start];while let last=line.last,let next=d.nodes[last].children.first{line.append(next)}
                return [.line(line,depth:depth)]+line.dropFirst().flatMap{lines(replacing:$0,depth:depth+1)}+ideas.filter{line.contains($0.root)}.map{.idea($0)}
            }
        }
        let main=line(d).ids,end:[Entry]=ideas.filter{$0.root==main.last}.map{.idea($0)}
        return rows(d,line:main).flatMap{row->[Entry] in [.row(row)]+[row.white,row.black].compactMap{$0}.flatMap{id in lines(replacing:id,depth:1)+ideas.filter{$0.root==d.nodes[id].parent}.map{.idea($0)}}}+end
    }
    /// A variation's move: numbered at the line's start and on White's moves, as in "1… c5 2. Nf3 d6".
    static func variationMoveText(_ n:GameNode,first:Bool)->String {first || n.side=="w" ? moveText(n):n.san ?? ""}
    /// The accessibility label of a move, e.g. "2, Black, dxc4"; acceptance gates find moves by it.
    static func moveLabel(_ n:GameNode)->String {"\(n.fullmove), \(PieceName.side(n.side)), \(n.san ?? "")"}
    static func moveText(_ n:GameNode)->String {n.moveText}
    /// "Leaves opening theory at 12… Nf5" as one localized sentence, the move a link the header opens by selecting it.
    static func leavesTheory(_ n:GameNode)->AttributedString {var move=AttributedString(moveText(n));move.link=URL(string:"checkmate-review:leaves-theory");return AttributedString(localized:"Leaves opening theory at \(move)",bundle:.checkmate,comment:"The move where the reviewed game leaves the opening book, shown as a link and read aloud")}
    /// An imagined line's name, e.g. "After 18…Nf5: 19.Qh5 Kh8 …": the move it branches after, then its first `plies`
    /// moves. The list stops at a move that cannot be played, so a damaged idea is still named.
    static func ideaLabel(_ d:GameDocument,_ branch:ReviewBranch,plies:Int=3)->String {
        let root=d.nodes.indices.contains(branch.root) ? d.nodes[branch.root]:nil
        let head=root.flatMap{node in node.san.map{String(localized:"After \(node.fullmove)\(node.side=="w" ? ".":"…")\($0)",bundle:.checkmate)}} ?? String(localized:"From the start",bundle:.checkmate)
        // A root the record does not hold has no position to play the line from: the idea is named by its root alone.
        var moves:[String]=[];let rules:ChessRules;do{rules=try d.snapshotRules(at:branch.root)}catch{return branch.moves.isEmpty ? head:"\(head): …"}
        for (index,uci) in branch.moves.prefix(plies).enumerated() {
            let move:MoveRecord;do{move=try rules.move(uci:uci)}catch{break}
            let number=Int(move.before.split(separator:" ").last ?? "") ?? 1
            moves.append(move.color=="w" ? "\(number).\(move.san)":index==0 ? "\(number)…\(move.san)":move.san)
        }
        if moves.count<branch.moves.count{moves.append("…")}
        return moves.isEmpty ? head:"\(head): \(moves.joined(separator:" "))"
    }
    /// An open imagined line's moves as the move list writes them, each numbered by its full move: "1… c5", "2. Nf3".
    /// The list stops at a move that cannot be played.
    static func ideaMoves(_ d:GameDocument,_ branch:ReviewBranch)->[String] {
        guard let rules=try? d.snapshotRules(at:branch.root) else{return []};var moves:[String]=[]
        for uci in branch.moves {guard let move=try? rules.move(uci:uci) else{break};moves.append("\(Int(move.before.split(separator:" ").last ?? "") ?? 1)\(move.color=="w" ? ".":"…") \(move.san)")}
        return moves
    }
    /// The kept ideas' heading: "My imagined lines (3)". The limit is named only once it is near, "(95 of 100)", so a
    /// learner is told before the oldest idea gives way rather than shown an internal number from the first idea.
    static func ideaListTitle(count:Int)->String {
        count>=ReviewPolicy.maximumBranches-10 ? String(localized:"My imagined lines (\(count) of \(ReviewPolicy.maximumBranches))",bundle:.checkmate,comment:"The kept imagined lines' heading near the limit: how many, of how many can be kept"):String(localized:"My imagined lines (\(count))",bundle:.checkmate,comment:"The kept imagined lines' heading: how many there are")
    }
    /// The header's opening (R-20): "D37 · Queen's Gambit Declined: Three Knights Variation", or nil before any named
    /// position, and the main-line move that leaves the book, nil while the game is still in it. Nil for a record the
    /// book has no position of. Kept per record content; a book that cannot be read is logged and names nothing.
    struct OpeningHeader:Equatable {let title:String?,leaves:Int?}
    @MainActor private static var openings:[String:OpeningHeader?] = [:]
    @MainActor static func openingHeader(_ d:GameDocument)->OpeningHeader? {
        if let known=openings[d.contentHash]{return known}
        var value:OpeningHeader?
        do{value=try OpeningBook.bundled().classify(d).map{OpeningHeader(title:$0.opening.map{"\($0.eco) · \($0.name)"},leaves:$0.leavesTheory)}}catch{NativeLog.storage.error("The opening book could not be read: \(String(describing:error),privacy:.public)")}
        if openings.count>=32{openings.removeAll()};openings[d.contentHash] = .some(value);return value
    }
    /// A cancelled whole-game analysis: how far it got before the deeper check of its leading moment.
    static func partialAnalysis(completed:Int,total:Int)->String {completed<total ? String(localized:"Analyzed \(completed) of \(total) moves",bundle:.checkmate):String(localized:"Analyzed all \(total) moves; the deeper check is unfinished",bundle:.checkmate)}
    /// A header value worth showing: not empty, not "?" and not an all-unknown date.
    static func known(_ value:String?)->String? {
        guard let value=value?.trimmingCharacters(in:.whitespacesAndNewlines),!value.isEmpty,value.contains(where:{$0 != "?" && $0 != "."}) else{return nil};return value
    }
    /// A PGN date with its unknown trailing parts removed: "1912.??.??" is "1912".
    static func date(_ value:String?)->String? {
        guard let value=known(value) else{return nil};var parts=value.split(separator:".",omittingEmptySubsequences:false).map(String.init)
        while let last=parts.last,last.allSatisfy({$0=="?"}){parts.removeLast()};return parts.isEmpty ? nil:parts.joined(separator:".")
    }
    /// The header's first line: the players, or what the record is when they are unknown.
    static func players(_ d:GameDocument)->String {
        if let own=d.provenance.ownGameTitle{return own}
        let white=known(d.header("White")),black=known(d.header("Black"))
        if white != nil || black != nil{return "\(white ?? PieceName.side("w")) – \(black ?? PieceName.side("b"))"}
        return d.historyAvailable ? String(localized:"Imported game",bundle:.checkmate):String(localized:"Imported position",bundle:.checkmate)
    }
    /// The header's second line: event, site and date, leaving out unknown parts and a site that only repeats the event.
    static func details(_ d:GameDocument)->String? {
        var parts:[String]=[]
        for value in [known(d.header("Event")),known(d.header("Site")),date(d.header("Date"))].compactMap({$0}) where !parts.contains(where:{value.hasPrefix($0) || $0.hasPrefix(value)}){parts.append(value)}
        return parts.isEmpty ? nil:parts.joined(separator:" · ")
    }
    /// A network game's agreed assistance (assistance plan A11): "Assistance: White: Hints on request; Black: Off". Nil
    /// for a record without the tag, which every game without assistance is.
    static func assistance(_ d:GameDocument)->String? {known(d.header("Assistance")).map{String(localized:"Assistance: \($0)",bundle:.checkmate,comment:"A network game's agreed help, from its record")}}
    static func result(_ result:String)->String {switch result{case "1-0":return "1–0";case "0-1":return "0–1";case "1/2-1/2":return "½–½";default:return String(localized:"Unfinished",bundle:.checkmate)}}
    /// A score from White's side: "+0.8", "−1.4", "0.0", "M3" (White mates), "−M2" (Black mates); a bound is marked.
    static func score(_ s:AnalysisScore)->String {
        let bound=s.bound=="lower" ? "≥":s.bound=="upper" ? "≤":""
        if s.kind=="mate"{return bound+(s.value==0 ? "#":s.value>0 ? "M\(s.value)":"−M\(-s.value)")}
        let pawns=Double(s.value)/100,text=String(format:"%.1f",abs(pawns));return bound+(text=="0.0" ? text:(pawns>0 ? "+":"−")+text)
    }
    /// The evaluation bar in plain words, from White's side, for VoiceOver: "Evaluation: White ahead by 1.2 pawns". Like
    /// the bar it ignores a bound; nil only for a score kind it cannot read.
    static func evaluationLabel(_ s:AnalysisScore)->String? {
        if s.kind=="mate"{let moves=abs(s.value);return s.value==0 ? String(localized:"Evaluation: checkmate",bundle:.checkmate,comment:"The evaluation bar read aloud when the position is already checkmate"):s.value>0 ? String(localized:"Evaluation: White can force checkmate in \(moves) moves",bundle:.checkmate,comment:"The evaluation bar read aloud"):String(localized:"Evaluation: Black can force checkmate in \(moves) moves",bundle:.checkmate,comment:"The evaluation bar read aloud")}
        guard s.kind=="cp" else{return nil};let pawns=Double(s.value)/100,text=String(format:"%.1f",abs(pawns))
        return text=="0.0" ? String(localized:"Evaluation: even",bundle:.checkmate,comment:"The evaluation bar read aloud when neither side is ahead"):pawns>0 ? String(localized:"Evaluation: White ahead by \(text) pawns",bundle:.checkmate,comment:"The evaluation bar read aloud; the number is in pawns"):String(localized:"Evaluation: Black ahead by \(text) pawns",bundle:.checkmate,comment:"The evaluation bar read aloud; the number is in pawns")
    }
    /// The overview's takeaways without any the summary already says.
    static func takeaways(_ e:ReviewExplanation?)->[String] {guard let e else{return []};return e.takeaways.filter{let item=$0.trimmingCharacters(in:.whitespaces);return !item.isEmpty && !e.summary.contains(item)}}
    static let evaluationLimit=5.0
    /// What the record's final position is worth whatever the engine returned: the limit for the side that mated, 0 for
    /// any other finished board or a recorded draw (agreed or claimed), nil when the game simply stops. The board decides
    /// over a contradicting Result tag. Building the board runs the rules engine, so the view asks once per record.
    static func finalOutcome(_ d:GameDocument)->Double? {
        guard let last=d.mainline.last else{return nil}
        if let status=try? d.status(at:last),status.terminal{return status.checkmate ? (d.nodes[last].side=="w" ? evaluationLimit:-evaluationLimit):0}
        return d.result=="1/2-1/2" ? 0:nil
    }
    @MainActor private static var outcomes:[String:Double?] = [:]
    /// `finalOutcome`, kept per record content so redrawing the graph (a drag, a new selection) does not rebuild the board.
    @MainActor static func cachedOutcome(_ d:GameDocument)->Double? {
        if let known=outcomes[d.contentHash]{return known};let value=finalOutcome(d)
        if outcomes.count>=32{outcomes.removeAll()};outcomes[d.contentHash] = .some(value);return value
    }
    /// The evaluation graph's samples in pawns from White's side, clamped to ±5: index 0 is the start, index i the
    /// position after the mainline's i-th move. A missing score is a gap (nil), never 0. `outcome` (see
    /// `finalOutcome`) replaces the final sample when the record says how the game ended.
    @MainActor static func series(_ d:GameDocument,evaluations:[Int:AnalysisScore],outcome:Double?)->[Double?] {
        func value(_ s:AnalysisScore?)->Double? {guard let s else{return nil};if s.kind=="mate"{return s.value>0 ? evaluationLimit:s.value<0 ? -evaluationLimit:nil};return min(evaluationLimit,max(-evaluationLimit,Double(s.value)/100))}
        var samples=[value(evaluations[0])]+line(d).ids.map{value(evaluations[$0])}
        if let outcome,samples.count>1{samples[samples.count-1]=outcome}
        return samples
    }
    /// A record's mainline and each node's place in it. Walking the mainline visits every node, so the pane builds it
    /// once per record content rather than on every redraw, drag or selection.
    struct Line {let ids:[Int],position:[Int:Int]}
    @MainActor private static var lines:[String:Line] = [:]
    @MainActor static func line(_ d:GameDocument)->Line {
        if let known=lines[d.contentHash]{return known};let ids=d.mainline,value=Line(ids:ids,position:Dictionary(ids.enumerated().map{($1,$0)},uniquingKeysWith:{a,_ in a}))
        if lines.count>=32{lines.removeAll()};lines[d.contentHash] = value;return value
    }
    /// The mainline index of a node (0 for the start), or nil off the mainline.
    @MainActor static func mainlineIndex(_ d:GameDocument,node:Int?)->Int? {guard let node else{return nil};if node==0{return 0};return line(d).position[node].map{$0+1}}
    /// The node shown at a mainline index.
    @MainActor static func node(_ d:GameDocument,index:Int)->Int {let ids=line(d).ids;return index<=0 || ids.isEmpty ? 0:ids[min(index,ids.count)-1]}
    /// Checks, captures, promotions and the final move: the moments to start with before any engine analysis.
    @MainActor static func heuristicMoments(_ d:GameDocument)->[Int] {let ids=line(d).ids,last=ids.last;return ids.filter{id in let san=d.nodes[id].san ?? "";return san.contains("+") || san.contains("#") || san.contains("x") || san.contains("=") || id==last}}
    /// The standard annotation glyphs (PGN NAGs) the review shows, with what each says; other numbers are left out.
    private static let annotations:[Int:(glyph:String,meaning:String)]=[1:("!",String(localized:"Good move",bundle:.checkmate)),2:("?",String(localized:"Poor move",bundle:.checkmate)),3:("!!",String(localized:"Brilliant move",bundle:.checkmate)),4:("??",String(localized:"Very poor move",bundle:.checkmate)),5:("!?",String(localized:"Interesting move",bundle:.checkmate)),6:("?!",String(localized:"Dubious move",bundle:.checkmate)),7:("□",String(localized:"Only move",bundle:.checkmate)),10:("=",String(localized:"Equal position",bundle:.checkmate)),13:("∞",String(localized:"Unclear position",bundle:.checkmate)),14:("⩲",String(localized:"White is slightly better",bundle:.checkmate)),15:("⩱",String(localized:"Black is slightly better",bundle:.checkmate)),16:("±",String(localized:"White is better",bundle:.checkmate)),17:("∓",String(localized:"Black is better",bundle:.checkmate)),18:("+−",String(localized:"White is winning",bundle:.checkmate)),19:("−+",String(localized:"Black is winning",bundle:.checkmate))]
    /// A move's annotation glyphs as the record gives them: move glyphs, then position glyphs after a space ("!! ±").
    static func glyphs(_ nags:[Int])->String {
        let move=nags.filter{$0<=9}.compactMap{annotations[$0]?.glyph}.joined(),position=nags.filter{$0>9}.compactMap{annotations[$0]?.glyph}.joined(separator:" ")
        return [move,position].filter{!$0.isEmpty}.joined(separator:" ")
    }
    /// What a move's glyphs say, for VoiceOver and help; nil without a known glyph.
    static func glyphMeanings(_ nags:[Int])->String? {let words=nags.compactMap{annotations[$0]?.meaning};return words.isEmpty ? nil:words.joined(separator:", ")}
    /// A node's comments from the record, without embedded commands such as [%clk …] or [%eval …].
    static func comments(_ n:GameNode)->[String] {
        (n.commentsBefore+n.commentsAfter).map{$0.replacingOccurrences(of:#"\[%[^\]]*\]"#,with:"",options:.regularExpression).split(whereSeparator:\.isWhitespace).joined(separator:" ")}.filter{!$0.isEmpty}
    }
    /// Why a move is graded, from the side that played it: "Mistake (?): this move gave up about 15% of White's chances."
    static func gradeLine(_ grade:MoveGrade,loss:Double,side:String)->String {String(localized:"\(grade.name) (\(grade.glyph)): this move gave up about \(Int((loss*100).rounded()))% of \(PieceName.side(side))'s chances.",bundle:.checkmate)}
    /// The position at a graph index: "Start" or its move, e.g. "2. Nf3".
    @MainActor private static func position(_ d:GameDocument,index:Int)->String {index<=0 ? String(localized:"Start",bundle:.checkmate,comment:"Noun: the starting position of a game"):moveText(d.nodes[node(d,index:index)])}
    /// The graph's hover readout: "2. Nf3?! +0.8"; a position without a score says so.
    @MainActor static func readout(_ d:GameDocument,index:Int,score:AnalysisScore?,grade:MoveGrade?)->String {
        let head=position(d,index:index)+(index>0 ? grade?.glyph ?? "":"");return score.map{"\(head) \(self.score($0))"} ?? String(localized:"\(head), no score",bundle:.checkmate,comment:"The graph's hover readout of a position without a score")
    }
    /// A graph point as VoiceOver reads it: "2. Nf3, +0.8, inaccuracy"; one whole format per shape.
    @MainActor static func pointLabel(_ d:GameDocument,index:Int,score:AnalysisScore?,grade:MoveGrade?)->String {
        let move=position(d,index:index),named=index>0 ? grade?.name.lowercased():nil
        switch (score.map{self.score($0)},named) {
        case let (value?,named?):return String(localized:"\(move), \(value), \(named)",bundle:.checkmate,comment:"A graph point: the move, its score, its grade")
        case let (value?,nil):return String(localized:"\(move), \(value)",bundle:.checkmate,comment:"A graph point: the move, its score")
        case let (nil,named?):return String(localized:"\(move), no score, \(named)",bundle:.checkmate,comment:"A graph point: the move without a score, then its grade")
        case (nil,nil):return String(localized:"\(move), no score",bundle:.checkmate,comment:"A graph point: the move without a score")
        }
    }
    /// The graph's label carries the selected move, its score and grade, since a chart reports no value; the pointer
    /// gate reads the move number from it.
    @MainActor static func graphLabel(_ d:GameDocument,index:Int?,score:AnalysisScore?,grade:MoveGrade?)->String {
        guard let index else{return String(localized:"Evaluation graph, not on the main line",bundle:.checkmate)}
        return String(localized:"Evaluation graph, \(pointLabel(d,index:index,score:score,grade:grade))",bundle:.checkmate,comment:"The evaluation graph's label: the selected move, its score and grade")
    }
    /// The engine comparison's caption, with the depth its first line reached.
    static func evidenceCaption(provisional:Bool,depth:Int?)->String {
        guard let depth,depth>0 else{return provisional ? String(localized:"Provisional engine estimate",bundle:.checkmate):String(localized:"Deeper engine comparison",bundle:.checkmate)}
        return provisional ? String(localized:"Provisional engine estimate · depth \(depth)",bundle:.checkmate,comment:"The engine comparison's caption and the search depth it reached"):String(localized:"Deeper engine comparison · depth \(depth)",bundle:.checkmate,comment:"The engine comparison's caption and the search depth it reached")
    }
    /// At most `limit` moments, in game order. `ids` is most important first: engine moments arrive that way; for the
    /// heuristic the final move counts first, then the earliest.
    @MainActor static func keyMoments(_ ids:[Int],in d:GameDocument,limit:Int=5,engine:Bool)->[Int] {
        let position=line(d).position,known=ids.filter{position[$0] != nil},ranked=engine ? known:known.last.map{[$0]+known.dropLast()} ?? []
        return Array(ranked.prefix(limit)).sorted{position[$0]!<position[$1]!}
    }
}

/// The native grouped-content surface: control background with a hairline, in light, dark and increased contrast.
struct ReviewCard:View {
    let radius:CGFloat
    var body:some View {RoundedRectangle(cornerRadius:radius).fill(Color(nsColor:.controlBackgroundColor)).overlay(RoundedRectangle(cornerRadius:radius).strokeBorder(Color(nsColor:.separatorColor),lineWidth:0.5))}
}
/// Players, event and result, with the record's actions.
struct ReviewHeader:View {
    @ObservedObject var review:ReviewController
    @ObservedObject var model:NativeModel
    let document:GameDocument
    var body:some View {VStack(alignment:.leading,spacing:Metrics.smallGap){
        HStack(alignment:.firstTextBaseline,spacing:Metrics.smallGap){
            VStack(alignment:.leading,spacing:2){
                // Imported header text is shown as written, never interpreted as Markdown.
                // One line each, shortened in the middle so both players' names stay readable; help shows the whole text.
                Text(verbatim:ReviewFormat.players(document)).sectionHeading(.title3.bold()).lineLimit(1).truncationMode(.middle).help(ReviewFormat.players(document))
                if let details=ReviewFormat.details(document){Text(verbatim:details).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(details)}
                // An opening book is help too: none during a network game.
                if model.fairness.engineHelpAllowed,let opening=ReviewFormat.openingHeader(document) {
                    if let title=opening.title{Text(verbatim:title).font(.subheadline).lineLimit(1).truncationMode(.tail).help(title).accessibilityIdentifier("review-opening")}
                    // One sentence with the move as a link inside it, so a translator can put the move where the language needs it.
                    if let leaves=opening.leaves{Text(ReviewFormat.leavesTheory(document.nodes[leaves])).font(.subheadline).foregroundStyle(.secondary).environment(\.openURL,OpenURLAction{_ in do{try review.select(leaves);model.saveReview()}catch{model.storageError=GameWindow.failureMessage(error)};return .handled}).accessibilityLabel(String(localized:"Leaves opening theory at \(ReviewFormat.moveLabel(document.nodes[leaves]))",bundle:.checkmate,comment:"The move where the reviewed game leaves the opening book, shown as a link and read aloud")).accessibilityAddTraits(.isLink).accessibilityIdentifier("review-leaves-theory")}
                }
                if let assistance=ReviewFormat.assistance(document){Text(verbatim:assistance).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("review-assistance")}
            }
            Spacer(minLength:0)
            Text(ReviewFormat.result(document.result)).font(.caption.weight(.semibold)).monospacedDigit().padding(.horizontal,6).padding(.vertical,2)
                .background(Capsule().fill(.quaternary)).accessibilityLabel("Result: \(ReviewFormat.result(document.result))")
        }
        HStack(spacing:Metrics.smallGap){
            if model.reviewDraft{Button("Save Review"){model.saveCurrentReview()}.buttonStyle(.borderedProminent)}
            // Availability follows the displayed position, including an imagined line from the parent.
            Button("Practice Here"){review.pause();model.practiceFromReview()}.disabled(!review.practiceForkAvailable)
            Spacer(minLength:0)
            Menu{
                Button("Choose Another Game…"){model.showReviewWorkspace()}
                Button("Export PGN…"){model.exportReview()}.disabled(!model.mayExportReview)
                if !model.reviewDraft{Divider();Button("Delete Saved Review…",role:.destructive){model.requestDeleteReview(document.id)}.disabled(model.deletingReviewID != nil)}
            } label:{AppSymbol.moreActions.image}.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Review actions").accessibilityLabel("Review actions").accessibilityIdentifier("review-document-actions")
        }.controlSize(.small)
    }}
}

/// Whole-game analysis: its button, its progress, and the evaluation graph once it is ready.
struct ReviewAnalysisSection:View {
    @ObservedObject var review:ReviewController
    @ObservedObject var model:NativeModel
    @ObservedObject var analyzer:ReviewAnalyzer
    let document:GameDocument
    var body:some View {
        let mine=analyzer.batchDocument==document.id
        VStack(alignment:.leading,spacing:Metrics.smallGap){
            Text("Evaluation").sectionHeading()
            // No engine output during a network game (LAN-play plan D8): the graph and its controls wait until it ends.
            if !model.fairness.engineHelpAllowed{Text(FairnessPolicy.analysisHidden).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
            else if ReviewFormat.line(document).ids.isEmpty{Text("This position has no moves to analyze as a game; Why? analyzes the position itself.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
            else if mine,["pending","deepening"].contains(analyzer.batchStatus){
                ProgressView(value:Double(analyzer.completed),total:Double(max(1,analyzer.total)))
                HStack{Text(analyzer.batchStatus=="deepening" ? String(localized:"Checking key moments more deeply",bundle:.checkmate):String(localized:"\(analyzer.completed) / \(analyzer.total) moves",bundle:.checkmate,comment:"Whole-game analysis progress: moves analyzed of all moves")).font(.caption).foregroundStyle(.secondary);Spacer(minLength:0);Button("Cancel Analysis"){analyzer.cancelBatch()}.controlSize(.small)}
            }
            else if mine,analyzer.batchStatus=="ready"{
                EvaluationGraph(review:review,model:model,analyzer:analyzer,document:document,samples:ReviewFormat.series(document,evaluations:analyzer.evaluations,outcome:ReviewFormat.cachedOutcome(document)))
                if analyzer.failed>0{Text("\(analyzer.failed) of \(analyzer.total) moves could not be analyzed.").font(.caption).foregroundStyle(.secondary)}
                Button("Analyze Again"){analyzer.startBatch(document)}.controlSize(.small)
            }
            // A cancelled run keeps what it finished; Resume searches only the positions still missing.
            else if mine,analyzer.batchStatus=="partial"{
                if !analyzer.evaluations.isEmpty{EvaluationGraph(review:review,model:model,analyzer:analyzer,document:document,samples:ReviewFormat.series(document,evaluations:analyzer.evaluations,outcome:ReviewFormat.cachedOutcome(document)))}
                Text(ReviewFormat.partialAnalysis(completed:analyzer.completed,total:analyzer.total)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Button("Resume Analysis"){analyzer.startBatch(document)}.controlSize(.small).accessibilityIdentifier("review-resume-analysis")
            }
            else{
                if mine,analyzer.batchStatus=="failed"{Text("Offline analysis is unavailable for this game. The record remains navigable; try again later.").font(.caption).foregroundStyle(Color(nsColor:NativeColors.error)).fixedSize(horizontal:false,vertical:true)}
                Button("Analyze Whole Game"){analyzer.startBatch(document)}.controlSize(.small)
            }
        }
    }
}

/// The evaluation across the mainline from White's side: White's share is light above the even line, Black's dark
/// below it, clamped to ±5 pawns. Key moments are marked in their grade's colour; hovering reads a position, and a click
/// or drag selects the nearest one.
struct EvaluationGraph:View,AXChartDescriptorRepresentable {
    @ObservedObject var review:ReviewController
    @ObservedObject var model:NativeModel
    @ObservedObject var analyzer:ReviewAnalyzer
    let document:GameDocument,samples:[Double?]
    @State private var hovered:Int?
    @Namespace private var rotor
    /// Every key-moment rotor entry lands on the graph itself, the one element that reads the selected move.
    private static let rotorTarget="evaluation-graph"
    private struct Sample:Identifiable {let id:Int,value:Double,run:Int}
    /// Samples grouped into runs of known scores, so a gap is drawn as a gap.
    private var points:[Sample] {var result:[Sample]=[],run=0;for (i,value) in samples.enumerated(){if let value{result.append(Sample(id:i,value:value,run:run))}else{run+=1}};return result}
    private var last:Int {max(1,samples.count-1)}
    private var selected:Int? {review.branch==nil ? ReviewFormat.mainlineIndex(document,node:review.nodeID):nil}
    private func choose(_ index:Int){let node=ReviewFormat.node(document,index:max(0,min(last,index)));guard review.branch != nil || review.nodeID != node else{return};do{try review.select(node);model.saveReview()}catch{model.storageError=GameWindow.failureMessage(error)}}
    /// The mainline index under a horizontal position in the chart, nil before the plot is laid out.
    private func index(_ x:CGFloat,_ proxy:ChartProxy,_ geometry:GeometryProxy)->Int? {guard let anchor=proxy.plotFrame else{return nil};let plot=geometry[anchor];guard plot.width>0 else{return nil};return max(0,min(last,Int(((x-plot.minX)/plot.width*CGFloat(last)).rounded())))}
    private func score(_ index:Int)->AnalysisScore? {analyzer.evaluations[ReviewFormat.node(document,index:index)]}
    private func grade(_ index:Int)->MoveGrade? {index>0 ? analyzer.grade(ReviewFormat.node(document,index:index)):nil}
    /// The key moments that have a drawn score, as samples.
    private var markers:[Sample] {let known=Dictionary(points.map{($0.id,$0)},uniquingKeysWith:{a,_ in a});return ReviewFormat.keyMoments(analyzer.moments.map(\.id),in:document,engine:true).compactMap{ReviewFormat.mainlineIndex(document,node:$0).flatMap{known[$0]}}}
    var body:some View {
        let points=self.points,singles=Set(Dictionary(grouping:points,by:\.run).filter{$0.value.count==1}.keys),markers=self.markers
        Chart{
            ForEach(points){p in
                AreaMark(x:.value("Position",p.id),yStart:.value("Even",0),yEnd:.value("Score",max(0,p.value)),series:.value("Run","White \(p.run)")).foregroundStyle(Color.white)
                AreaMark(x:.value("Position",p.id),yStart:.value("Even",0),yEnd:.value("Score",min(0,p.value)),series:.value("Run","Black \(p.run)")).foregroundStyle(Color.black.opacity(0.8))
                LineMark(x:.value("Position",p.id),y:.value("Score",p.value),series:.value("Run","Line \(p.run)")).foregroundStyle(Color.gray).lineStyle(StrokeStyle(lineWidth:1))
                if singles.contains(p.run){PointMark(x:.value("Position",p.id),y:.value("Score",p.value)).symbolSize(12).foregroundStyle(Color.gray)}
            }
            RuleMark(y:.value("Even",0)).foregroundStyle(Color.secondary).lineStyle(StrokeStyle(lineWidth:0.75))
            ForEach(markers){m in PointMark(x:.value("Position",m.id),y:.value("Score",m.value)).symbolSize(30).foregroundStyle(ReviewGradeStyle.color(grade(m.id)))}
            if let hovered,hovered != selected{RuleMark(x:.value("Hovered",hovered)).foregroundStyle(Color.primary.opacity(0.35)).lineStyle(StrokeStyle(lineWidth:1,dash:[2,2]))}
            if let selected{RuleMark(x:.value("Selected",selected)).foregroundStyle(Color.primary.opacity(0.7)).lineStyle(StrokeStyle(lineWidth:1))}
        }
        .chartXScale(domain:0...last).chartYScale(domain:-ReviewFormat.evaluationLimit...ReviewFormat.evaluationLimit).chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
        .chartPlotStyle{$0.background(Color.gray.opacity(0.35))}
        .chartOverlay{proxy in GeometryReader{geometry in Rectangle().fill(.clear).contentShape(Rectangle())
            .onContinuousHover{phase in switch phase{case .active(let location):hovered=index(location.x,proxy,geometry);case .ended:hovered=nil}}
            .gesture(DragGesture(minimumDistance:0).onChanged{drag in if let i=index(drag.location.x,proxy,geometry){choose(i)}})}}
        .overlay(alignment:.topLeading){if let hovered{Text(verbatim:ReviewFormat.readout(document,index:hovered,score:score(hovered),grade:grade(hovered))).font(.caption2).monospacedDigit()
            .padding(.horizontal,Metrics.tightGap).padding(.vertical,1).background(.regularMaterial,in:RoundedRectangle(cornerRadius:3)).padding(3).allowsHitTesting(false).accessibilityHidden(true)}}
        .frame(height:64).padding(.vertical,2).background(ReviewCard(radius:6))
        .help("Evaluation from White's side: light above the line favors White, dark below favors Black. Click or drag to choose a position.")
        // A chart element reports no AXValue, so the selected move, its score and grade are part of its label.
        .accessibilityElement(children:.ignore).accessibilityLabel(ReviewFormat.graphLabel(document,index:selected,score:selected.flatMap(score),grade:selected.flatMap(grade))).accessibilityIdentifier("review-evaluation-graph")
        // VoiceOver's rotor steps through the key moments marked on the graph; choosing one selects its move.
        .accessibilityRotorEntry(id:Self.rotorTarget,in:rotor)
        .accessibilityRotor(String(localized:"Key Moments",bundle:.checkmate)){ForEach(markers){m in AccessibilityRotorEntry(Text(verbatim:ReviewFormat.pointLabel(document,index:m.id,score:score(m.id),grade:grade(m.id))),id:Self.rotorTarget,in:rotor){choose(m.id)}}}
        .accessibilityAdjustableAction{direction in switch direction{case .increment:choose((selected ?? -1)+1);case .decrement:choose((selected ?? 1)-1);default:break}}
        .accessibilityChartDescriptor(self)
    }
    func makeChartDescriptor()->AXChartDescriptor {
        // Positions are named by their move, and each point reads as move, score and grade.
        let moves=(0...last).map{$0==0 ? String(localized:"Start",bundle:.checkmate,comment:"Noun: the starting position of a game"):ReviewFormat.moveText(document.nodes[ReviewFormat.node(document,index:$0)])}
        let x=AXNumericDataAxisDescriptor(title:String(localized:"Move",bundle:.checkmate,comment:"Noun: one move in a chess game"),range:0...Double(last),gridlinePositions:[]){let i=Int($0);return moves.indices.contains(i) ? moves[i]:String(localized:"Position \(i)",bundle:.checkmate)}
        let y=AXNumericDataAxisDescriptor(title:String(localized:"Pawns from White's side",bundle:.checkmate),range:-ReviewFormat.evaluationLimit...ReviewFormat.evaluationLimit,gridlinePositions:[0]){String(format:"%+.1f",$0)}
        // One series per run of known scores, as drawn: a position without a score is a gap, not part of a line.
        let runs=Dictionary(grouping:points,by:\.run).sorted{$0.key<$1.key},missing=samples.count-points.count
        let series=runs.enumerated().map{index,run in AXDataSeriesDescriptor(name:runs.count==1 ? String(localized:"Evaluation",bundle:.checkmate):String(localized:"Evaluation, part \(index+1)",bundle:.checkmate),isContinuous:run.value.count>1,dataPoints:run.value.map{AXDataPoint(x:Double($0.id),y:$0.value,additionalValues:[],label:ReviewFormat.pointLabel(document,index:$0.id,score:score($0.id),grade:grade($0.id)))})}
        let summary=Sentences.join(String(localized:"Evaluation after each move of the main line, from White's side.",bundle:.checkmate),missing>0 ? String(localized:"\(missing) of \(samples.count) positions have no score.",bundle:.checkmate,comment:"The evaluation graph's summary: positions without a score"):"")
        return AXChartDescriptor(title:String(localized:"Evaluation graph",bundle:.checkmate),summary:summary,xAxis:x,yAxis:y,additionalAxes:[],series:series)
    }
}
/// A move grade's colour, shared by the move list and the graph's markers; an ungraded key moment uses the accent colour.
enum ReviewGradeStyle {
    static func color(_ grade:MoveGrade?)->Color {switch grade{case .inaccuracy:return Color(nsColor:.systemYellow);case .mistake:return Color(nsColor:.systemOrange);case .blunder:return Color(nsColor:.systemRed);case nil:return Color.accentColor}}
}

/// The mainline as a table of full moves, with the key moments above it.
struct ReviewMoveSection:View {
    @ObservedObject var review:ReviewController
    @ObservedObject var model:NativeModel
    @ObservedObject var analyzer:ReviewAnalyzer
    let document:GameDocument
    /// The list shows whole rows only, up to `visibleRows`; a longer game scrolls inside it.
    private static let rowHeight:CGFloat=22,visibleRows=12
    @Namespace private var rotor
    private var moments:[ReviewMoment] {analyzer.fairness.engineHelpAllowed && analyzer.batchDocument==document.id ? analyzer.moments.filter{document.nodes.indices.contains($0.id)}:[]}
    private func select(_ id:Int){do{try review.select(id);model.saveReview()}catch{model.storageError=GameWindow.failureMessage(error)}}
    var body:some View {
        let moments=self.moments,reasons=Dictionary(moments.map{($0.id,$0.reason)},uniquingKeysWith:{a,_ in a}),rows=ReviewFormat.rows(document,line:ReviewFormat.line(document).ids)
        let graded=analyzer.fairness.engineHelpAllowed && analyzer.batchDocument==document.id,anyGrade=graded && ReviewFormat.line(document).ids.contains{analyzer.grade($0) != nil}
        let ranked=moments.isEmpty ? ReviewFormat.heuristicMoments(document):moments.map(\.id),key=ReviewFormat.keyMoments(ranked,in:document,engine:!moments.isEmpty)
        if !rows.isEmpty {VStack(alignment:.leading,spacing:Metrics.smallGap){
            Text("Moves").sectionHeading()
            if !key.isEmpty {
                ViewThatFits(in:.horizontal){ForEach([5,4,3,2,1],id:\.self){count in HStack(spacing:Metrics.tightGap){ForEach(ReviewFormat.keyMoments(ranked,in:document,limit:count,engine:!moments.isEmpty),id:\.self){id in
                    Button(ReviewFormat.moveText(document.nodes[id])){select(id)}.buttonStyle(.bordered).controlSize(.small).accessibilityLabel("Key moment, \(ReviewFormat.moveLabel(document.nodes[id]))").help(reasons[id] ?? String(localized:"A check, capture, promotion or the final move",bundle:.checkmate))}}}}
                Text(anyGrade ? String(localized:"?! inaccuracy · ? mistake · ?? blunder; estimates may change.",bundle:.checkmate,comment:"The move grades' glyphs and what they mean"):moments.isEmpty ? String(localized:"Checks, captures, promotions and the final move.",bundle:.checkmate):String(localized:"Moments to start with; estimates may change.",bundle:.checkmate)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            let entries=ReviewFormat.entries(document,ideas:review.authoredBranches)
            ScrollViewReader{proxy in
                // Each line is identified by what it shows (`Entry.id`), never by its position: a sideline or an idea
                // added above a row must not leave that row drawn twice.
                ScrollView{LazyVStack(spacing:0){ForEach(Array(entries.enumerated()),id:\.element.id){index,entry in
                    switch entry {
                    case .row(let row):HStack(spacing:Metrics.tightGap){
                        Text("\(row.number).").monospacedDigit().foregroundStyle(.secondary).frame(width:34,alignment:.trailing)
                        cell(row.white,graded:graded,empty:row.white==nil && index==0 ? "…":"");cell(row.black,graded:graded,empty:"")
                    }.frame(height:Self.rowHeight).id(entry.id)
                    case .line(let ids,let depth):variation(ids,depth:depth).id(entry.id)
                    case .idea(let branch):idea(branch).id(entry.id)
                    }
                }}.padding(.vertical,2)}
                .frame(height:CGFloat(min(entries.count,Self.visibleRows))*Self.rowHeight+4)
                .background(ReviewCard(radius:6))
                .onAppear{scroll(proxy,entries)}.onChange(of:review.nodeID){_,_ in withAnimation(.easeInOut(duration:0.15)){scroll(proxy,entries)}}
            }
        }
        // VoiceOver's rotor steps through the key moments in the move list.
        .accessibilityRotor(String(localized:"Key Moments",bundle:.checkmate)){ForEach(key,id:\.self){id in AccessibilityRotorEntry(Text(verbatim:ReviewFormat.moveLabel(document.nodes[id])),id:id,in:rotor)}}}
    }
    private func scroll(_ proxy:ScrollViewProxy,_ entries:[ReviewFormat.Entry]){
        let shown=entries.first{entry in switch entry{case .row(let row):return row.white==review.nodeID || row.black==review.nodeID;case .line(let ids,_):return ids.contains(review.nodeID);case .idea(let branch):return branch.id==review.branch?.id}}
        guard let shown else{return};proxy.scrollTo(shown.id,anchor:.center)
    }
    /// A recorded variation, inline and indented by its depth; each move shows its position, and ↑/↓ reach it too.
    private func variation(_ ids:[Int],depth:Int)->some View {
        ScrollView(.horizontal,showsIndicators:false){HStack(spacing:2){ForEach(Array(ids.enumerated()),id:\.element){index,id in
            let n=document.nodes[id],chosen=review.branch==nil && review.nodeID==id
            Button(ReviewFormat.variationMoveText(n,first:index==0)){select(id)}.buttonStyle(.plain).font(.callout).monospacedDigit()
                .foregroundStyle(chosen ? Color.primary:Color.secondary).fontWeight(chosen ? .semibold:.regular).padding(.horizontal,3)
                .background(RoundedRectangle(cornerRadius:4).fill(chosen ? Color.accentColor.opacity(0.25):Color.clear))
                .accessibilityLabel(String(localized:"Variation, \(ReviewFormat.moveLabel(n))",bundle:.checkmate,comment:"A move of a recorded variation in the move list, read aloud, as in: Variation, 2, Black, dxc4")).accessibilityAddTraits(chosen ? .isSelected:[])
        }}.padding(.leading,CGFloat(26+12*depth))}.frame(height:Self.rowHeight)
    }
    /// A kept idea, inline under the move it replaces; choosing it opens it at its first move.
    private func idea(_ branch:ReviewBranch)->some View {
        let open=review.branch?.id==branch.id
        return Button(ReviewFormat.ideaLabel(document,branch)){do{try review.openSavedBranch(branch.id);review.seekBranch(1)}catch{model.storageError=userFacingMessage(error,fallback:String(localized:"This imagined line could not be opened.",bundle:.checkmate))}}
            .buttonStyle(.plain).font(.callout).italic().foregroundStyle(open ? Color.primary:Color.secondary).lineLimit(1).truncationMode(.tail)
            .padding(.leading,38).frame(maxWidth:.infinity,minHeight:Self.rowHeight,maxHeight:Self.rowHeight,alignment:.leading)
            .accessibilityLabel(String(localized:"Imagined line, \(ReviewFormat.ideaLabel(document,branch))",bundle:.checkmate,comment:"A kept imagined line in the move list, read aloud, then its name")).accessibilityAddTraits(open ? .isSelected:[])
    }
    /// A move: its SAN, the record's own annotation glyphs, then the engine's grade in its colour.
    @ViewBuilder private func cell(_ id:Int?,graded:Bool,empty:String)->some View {
        if let id {
            let n=document.nodes[id],chosen=review.branch==nil && review.nodeID==id,grade=graded ? analyzer.grade(id):nil,glyphs=ReviewFormat.glyphs(n.nags)
            let reason=[grade?.name,ReviewFormat.glyphMeanings(n.nags).map{String(localized:"Marked in the record: \($0)",bundle:.checkmate,comment:"The record's own annotation of a move, then what it means")}].compactMap{$0}.joined(separator:"; ")
            Button{select(id)} label:{HStack(spacing:2){
                Text(verbatim:n.san ?? "").monospacedDigit().foregroundStyle(Color.primary).fontWeight(chosen ? .semibold:.regular)
                if !glyphs.isEmpty{Text(verbatim:glyphs).foregroundStyle(.secondary).accessibilityHidden(true)}
                if let grade{Text(verbatim:grade.glyph).fontWeight(.bold).foregroundStyle(ReviewGradeStyle.color(grade)).accessibilityHidden(true)}
                Spacer(minLength:0)
            }.padding(.horizontal,6).frame(maxWidth:.infinity,minHeight:Self.rowHeight-2).background(RoundedRectangle(cornerRadius:4).fill(chosen ? Color.accentColor.opacity(0.25):Color.clear)).contentShape(Rectangle())}
            .buttonStyle(.plain).help(reason).accessibilityLabel(ReviewFormat.moveLabel(n)).accessibilityValue(reason).accessibilityAddTraits(chosen ? .isSelected:[]).accessibilityRotorEntry(id:id,in:rotor)
        } else {Text(empty).foregroundStyle(.secondary).padding(.horizontal,6).frame(maxWidth:.infinity,alignment:.leading)}
    }
}

/// What the selected position shows: its explanation, actions, engine comparison and board facts.
struct ReviewPositionPanel:View {
    @ObservedObject var review:ReviewController
    @ObservedObject var model:NativeModel
    @ObservedObject var analyzer:ReviewAnalyzer
    let document:GameDocument
    private func attempt(_ fallback:String,_ action:()throws->Void){do{try action()}catch{model.storageError=userFacingMessage(error,fallback:fallback)}}
    var body:some View {
        let explanation=review.explanation
        VStack(alignment:.leading,spacing:Metrics.smallGap){
            Text(verbatim:explanation?.title ?? document.title).sectionHeading().fixedSize(horizontal:false,vertical:true)
            if let summary=explanation?.summary,!summary.isEmpty{Text(verbatim:summary).fixedSize(horizontal:false,vertical:true)}
            if let note=explanation?.historyNote{Text(verbatim:note).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
            if review.nodeID==0{BulletedLines(lines:ReviewFormat.takeaways(explanation))}
            if review.branch==nil {
                // The engine's grade of the move played (R-1), then the record's own comments on it (R-7).
                if model.fairness.engineHelpAllowed,analyzer.batchDocument==document.id,let grade=analyzer.grade(review.nodeID),let loss=analyzer.losses[review.nodeID]{
                    Text(verbatim:ReviewFormat.gradeLine(grade,loss:loss,side:document.nodes[review.nodeID].side)).fontWeight(.medium).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("review-move-grade")
                }
                ForEach(Array(ReviewFormat.comments(document.nodes[review.nodeID]).enumerated()),id:\.offset){_,comment in
                    Text(verbatim:comment).italic().foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal:false,vertical:true).accessibilityLabel(String(localized:"Comment in the record: \(comment)",bundle:.checkmate,comment:"A comment from the game record, read aloud"))
                }
            }
            if let branch=review.branch {ImaginedLineCallout(review:review,model:model,branch:branch,document:document)}
            else if !model.fairness.engineHelpAllowed{Text(FairnessPolicy.analysisHidden).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true);idea.controlSize(.small)}
            else {
                ViewThatFits(in:.horizontal){
                    HStack(spacing:Metrics.smallGap){actions}
                    VStack(alignment:.leading,spacing:Metrics.smallGap){HStack(spacing:Metrics.smallGap){why;deeper};idea}
                }.controlSize(.small)
                if let pv=review.evidence?.root.lines.first?.pv,!pv.isEmpty{Button("Compare Best Line · Before This Move"){attempt(String(localized:"The best line could not be shown.",bundle:.checkmate)){try review.previewLine(pv,fromNode:document.nodes[review.nodeID].parent);review.seekBranch(0)}}.buttonStyle(.link).controlSize(.small)}
            }
            if review.analysisStatus=="pending"{ProgressView("Analyzing offline…").controlSize(.small)}
            if let error=review.error{Text(error).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
            if model.fairness.engineHelpAllowed,let evidence=review.evidence{EngineEvidenceList(evidence:evidence)}
            DisclosureGroup("Verified board facts"){VStack(alignment:.leading,spacing:Metrics.tightGap){ForEach(explanation?.facts ?? []){fact in Text(verbatim:fact.text).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)}}.padding(.top,Metrics.tightGap)}
            if document.nodes[review.nodeID].children.count>1{HStack(spacing:Metrics.tightGap){Text("Played next:").foregroundStyle(.secondary);ForEach(document.nodes[review.nodeID].children,id:\.self){id in Button(document.nodes[id].san ?? String(localized:"Position",bundle:.checkmate,comment:"Noun: the arrangement of pieces on the board")){attempt(String(localized:"That move could not be shown.",bundle:.checkmate)){try review.select(id)}}.buttonStyle(.link)}}}
        }
    }
    @ViewBuilder private var actions:some View {why;deeper;idea}
    private var why:some View {Button("Why?"){review.analyze(using:model.reviewAnalyzer)}}
    private var deeper:some View {Button("Look Deeper"){review.analyze(using:model.reviewAnalyzer,budget:ReviewPolicy.deepBudget)}}
    private var idea:some View {Button("Test My Idea"){attempt(String(localized:"An imagined line could not start here.",bundle:.checkmate)){try review.beginBranch()}}}
}

/// The engine's lines as score and moves, one line each; engine details are in the caption's help.
struct EngineEvidenceList:View {
    let evidence:ReviewEvidence
    var body:some View {VStack(alignment:.leading,spacing:Metrics.tightGap){
        Text(ReviewFormat.evidenceCaption(provisional:evidence.provisional,depth:evidence.root.lines.first?.depth)).font(.caption).foregroundStyle(.secondary).help("\(evidence.engineVersion) · \(evidence.budgetMs) ms · full strength")
        ForEach(Array(evidence.root.lines.enumerated()),id:\.offset){_,line in let moves=line.san.joined(separator:" ")
            HStack(alignment:.firstTextBaseline,spacing:6){Text(ReviewFormat.score(line.score)).monospacedDigit().fontWeight(.medium).frame(width:46,alignment:.trailing);Text(verbatim:moves).lineLimit(1).truncationMode(.tail)}.font(.callout).help(moves)
        }
        Text("Scores are from White's side.").font(.caption2).foregroundStyle(.secondary)
    }}
}

/// An open imagined line: what it is, its moves and its own actions, in place of the position's actions.
struct ImaginedLineCallout:View {
    @ObservedObject var review:ReviewController
    @ObservedObject var model:NativeModel
    let branch:ReviewBranch,document:GameDocument
    var body:some View {VStack(alignment:.leading,spacing:Metrics.smallGap){
        Label("Imagined line",symbol:.imaginedLine).sectionHeading()
        Text(branch.id==review.previewBranchID ? String(localized:"A preview line: it is not kept unless you play a move in it.",bundle:.checkmate):String(localized:"Either side can make legal moves here. The imported game is preserved.",bundle:.checkmate)).font(.callout).fixedSize(horizontal:false,vertical:true)
        IdeaMoves(review:review,branch:branch,document:document)
        HStack(spacing:Metrics.smallGap){
            // No engine output during a network game (D8): say so rather than offer a button that does nothing.
            if model.fairness.engineHelpAllowed{Button("Analyze This Idea"){review.analyze(using:model.reviewAnalyzer)};Button("Look Deeper"){review.analyze(using:model.reviewAnalyzer,budget:ReviewPolicy.deepBudget)}}
            else{Text(FairnessPolicy.analysisHidden).foregroundStyle(.secondary)}
            if review.canUndoIdeaChange{Button("Undo Change"){do{try review.undoIdeaChange();model.saveReview()}catch{model.storageError=userFacingMessage(error,fallback:String(localized:"The change could not be undone.",bundle:.checkmate))}}}
        }.controlSize(.small)
    }.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(RoundedRectangle(cornerRadius:Metrics.cornerRadius).fill(Color.accentColor.opacity(0.08))).overlay(RoundedRectangle(cornerRadius:Metrics.cornerRadius).strokeBorder(Color.accentColor.opacity(0.3)))}
}

/// The optional voice coach in review: status, its actions and the transcript, newest first.
struct ReviewVoiceSection:View {
    @ObservedObject var voice:VoiceCoach
    /// Connect Voice, which asks for consent first.
    let connect:()->Void
    @State private var transcriptShown=true
    var body:some View {
        // Voice status and failures stay visible in review.
        let active=voice.connection != .disconnected || !voice.history.isEmpty
        if active || ReviewRolloutPolicy.reviewVoiceEnabled {VStack(alignment:.leading,spacing:Metrics.smallGap){
            Text("Voice coach").sectionHeading()
            if active{Text(voice.status).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
            Text(voice.connected ? String(localized:"Connected. Only selected verified facts are shared.",bundle:.checkmate):String(localized:"Optional. Only selected verified facts are shared.",bundle:.checkmate)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            VoiceCoachControls(voice:voice,idPrefix:"review-voice",actions:[.init(id:"narrate",title:String(localized:"Narrate Facts",bundle:.checkmate)){voice.narrateReview()}],connect:ReviewRolloutPolicy.reviewVoiceEnabled ? {connect()}:nil).controlSize(.small)
            if !voice.history.isEmpty{DisclosureGroup("Transcript",isExpanded:$transcriptShown){VStack(alignment:.leading,spacing:6){ForEach(Array(voice.history.reversed())){entry in VStack(alignment:.leading,spacing:1){Text(entry.role=="learner" ? String(localized:"You",bundle:.checkmate):String(localized:"Coach",bundle:.checkmate)).font(.caption).foregroundStyle(.secondary);Text(entry.text).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)}}}.padding(.top,Metrics.tightGap)}}
        }}
    }
}
