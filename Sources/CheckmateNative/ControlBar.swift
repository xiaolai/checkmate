import SwiftUI
import CheckmateCore

/// Everything the bottom control bar can do. One action has one meaning, and so one symbol (see `ControlBarItem`).
enum ControlBarAction:Hashable {
    case stepFromStart,previousStep,previousLesson,playPause,nextStep,nextLesson
    case resumeAttempt,attemptHint,attemptUndo,attemptRestart
    case newGame,takeBack,hint,tryMove,resumeGame,continueWithStockfish
    case previewPrevious,previewNext,tryAnotherMove,returnToGame
    case demoPrevious,demoPlayPause,demoNext
    case voiceConnect,voiceCancel,voiceMicrophone,voiceStop,voiceDisconnect
    case backFromMiniGame,miniUndo,miniNewGame
    case reviewFirst,reviewPrevious,reviewPlayPause,reviewNext,reviewLast,returnToOriginal
    case puzzleLibrary,nextPuzzle
    case trainingHint,trainingTakeBack,trainingTryAgain,trainingNextExercise,trainingLibrary,backToTraining
}

/// One control: an icon button when `symbol` is set, otherwise a text button. `label` is what VoiceOver says and the
/// tooltip shows; a text button shows `label` itself.
struct ControlBarItem:Equatable,Identifiable {
    let action:ControlBarAction
    var symbol:String?=nil
    let label:String
    var enabled=true
    /// A text button that recovers or moves on: drawn prominent.
    var prominent=false
    /// The main playback control, drawn with a larger symbol.
    var primary=false
    /// Voice: Disconnect is offered from this control's menu.
    var menu:[ControlBarItem]=[]
    /// More to say than the label, shown as the tooltip (a connection's progress).
    var detail:String?=nil
    var id:ControlBarAction {action}
}

/// What the bar says about the state shown: plain text, whose turn it is, or that something is being worked out.
enum ControlBarStatus:Equatable {
    case text(String)
    case turn(side:String,label:String)
    case working(String)
}

/// The bar for one state of the app: status, leading actions, the centre group and trailing tools.
///
/// In a lesson the centre always holds the same four playback slots (from the start, previous, play, next), so they
/// never move while the learner steps through it, its exercise step included; a slot that cannot act is disabled.
/// Practice, mini-games and training put their status in the centre: the board is their main control.
struct ControlBarModel:Equatable {
    var status:ControlBarStatus?=nil
    var statusInCentre=false
    var leading:[ControlBarItem]=[]
    var centre:[ControlBarItem]=[]
    var trailing:[ControlBarItem]=[]
    /// Further trailing groups, each drawn as its own group (voice beside the game's tools).
    var trailingGroups:[[ControlBarItem]]=[]

    var items:[ControlBarItem] {leading+centre+trailing+trailingGroups.flatMap{$0}}
    func item(_ action:ControlBarAction)->ControlBarItem? {items.first{$0.action==action}}
}

/// The voice coach as the bar shows it.
enum ControlBarVoice:Equatable {
    case off(available:Bool)
    case connecting(String)
    case on(microphone:Bool,canStop:Bool)
}

extension ControlBarModel {
    /// The bar for what the app shows now. Pure: it reads the model and decides nothing else.
    @MainActor static func make(session:GameSession,learning:LearningPlayer,review:ReviewController,training:TrainingController?,voice:ControlBarVoice)->ControlBarModel {
        if review.active {return reviewBar(review)}
        // The network game's actions live in its own pane and menus (LAN-play plan D10: no new toolbar items).
        if session.mode == .network {return ControlBarModel()}
        if session.mode == .practice {return practiceBar(session,voice:voice)}
        if learning.mini {return miniBar(learning)}
        if session.mode == .training,let training {return trainingBar(training,session:session)}
        if session.mode == .lesson {return lessonBar(learning)}
        if learning.activePuzzle != nil {
            return ControlBarModel(leading:[ControlBarItem(action:.puzzleLibrary,symbol:"square.grid.2x2",label:"Puzzle library")],trailing:[ControlBarItem(action:.nextPuzzle,label:"Next puzzle",enabled:learning.passed,prominent:learning.passed)])
        }
        return ControlBarModel()
    }

