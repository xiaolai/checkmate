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
    /// The accessibility label of a move, e.g. "2, Black, dxc4"; acceptance gates find moves by it.
    static func moveLabel(_ n:GameNode)->String {"\(n.fullmove), \(n.side=="w" ? "White":"Black"), \(n.san ?? "")"}
    static func moveText(_ n:GameNode)->String {"\(n.fullmove)\(n.side=="w" ? ".":"…") \(n.san ?? "")"}
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
        if d.provenance=="Current game" || d.provenance=="Previous game"{return d.provenance}
        let white=known(d.header("White")),black=known(d.header("Black"))
        if white != nil || black != nil{return "\(white ?? "White") – \(black ?? "Black")"}
        return d.historyAvailable ? "Imported game":"Imported position"
    }
    /// The header's second line: event, site and date, leaving out unknown parts and a site that only repeats the event.
    static func details(_ d:GameDocument)->String? {
        var parts:[String]=[]
        for value in [known(d.header("Event")),known(d.header("Site")),date(d.header("Date"))].compactMap({$0}) where !parts.contains(where:{value.hasPrefix($0) || $0.hasPrefix(value)}){parts.append(value)}
        return parts.isEmpty ? nil:parts.joined(separator:" · ")
    }
    /// A network game's agreed assistance (assistance plan A11): "Assistance: White: Hints on request; Black: Off". Nil
    /// for a record without the tag, which every game without assistance is.
    static func assistance(_ d:GameDocument)->String? {known(d.header("Assistance")).map{"Assistance: "+$0}}
    static func result(_ result:String)->String {switch result{case "1-0":return "1–0";case "0-1":return "0–1";case "1/2-1/2":return "½–½";default:return "Unfinished"}}
    /// A score from White's side: "+0.8", "−1.4", "0.0", "M3" (White mates), "−M2" (Black mates); a bound is marked.
    static func score(_ s:AnalysisScore)->String {
        let bound=s.bound=="lower" ? "≥":s.bound=="upper" ? "≤":""
        if s.kind=="mate"{return bound+(s.value==0 ? "#":s.value>0 ? "M\(s.value)":"−M\(-s.value)")}
        let pawns=Double(s.value)/100,text=String(format:"%.1f",abs(pawns));return bound+(text=="0.0" ? text:(pawns>0 ? "+":"−")+text)
    }
    /// The overview's takeaways without any the summary already says.
    static func takeaways(_ e:ReviewExplanation?)->[String] {guard let e else{return []};return e.takeaways.filter{let item=$0.trimmingCharacters(in:.whitespaces);return !item.isEmpty && !e.summary.contains(item)}}
    static let evaluationLimit=10.0
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
    /// The evaluation graph's samples in pawns from White's side, clamped to ±10: index 0 is the start, index i the
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
    /// Moves the engine rates as costly: a moment whose expectation loss passes the review's "interesting" threshold.
    /// Checks, captures and the final move are moments too, but they are marked only when they also cost this much.
    static func costly(_ moments:[ReviewMoment])->Set<Int> {Set(moments.filter{($0.expectationLoss ?? 0)>ReviewQualityPolicy.interestingExpectationLoss}.map(\.id))}
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
                Text(verbatim:ReviewFormat.players(document)).font(.title3.bold()).fixedSize(horizontal:false,vertical:true)
                if let details=ReviewFormat.details(document){Text(verbatim:details).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
                if let assistance=ReviewFormat.assistance(document){Text(verbatim:assistance).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("review-assistance")}
            }
            Spacer(minLength:0)
            Text(ReviewFormat.result(document.result)).font(.caption.weight(.semibold)).monospacedDigit().padding(.horizontal,6).padding(.vertical,2)
                .background(Capsule().fill(.quaternary)).accessibilityLabel("Result: "+ReviewFormat.result(document.result))
        }
        HStack(spacing:Metrics.smallGap){
            if model.reviewDraft{Button("Save Review"){model.saveCurrentReview()}.buttonStyle(.borderedProminent)}
            // Availability follows the displayed position, including an imagined line from the parent.
            Button("Practise here"){review.pause();model.practiceFromReview()}.disabled(!review.practiceForkAvailable)
            Spacer(minLength:0)
            Menu{
                Button("Choose Another Game…"){model.showReviewWorkspace()}
                Button("Export PGN…"){model.exportReview()}
                if !model.reviewDraft{Divider();Button("Delete Saved Review…",role:.destructive){model.requestDeleteReview(document.id)}.disabled(model.deletingReviewID != nil)}
            } label:{Image(systemName:"ellipsis.circle")}.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
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
            Text("Evaluation").font(.headline)
            // No engine output during a network game (LAN-play plan D8): the graph and its controls wait until it ends.
            if !model.fairness.engineHelpAllowed{Text(FairnessPolicy.analysisHidden).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
            else if ReviewFormat.line(document).ids.isEmpty{Text("This position has no moves to analyze as a game; Why? analyzes the position itself.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
            else if mine,["pending","deepening"].contains(analyzer.batchStatus){
                ProgressView(value:Double(analyzer.completed),total:Double(max(1,analyzer.total)))
                HStack{Text(analyzer.batchStatus=="deepening" ? "Checking the leading moment more deeply":"\(analyzer.completed) / \(analyzer.total) moves").font(.caption).foregroundStyle(.secondary);Spacer(minLength:0);Button("Cancel Analysis"){analyzer.cancelBatch()}.controlSize(.small)}
            }
            else if mine,analyzer.batchStatus=="ready"{
                EvaluationGraph(review:review,model:model,document:document,samples:ReviewFormat.series(document,evaluations:analyzer.evaluations,outcome:ReviewFormat.cachedOutcome(document)))
                if analyzer.failed>0{Text("\(analyzer.failed) of \(analyzer.total) moves could not be analyzed.").font(.caption).foregroundStyle(.secondary)}
                Button("Analyze Again"){analyzer.startBatch(document)}.buttonStyle(.borderless).controlSize(.small)
            }
            else{
                if mine,analyzer.batchStatus=="failed"{Text("Offline analysis is unavailable for this game. The record remains navigable; try again later.").font(.caption).foregroundStyle(Color(nsColor:NativeColors.error)).fixedSize(horizontal:false,vertical:true)}
                Button("Analyze Whole Game"){analyzer.startBatch(document)}.controlSize(.small)
            }
        }
    }
}

/// The evaluation across the mainline from White's side; a click or drag selects the nearest position.
struct EvaluationGraph:View,AXChartDescriptorRepresentable {
    @ObservedObject var review:ReviewController
    @ObservedObject var model:NativeModel
    let document:GameDocument,samples:[Double?]
    private struct Sample:Identifiable {let id:Int,value:Double,run:Int}
    /// Samples grouped into runs of known scores, so a gap is drawn as a gap.
    private var points:[Sample] {var result:[Sample]=[],run=0;for (i,value) in samples.enumerated(){if let value{result.append(Sample(id:i,value:value,run:run))}else{run+=1}};return result}
    private var last:Int {max(1,samples.count-1)}
    private var selected:Int? {review.branch==nil ? ReviewFormat.mainlineIndex(document,node:review.nodeID):nil}
    private func choose(_ index:Int){let node=ReviewFormat.node(document,index:max(0,min(last,index)));guard review.branch != nil || review.nodeID != node else{return};try? review.select(node);model.saveReview()}
    var body:some View {
        let points=self.points,singles=Set(Dictionary(grouping:points,by:\.run).filter{$0.value.count==1}.keys)
        Chart{
            ForEach(points){p in
                AreaMark(x:.value("Position",p.id),yStart:.value("Even",0),yEnd:.value("Score",p.value),series:.value("Run",p.run)).foregroundStyle(Color.accentColor.opacity(0.22))
                LineMark(x:.value("Position",p.id),y:.value("Score",p.value),series:.value("Run",p.run)).foregroundStyle(Color.accentColor).lineStyle(StrokeStyle(lineWidth:1.2))
                if singles.contains(p.run){PointMark(x:.value("Position",p.id),y:.value("Score",p.value)).symbolSize(12).foregroundStyle(Color.accentColor)}
            }
            RuleMark(y:.value("Even",0)).foregroundStyle(Color.secondary.opacity(0.5)).lineStyle(StrokeStyle(lineWidth:0.5))
            if let selected{RuleMark(x:.value("Selected",selected)).foregroundStyle(Color.primary.opacity(0.7)).lineStyle(StrokeStyle(lineWidth:1))}
        }
        .chartXScale(domain:0...last).chartYScale(domain:-ReviewFormat.evaluationLimit...ReviewFormat.evaluationLimit).chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
        .chartOverlay{proxy in GeometryReader{geometry in Rectangle().fill(.clear).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance:0).onChanged{drag in guard let anchor=proxy.plotFrame else{return};let plot=geometry[anchor];guard plot.width>0 else{return};choose(Int(((drag.location.x-plot.minX)/plot.width*CGFloat(last)).rounded()))})}}
        .frame(height:56).padding(.vertical,2).background(ReviewCard(radius:6))
        .help("Evaluation from White's side: above the line favours White. Click or drag to choose a position.")
        // A chart element reports no AXValue, so the selected position is part of its label.
        .accessibilityElement(children:.ignore).accessibilityLabel("Evaluation graph, "+(selected.map{"position \($0) of \(last)"} ?? "not on the main line")).accessibilityIdentifier("review-evaluation-graph")
        .accessibilityAdjustableAction{direction in switch direction{case .increment:choose((selected ?? -1)+1);case .decrement:choose((selected ?? 1)-1);default:break}}
        .accessibilityChartDescriptor(self)
    }
    func makeChartDescriptor()->AXChartDescriptor {
        let x=AXNumericDataAxisDescriptor(title:"Position",range:0...Double(last),gridlinePositions:[]){"Position \(Int($0))"}
        let y=AXNumericDataAxisDescriptor(title:"Pawns from White's side",range:-ReviewFormat.evaluationLimit...ReviewFormat.evaluationLimit,gridlinePositions:[0]){String(format:"%+.1f",$0)}
        // One series per run of known scores, as drawn: a position without a score is a gap, not part of a line.
        let runs=Dictionary(grouping:points,by:\.run).sorted{$0.key<$1.key},missing=samples.count-points.count
        let series=runs.enumerated().map{index,run in AXDataSeriesDescriptor(name:runs.count==1 ? "Evaluation":"Evaluation, part \(index+1)",isContinuous:run.value.count>1,dataPoints:run.value.map{AXDataPoint(x:Double($0.id),y:$0.value)})}
        let summary="Evaluation after each move of the main line, from White's side."+(missing>0 ? " \(missing) of \(samples.count) positions have no score.":"")
        return AXChartDescriptor(title:"Evaluation graph",summary:summary,xAxis:x,yAxis:y,additionalAxes:[],series:series)
    }
}

