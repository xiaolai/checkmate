import SwiftUI
import CheckmateCore
/// The sidebar row for an activity. The workspace, an unsaved review and each saved review are separate rows, so
/// choosing Review game from an open review is a real selection change (RV-12).
enum SidebarSelection {
    static func tag(_ activity:Activity,saved:Set<UUID>,lessonIndex:Int)->String {
        if let visit=activity.review{guard let document=visit.document else{return "review"};return saved.contains(document) ? "review:"+document.uuidString:"review:draft"}
        switch activity.place {case .practice:return "practice";case .puzzleLibrary,.puzzle:return "puzzles";case .lesson:return "lesson:\(lessonIndex)";case .miniGame(let index,_,_):return index==nil ? "training":"lesson:\(lessonIndex)";case .trainingLibrary,.training:return "training";case .network:return "network"}
    }
    /// How many saved reviews the sidebar lists.
    static let recentLimit=8
    /// The most recent saved reviews, plus the one open when it is older, so the open review's row is always there.
    static func recentReviews(_ reviews:[ReviewIndexEntry],open:UUID?)->[ReviewIndexEntry] {
        let recent=Array(reviews.prefix(recentLimit))
        guard let open,!recent.contains(where:{$0.id==open}),let entry=reviews.first(where:{$0.id==open}) else{return recent}
        return recent+[entry]
    }
    /// Each mini-game whose lesson is in the course, in the course's order, with that lesson.
    static func miniGames(_ library:CourseLibrary)->[(kind:MiniGameKind,lesson:Int)] {
        library.lessons.indices.flatMap{index in MiniGameKind.available(lessonID:library.lessons[index].id).map{(kind:$0,lesson:index)}}
    }
    /// "Network game · your move" under Play on Network while the learner is elsewhere, Review included (LAN-play D9).
    @MainActor static func networkBadge(_ activity:Activity,_ network:NetworkGameController)->String? {activity == .at(.network) ? nil:network.badge}
}
struct SidebarContent:View {
    @ObservedObject var session:GameSession
    @ObservedObject var learning:LearningPlayer
    @ObservedObject var model:NativeModel
    @ObservedObject var network:NetworkGameController
    private var selected:String {SidebarSelection.tag(session.activity,saved:Set(model.reviews.map(\.id)),lessonIndex:learning.lessonIndex)}
    /// VoiceOver hears what the indent shows: which lesson an activity practises.
    private func practiceHint(_ lesson:CourseLesson)->String {
        guard let parent=lesson.practiceFor,let index=learning.library.lessons.firstIndex(where:{$0.id==parent}) else{return ""}
        return String(localized:"Practice activity for \(learning.localizedTitle(index:index))",bundle:.checkmate)
    }
    private func navigate(_ value:String?) {
        guard let value=value else{return}
        if value=="review:draft" {return}
        if value=="review" {model.showReviewWorkspace()}
        else if value=="reviews:all" {model.showReviewWorkspace();model.library.query="";model.library.scope = .saved}
        else if value.hasPrefix("mini:"),let kind=MiniGameKind(rawValue:String(value.dropFirst(5))) {model.playMiniGame(kind)}
        else if value.hasPrefix("review:"),let id=UUID(uuidString:String(value.dropFirst(7))) {model.openSavedReview(id)}
        else if value=="practice" {model.practice()}
        else if value=="puzzles" {model.puzzles()}
        else if value=="training" {model.trainingLibrary()}
        else if value=="network" {model.playOnNetwork()}
        else if let i=Int(value.replacingOccurrences(of:"lesson:",with:"")) {model.lesson(i)}
    }
    /// During a network game lessons, puzzles and training are closed (LAN-play plan D8): their rows say why.
    private var participating:Bool {!model.fairness.engineHelpAllowed}
    /// Why a closed destination is closed, shown under its title and read as its value, not only on hover (D-33).
    private var closedReason:String? {participating ? FairnessPolicy.destinationUnavailable:nil}
    /// A lesson row's VoiceOver value: its status, whether learning continues here, and why it is closed.
    static func lessonValue(status:String,here:Bool,closedReason:String?)->String {
        let value=here ? String(localized:"\(status), continue here",bundle:.checkmate,comment:"A lesson's status, then that the learner continues from it"):status
        return closedReason.map{String(localized:"\(value). \($0)",bundle:.checkmate,comment:"A lesson's status, then why it is closed")} ?? value
    }
    private func destination(_ title:String,symbol:AppSymbol,tag:String)->some View {
        Label{VStack(alignment:.leading,spacing:1){Text(title);if let closedReason{Text(closedReason).font(.caption).foregroundStyle(.secondary)}}}icon:{symbol.image}
            .tag(tag).selectionDisabled(closedReason != nil).accessibilityValue(closedReason ?? "")
    }
    var body:some View {List(selection:Binding<String?>(get:{selected},set:navigate)){
        Section {
            Label("Practice a game",symbol:.practice).tag("practice")
            if NetworkPolicy.availableHere{Label{VStack(alignment:.leading,spacing:1){Text("Play on Network");if let badge=SidebarSelection.networkBadge(session.activity,network){Text(badge).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("network-sidebar-badge")}}}icon:{AppSymbol.network.image}.tag("network")}
            destination(String(localized:"Quick puzzles",bundle:.checkmate),symbol:.puzzles,tag:"puzzles")
            if model.training != nil{destination(String(localized:"Training",bundle:.checkmate),symbol:.training,tag:"training")}
            Label("Review game",symbol:.review).tag("review")
            if model.review.active,let document=model.review.document,!model.reviews.contains(where:{$0.id==document.id}){Label("Unsaved review",symbol:.unsavedReview).tag("review:draft")}
        }
        // The most recent saved reviews (and the one open, if older); the library's Saved scope lists, searches and
        // sorts them all (R-11).
        if !model.reviews.isEmpty {
            Section("Saved reviews"){
                ForEach(SidebarSelection.recentReviews(model.reviews,open:model.review.document?.id)){record in Label(record.title=="?" ? String(localized:"Untitled game",bundle:.checkmate):record.title,symbol:.savedReview).tag("review:"+record.id.uuidString)
                    .contextMenu{Button("Rename…"){model.requestRenameReview(record.id)};Button("Delete Saved Review…",role:.destructive){model.requestDeleteReview(record.id)}.disabled(model.deletingReviewID != nil)}}
                if model.reviews.count>SidebarSelection.recentLimit{Label("All Saved Reviews (\(model.reviews.count))",symbol:.allSavedReviews).tag("reviews:all").accessibilityIdentifier("sidebar-all-saved-reviews")}
            }
        }
        // The mini-games, otherwise reached only inside their lessons (L-33). Each opens from its lesson, as there.
        // Closed during a network game, they say why under the heading and as each row's value, not only on hover (D-33).
        Section("Mini-games"){
            if let closedReason{Text(closedReason).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("sidebar-mini-closed")}
            ForEach(SidebarSelection.miniGames(learning.library),id:\.kind){entry in Label(entry.kind.title,symbol:.miniGame).accessibilityIdentifier("sidebar-mini-"+entry.kind.rawValue).tag("mini:"+entry.kind.rawValue).selectionDisabled(participating).accessibilityValue(closedReason ?? "").help(closedReason ?? "")}
        }
        // A practice activity sits indented under its lesson, off the main path but one click away. The icon is the
        // row's kind; how far the learner has taken it (explored, practiced, mastered) is a trailing badge VoiceOver reads.
        Section {
            if let closedReason{Text(closedReason).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("sidebar-learn-closed")}
            if let next=learning.continueIndex {Button{model.lesson(next)}label:{Label("Continue Learning",symbol:.continueLearning)}.disabled(participating).help(participating ? FairnessPolicy.destinationUnavailable:String(localized:"Open \(learning.localizedTitle(index:next))",bundle:.checkmate)).accessibilityIdentifier("sidebar-continue-learning")}
            ForEach(Array(learning.library.lessons.enumerated()),id:\.element.id){i,l in let status=learning.status(index:i),here=i==learning.continueIndex;Label {HStack(spacing:Metrics.smallGap){Text(learning.localizedTitle(index:i));if here{AppSymbol.continueHere.image.foregroundStyle(.tint).help("Continue here").accessibilityHidden(true)}}} icon:{(l.isPractice ? AppSymbol.gameActivity:.lesson).image}.badge(status.title.map{Text($0)}).accessibilityValue(Self.lessonValue(status:status.title ?? String(localized:"Not started",bundle:.checkmate),here:here,closedReason:closedReason)).padding(.leading,l.isPractice ? Metrics.practiceIndent:0).accessibilityHint(participating ? FairnessPolicy.destinationUnavailable:practiceHint(l)).accessibilityIdentifier("sidebar-lesson-"+l.id).tag("lesson:\(i)").selectionDisabled(participating)}
        } header:{HStack{Text("Learn & explore");Spacer();Text(learning.courseProgress.text).monospacedDigit().accessibilityLabel("\(learning.courseProgress.explored) of \(learning.courseProgress.total) lessons explored")}.accessibilityElement(children:.combine).accessibilityIdentifier("sidebar-course-progress")}
    }.listStyle(.sidebar).scrollContentBackground(.hidden).overlay(alignment:.bottom){if model.importingReview{VStack{ProgressView("Loading review…");Button("Cancel Import"){model.cancelReviewImport()}}.padding().background(.regularMaterial)}}}
}
struct DetailContent:View {
    @ObservedObject var session:GameSession
    @ObservedObject var learning:LearningPlayer
    @ObservedObject var model:NativeModel
    @ObservedObject var voice:VoiceCoach
    @ObservedObject var relationships:RelationshipController
    let history:PracticeHistory
    let inspect:(RelationshipMode)->Void
    /// The practice drawer's heading, from the game shown: its result once it is over, Stockfish thinking, or whose move it is.
    @MainActor static func practiceHeading(_ s:GameSession)->String {practiceHeading(result:s.finished ? s.state.practice.ending?.result ?? s.rules.ending?.result ?? "*":nil,learner:s.humanSide,thinking:s.busyReason == .opponent,learnerToMove:s.rules.turn==s.humanSide)}
    /// `result` is the finished game's PGN result, nil while it is in play.
    static func practiceHeading(result:String?,learner:String,thinking:Bool,learnerToMove:Bool)->String {
        if let result {switch result {case "1/2-1/2":return String(localized:"Drawn game",bundle:.checkmate);case "1-0","0-1":return result==(learner=="w" ? "1-0":"0-1") ? String(localized:"You won",bundle:.checkmate):String(localized:"You lost",bundle:.checkmate);default:return String(localized:"Game over",bundle:.checkmate)}}
        return thinking ? String(localized:"Stockfish is thinking",bundle:.checkmate):learnerToMove ? String(localized:"Your move",bundle:.checkmate):String(localized:"Opponent's move",bundle:.checkmate)
    }
    /// A finished game's summary line: its result and how many moves were played, e.g. "1–0 · 23 moves".
    static func practiceSummary(result:String,plies:Int)->String {let moves=(plies+1)/2;return String(localized:"\(ReviewFormat.result(result)) · \(moves) moves",bundle:.checkmate,comment:"A game summary: its result, then how many moves it lasted")}
    /// Runs a learner's practice action; one that cannot be done is said in the drawer, never dropped.
    @MainActor static func attempt(_ session:GameSession,_ action:() throws -> Void){do{try action()}catch{session.report(GameWindow.failureMessage(error))}}
    @State private var lessonGoalsShown=false
    var body:some View {ScrollView {VStack(alignment:.leading,spacing:Metrics.sectionGap) {
        if model.reviewWorkspace {WorkspaceInspector(library:model.library,theme:session.state.settings.boardTheme)} else if model.review.active{ReviewDetailContent(review:model.review,model:model)}else {
        if let label=relationships.selectedLabel{RelationshipContent(relationships:relationships,label:label,inspect:inspect);Divider()}
        if session.mode == .network {NetworkDetail(model:model,game:model.network,assistant:model.networkAssistant,voice:voice)}
        else if session.mode == .practice {practiceDetail}
        else if relationships.report==nil {
            if learning.mini {miniDetail}
            else if learning.activePuzzle != nil || session.mode == .lesson {lessonOrPuzzleDetail}
            else if session.mode == .training,let training=model.training {
                if case .training=session.activity.place,training.exercise != nil {TrainingPanel(model:model,training:training)}
                else {Text("Training").sectionHeading(.title2.bold());Text("Choose an exercise from the library.")}
            } else {Text("Quick puzzles").sectionHeading(.title2.bold());Text("Choose an exercise from the library.")}
        }
    }
    }.frame(maxWidth:.infinity,alignment:.leading).padding(Metrics.sectionGap)}.id(session.mode == .lesson ? learning.current.id+(learning.mini ? ":"+learning.miniKind.rawValue:""):session.mode.rawValue)}
    @ViewBuilder private var practiceDetail:some View {
        if !model.fairness.engineHelpAllowed{Text(FairnessPolicy.practicePaused).foregroundStyle(.secondary).accessibilityIdentifier("practice-network-paused")}
        if relationships.report==nil {
        if !session.presentationHidden,let d=session.demonstration {
            Text(d.title).sectionHeading(.title2.bold());Text("Imagined moves").foregroundStyle(.secondary)
            Picker("Line",selection:Binding(get:{d.line},set:{line in Self.attempt(session){try session.seekDemo(line:line,ply:0)}})){ForEach(d.lines.indices,id:\.self){i in Text(d.lines[i].label).tag(i)}}
            Text(d.lines[d.line].frames[d.ply].explanation)
            if session.rules.turn==session.opponentSide{Text("Stockfish waits while this demonstration is shown. Choose Game above or close it to continue.").font(.caption).foregroundStyle(.secondary)}
            Text("\(d.ply) / \(d.lines[d.line].frames.count-1)").foregroundStyle(.secondary)
        } else if !session.presentationHidden,let p=session.preview {
            Text("Try a move").sectionHeading(.title2.bold());Text("This does not change your game.").foregroundStyle(.secondary)
            if let candidate=p.candidate {Text(candidate.description)}else{Text("Select a piece, then a destination to test your idea.")}
            if let e=p.evaluation {Text(e.comparison);Picker("Continuation",selection:Binding(get:{p.line},set:{line in Self.attempt(session){try session.previewAt(ply:0,line:line)}})){Text("Your move").tag("candidate");Text("Engine suggestion").tag("recommended")};Text((p.line=="candidate" ? e.candidateFrames:e.recommendedFrames).dropFirst().map(\.san).joined(separator:" · "));Button("Play My Move"){Self.attempt(session){try session.playCandidate()}}}
            if p.status == .analyzing{ProgressView("Comparing moves…")};if let error=p.error{Text(error).foregroundStyle(.secondary)}
        } else {
            if session.explicitResumeRequired {Text("Game paused").sectionHeading(.title2.bold());Text(session.message);Text("Your game is paused because a saved review could not be restored.");Button("Return to Game"){model.resumeAfterFailedRestore()}}
            // A finished game sums itself up and offers its review (B-7), without taking Return from the board or the coach.
            else if session.finished,let result=session.state.practice.ending?.result ?? session.rules.ending?.result {VStack(alignment:.leading,spacing:Metrics.smallGap){
                Text(Self.practiceHeading(session)).sectionHeading(.title2.bold()).accessibilityIdentifier("practice-heading");Text(session.message)
                Text(Self.practiceSummary(result:result,plies:session.rules.history.count)).foregroundStyle(.secondary).monospacedDigit()
                Button("Review This Game"){model.reviewCurrent()}.buttonStyle(.borderedProminent).disabled(!model.canReviewCurrent).accessibilityIdentifier("practice-review-this-game")
            }.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(ReviewCard(radius:Metrics.cornerRadius))}
            else {Text(Self.practiceHeading(session)).sectionHeading(.title2.bold()).accessibilityIdentifier("practice-heading");Text(session.message)}
            if session.pausedOpponent {Text("The companion opponent disconnected.");Button("Continue with Stockfish"){model.companion.disable();session.continueWithStockfish()}}
            PracticeMaterial(session:session,history:history)
            OpponentSettingsContent(session:session)
            PracticeMoveList(session:session,history:history)
        }
        }
        VoiceCoachCard(voice:voice,model:model)
        if let error=session.error {Text(error).foregroundStyle(Color(nsColor:NativeColors.error));Button("Retry Stockfish"){session.retryEngine()}}
    }
    @ViewBuilder private var miniDetail:some View {
        Text(learning.miniStatus).font(.title2.bold())
        if !learning.miniKind.solo {
            Picker("Opponent",selection:Binding(get:{learning.miniGame?.computer ?? true},set:{learning.setMiniComputer($0)})){Text("Computer").tag(true);Text("Two players on this device").tag(false)}
            // Per game, and only the levels this game offers. The game in progress keeps the level its run started with,
            // labelled while it differs (also when that level is no longer offered).
            if MiniGameOffering.offersChoice(learning.miniKind) {
                Picker("Difficulty",selection:Binding(get:{learning.miniPreferredLevel},set:{learning.setMiniLevel($0)})){ForEach(MiniGameOffering.levels(for:learning.miniKind),id:\.self){Text(MiniGameOffering.title($0)).tag($0)}}.accessibilityIdentifier("mini-difficulty")
            }
            if learning.miniNewLevelOffered,let level=learning.miniLevel {
                Text(learning.miniLevelWithdrawn ? String(localized:"This game continues at \(MiniGameOffering.title(level)), a level this game no longer offers.",bundle:.checkmate):String(localized:"This game continues at \(MiniGameOffering.title(level)).",bundle:.checkmate)).foregroundStyle(.secondary).accessibilityIdentifier("mini-level-continues")
                Button("Start a New Game at \(MiniGameOffering.title(learning.miniPreferredLevel))"){learning.restartMini()}.accessibilityIdentifier("mini-new-level")
            }
            Text(learning.miniGame?.computer==true ? String(localized:"You play White. Select a piece, then its destination. The computer plays Black.",bundle:.checkmate):String(localized:"Take turns moving White and Black on this device.",bundle:.checkmate))
        }
        if learning.miniGame?.isFinished==true {Button {learning.restartMini()} label:{Label("Play again",symbol:.startOver)}.accessibilityIdentifier("mini-play-again");MiniGameReviewSection(reviewer:learning.miniReview)}
        Text(learning.miniKind.rules).foregroundStyle(.secondary)
        if !learning.feedback.isEmpty{Text(learning.feedback)}
    }
    @ViewBuilder private var lessonOrPuzzleDetail:some View {
        if session.mode == .lesson {
            if learning.practiceAvailable {
                ForEach(MiniGameKind.available(lessonID:learning.current.id),id:\.self){kind in
                    Button {learning.startMini(kind)} label:{Label("Play \(kind.title)",symbol:.play)}
                        .controlSize(.large).accessibilityIdentifier("lesson-play-"+kind.rawValue)
                }
                ForEach(learning.library.practice(for:learning.lessonIndex),id:\.self){index in
                    Button {model.openPractice(index)} label:{Label("Practice: \(learning.localizedTitle(index:index))",symbol:.gameActivity)}
                        .controlSize(.large).accessibilityIdentifier("lesson-open-practice-"+learning.library.lessons[index].id)
                }
                // The exercise is played on the lesson's own invitation step; elsewhere in the lesson this leads there.
                if !learning.attemptStep,learning.invitationStep != nil,let practice=learning.current.practice {
                    Button {learning.goToAttempt()} label:{Label(learning.attemptInProgress ? String(localized:"Resume Your Attempt",bundle:.checkmate):String(localized:"Go to Your Turn",bundle:.checkmate),symbol:.play)}
                        .controlSize(.large).accessibilityIdentifier("lesson-go-to-attempt")
                    Text(practice.goal).foregroundStyle(.secondary)
                }
            }
            if learning.attemptStep {LessonAttemptPanel(learning:learning,continueLesson:{model.continueLesson()},restart:{model.requestRestartAttempt()});Divider()}
            Picker("Transcript",selection:Binding(get:{learning.step},set:{learning.seek(step:$0)})){ForEach(learning.current.beats.indices,id:\.self){i in Text("\(i+1). \(learning.localizedStepTitle(index:learning.lessonIndex,step:i))").tag(i)}}
                .labelsHidden()
            if let fallback=learning.fallbackMessage{Text(fallback).font(.caption).foregroundStyle(.secondary)}
            Text(learning.subtitle).textSelection(.enabled)
        } else {
            if let prompt=learning.exercise?.prompt {Text(prompt).font(.title2.bold())}
            Text(learning.activePuzzle?.context ?? learning.subtitle).textSelection(.enabled)
            ForEach(Array(learning.hintTexts.enumerated()),id:\.offset){index,hint in Text("Hint \(index+1): \(hint)").foregroundStyle(.secondary).accessibilityIdentifier("puzzle-hint-\(index+1)")}
        }
        if let e=learning.activePuzzle?.exercise {
            if e.kind=="choice" {ForEach(e.choices ?? [],id:\.self){choice in Button(choice){learning.choose(choice)}.disabled(learning.passed)}}
            if e.kind=="squares" {if e.answers?.count != 1{Button("Check My Answer"){learning.checkAnswer()}.disabled(learning.picked.isEmpty || learning.passed)};if e.allowNone==true{Button("No Squares"){learning.noSquares()}.disabled(learning.passed)}}
            if e.kind=="path"{Button("Restart Path"){learning.restartPath()}}
            HStack{Button(learning.puzzleHints==0 ? String(localized:"Hint",bundle:.checkmate,comment:"Noun: ask for a hint"):String(localized:"Another Hint",bundle:.checkmate)){learning.hint()}.disabled(!learning.canHint).accessibilityIdentifier("puzzle-hint");Button("Reveal Answer"){learning.reveal()}.disabled(learning.passed)}
        }
        if !learning.feedback.isEmpty{Text(learning.feedback).foregroundStyle(.secondary)}
        if session.mode == .lesson {
            // The title toggles too; by default only the chevron does.
            DisclosureGroup(isExpanded:$lessonGoalsShown){ForEach(learning.teaches,id:\.self){Text($0)}} label:{Text("In this lesson").contentShape(Rectangle()).onTapGesture{lessonGoalsShown.toggle()}}
            if session.state.course.completed.contains(learning.current.id),let title=learning.checkYourselfTitle(index:learning.lessonIndex) {Button(title){model.checkYourself(learning.lessonIndex)}.disabled(!model.fairness.engineHelpAllowed).accessibilityIdentifier("lesson-check-yourself")}
            // On an exercise step the attempt panel carries the one Continue button.
            if !learning.attemptStep,session.state.course.completed.contains(learning.current.id),let next=learning.library.nextMainLesson(after:learning.lessonIndex) {Button("Continue to \(learning.localizedTitle(index:next))"){model.continueLesson()}}
            if CourseCompleteCard.shown(learning) {
                GroupBox {VStack(alignment:.leading,spacing:Metrics.smallGap){
                    Text(CourseCompleteCard.title).sectionHeading()
                    Text(CourseCompleteCard.message(trainingAvailable:model.training != nil)).foregroundStyle(.secondary)
                    HStack{ForEach(CourseCompleteCard.actions(trainingAvailable:model.training != nil),id:\.self){action in Button(action.title){switch action {case .puzzles:model.puzzles();case .training:model.trainingLibrary();case .game:model.practice()}}}}
                }.frame(maxWidth:.infinity,alignment:.leading)}.accessibilityElement(children:.contain).accessibilityIdentifier("course-complete")
            }
        } else {Button("Next Puzzle"){learning.next()}.disabled(!learning.passed)}
    }
}
/// Import, storage, export and practice-fork failures, rendered over the board area so they
/// are visible whichever drawers are open. Dismiss clears the message.
struct StorageErrorBanner:View {
    @ObservedObject var model:NativeModel
    var body:some View {
        if let message=model.storageError {
            HStack(alignment:.top,spacing:Metrics.smallGap){
                AppSymbol.warning.image.foregroundStyle(Color(nsColor:NativeColors.error)).accessibilityHidden(true)
                Text(message).textSelection(.enabled).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("storage-error-message")
                Spacer(minLength:0)
                if model.restoreResumePending {Button("Return to Game"){model.resumeAfterFailedRestore()}}
                Button("Dismiss"){model.dismissStorageError()}
            }
            .padding(Metrics.padding).background(.regularMaterial,in:RoundedRectangle(cornerRadius:Metrics.cornerRadius)).padding(Metrics.padding)
            .accessibilityElement(children:.contain).accessibilityLabel("Problem").accessibilityIdentifier("storage-error-banner")
        }
    }
}
struct TurnIndicator:View {
    let side:String,label:String
    var body:some View {Circle().fill(Color(nsColor:side=="w" ? BoardPalette.lightPiece:BoardPalette.darkPiece)).overlay(Circle().stroke(Color(nsColor:NativeColors.secondaryText),lineWidth:Metrics.turnIndicatorOutline)).frame(width:Metrics.turnIndicatorSize,height:Metrics.turnIndicatorSize).help(label).accessibilityLabel(label)}
}
struct TransportContent:View {
    @ObservedObject var session:GameSession
    @ObservedObject var learning:LearningPlayer
    @ObservedObject var voice:VoiceCoach
    @ObservedObject var review:ReviewController
    /// The network game, whose bar carries its turn, clocks and actions (B-1).
    @ObservedObject var network:NetworkGameController
    let newGame:()->Void,showDetails:()->Void
    /// Flip Board and Resign, which the window performs as its Game menu does (each asks first where it must).
    var gameCommand:(ControlBarAction)->Void={_ in}
    /// The network clock's low-time warning, held by the window so it sounds once per game (B-2).
    var lowTime:NetworkLowTimeWarning?=nil
    /// Hands Black back to Stockfish after the companion opponent disconnected.
    var continueWithStockfish:()->Void={}
    /// Explicit resume for a reply held after a failed review entry; always reachable with both drawers closed.
    var resumeGame:()->Void={}
    /// The training controller, when training is enabled, and the way back to its library.
    var training:TrainingController?=nil
    var openTrainingLibrary:()->Void={}
    /// Opens the next main lesson and plays it, as the lesson panel's Continue does.
    var continueLesson:()->Void={}
    /// Restarts the lesson exercise, confirmed first as the drawer's Restart is (`NativeModel.requestRestartAttempt`).
    var restartAttempt:()->Void
    /// Opens the previous main lesson at its last transcript, the reverse of Continue.
    var previousLessonEnd:()->Void={}
    /// Leaves an imagined review branch for the imported game, saving the review as the drawer's button does.
    var returnToOriginal:()->Void={}
    /// Called with the rows the bar needs (1 or 2); the window sizes the bar and the board yields the height.
    var rowsChanged:(Int)->Void={_ in}
    /// Where the bar laid out each control, for the layout acceptance.
    var framesChanged:([String:CGRect])->Void={_ in}
    /// The bar's Connect, which asks for consent first (`NativeModel.connectPracticeVoice`).
    let connectVoice:()->Void
    var voiceState:ControlBarVoice {
        if voice.connecting{return .connecting(voice.status)}
        if voice.connected{return .on(microphone:session.state.settings.voiceMicrophone,canStop:voice.canStopTurn)}
        return .off(unavailable:session.mode == .training ? voice.trainingVoiceUnavailability:voice.practiceVoiceUnavailability)
    }
    /// The training game's coach is offered: its flag, and a game being played or a session open for it.
    var trainingVoice:Bool {voice.training != nil && (voice.trainingSession || voice.trainingVoiceAvailable)}
    /// The bar for what is shown now; the Lesson menu reads the same model, so menu and bar always agree.
    var barModel:ControlBarModel {ControlBarModel.make(session:session,learning:learning,review:review,training:training,network:network,voice:voiceState,trainingVoice:trainingVoice)}
    var body:some View {ControlBarView(model:barModel,perform:perform,rowsChanged:rowsChanged,framesChanged:framesChanged,network:network,lowTime:lowTime)}
    /// What each control does; the model decides only which controls show and whether they can act.
    func perform(_ action:ControlBarAction){
        switch action {
        case .stepFromStart:learning.replay()
        case .previousStep:learning.seek(step:learning.step-1)
        case .previousLesson:previousLessonEnd()
        case .playPause:learning.playing ? learning.pause():learning.play()
        case .nextStep:learning.next()
        case .nextLesson:learning.complete();continueLesson()
        case .resumeAttempt:learning.attempt.resume()
        case .attemptHint:learning.attempt.hint();showDetails()
        case .attemptUndo:learning.attempt.undo()
        case .attemptRestart:restartAttempt()
        case .newGame,.miniNewGame:newGame()
        case .takeBack:session.undo()
        case .hint:session.hint();showDetails()
        case .tryMove,.tryAnotherMove:DetailContent.attempt(session){try session.beginPreview()}
        case .resumeGame:resumeGame()
        case .continueWithStockfish:continueWithStockfish()
        case .previewPrevious:if let p=session.preview{DetailContent.attempt(session){try session.previewAt(ply:max(0,p.ply-1),line:p.line)}}
        case .previewNext:
            if let p=session.preview{let frames=(p.line=="candidate" ? p.evaluation?.candidateFrames.count:p.evaluation?.recommendedFrames.count) ?? 0;DetailContent.attempt(session){try session.previewAt(ply:min(frames-1,p.ply+1),line:p.line)}}
        case .returnToGame:session.closePresentation()
        case .demoPrevious:if let d=session.demonstration{DetailContent.attempt(session){try session.seekDemo(line:d.line,ply:max(0,d.ply-1))}}
        case .demoPlayPause:if let d=session.demonstration{d.playing ? session.pauseDemo():session.playDemo()}
        case .demoNext:if let d=session.demonstration{DetailContent.attempt(session){try session.seekDemo(line:d.line,ply:min(d.lines[d.line].frames.count-1,d.ply+1))}}
        case .voiceConnect:connectVoice()
        case .voiceCancel,.voiceDisconnect:voice.disconnect()
        case .voiceMicrophone:var settings=session.state.settings;settings.voiceMicrophone.toggle();session.updateSettings(settings)
        case .voiceStop:voice.stopTurn()
        case .backFromMiniGame:learning.leaveMini()
        case .miniUndo:learning.undoMini()
        case .reviewFirst:review.first()
        case .reviewPrevious:review.step(-1)
        case .reviewPlayPause:review.playing ? review.pause():review.play()
        case .reviewNext:review.step(1)
        case .reviewLast:review.last()
        case .returnToOriginal:returnToOriginal()
        case .puzzleLibrary:learning.showPuzzleLibrary()
        case .nextPuzzle:learning.next()
        case .puzzleHint:learning.hint()
        case .skipPuzzle:learning.skip()
        case .trainingHint:training?.hint()
        case .trainingTakeBack:training?.undo()
        case .trainingTryAgain:training?.retry()
        case .trainingNextExercise:training?.next()
        case .trainingLibrary,.backToTraining:openTrainingLibrary()
        case .offerDraw:network.offerDraw()
        case .acceptDraw:network.answerDraw(accept:true)
        case .declineDraw:network.answerDraw(accept:false)
        case .resign,.flipBoard:gameCommand(action)
        case .more:break
        }
    }
}
// A passive edge indicator keeps playback feedback out of the transport controls.
struct LessonProgressContent:View {
    @ObservedObject var review:ReviewController
    @ObservedObject var session:GameSession
    @ObservedObject var learning:LearningPlayer
    private var fraction:Double {if review.active{return review.progress};return learning.duration>0 ? min(1,max(0,learning.seconds/learning.duration)):0}
    var body:some View {
        if review.active || session.mode == .lesson && !learning.mini && learning.activePuzzle==nil {
            GeometryReader {geometry in
                Rectangle().fill(Color.accentColor).frame(width:geometry.size.width*fraction,height:Metrics.playbackLineHeight)
            }
            .allowsHitTesting(false)
            .accessibilityElement(children:.ignore)
            .accessibilityLabel(review.active ? String(localized:"Review playback",bundle:.checkmate):String(localized:"Transcript playback",bundle:.checkmate))
            .accessibilityValue("\(Int(fraction*100)) percent")
        }
    }
}
struct PuzzleLibraryContent:View {
    @ObservedObject var learning:LearningPlayer
    @ObservedObject var session:GameSession
    var body:some View {let puzzles=learning.filteredPuzzles;VStack(alignment:.leading,spacing:Metrics.padding){Text("Quick puzzles").sectionHeading(.largeTitle.bold());Text(PuzzleRowFormat.heading(session.state.puzzles)).foregroundStyle(.secondary)
        if let summary=learning.setSummary {GroupBox {VStack(alignment:.leading,spacing:Metrics.smallGap){Text("You Reached the End of This Set").sectionHeading();Text(summary.text);if summary.toReview>0{Button("Review Mistakes"){learning.reviewMistakes()}.accessibilityIdentifier("puzzle-review-mistakes")}}.frame(maxWidth:.infinity,alignment:.leading)}.accessibilityElement(children:.contain).accessibilityIdentifier("puzzle-set-summary")}
        TextField("Search exercises",text:$learning.query).textFieldStyle(.roundedBorder)
        HStack {Picker("Topic",selection:$learning.topic){Text("All topics").tag(String?.none);ForEach(learning.topicGroups,id:\.title){group in Section(group.title){ForEach(group.topics,id:\.self){Text($0).tag(String?.some($0))}}}};Picker("Level",selection:$learning.level){Text("All levels").tag(String?.none);ForEach(learning.levels,id:\.self){Text($0).tag(String?.some($0))}};Picker("Status",selection:$learning.filter){ForEach(PuzzleStatusFilter.allCases,id:\.self){Text($0.title).tag($0)}}}
        Text(String(localized:"\(puzzles.count) exercises",bundle:.checkmate)).foregroundStyle(.secondary)
        if puzzles.isEmpty{ContentUnavailableView{Label("No matching exercises",symbol:.search)}description:{Text("No exercises match these filters.")}actions:{Button("Clear Filters"){learning.clearFilters()}.disabled(!learning.filtersActive)}.accessibilityIdentifier("puzzle-library-empty")}
        else{List(puzzles,id:\.id){p in let row=PuzzleRowFormat(p,record:session.state.puzzles[p.id] ?? PuzzleProgress());Button{learning.openPuzzle(id:p.id)}label:{HStack{VStack(alignment:.leading){Text(row.title);Text(row.detail).font(.caption).foregroundStyle(.secondary)};Spacer();if row.review{AppSymbol.toReview.image.foregroundStyle(.secondary).help("To review").accessibilityHidden(true)};if let mark=row.mark,let help=row.markHelp{mark.symbol.image.foregroundStyle(Color(nsColor:NativeColors.success)).help(help).accessibilityHidden(true)}}}.buttonStyle(.plain)
            .accessibilityValue(row.accessibilityValue)}}
    }.padding(Metrics.sectionGap)}
}
extension PuzzleStatusFilter {var title:String{switch self{case .all:return String(localized:"All",bundle:.checkmate);case .unsolved:return String(localized:"Unsolved",bundle:.checkmate);case .review:return String(localized:"To review",bundle:.checkmate)}}}
struct WelcomeContent:View {let title:String;var body:some View {VStack(spacing:Metrics.sectionGap){Image("LessonKnight",bundle:.main).resizable().renderingMode(.template).scaledToFit().foregroundStyle(.primary).frame(width:Metrics.mascotSize,height:Metrics.mascotSize).accessibilityHidden(true);Text(title).sectionHeading(.largeTitle.bold())}.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.center)}}
/// Exercise controls under the board: hint, try again or next, and the way back to the library.