    @MainActor private static func lessonBar(_ learning:LearningPlayer)->ControlBarModel {
        var bar=ControlBarModel()
        let step=learning.step,last=learning.current.beats.count-1
        let previous=step==0 ? learning.library.previousMainLesson(before:learning.lessonIndex):nil
        let next=step>=last ? learning.library.nextMainLesson(after:learning.lessonIndex):nil
        if learning.readingFromTraining{bar.leading.append(ControlBarItem(action:.backToTraining,label:"Back to training"))}
        let replay=learning.attemptStep ? (learning.attempt.hasMoves ? "Replay the original instruction (your game stays as it is)":"Replay the instruction"):"Replay transcript"
        bar.centre=[
            ControlBarItem(action:.stepFromStart,symbol:"backward.end",label:replay),
            previous.map{ControlBarItem(action:.previousLesson,symbol:"chevron.backward.2",label:"Previous lesson: \(learning.localizedTitle(index:$0))")}
                ?? ControlBarItem(action:.previousStep,symbol:"chevron.backward",label:"Previous transcript",enabled:step>0),
            ControlBarItem(action:.playPause,symbol:learning.playing ? "pause.fill":"play.fill",label:learning.playing ? "Pause":"Play",primary:true),
            next.map{ControlBarItem(action:.nextLesson,symbol:"chevron.forward.2",label:"Next lesson: \(learning.localizedTitle(index:$0))")}
                ?? ControlBarItem(action:.nextStep,symbol:"chevron.forward",label:"Next transcript"),
        ]
        if learning.attemptStep,let status=learning.attemptStatus {
            let attempt:LessonAttemptController=learning.attempt
            bar.status = attempt.thinking ? .working(status):.turn(side:attempt.rules.turn,label:status)
            if attempt.waitingToResume{bar.leading.append(ControlBarItem(action:.resumeAttempt,label:"Resume your attempt",prominent:true))}
            let hint=attempt.canShowMove ? "Show me a move":(attempt.record?.hints ?? 0)==0 ? "Hint":"Another hint"
            bar.trailing=[
                ControlBarItem(action:.attemptHint,symbol:"lightbulb",label:hint,enabled:attempt.learnerToMove || attempt.phase == .offTrack),
                ControlBarItem(action:.attemptUndo,symbol:"arrow.uturn.backward",label:"Undo turn",enabled:attempt.hasMoves),
                ControlBarItem(action:.attemptRestart,symbol:"arrow.counterclockwise",label:"Restart",enabled:attempt.hasMoves),
            ]
        } else {
            var text="Step \(step+1) of \(last+1)"
            if let next{text+=" · next: \(learning.localizedTitle(index:next))"}
            else if let previous{text+=" · back: \(learning.localizedTitle(index:previous))"}
            bar.status = .text(text)
        }
        return bar
    }