/// The mainline as a table of full moves, with the key moments above it.
struct ReviewMoveSection:View {
    @ObservedObject var review:ReviewController
    @ObservedObject var model:NativeModel
    @ObservedObject var analyzer:ReviewAnalyzer
    let document:GameDocument
    private static let rowHeight:CGFloat=22,maximumHeight:CGFloat=220
    private var moments:[ReviewMoment] {analyzer.fairness.engineHelpAllowed && analyzer.batchDocument==document.id ? analyzer.moments.filter{document.nodes.indices.contains($0.id)}:[]}
    private func select(_ id:Int){try? review.select(id);model.saveReview()}
    var body:some View {
        let moments=self.moments,reasons=Dictionary(moments.map{($0.id,$0.reason)},uniquingKeysWith:{a,_ in a}),costly=ReviewFormat.costly(moments),rows=ReviewFormat.rows(document,line:ReviewFormat.line(document).ids)
        let ranked=moments.isEmpty ? ReviewFormat.heuristicMoments(document):moments.map(\.id),key=ReviewFormat.keyMoments(ranked,in:document,engine:!moments.isEmpty)
        if !rows.isEmpty {VStack(alignment:.leading,spacing:Metrics.smallGap){
            Text("Moves").font(.headline)
            if !key.isEmpty {
                ViewThatFits(in:.horizontal){ForEach([5,4,3,2,1],id:\.self){count in HStack(spacing:4){ForEach(ReviewFormat.keyMoments(ranked,in:document,limit:count,engine:!moments.isEmpty),id:\.self){id in
                    Button(ReviewFormat.moveText(document.nodes[id])){select(id)}.buttonStyle(.bordered).controlSize(.small).accessibilityLabel("Key moment, "+ReviewFormat.moveLabel(document.nodes[id])).help(reasons[id] ?? "A check, capture, promotion or the final move")}}}}
                Text(moments.isEmpty ? "Checks, captures, promotions and the final move.":costly.isEmpty ? "Moments to start with; estimates may change.":"Dots mark costly moves; estimates may change.").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            ScrollViewReader{proxy in
                ScrollView{LazyVStack(spacing:0){ForEach(Array(rows.enumerated()),id:\.offset){index,row in
                    HStack(spacing:4){
                        Text("\(row.number).").monospacedDigit().foregroundStyle(.secondary).frame(width:34,alignment:.trailing)
                        cell(row.white,costly:costly,empty:row.white==nil && index==0 ? "…":"");cell(row.black,costly:costly,empty:"")
                    }.frame(height:Self.rowHeight).id(index)
                }}.padding(.vertical,2)}
                .frame(height:min(Self.maximumHeight,CGFloat(rows.count)*Self.rowHeight+4))
                .background(ReviewCard(radius:6))
                .onAppear{scroll(proxy,rows)}.onChange(of:review.nodeID){_,_ in withAnimation(.easeInOut(duration:0.15)){scroll(proxy,rows)}}
            }
        }}
    }
    private func scroll(_ proxy:ScrollViewProxy,_ rows:[ReviewFormat.MoveRow]){guard let row=rows.firstIndex(where:{$0.white==review.nodeID || $0.black==review.nodeID}) else{return};proxy.scrollTo(row,anchor:.center)}
    @ViewBuilder private func cell(_ id:Int?,costly:Set<Int>,empty:String)->some View {
        if let id {
            let n=document.nodes[id],chosen=review.branch==nil && review.nodeID==id,reason=costly.contains(id) ? "The engine found a clearly better move here.":nil
            Button{select(id)} label:{HStack(spacing:3){
                Text(verbatim:n.san ?? "").monospacedDigit().foregroundStyle(Color.primary).fontWeight(chosen ? .semibold:.regular)
                if reason != nil{Circle().fill(Color.orange).frame(width:5,height:5).accessibilityHidden(true)}
                Spacer(minLength:0)
            }.padding(.horizontal,6).frame(maxWidth:.infinity,minHeight:Self.rowHeight-2).background(RoundedRectangle(cornerRadius:4).fill(chosen ? Color.accentColor.opacity(0.25):Color.clear)).contentShape(Rectangle())}
            .buttonStyle(.plain).help(reason ?? "").accessibilityLabel(ReviewFormat.moveLabel(n)).accessibilityValue(reason ?? "").accessibilityAddTraits(chosen ? .isSelected:[])
        } else {Text(empty).foregroundStyle(.secondary).padding(.horizontal,6).frame(maxWidth:.infinity,alignment:.leading)}
    }
}

/// What the selected position shows: its explanation, actions, engine comparison and board facts.
struct ReviewPositionPanel:View {
    @ObservedObject var review:ReviewController
    @ObservedObject var model:NativeModel
    let document:GameDocument
    private func attempt(_ fallback:String,_ action:()throws->Void){do{try action()}catch{model.storageError=userFacingMessage(error,fallback:fallback)}}
    var body:some View {
        let explanation=review.explanation
        VStack(alignment:.leading,spacing:Metrics.smallGap){
            Text(verbatim:explanation?.title ?? document.title).font(.headline).fixedSize(horizontal:false,vertical:true)
            if let summary=explanation?.summary,!summary.isEmpty{Text(verbatim:summary).fixedSize(horizontal:false,vertical:true)}
            if let note=explanation?.historyNote{Text(verbatim:note).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
            if review.nodeID==0{ForEach(ReviewFormat.takeaways(explanation),id:\.self){item in HStack(alignment:.firstTextBaseline,spacing:6){Text("•").foregroundStyle(.secondary);Text(verbatim:item).fixedSize(horizontal:false,vertical:true)}}}
            if let branch=review.branch {ImaginedLineCallout(review:review,model:model,branch:branch,document:document)}
            else if !model.fairness.engineHelpAllowed{Text(FairnessPolicy.analysisHidden).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true);idea.controlSize(.small)}
            else {
                ViewThatFits(in:.horizontal){
                    HStack(spacing:Metrics.smallGap){actions}
                    VStack(alignment:.leading,spacing:Metrics.smallGap){HStack(spacing:Metrics.smallGap){why;deeper};idea}
                }.controlSize(.small)
                if let pv=review.evidence?.root.lines.first?.pv,!pv.isEmpty{Button("Compare best line · before this move"){try? review.previewLine(pv,fromNode:document.nodes[review.nodeID].parent);review.seekBranch(0)}.buttonStyle(.link).controlSize(.small)}
            }
            if review.analysisStatus=="pending"{ProgressView("Analyzing offline…").controlSize(.small)}
            if let error=review.error{Text(error).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
            if model.fairness.engineHelpAllowed,let evidence=review.evidence{EngineEvidenceList(evidence:evidence)}
            DisclosureGroup("Verified board facts"){VStack(alignment:.leading,spacing:4){ForEach(explanation?.facts ?? []){fact in Text(verbatim:fact.text).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)}}.padding(.top,4)}
            if !document.nodes[review.nodeID].children.isEmpty{DisclosureGroup("Recorded continuations"){VStack(alignment:.leading,spacing:4){ForEach(document.nodes[review.nodeID].children,id:\.self){id in Button(document.nodes[id].san ?? "Position"){try? review.select(id)}.buttonStyle(.link)}}.padding(.top,4)}}
        }
    }
    @ViewBuilder private var actions:some View {why;deeper;idea}
    private var why:some View {Button("Why?"){review.analyze(using:model.reviewAnalyzer)}}
    private var deeper:some View {Button("Look Deeper"){review.analyze(using:model.reviewAnalyzer,budget:ReviewPolicy.deepBudget)}}
    private var idea:some View {Button("Test My Idea"){attempt("An imagined line could not start here."){try review.beginBranch()}}}
}

/// The engine's lines as score and moves, one line each; engine details are in the caption's help.
struct EngineEvidenceList:View {
    let evidence:ReviewEvidence
    var body:some View {VStack(alignment:.leading,spacing:4){
        Text(evidence.provisional ? "Provisional engine estimate":"Deeper engine comparison").font(.caption).foregroundStyle(.secondary).help("\(evidence.engineVersion) · \(evidence.budgetMs) ms · full strength")
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
        Label("Imagined line",systemImage:"lightbulb").font(.headline)
        Text(branch.id==review.previewBranchID ? "A preview line: it is not kept unless you play a move in it.":"Either side can make legal moves here. The imported game is preserved.").font(.callout).fixedSize(horizontal:false,vertical:true)
        IdeaMoves(review:review,branch:branch,document:document)
        HStack(spacing:Metrics.smallGap){
            // No engine output during a network game (D8): say so rather than offer a button that does nothing.
            if model.fairness.engineHelpAllowed{Button("Analyze This Idea"){review.analyze(using:model.reviewAnalyzer)}}
            else{Text(FairnessPolicy.analysisHidden).foregroundStyle(.secondary)}
            if review.canUndoIdeaChange{Button("Undo Change"){do{try review.undoIdeaChange();model.saveReview()}catch{model.storageError=userFacingMessage(error,fallback:"The change could not be undone.")}}}
        }.controlSize(.small)
    }.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(RoundedRectangle(cornerRadius:8).fill(Color.accentColor.opacity(0.08))).overlay(RoundedRectangle(cornerRadius:8).strokeBorder(Color.accentColor.opacity(0.3)))}
}

/// The optional voice coach in review: status, its actions and the transcript, newest first.
struct ReviewVoiceSection:View {
    @ObservedObject var voice:VoiceCoach
    @State private var transcriptShown=true
    var body:some View {
        // Voice status and failures stay visible in review.
        let active=voice.connected || !voice.history.isEmpty || voice.status != "Disconnected"
        if active || ReviewRolloutPolicy.reviewVoiceEnabled {VStack(alignment:.leading,spacing:Metrics.smallGap){
            Text("Voice coach").font(.headline)
            if active{Text(voice.status).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
            Text(voice.connected ? "Connected. Only selected verified facts are shared.":"Optional. Only selected verified facts are shared.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            HStack(spacing:Metrics.smallGap){if voice.connected{Button("Narrate Facts"){voice.narrateReview()};Button("Disconnect"){voice.disconnect()}}else if ReviewRolloutPolicy.reviewVoiceEnabled{Button("Connect Voice"){voice.connect()}}}.controlSize(.small)
            if !voice.history.isEmpty{DisclosureGroup("Transcript",isExpanded:$transcriptShown){VStack(alignment:.leading,spacing:6){ForEach(Array(voice.history.reversed())){entry in VStack(alignment:.leading,spacing:1){Text(entry.role=="learner" ? "You":"Coach").font(.caption).foregroundStyle(.secondary);Text(entry.text).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)}}}.padding(.top,4)}}
        }}
    }
}
