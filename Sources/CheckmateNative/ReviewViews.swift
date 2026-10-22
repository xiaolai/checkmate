import SwiftUI
import CheckmateCore
/// The review workspace: the ways to start a review on top, then the game library filling the rest of the height.
/// Only the library's list scrolls; the header and the library's controls stay in place.
struct ReviewWorkspaceContent:View {
    @ObservedObject var model:NativeModel
    var body:some View {VStack(spacing:Metrics.sectionGap){
        VStack(spacing:Metrics.smallGap){
            HStack(spacing:Metrics.smallGap){
                AppSymbol.review.image.font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment:.leading,spacing:2){Text("Game review").sectionHeading(.title.bold());Text("Choose a game or position to explore.").foregroundStyle(.secondary)}
            }
            HStack(spacing:Metrics.smallGap){
                Button("Open PGN…"){model.openPGN()}.buttonStyle(.borderedProminent)
                Menu("More Ways to Review"){secondaryActions}.fixedSize().accessibilityIdentifier("review-start-more")
            }
            Text(model.session.rules.history.isEmpty ? String(localized:"Play a move to review your current game. You can also drop a PGN file on the window.",bundle:.checkmate):String(localized:"You can also drop a PGN file on the window.",bundle:.checkmate)).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.fixedSize(horizontal:false,vertical:true)
        GameLibraryBrowser(model:model,library:model.library).frame(maxHeight:.infinity)
        Button("Return to Game"){model.returnToGame()}.buttonStyle(.bordered)
    }.padding(Metrics.padding).frame(maxWidth:680).frame(maxWidth:.infinity,maxHeight:.infinity)}
    /// One primary way to start (Open PGN…) and the rest behind one menu, so the start never stacks four buttons (D-32).
    @ViewBuilder private var secondaryActions:some View {
        Button("Paste PGN or FEN"){model.pasteReview()}
        Button("Review Current Game"){model.reviewCurrent()}.disabled(model.session.rules.history.isEmpty)
        if model.canReviewPrevious{Button("Review Previous Game"){model.reviewCurrent(previous:true)}}
    }
}
struct ReviewDetailContent:View {
    @ObservedObject var review:ReviewController
    @ObservedObject var model:NativeModel
    @ObservedObject var analyzer:ReviewAnalyzer
    @ObservedObject var voice:VoiceCoach
    @ObservedObject var orientation:BoardOrientation
    init(review:ReviewController,model:NativeModel){self.review=review;self.model=model;analyzer=model.reviewAnalyzer;voice=model.voice;orientation=model.boardOrientation}
    var body:some View {VStack(alignment:.leading,spacing:Metrics.sectionGap){
        if let d=review.document {
            ReviewHeader(review:review,model:model,document:d)
            MaterialRow(balance:MaterialBalance(board:review.board,start:TrainingMaterial.board(fen:d.startingFEN) ?? review.board),blackAtBottom:orientation.blackAtBottom)
            ReviewAnalysisSection(review:review,model:model,analyzer:analyzer,document:d)
            ReviewRetrySection(retry:model.reviewRetry,analyzer:analyzer,model:model,document:d)
            ReviewMoveSection(review:review,model:model,analyzer:analyzer,document:d)
            ReviewPositionPanel(review:review,model:model,analyzer:analyzer,document:d)
            if !review.authoredBranches.isEmpty{DisclosureGroup(ReviewFormat.ideaListTitle(count:review.authoredBranches.count)){VStack(alignment:.leading,spacing:Metrics.tightGap){ForEach(review.authoredBranches,id:\.id){branch in HStack{
                Button(ReviewFormat.ideaLabel(d,branch)){do{try review.openSavedBranch(branch.id)}catch{model.storageError=userFacingMessage(error,fallback:String(localized:"This imagined line could not be opened.",bundle:.checkmate))}}.buttonStyle(.link)
                Spacer();Button("Delete",role:.destructive){do{try review.deleteBranch(branch.id);model.saveReview()}catch{model.storageError=userFacingMessage(error,fallback:String(localized:"This imagined line could not be deleted.",bundle:.checkmate))}}.controlSize(.small).accessibilityLabel("Delete idea: \(ReviewFormat.ideaLabel(d,branch))")}}}.padding(.top,Metrics.tightGap)}}
            ReviewVoiceSection(voice:voice,connect:{[weak model] in model?.connectVoiceFromSettings()})
            // The review control bar has no way back to the game, and the workspace hides it.
            Button("Return to Game"){model.returnToGame()}.buttonStyle(.bordered)
        }
    }.sheet(isPresented:$model.practiceForkRequested){ReviewPracticeSheet(model:model)}
    // A confirmation belongs to the review on screen; one left raised when the review closed must not reappear later.
    .onDisappear{model.practiceForkRequested=false}}
}
struct OpponentSettingsContent:View {
    @ObservedObject var session:GameSession
    private var displayedPreset:String {session.state.settings.opponentPreset=="first_steps" && !ReviewRolloutPolicy.beginnerOpponentEnabled ? "custom":session.state.settings.opponentPreset}
    private var displayedMode:String {
        if !ReviewRolloutPolicy.beginnerOpponentEnabled && (session.state.settings.opponentPreset=="first_steps" || session.state.settings.opponentMode=="beginner") {return "skill"}
        return session.state.settings.opponentMode
    }
    private var mode:Binding<String>{Binding(get:{displayedMode},set:{value in var settings=session.state.settings;settings.opponentMode=value;settings.opponentPreset="custom";session.updateSettings(settings)})}
    func binding<T>(_ key:WritableKeyPath<AppSettings,T>)->Binding<T> {Binding(get:{session.state.settings[keyPath:key]},set:{var settings=session.state.settings;settings[keyPath:key]=$0;settings.opponentPreset="custom";session.updateSettings(settings)})}
    var preset:Binding<String>{Binding(get:{displayedPreset},set:{value in var settings=session.state.settings;settings.opponentPreset=value;session.updateSettings(settings)})}
    var body:some View {VStack(alignment:.leading,spacing:Metrics.smallGap){
        Grid(alignment:.leading,horizontalSpacing:Metrics.smallGap,verticalSpacing:Metrics.smallGap){
            GridRow {
                Text("Opponent")
                Picker("Opponent",selection:preset){
                    if ReviewRolloutPolicy.beginnerOpponentEnabled{Text("First steps").tag("first_steps")}
                    Text("Gentle").tag("gentle");Text("Club").tag("club");Text("Custom").tag("custom")
                }.labelsHidden().frame(maxWidth:.infinity)
            }
            if displayedPreset=="custom"{
                GridRow {
                    Text("Strength")
                    Picker("Strength control",selection:mode){
                        Text("Stockfish skill").tag("skill");Text("Estimated engine Elo").tag("elo")
                        if ReviewRolloutPolicy.beginnerOpponentEnabled{Text("Beginner").tag("beginner")}
                    }.labelsHidden().frame(maxWidth:.infinity)
                }
                if displayedMode=="skill"{
                    GridRow {
                        Text("Skill")
                        Picker("Skill",selection:binding(\.skill)){ForEach(0...20,id:\.self){Text("Level \($0)").tag($0)}}
                            .labelsHidden().frame(maxWidth:.infinity)
                    }
                }
                if displayedMode=="elo",let engine=session.engine as? NativeEngine{
                    EngineEloControl(engine:engine,value:binding(\.opponentElo)).gridCellColumns(2)
                }
            }
        }
        if displayedPreset=="custom",displayedMode=="elo"{Text("An engine estimate, not a tournament rating.").font(.caption).foregroundStyle(.secondary)}
        if displayedPreset=="first_steps" || (displayedPreset=="custom" && displayedMode=="beginner"){Text("First steps gives more opportunities to practice. You can always use hints or take back a move.").font(.caption).foregroundStyle(.secondary)}
    }}
}
struct EngineEloControl:View {
    @ObservedObject var engine:NativeEngine
    @Binding var value:Int
    @State private var unavailable=false
    var body:some View {Group{if let range=engine.capabilities.eloRange{let shown=min(max(value,range.lowerBound),range.upperBound);Stepper("Engine estimate: \(shown)",value:Binding(get:{shown},set:{value=$0}),in:range,step:50)}else{Text(unavailable ? String(localized:"This engine does not provide an Elo setting. Use Stockfish skill instead.",bundle:.checkmate):String(localized:"Checking engine strength settings…",bundle:.checkmate)).foregroundStyle(.secondary)}}.task{do{try await engine.prepare();unavailable=engine.capabilities.eloRange==nil}catch{unavailable=true}}}
}