    @MainActor private static func practiceBar(_ session:GameSession,voice:ControlBarVoice)->ControlBarModel {
        let voiceGroup=voiceControls(voice)
        if !session.presentationHidden,let d=session.demonstration {
            let count=d.lines[d.line].frames.count
            return ControlBarModel(status:.text("Demonstration · move \(d.ply) of \(max(0,count-1))"),centre:[
                ControlBarItem(action:.demoPrevious,symbol:"chevron.backward",label:"Previous imagined move",enabled:d.ply>0),
                ControlBarItem(action:.demoPlayPause,symbol:d.playing ? "pause.fill":"play.fill",label:d.playing ? "Pause demonstration":"Play demonstration",primary:true),
                ControlBarItem(action:.demoNext,symbol:"chevron.forward",label:"Next imagined move",enabled:d.ply<count-1),
            ],trailing:[ControlBarItem(action:.returnToGame,label:"Return to game",prominent:true)],trailingGroups:[voiceGroup.items])
        }
        if !session.presentationHidden,let p=session.preview {
            let frames=(p.line=="candidate" ? p.evaluation?.candidateFrames.count:p.evaluation?.recommendedFrames.count) ?? 0
            var trailing:[ControlBarItem]=[]
            if p.candidate != nil{trailing.append(ControlBarItem(action:.tryAnotherMove,label:"Try another move",enabled:session.rules.turn==session.humanSide && !session.rules.over))}
            trailing.append(ControlBarItem(action:.returnToGame,label:"Return to game",prominent:true))
            return ControlBarModel(status:.text(p.evaluation==nil ? "Your idea":"Your idea · move \(p.ply) of \(max(0,frames-1))"),centre:[
                ControlBarItem(action:.previewPrevious,symbol:"chevron.backward",label:"Previous preview move",enabled:p.evaluation != nil && p.ply>0),
                ControlBarItem(action:.previewNext,symbol:"chevron.forward",label:"Next preview move",enabled:p.evaluation != nil && p.ply<frames-1),
            ],trailing:trailing,trailingGroups:[voiceGroup.items])
        }
        var bar=ControlBarModel(statusInCentre:true)
        // During a network game practice is viewable only: Stockfish waits and hints, Try a move and voice are off (D8).
        let fair=session.fairness.engineHelpAllowed
        bar.status = !fair ? .text(FairnessPolicy.practicePaused):session.busyReason=="opponent" ? .working("Stockfish is thinking"):session.busy ? .working("Finding a hint"):.turn(side:session.rules.turn,label:session.rules.status)
        bar.leading=[ControlBarItem(action:.newGame,label:"New game…")]
        if session.explicitResumeRequired{bar.leading.append(ControlBarItem(action:.resumeGame,label:"Resume game",prominent:true))}
        else if session.pausedOpponent{bar.leading.append(ControlBarItem(action:.continueWithStockfish,label:"Continue with Stockfish",prominent:true))}
        let yourMove=session.rules.turn==session.humanSide && !session.finished
        bar.trailing=[
            ControlBarItem(action:.takeBack,symbol:"arrow.uturn.backward",label:"Take back move",enabled:session.canTakeBack),
            ControlBarItem(action:.hint,symbol:"lightbulb",label:"Hint",enabled:fair && !session.busy && yourMove),
            ControlBarItem(action:.tryMove,label:"Try a move",enabled:fair && yourMove && session.busyReason != "opponent" && session.demonstration==nil),
        ]
        bar.trailingGroups=fair ? [voiceGroup.items]:[]
        if let status=voiceGroup.status{bar.status = .working(status)}
        return bar
    }

    /// The voice coach's controls, the same beside the game and over a preview or demonstration: Cancel while it
    /// connects, Stop one click away while it is on, Disconnect in the microphone's menu.
    private static func voiceControls(_ voice:ControlBarVoice)->(items:[ControlBarItem],status:String?) {
        switch voice {
        case .off(let available):return ([ControlBarItem(action:.voiceConnect,symbol:"mic",label:available ? "Connect voice coach":"Disconnect the MCP companion before connecting voice",enabled:available)],nil)
        case .connecting(let status):return ([ControlBarItem(action:.voiceCancel,label:"Cancel voice connection",detail:status)],"Connecting voice coach")
        case .on(let microphone,let canStop):return ([
            ControlBarItem(action:.voiceStop,symbol:"stop.fill",label:"Stop coach speaking",enabled:canStop),
            ControlBarItem(action:.voiceMicrophone,symbol:microphone ? "mic":"mic.slash",label:microphone ? "Mute microphone":"Enable microphone",menu:[ControlBarItem(action:.voiceDisconnect,label:"Disconnect voice coach")]),
        ],nil)
        }
    }

    @MainActor private static func miniBar(_ learning:LearningPlayer)->ControlBarModel {
        let back=learning.miniFromLibrary ? "Back to training":"Back to \(learning.localizedTitle(index:learning.lessonIndex))"
        var bar=ControlBarModel(statusInCentre:true,leading:[ControlBarItem(action:.backFromMiniGame,label:back)])
        bar.status = learning.miniKind.solo ? .text(learning.miniStatus):.turn(side:learning.miniTurn,label:learning.miniStatus)
        bar.trailing=[
            ControlBarItem(action:.miniUndo,symbol:"arrow.uturn.backward",label:"Undo turn",enabled:learning.miniGame?.history.isEmpty == false),
            ControlBarItem(action:.miniNewGame,symbol:"arrow.counterclockwise",label:"New game"),
        ]
        return bar
    }

