import SwiftUI
import CheckmateCore
/// The sidebar row for an activity. The workspace, an unsaved review and each saved review are separate rows, so
/// choosing Review game from an open review is a real selection change (RV-12).
enum SidebarSelection {
    static func tag(_ activity:Activity,saved:Set<UUID>,lessonIndex:Int)->String {
        if let visit=activity.review{guard let document=visit.document else{return "review"};return saved.contains(document) ? "review:"+document.uuidString:"review:draft"}
        switch activity.place {case .practice:return "practice";case .puzzleLibrary,.puzzle:return "puzzles";case .lesson:return "lesson:\(lessonIndex)";case .miniGame(let index,_,_):return index==nil ? "training":"lesson:\(lessonIndex)";case .trainingLibrary,.training:return "training";case .network:return "network"}
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
        return "Practice activity for \(learning.localizedTitle(index:index))"
    }
    private func navigate(_ value:String?) {
        guard let value=value else{return}
        if value=="review:draft" {return}
        if value=="review" {model.showReviewWorkspace()}
        else if value.hasPrefix("review:"),let id=UUID(uuidString:String(value.dropFirst(7))) {model.openSavedReview(id)}
        else if value=="practice" {model.practice()}
        else if value=="puzzles" {model.puzzles()}
        else if value=="training" {model.trainingLibrary()}
        else if value=="network" {model.playOnNetwork()}
        else if let i=Int(value.replacingOccurrences(of:"lesson:",with:"")) {model.lesson(i)}
    }
    /// During a network game lessons, puzzles and training are closed (LAN-play plan D8): their rows say why.
    private var participating:Bool {!model.fairness.engineHelpAllowed}
    var body:some View {List(selection:Binding<String?>(get:{selected},set:navigate)){
        Section {
            Label("Practice a game",systemImage:"flag.checkered").tag("practice")
            if NetworkPolicy.availableHere{Label{VStack(alignment:.leading,spacing:1){Text("Play on Network");if let badge=SidebarSelection.networkBadge(session.activity,network){Text(badge).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("network-sidebar-badge")}}}icon:{Image(systemName:"network")}.tag("network")}
            Label("Quick puzzles",systemImage:"lightbulb").tag("puzzles").selectionDisabled(participating).help(participating ? FairnessPolicy.destinationUnavailable:"")
            if model.training != nil{Label("Training",systemImage:"figure.run").tag("training").selectionDisabled(participating).help(participating ? FairnessPolicy.destinationUnavailable:"")}
            Label("Review game",systemImage:"doc.text.magnifyingglass").tag("review")
            if model.review.active,let document=model.review.document,!model.reviews.contains(where:{$0.id==document.id}){Label("Unsaved review",systemImage:"doc.badge.ellipsis").tag("review:draft")}
        }
        if !model.reviews.isEmpty {
            Section("Saved reviews"){ForEach(model.reviews){record in Label(record.title=="?" ? "Untitled game":record.title,systemImage:"doc.text").tag("review:"+record.id.uuidString)
                .contextMenu{Button("Delete Saved Review…",role:.destructive){model.requestDeleteReview(record.id)}.disabled(model.deletingReviewID != nil)}}}
        }
        // A practice activity sits indented under its lesson, off the main path but one click away.
        Section("Learn & explore") {ForEach(Array(learning.library.lessons.enumerated()),id:\.element.id){i,l in Label {Text(learning.localizedTitle(index:i))} icon:{Image(systemName:session.state.course.completed.contains(l.id) ? "checkmark.circle.fill":l.isPractice ? "gamecontroller":"book")}.padding(.leading,l.isPractice ? Metrics.practiceIndent:0).accessibilityHint(participating ? FairnessPolicy.destinationUnavailable:practiceHint(l)).tag("lesson:\(i)").selectionDisabled(participating)}}
    }.listStyle(.sidebar).scrollContentBackground(.hidden).overlay(alignment:.bottom){if model.importingReview{VStack{ProgressView("Loading review…");Button("Cancel import"){model.cancelReviewImport()}}.padding().background(.regularMaterial)}}}
}
struct DetailContent:View {
    @ObservedObject var session:GameSession
    @ObservedObject var learning:LearningPlayer
    @ObservedObject var model:NativeModel
    @ObservedObject var voice:VoiceCoach
    @ObservedObject var relationships:RelationshipController
    let inspect:(RelationshipMode)->Void
    @State private var lessonGoalsShown=false
    var body:some View {ScrollView {VStack(alignment:.leading,spacing:Metrics.sectionGap) {
        if model.reviewWorkspace {
            Text("PGN game records").font(.headline)
            Text("Open a finished or unfinished game, including its recorded moves and variations.")
            Text("FEN positions").font(.headline)
            Text("Explore a single board position. Earlier moves and repetition history are not included.").foregroundStyle(.secondary)
        } else if model.review.active{ReviewDetailContent(review:model.review,model:model)}else {
        if let label=relationships.selectedLabel{RelationshipContent(relationships:relationships,label:label,inspect:inspect);Divider()}
        if session.mode == .network {NetworkDetail(model:model,game:model.network)}
        else if session.mode == .practice {practiceDetail}
        else if relationships.report==nil {
            if learning.mini {miniDetail}
            else if learning.activePuzzle != nil || session.mode == .lesson {lessonOrPuzzleDetail}
            else if session.mode == .training,let training=model.training {
                if case .training=session.activity.place,training.exercise != nil {TrainingPanel(model:model,training:training)}
                else {Text("Training").font(.title2.bold());Text("Choose an exercise from the library.")}
            } else {Text("Quick puzzles").font(.title2.bold());Text("Choose an exercise from the library.")}
        }
    }
    }.frame(maxWidth:.infinity,alignment:.leading).padding(Metrics.sectionGap)}.id(session.mode == .lesson ? learning.current.id+(learning.mini ? ":"+learning.miniKind.rawValue:""):session.mode.rawValue)}
    @ViewBuilder private var practiceDetail:some View {
        if !model.fairness.engineHelpAllowed{Text(FairnessPolicy.practicePaused).foregroundStyle(.secondary).accessibilityIdentifier("practice-network-paused")}
        if relationships.report==nil {
        if !session.presentationHidden,let d=session.demonstration {
            Text(d.title).font(.title2.bold());Text("Imagined moves").foregroundStyle(.secondary)
            Picker("Line",selection:Binding(get:{d.line},set:{try? session.seekDemo(line:$0,ply:0)})){ForEach(d.lines.indices,id:\.self){i in Text(d.lines[i].label).tag(i)}}
            Text(d.lines[d.line].frames[d.ply].explanation)
            if session.rules.turn==session.opponentSide{Text("Stockfish waits while this demonstration is shown. Choose Game above or close it to continue.").font(.caption).foregroundStyle(.secondary)}
            Text("\(d.ply) / \(d.lines[d.line].frames.count-1)").foregroundStyle(.secondary)
        } else if !session.presentationHidden,let p=session.preview {
            Text("Try a move").font(.title2.bold());Text("This does not change your game.").foregroundStyle(.secondary)
            if let candidate=p.candidate {Text(candidate.description)}else{Text("Select a piece, then a destination to test your idea.")}
            if let e=p.evaluation {Text(e.comparison);Picker("Continuation",selection:Binding(get:{p.line},set:{try? session.previewAt(ply:0,line:$0)})){Text("Your move").tag("candidate");Text("Engine suggestion").tag("recommended")};Text((p.line=="candidate" ? e.candidateFrames:e.recommendedFrames).dropFirst().map(\.san).joined(separator:" · "));Button("Play my move"){try? session.playCandidate()}}
            if p.status=="analyzing"{ProgressView("Comparing moves…")};if let error=p.error{Text(error).foregroundStyle(.secondary)}
        } else {
            if session.explicitResumeRequired {Text("Game paused.").font(.title2.bold());Text(session.message);Text("Your game is paused because a saved review could not be restored.");Button("Return to game"){model.resumeAfterFailedRestore()}}
            else {Text("Your next move.").font(.title2.bold());Text(session.message)}
            if session.pausedOpponent {Text("The companion opponent disconnected.");Button("Continue with Stockfish"){model.companion.disable();session.continueWithStockfish()}}
            OpponentSettingsContent(session:session)
            Text("Moves").font(.headline);Text(session.rules.history.isEmpty ? "Your story starts with one move.":session.moveListText).textSelection(.enabled)
        }
        }
        if voice.connected || voice.connecting || !voice.history.isEmpty || voice.status != "Disconnected" {Divider();Text("Voice coach").font(.headline);Text(voice.status).foregroundStyle(.secondary);if voice.connected{HStack{Button("Recheck"){voice.recheck()};Button("Stop speaking"){voice.stopTurn()}}};ForEach(Array(voice.history.reversed())){entry in VStack(alignment:.leading){Text(entry.role=="learner" ? "You":"Coach").font(.caption).foregroundStyle(.secondary);Text(entry.text).textSelection(.enabled)}}}
        if let error=session.error {Text(error).foregroundStyle(Color(nsColor:NativeColors.error));Button("Retry Stockfish"){session.retryEngine()}}
    }
    @ViewBuilder private var miniDetail:some View {
        Text(learning.miniStatus).font(.title2.bold())
        if !learning.miniKind.solo {
            Picker("Opponent",selection:Binding(get:{learning.miniGame?.computer ?? true},set:{learning.setMiniComputer($0)})){Text("Computer").tag(true);Text("Two players on this device").tag(false)}
            Picker("Difficulty",selection:Binding(get:{session.state.settings.miniOpponentProfile},set:{var settings=session.state.settings;settings.miniOpponentProfile=$0;session.updateSettings(settings)})){Text("Beginner").tag("beginner");Text("Standard").tag("standard");Text("Challenging").tag("challenging")}
            Text(learning.miniGame?.computer==true ? "You play White. Select a piece, then its destination. The computer plays Black.":"Take turns moving White and Black on this device.")
        }
        if learning.miniGame?.isFinished==true {Button {learning.restartMini()} label:{Label("Play again",systemImage:"arrow.counterclockwise")}.accessibilityIdentifier("mini-play-again")}
        Text(learning.miniKind.rules).foregroundStyle(.secondary)
        if !learning.feedback.isEmpty{Text(learning.feedback)}
    }
    @ViewBuilder private var lessonOrPuzzleDetail:some View {
        if session.mode == .lesson {
            if learning.practiceAvailable {
                ForEach(MiniGameKind.available(lessonID:learning.current.id),id:\.self){kind in
                    Button {learning.startMini(kind)} label:{Label("Play \(kind.title)",systemImage:"play.fill")}
                        .controlSize(.large).accessibilityIdentifier("lesson-play-"+kind.rawValue)
                }
                ForEach(learning.library.practice(for:learning.lessonIndex),id:\.self){index in
                    Button {model.openPractice(index)} label:{Label("Practise: \(learning.localizedTitle(index:index))",systemImage:"gamecontroller")}
                        .controlSize(.large).accessibilityIdentifier("lesson-open-practice-"+learning.library.lessons[index].id)
                }
                // The exercise is played on the lesson's own invitation step; elsewhere in the lesson this leads there.
                if !learning.attemptStep,learning.invitationStep != nil,let practice=learning.current.practice {
                    Button {learning.goToAttempt()} label:{Label(learning.attemptInProgress ? "Resume your attempt":"Go to your turn",systemImage:"play.fill")}
                        .controlSize(.large).accessibilityIdentifier("lesson-go-to-attempt")
                    Text(practice.goal).foregroundStyle(.secondary)
                }
            }
            if learning.attemptStep {LessonAttemptPanel(learning:learning,continueLesson:{model.continueLesson()});Divider()}
            Picker("Transcript",selection:Binding(get:{learning.step},set:{learning.seek(step:$0)})){ForEach(learning.current.beats.indices,id:\.self){i in Text("\(i+1). \(learning.localizedStepTitle(index:learning.lessonIndex,step:i))").tag(i)}}
                .labelsHidden()
            if let fallback=learning.fallbackMessage{Text(fallback).font(.caption).foregroundStyle(.secondary)}
            Text(learning.subtitle).textSelection(.enabled)
        } else {
            if let prompt=learning.exercise?.prompt {Text(prompt).font(.title2.bold())}
            Text(learning.activePuzzle?.context ?? learning.subtitle).textSelection(.enabled)
        }
        if let e=learning.activePuzzle?.exercise {
            if e.kind=="choice" {ForEach(e.choices ?? [],id:\.self){choice in Button(choice){learning.choose(choice)}.disabled(learning.passed)}}
            if e.kind=="squares" {if e.answers?.count != 1{Button("Check my answer"){learning.checkAnswer()}.disabled(learning.picked.isEmpty || learning.passed)};if e.allowNone==true{Button("No squares"){learning.noSquares()}.disabled(learning.passed)}}
            if e.kind=="path"{Button("Restart path"){learning.restartPath()}}
            Button("Reveal answer"){learning.reveal()}.disabled(learning.passed)
        }
        if !learning.feedback.isEmpty{Text(learning.feedback).foregroundStyle(.secondary)}
        if session.mode == .lesson {
            // The title toggles too; by default only the chevron does.
            DisclosureGroup(isExpanded:$lessonGoalsShown){ForEach(learning.teaches,id:\.self){Text($0)}} label:{Text("In this lesson").contentShape(Rectangle()).onTapGesture{lessonGoalsShown.toggle()}}
            if session.state.course.completed.contains(learning.current.id),let next=learning.library.nextMainLesson(after:learning.lessonIndex) {Button("Continue to \(learning.localizedTitle(index:next))"){model.continueLesson()}}
        } else {Button("Next puzzle"){learning.next()}.disabled(!learning.passed)}
    }
}
/// Import, storage, export and practice-fork failures, rendered over the board area so they
/// are visible whichever drawers are open. Dismiss clears the message.
struct StorageErrorBanner:View {
    @ObservedObject var model:NativeModel
    var body:some View {
        if let message=model.storageError {
            HStack(alignment:.top,spacing:Metrics.smallGap){
                Image(systemName:"exclamationmark.triangle.fill").foregroundStyle(Color(nsColor:NativeColors.error)).accessibilityHidden(true)
                Text(message).textSelection(.enabled).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("storage-error-message")
                Spacer(minLength:0)
                if model.restoreResumePending {Button("Return to game"){model.resumeAfterFailedRestore()}}
                Button("Dismiss"){model.dismissStorageError()}
            }
            .padding(Metrics.padding).background(.regularMaterial,in:RoundedRectangle(cornerRadius:8)).padding(Metrics.padding)
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
    let newGame:()->Void,showDetails:()->Void
    /// Hands Black back to Stockfish after the companion opponent disconnected.
    var continueWithStockfish:()->Void={}
    /// Explicit resume for a reply held after a failed review entry; always reachable with both drawers closed.
    var resumeGame:()->Void={}
    /// The training controller, when training is enabled, and the way back to its library.
    var training:TrainingController?=nil
    var openTrainingLibrary:()->Void={}
    /// Opens the next main lesson and plays it, as the lesson panel's Continue does.
    var continueLesson:()->Void={}
    /// Opens the previous main lesson at its last transcript, the reverse of Continue.
    var previousLessonEnd:()->Void={}
    /// Leaves an imagined review branch for the imported game, saving the review as the drawer's button does.
    var returnToOriginal:()->Void={}
    /// Called with the rows the bar needs (1 or 2); the window sizes the bar and the board yields the height.
    var rowsChanged:(Int)->Void={_ in}
    /// Where the bar laid out each control, for the layout acceptance.
    var framesChanged:([String:CGRect])->Void={_ in}
    var voiceState:ControlBarVoice {
        if voice.connecting{return .connecting(voice.status)}
        if voice.connected{return .on(microphone:session.state.settings.voiceMicrophone,canStop:voice.canStopTurn)}
        return .off(available:!session.companionEnabled)
    }
    /// The bar for what is shown now; the Lesson menu reads the same model, so menu and bar always agree.
    var barModel:ControlBarModel {ControlBarModel.make(session:session,learning:learning,review:review,training:training,voice:voiceState)}
    var body:some View {ControlBarView(model:barModel,perform:perform,rowsChanged:rowsChanged,framesChanged:framesChanged)}
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
        case .attemptRestart:learning.attempt.restart()
        case .newGame,.miniNewGame:newGame()
        case .takeBack:session.undo()
        case .hint:session.hint()
        case .tryMove,.tryAnotherMove:try? session.beginPreview()
        case .resumeGame:resumeGame()
        case .continueWithStockfish:continueWithStockfish()
        case .previewPrevious:if let p=session.preview{try? session.previewAt(ply:max(0,p.ply-1),line:p.line)}
        case .previewNext:
            if let p=session.preview{let frames=(p.line=="candidate" ? p.evaluation?.candidateFrames.count:p.evaluation?.recommendedFrames.count) ?? 0;try? session.previewAt(ply:min(frames-1,p.ply+1),line:p.line)}
        case .returnToGame:session.closePresentation()
        case .demoPrevious:if let d=session.demonstration{try? session.seekDemo(line:d.line,ply:max(0,d.ply-1))}
        case .demoPlayPause:if let d=session.demonstration{d.playing ? session.pauseDemo():session.playDemo()}
        case .demoNext:if let d=session.demonstration{try? session.seekDemo(line:d.line,ply:min(d.lines[d.line].frames.count-1,d.ply+1))}
        case .voiceConnect:voice.connect()
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
        case .trainingHint:training?.hint()
        case .trainingTakeBack:training?.undo()
        case .trainingTryAgain:training?.retry()
        case .trainingNextExercise:training?.next()
        case .trainingLibrary,.backToTraining:openTrainingLibrary()
        }
    }
}
// A passive edge indicator keeps playback feedback out of the transport controls.
struct LessonProgressContent:View {
    @ObservedObject var review:ReviewController
    @ObservedObject var session:GameSession
    @ObservedObject var learning:LearningPlayer
    @State private var color=NativeColors.playbackAccents.randomElement() ?? NSColor.controlAccentColor
    private var fraction:Double {if review.active{return review.progress};return learning.duration>0 ? min(1,max(0,learning.seconds/learning.duration)):0}
    var body:some View {
        if review.active || session.mode == .lesson && !learning.mini && learning.activePuzzle==nil {
            GeometryReader {geometry in
                Rectangle().fill(Color(nsColor:color)).frame(width:geometry.size.width*fraction,height:Metrics.playbackLineHeight)
            }
            .allowsHitTesting(false)
            .accessibilityElement(children:.ignore)
            .accessibilityLabel(review.active ? "Review playback":"Transcript playback")
            .accessibilityValue("\(Int(fraction*100)) percent")
        }
    }
}
struct PuzzleLibraryContent:View {
    @ObservedObject var learning:LearningPlayer
    @ObservedObject var session:GameSession
    var body:some View {let puzzles=learning.filteredPuzzles;VStack(alignment:.leading,spacing:Metrics.padding){Text("Quick puzzles").font(.largeTitle.bold());Text("\(session.state.puzzles.values.filter(\.solved).count) solved · \(session.state.puzzles.values.filter(\.review).count) to review").foregroundStyle(.secondary)
        TextField("Search exercises",text:$learning.query).textFieldStyle(.roundedBorder)
        HStack {Picker("Topic",selection:$learning.topic){Text("All topics").tag("All topics");ForEach(Array(Set(learning.library.puzzles.map(\.topic))).sorted(),id:\.self){Text($0).tag($0)}};Picker("Level",selection:$learning.level){ForEach(["All levels","Foundation","Developing"],id:\.self){Text($0).tag($0)}};Picker("Status",selection:$learning.filter){ForEach(["All","Unsolved","To review"],id:\.self){Text($0).tag($0)}}}
        Text("\(puzzles.count) exercises").foregroundStyle(.secondary)
        List(puzzles,id:\.id){p in Button{learning.openPuzzle(id:p.id)}label:{HStack{VStack(alignment:.leading){Text(p.title);Text(p.topic).font(.caption).foregroundStyle(.secondary)};Spacer();if session.state.puzzles[p.id]?.solved==true{Image(systemName:"checkmark.circle.fill").foregroundStyle(Color(nsColor:NativeColors.success))}}}.buttonStyle(.plain)}
        if puzzles.isEmpty{Text("No exercises match these filters.")}
    }.padding(Metrics.sectionGap)}
}
struct WelcomeContent:View {let title:String;var body:some View {VStack(spacing:Metrics.sectionGap){Image("LessonKnight",bundle:.main).resizable().renderingMode(.template).scaledToFit().foregroundStyle(.primary).frame(width:Metrics.mascotSize,height:Metrics.mascotSize).accessibilityHidden(true);Text(title).font(.largeTitle.bold())}.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.center)}}
/// Exercise controls under the board: hint, try again or next, and the way back to the library.