struct ReviewPracticeSheet:View {
    @ObservedObject var model:NativeModel
    @State private var side="w"
    @State private var preset:String
    /// The position this confirmation was raised for. An open, step or edit underneath the sheet (menu, drop or MCP)
    /// must not make Start fork, or Save keep, a different position.
    @State private var target:String?
    // Starts at the learner's current opponent rather than silently switching to custom settings.
    init(model:NativeModel){self.model=model;let current=model.session.state.settings.opponentPreset;_preset=State(initialValue:current=="first_steps" && !ReviewRolloutPolicy.beginnerOpponentEnabled ? "custom":current);_target=State(initialValue:model.review.practiceForkTarget)}
    private func stillShown()->Bool {
        guard target != nil,model.review.practiceForkTarget==target else{model.practiceForkRequested=false;model.storageError=String(localized:"The review changed while this was open, so nothing was started or saved. Choose Practice Here again.",bundle:.checkmate);return false};return true
    }
    var body:some View {VStack(alignment:.leading,spacing:Metrics.sectionGap){
        Text("Practice from this position").sectionHeading()
        Text("Your current practice is backed up and becomes Previous game, replacing that shortcut’s older game. The imported record stays unchanged.")
        Picker("Play as",selection:$side){Text("White").tag("w");Text("Black").tag("b")}
        Picker("Opponent",selection:$preset){if ReviewRolloutPolicy.beginnerOpponentEnabled{Text("First steps").tag("first_steps")};Text("Gentle").tag("gentle");Text("Club").tag("club");Text("Keep custom settings").tag("custom")}
        Button("Save This Position for Later"){guard stillShown() else{return};model.saveCurrentReview();model.practiceForkRequested=false}
        HStack{Spacer();Button("Cancel"){model.practiceForkRequested=false}.keyboardShortcut(.cancelAction);Button("Start Practice"){guard stillShown() else{return};model.confirmPracticeFork(side:side,preset:preset)}.keyboardShortcut(.defaultAction)}
    }.padding(Metrics.padding).frame(minWidth:Metrics.right)}
}

/// The open imagined line's moves, numbered by full moves like the main move list; each one shows its position.
struct IdeaMoves:View {
    @ObservedObject var review:ReviewController
    let branch:ReviewBranch,document:GameDocument
    var body:some View {
        let moves=ReviewFormat.ideaMoves(document,branch)
        if !moves.isEmpty {
            Text("Moves in this line").font(.subheadline.weight(.semibold))
            ForEach(Array(moves.enumerated()),id:\.offset){index,move in
                // The spoken label keeps the move's place in the line; the SAN is the text after the move number.
                let san=move.split(separator:" ",maxSplits:1).last.map(String.init) ?? move
                Button(move){review.seekBranch(index+1)}.buttonStyle(.plain).foregroundStyle(index+1==review.branchPly ? .primary:.secondary)
                    .accessibilityLabel("Imagined move \(index+1), \(san)")
            }
        }
    }
}