    @MainActor private static func reviewBar(_ review:ReviewController)->ControlBarModel {
        var bar=ControlBarModel(status:.text(review.branch==nil ? "Original game":"Imagined line"))
        bar.centre=[
            ControlBarItem(action:.reviewFirst,symbol:"backward.end.fill",label:"First position"),
            ControlBarItem(action:.reviewPrevious,symbol:"chevron.backward",label:"Previous review move"),
            ControlBarItem(action:.reviewPlayPause,symbol:review.playing ? "pause.fill":"play.fill",label:review.playing ? "Pause review":"Play review",primary:true),
            ControlBarItem(action:.reviewNext,symbol:"chevron.forward",label:"Next review move"),
            ControlBarItem(action:.reviewLast,symbol:"forward.end.fill",label:"Last position"),
        ]
        if review.branch != nil{bar.trailing=[ControlBarItem(action:.returnToOriginal,label:"Return to original",prominent:true)]}
        return bar
    }

    /// Whether a training exercise can take a move back now: a movement drill once it has moved, a game while its
    /// own rule allows; never once the exercise is finished. The bar and ⌘Z both ask this.
    @MainActor static func canTakeBack(_ training:TrainingController,_ exercise:TrainingController.Exercise)->Bool {
        guard !exercise.finished else{return false}
        if exercise.scenario.drill != nil{return exercise.movesUsed>0}
        return exercise.task == .game && training.canUndo(exercise)
    }

    @MainActor private static func trainingBar(_ training:TrainingController,session:GameSession)->ControlBarModel {
        var bar=ControlBarModel(statusInCentre:true)
        bar.trailingGroups=[[ControlBarItem(action:.trainingLibrary,symbol:"square.grid.2x2",label:"Training library")]]
        guard case .training=session.activity.place,let exercise=training.exercise else{return bar}
        if exercise.finished {
            bar.status = .text(TrainingPanel.resultLabel(exercise))
            if TrainingPanel.canRetry(exercise){bar.trailing.append(ControlBarItem(action:.trainingTryAgain,symbol:"arrow.counterclockwise",label:"Try again"))}
            bar.trailing.append(ControlBarItem(action:.trainingNextExercise,label:"Next exercise",prominent:true))
        } else {
            bar.status = .turn(side:exercise.scenario.learner,label:exercise.scenario.learner=="w" ? "You are White":"You are Black")
            bar.trailing.append(ControlBarItem(action:.trainingHint,symbol:"lightbulb",label:TrainingPanel.hintTitle(exercise),enabled:!TrainingPanel.hintDisabled(exercise,thinking:training.games.thinking)))
            if exercise.scenario.drill != nil || exercise.task == .game{bar.trailing.append(ControlBarItem(action:.trainingTakeBack,symbol:"arrow.uturn.backward",label:"Take back a move",enabled:canTakeBack(training,exercise)))}
        }
        return bar
    }
}

// MARK: Drawing

/// Draws a `ControlBarModel`: status and leading actions at the leading edge, the centre group centred under the
/// board, tools at the trailing edge. When the sides do not fit beside the centre, the bar takes two rows (sides
/// above, centre below) and reports it, so the window gives it the height and the board stays square.
struct ControlBarView:View {
    let model:ControlBarModel
    let perform:(ControlBarAction)->Void
    /// Called with the number of rows the bar needs now (1 to 3).
    let rowsChanged:(Int)->Void
    /// Called with where each control (by action) and the status were laid out, in the bar's own coordinates; the
    /// layout acceptance checks them at every board size.
    var framesChanged:([String:CGRect])->Void={_ in}
    @State private var widths:[Int:CGFloat]=[:]
    static let groupGap:CGFloat=14,itemGap:CGFloat=4,rowHeight:CGFloat=32
    /// The narrowest a leading status may become before the bar takes another row; longer status text is shortened
    /// with an ellipsis instead, so a step with a long lesson name never changes the bar's height.
    static let statusMinimum:CGFloat=72

    /// Whether the bar fits one row in `width`, given its groups' widths. Only controls decide: a leading status
    /// keeps a minimum of room only when nothing else leads, and otherwise takes what is left or hides, so neither a
    /// long status nor a recovery button (Resume, Back) changes the bar's height and resizes the board.
    static func fitsOneRow(_ model:ControlBarModel,leading:CGFloat,centre:CGFloat,trailing:CGFloat,width:CGFloat)->Bool {
        let reserve=(!model.statusInCentre && model.status != nil && model.leading.isEmpty) ? statusMinimum:0
        return max(leading+reserve,trailing)*2+centre+groupGap*2<=width
    }
    /// The rows the bar needs: one when the sides fit beside the centre; two when the sides fit beside each other
    /// above it; three (leading, trailing, centre) when even they do not.
    static func rows(_ model:ControlBarModel,leading:CGFloat,centre:CGFloat,trailing:CGFloat,width:CGFloat)->Int {
        if fitsOneRow(model,leading:leading,centre:centre,trailing:trailing,width:width){return 1}
        let reserve=(!model.statusInCentre && model.status != nil && model.leading.isEmpty) ? statusMinimum:0
        // The upper row is leading, a spacer and trailing, with a gap on each side of the spacer.
        return leading+reserve+trailing+groupGap*2<=width ? 2:3
    }
    var body:some View {
        GeometryReader {geometry in
            let inner=geometry.size.width-Metrics.padding*2
            let leadingButtons=widths[0] ?? 0,trailingWidth=widths[2] ?? 0,centre=widths[1] ?? 0
            let rows=Self.rows(model,leading:leadingButtons,centre:centre,trailing:trailingWidth,width:inner)
            let side=rows==1 ? (inner-centre)/2-Self.groupGap:rows==2 ? inner-trailingWidth-Self.groupGap:inner
            Group {
                switch rows {
                case 1:
                    ZStack {
                        HStack(spacing:0){leading(room:side-leadingButtons);Spacer(minLength:0);trailing.background(measure(2))}
                        centreGroup(room:inner).background(measure(1))
                    }
                case 2:
                    VStack(spacing:Metrics.smallGap) {
                        HStack(spacing:Self.groupGap){leading(room:side-leadingButtons);Spacer(minLength:0);trailing.background(measure(2))}
                        centreGroup(room:inner).background(measure(1))
                    }
                default:
                    VStack(spacing:Metrics.smallGap) {
                        HStack(spacing:0){leading(room:side-leadingButtons);Spacer(minLength:0)}
                        HStack(spacing:0){Spacer(minLength:0);trailing.background(measure(2))}
                        centreGroup(room:inner).background(measure(1))
                    }
                }
            }
            .padding(.horizontal,Metrics.padding)
            .frame(width:geometry.size.width,height:geometry.size.height)
            .coordinateSpace(name:Self.space)
            .onAppear{rowsChanged(rows)}
            .onChange(of:rows){_,count in rowsChanged(count)}
        }
        .onPreferenceChange(BarWidths.self){widths=$0}
        .onPreferenceChange(BarFrames.self){framesChanged($0)}
    }
    static let space="control-bar"
    private func place(_ key:String)->some View {GeometryReader{Color.clear.preference(key:BarFrames.self,value:[key:$0.frame(in:.named(Self.space))])}}
    private func measure(_ index:Int)->some View {GeometryReader{Color.clear.preference(key:BarWidths.self,value:[index:$0.size.width])}}
    /// Leading actions at their full size, then the status within `room`, shortened when it does not fit.
    private func leading(room:CGFloat)->some View {
        HStack(spacing:Self.groupGap) {
            if !model.leading.isEmpty{HStack(spacing:Self.itemGap){ForEach(model.leading){button($0)}}.fixedSize().background(measure(0))}
            let statusRoom=room-(model.leading.isEmpty ? 0:Self.groupGap)
            if !model.statusInCentre,let status=model.status,statusRoom>=Self.statusMinimum{StatusPill(status:status).frame(maxWidth:statusRoom,alignment:.leading).background(place("status"))}
        }
    }
    /// The centre group at its natural width: centred statuses are short by construction (turn, thinking, connecting).
    private func centreGroup(room:CGFloat)->some View {
        HStack(spacing:Self.groupGap) {
            if model.statusInCentre,let status=model.status{StatusPill(status:status).background(place("status"))}
            if !model.centre.isEmpty{HStack(spacing:Self.itemGap){ForEach(model.centre){button($0)}}.accessibilityElement(children:.contain).accessibilityLabel("Playback")}
        }.fixedSize()
    }
    private var trailing:some View {
        HStack(spacing:Self.groupGap) {
            if !model.trailing.isEmpty{HStack(spacing:Self.itemGap){ForEach(model.trailing){button($0)}}}
            ForEach(Array(model.trailingGroups.enumerated()),id:\.offset){_,group in HStack(spacing:Self.itemGap){ForEach(group){button($0)}}}
        }.fixedSize()
    }
    /// Each control is identified by its action, whatever its label says now, so checks can follow one slot.
    private func button(_ item:ControlBarItem)->some View {control(item).accessibilityIdentifier("bar-\(item.action)").background(place("\(item.action)"))}
    @ViewBuilder private func control(_ item:ControlBarItem)->some View {
        if let symbol=item.symbol {
            if item.menu.isEmpty {
                Button{perform(item.action)}label:{icon(symbol,primary:item.primary)}
                    .buttonStyle(.bordered).controlSize(.large).disabled(!item.enabled).help(item.label).accessibilityLabel(item.label)
            } else {
                Menu{ForEach(item.menu){entry in Button(entry.label){perform(entry.action)}}}label:{icon(symbol,primary:false)}primaryAction:{perform(item.action)}
                    .menuStyle(.button).buttonStyle(.bordered).controlSize(.large).fixedSize().disabled(!item.enabled).help(item.label).accessibilityLabel(item.label)
            }
        } else if item.prominent {
            Button(item.label){perform(item.action)}.buttonStyle(.borderedProminent).controlSize(.large).disabled(!item.enabled).help(item.label)
        } else {
            Button(item.label){perform(item.action)}.buttonStyle(.bordered).controlSize(.large).disabled(!item.enabled).help(item.detail ?? item.label)
        }
    }
    /// Every icon sits in the same square, so swapping play for pause or one chevron for two never resizes a slot.
    private func icon(_ symbol:String,primary:Bool)->some View {
        Image(systemName:symbol).imageScale(primary ? .large:.medium).frame(width:primary ? 26:20,height:20)
    }
}

/// The status as a small labelled pill: a turn dot with its words, a spinner with what is being worked out, or text.
struct StatusPill:View {
    let status:ControlBarStatus
    private var text:String {switch status{case .turn(_,let label),.working(let label),.text(let label):return label}}
    var body:some View {
        HStack(spacing:6) {
            switch status {
            case .turn(let side,let label):TurnIndicator(side:side,label:label).fixedSize();Text(label)
            case .working(let label):ProgressView().controlSize(.small).fixedSize();Text(label)
            case .text(let label):Text(label)
            }
        }
        .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        .help(text).accessibilityElement(children:.ignore).accessibilityLabel(text).accessibilityAddTraits(.updatesFrequently)
    }
}

private struct BarFrames:PreferenceKey {
    static var defaultValue:[String:CGRect]=[:]
    static func reduce(value:inout [String:CGRect],nextValue:()->[String:CGRect]){value.merge(nextValue()){$1}}
}
private struct BarWidths:PreferenceKey {
    static var defaultValue:[Int:CGFloat]=[:]
    static func reduce(value:inout [Int:CGFloat],nextValue:()->[Int:CGFloat]){value.merge(nextValue()){$1}}
}
