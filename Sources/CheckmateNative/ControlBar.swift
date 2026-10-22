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
    case puzzleLibrary,nextPuzzle,puzzleHint,skipPuzzle
    case trainingHint,trainingTakeBack,trainingTryAgain,trainingNextExercise,trainingLibrary,backToTraining
    case offerDraw,acceptDraw,declineDraw,resign,flipBoard,more
}

/// One control: an icon button when `symbol` is set, otherwise a text button. `label` is what VoiceOver says and the
/// tooltip shows; a text button shows `label` itself.
struct ControlBarItem:Equatable,Identifiable {
    let action:ControlBarAction
    var symbol:AppSymbol?=nil
    let label:String
    var enabled=true
    /// A text button that recovers or moves on: drawn prominent.
    var prominent=false
    /// The main playback control, drawn with a larger symbol.
    var primary=false
    /// Voice: Disconnect is offered from this control's menu; More is only a menu.
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
    /// Further leading groups, each drawn as its own group: a recovery (Resume) apart from the tools beside it, so its
    /// tinted glass never runs into theirs.
    var leadingGroups:[[ControlBarItem]]=[]
    var centre:[ControlBarItem]=[]
    var trailing:[ControlBarItem]=[]
    /// Further trailing groups, each drawn as its own group (voice beside the game's tools).
    var trailingGroups:[[ControlBarItem]]=[]
    /// The network game's two clocks show beside the status (B-2).
    var clocks=false

    var items:[ControlBarItem] {leading+leadingGroups.flatMap{$0}+centre+trailing+trailingGroups.flatMap{$0}}
    /// Whether any control leads the bar, in any group.
    var hasLeadingControls:Bool {!leading.isEmpty || leadingGroups.contains{!$0.isEmpty}}
    func item(_ action:ControlBarAction)->ControlBarItem? {items.first{$0.action==action}}
}

/// The voice coach as the bar shows it.
enum ControlBarVoice:Equatable {
    /// Not connected: Connect, or, when the coach cannot connect now, the plain reason why.
    case off(unavailable:VoiceUnavailability?)
    case connecting(String)
    case on(microphone:Bool,canStop:Bool)
}

extension ControlBarModel {
    /// The bar for what the app shows now. Pure: it reads the model and decides nothing else.
    /// `trainingVoice`: the training game's coach is offered (mini-game plan WI-021, behind its flag), so the training
    /// bar carries the same voice controls as practice's.
    @MainActor static func make(session:GameSession,learning:LearningPlayer,review:ReviewController,training:TrainingController?,network:NetworkGameController,voice:ControlBarVoice,trainingVoice:Bool=false)->ControlBarModel {
        if review.active {return reviewBar(review)}
        if session.mode == .network {return networkBar(network)}
        if session.mode == .practice {return practiceBar(session,voice:voice)}
        if learning.mini {return miniBar(learning)}
        if session.mode == .training,let training {var bar=trainingBar(training,session:session);if trainingVoice,case .training=session.activity.place,training.exercise?.task == .game{bar.trailingGroups.insert(voiceControls(voice).items,at:0)};return bar}
        if session.mode == .lesson {return lessonBar(learning)}
        if learning.activePuzzle != nil {
            return ControlBarModel(leading:[ControlBarItem(action:.puzzleLibrary,symbol:.library,label:String(localized:"Puzzle library",bundle:.checkmate))],trailing:learning.passed ? [ControlBarItem(action:.nextPuzzle,label:String(localized:"Next Puzzle",bundle:.checkmate),prominent:true)]:[ControlBarItem(action:.puzzleHint,label:learning.puzzleHints==0 ? String(localized:"Hint",bundle:.checkmate,comment:"Noun: ask for a hint"):String(localized:"Another Hint",bundle:.checkmate),enabled:learning.canHint),ControlBarItem(action:.skipPuzzle,label:String(localized:"Skip",bundle:.checkmate))])
        }
        return ControlBarModel()
    }

    @MainActor private static func lessonBar(_ learning:LearningPlayer)->ControlBarModel {
        var bar=ControlBarModel()
        let step=learning.step,last=learning.current.beats.count-1
        let previous=step==0 ? learning.library.previousMainLesson(before:learning.lessonIndex):nil
        let next=step>=last ? learning.library.nextMainLesson(after:learning.lessonIndex):nil
        if learning.readingFromTraining{bar.leading.append(ControlBarItem(action:.backToTraining,label:String(localized:"Back to Training",bundle:.checkmate)))}
        let replay=learning.attemptStep ? (learning.attempt.hasMoves ? String(localized:"Replay the original instruction (your game stays as it is)",bundle:.checkmate):String(localized:"Replay the instruction",bundle:.checkmate)):String(localized:"Replay transcript",bundle:.checkmate)
        bar.centre=[
            ControlBarItem(action:.stepFromStart,symbol:.replayFromStart,label:replay),
            previous.map{ControlBarItem(action:.previousLesson,symbol:.previousLesson,label:String(localized:"Previous lesson: \(learning.localizedTitle(index:$0))",bundle:.checkmate))}
                ?? ControlBarItem(action:.previousStep,symbol:.previous,label:String(localized:"Previous transcript",bundle:.checkmate),enabled:step>0),
            ControlBarItem(action:.playPause,symbol:learning.playing ? .pause:.play,label:learning.playing ? String(localized:"Pause",bundle:.checkmate):String(localized:"Play",bundle:.checkmate,comment:"Verb: start playback of a lesson"),primary:true),
            next.map{ControlBarItem(action:.nextLesson,symbol:.nextLesson,label:String(localized:"Next lesson: \(learning.localizedTitle(index:$0))",bundle:.checkmate))}
                ?? ControlBarItem(action:.nextStep,symbol:.next,label:String(localized:"Next transcript",bundle:.checkmate)),
        ]
        if learning.attemptStep,let status=learning.attemptStatus {
            let attempt:LessonAttemptController=learning.attempt
            bar.status = attempt.thinking ? .working(status):.turn(side:attempt.rules.turn,label:status)
            if attempt.waitingToResume{bar.leadingGroups.append([ControlBarItem(action:.resumeAttempt,label:String(localized:"Resume Your Attempt",bundle:.checkmate),prominent:true)])}
            let hint=attempt.canShowMove ? String(localized:"Show me a move",bundle:.checkmate):(attempt.record?.hints ?? 0)==0 ? String(localized:"Hint",bundle:.checkmate,comment:"Noun: ask for a hint"):String(localized:"Another hint",bundle:.checkmate)
            // Off track the refutation stays on the board until the learner takes the move back; Hint could only repeat the advice.
            if attempt.phase == .offTrack {bar.trailing=[ControlBarItem(action:.attemptUndo,label:String(localized:"Take Back",bundle:.checkmate),prominent:true),ControlBarItem(action:.attemptRestart,symbol:.startOver,label:String(localized:"Restart",bundle:.checkmate))]}
            else {bar.trailing=[
                ControlBarItem(action:.attemptHint,symbol:.hint,label:hint,enabled:attempt.learnerToMove),
                ControlBarItem(action:.attemptUndo,symbol:.undo,label:String(localized:"Undo Turn",bundle:.checkmate),enabled:attempt.hasMoves),
                ControlBarItem(action:.attemptRestart,symbol:.startOver,label:String(localized:"Restart",bundle:.checkmate),enabled:attempt.hasMoves),
            ]}
        } else {
            let text=if let next{String(localized:"Step \(step+1) of \(last+1) · next: \(learning.localizedTitle(index:next))",bundle:.checkmate)}
                else if let previous{String(localized:"Step \(step+1) of \(last+1) · back: \(learning.localizedTitle(index:previous))",bundle:.checkmate)}
                else{String(localized:"Step \(step+1) of \(last+1)",bundle:.checkmate)}
            bar.status = .text(text)
        }
        return bar
    }

    @MainActor private static func practiceBar(_ session:GameSession,voice:ControlBarVoice)->ControlBarModel {
        let voiceGroup=voiceControls(voice)
        if !session.presentationHidden,let d=session.demonstration {
            let count=d.lines[d.line].frames.count
            return ControlBarModel(status:.text(String(localized:"Demonstration · move \(d.ply) of \(max(0,count-1))",bundle:.checkmate)),centre:[
                ControlBarItem(action:.demoPrevious,symbol:.previous,label:String(localized:"Previous imagined move",bundle:.checkmate),enabled:d.ply>0),
                ControlBarItem(action:.demoPlayPause,symbol:d.playing ? .pause:.play,label:d.playing ? String(localized:"Pause demonstration",bundle:.checkmate):String(localized:"Play demonstration",bundle:.checkmate),primary:true),
                ControlBarItem(action:.demoNext,symbol:.next,label:String(localized:"Next imagined move",bundle:.checkmate),enabled:d.ply<count-1),
            ],trailing:[ControlBarItem(action:.returnToGame,label:String(localized:"Return to Game",bundle:.checkmate),prominent:true)],trailingGroups:[voiceGroup.items])
        }
        if !session.presentationHidden,let p=session.preview {
            let frames=(p.line=="candidate" ? p.evaluation?.candidateFrames.count:p.evaluation?.recommendedFrames.count) ?? 0
            var trailing:[ControlBarItem]=[]
            if p.candidate != nil{trailing.append(ControlBarItem(action:.tryAnotherMove,label:String(localized:"Try Another Move",bundle:.checkmate),enabled:session.rules.turn==session.humanSide && !session.rules.over))}
            trailing.append(ControlBarItem(action:.returnToGame,label:String(localized:"Return to Game",bundle:.checkmate),prominent:true))
            return ControlBarModel(status:.text(p.evaluation==nil ? String(localized:"Your idea",bundle:.checkmate):String(localized:"Your idea · move \(p.ply) of \(max(0,frames-1))",bundle:.checkmate)),centre:[
                ControlBarItem(action:.previewPrevious,symbol:.previous,label:String(localized:"Previous preview move",bundle:.checkmate),enabled:p.evaluation != nil && p.ply>0),
                ControlBarItem(action:.previewNext,symbol:.next,label:String(localized:"Next preview move",bundle:.checkmate),enabled:p.evaluation != nil && p.ply<frames-1),
            ],trailing:trailing,trailingGroups:[voiceGroup.items])
        }
        var bar=ControlBarModel(statusInCentre:true)
        // During a network game practice is viewable only: Stockfish waits and hints, Try a move and voice are off (D8).
        let fair=session.fairness.engineHelpAllowed
        bar.status = !fair ? .text(FairnessPolicy.practicePaused):session.busyReason == .opponent ? .working(String(localized:"Stockfish is thinking",bundle:.checkmate)):session.busy ? .working(String(localized:"Finding a hint",bundle:.checkmate)):.turn(side:session.rules.turn,label:session.rules.status)
        // More (Flip Board, Resign) sits beside New game: the bar is centered, so the longer side sets when it wraps.
        bar.leading=[ControlBarItem(action:.newGame,label:String(localized:"New Game…",bundle:.checkmate)),ControlBarItem(action:.more,symbol:.moreActions,label:String(localized:"More",bundle:.checkmate),menu:[ControlBarItem(action:.flipBoard,label:String(localized:"Flip Board",bundle:.checkmate)),ControlBarItem(action:.resign,label:String(localized:"Resign…",bundle:.checkmate),enabled:session.canResign)])]
        // The way back into a held game is a group of its own: beside More its tint ran into More's capsule.
        if session.explicitResumeRequired{bar.leadingGroups=[[ControlBarItem(action:.resumeGame,label:String(localized:"Resume Game",bundle:.checkmate),prominent:true)]]}
        else if session.pausedOpponent{bar.leadingGroups=[[ControlBarItem(action:.continueWithStockfish,label:String(localized:"Continue with Stockfish",bundle:.checkmate),prominent:true)]]}
        let yourMove=session.rules.turn==session.humanSide && !session.finished
        bar.trailing=[
            ControlBarItem(action:.takeBack,symbol:.undo,label:String(localized:"Take back move",bundle:.checkmate),enabled:session.canTakeBack),
            practiceHint(step:session.hintStep,available:fair && !session.busy && yourMove),
            ControlBarItem(action:.tryMove,label:String(localized:"Try a Move",bundle:.checkmate),enabled:fair && yourMove && session.busyReason != .opponent && session.demonstration==nil),
        ]
        bar.trailingGroups=fair ? [voiceGroup.items]:[]
        if let status=voiceGroup.status{bar.status = .working(status)}
        return bar
    }

    /// Practice's Hint, step by step (B-5): the first request marks the piece, the second shows the move, and then the
    /// move is on the board until the learner plays.
    static func practiceHint(step:Int,available:Bool)->ControlBarItem {
        ControlBarItem(action:.hint,symbol:.hint,label:step==1 ? String(localized:"Show Move",bundle:.checkmate):String(localized:"Hint",bundle:.checkmate,comment:"Noun: ask for a hint"),enabled:available && step<2)
    }

    /// The voice coach's controls, the same beside the game and over a preview or demonstration: Cancel while it
    /// connects, Stop one click away while it is on, Disconnect in the microphone's menu.
    private static func voiceControls(_ voice:ControlBarVoice)->(items:[ControlBarItem],status:String?) {
        switch voice {
        case .off(let reason):return ([ControlBarItem(action:.voiceConnect,symbol:.microphone,label:reason?.message ?? String(localized:"Connect voice coach",bundle:.checkmate),enabled:reason==nil)],nil)
        case .connecting(let status):return ([ControlBarItem(action:.voiceCancel,label:VoiceCoachControls.cancelTitle,detail:status)],String(localized:"Connecting voice coach",bundle:.checkmate))
        case .on(let microphone,let canStop):return ([
            ControlBarItem(action:.voiceStop,symbol:.stopSpeaking,label:String(localized:"Stop coach speaking",bundle:.checkmate),enabled:canStop),
            ControlBarItem(action:.voiceMicrophone,symbol:microphone ? .microphone:.microphoneOff,label:microphone ? String(localized:"Mute microphone",bundle:.checkmate):String(localized:"Enable microphone",bundle:.checkmate),menu:[ControlBarItem(action:.voiceDisconnect,label:VoiceCoachControls.disconnectTitle)]),
        ],nil)
        }
    }

    @MainActor private static func miniBar(_ learning:LearningPlayer)->ControlBarModel {
        let back=learning.miniFromLibrary ? String(localized:"Back to Training",bundle:.checkmate):String(localized:"Back to \(learning.localizedTitle(index:learning.lessonIndex))",bundle:.checkmate)
        var bar=ControlBarModel(statusInCentre:true,leading:[ControlBarItem(action:.backFromMiniGame,label:back)])
        bar.status = learning.miniKind.solo ? .text(learning.miniStatus):.turn(side:learning.miniTurn,label:learning.miniStatus)
        bar.trailing=[
            ControlBarItem(action:.miniUndo,symbol:.undo,label:String(localized:"Undo Turn",bundle:.checkmate),enabled:learning.miniGame?.history.isEmpty == false),
            ControlBarItem(action:.miniNewGame,symbol:.startOver,label:String(localized:"New game",bundle:.checkmate)),
        ]
        return bar
    }

    @MainActor private static func reviewBar(_ review:ReviewController)->ControlBarModel {
        var bar=ControlBarModel(status:.text(review.branch==nil ? String(localized:"Original game",bundle:.checkmate):String(localized:"Imagined line",bundle:.checkmate)))
        bar.centre=[
            ControlBarItem(action:.reviewFirst,symbol:.firstPosition,label:String(localized:"First position",bundle:.checkmate)),
            ControlBarItem(action:.reviewPrevious,symbol:.previous,label:String(localized:"Previous review move",bundle:.checkmate)),
            ControlBarItem(action:.reviewPlayPause,symbol:review.playing ? .pause:.play,label:review.playing ? String(localized:"Pause review",bundle:.checkmate):String(localized:"Play review",bundle:.checkmate),primary:true),
            ControlBarItem(action:.reviewNext,symbol:.next,label:String(localized:"Next review move",bundle:.checkmate)),
            ControlBarItem(action:.reviewLast,symbol:.lastPosition,label:String(localized:"Last position",bundle:.checkmate)),
        ]
        if review.branch != nil{bar.trailing=[ControlBarItem(action:.returnToOriginal,label:String(localized:"Return to Original",bundle:.checkmate),prominent:true)]}
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
        bar.trailingGroups=[[ControlBarItem(action:.trainingLibrary,symbol:.library,label:String(localized:"Training library",bundle:.checkmate))]]
        guard case .training=session.activity.place,let exercise=training.exercise else{return bar}
        if exercise.finished {
            bar.status = .text(TrainingPanel.resultLabel(exercise))
            if TrainingPanel.canRetry(exercise){bar.trailing.append(ControlBarItem(action:.trainingTryAgain,symbol:.startOver,label:String(localized:"Try Again",bundle:.checkmate)))}
            bar.trailing.append(ControlBarItem(action:.trainingNextExercise,label:String(localized:"Next Exercise",bundle:.checkmate),prominent:true))
        } else if !exercise.feedback.isEmpty {
            // The latest feedback line, which may be long: it sits at the leading edge, where the status truncates.
            bar.status = .text(exercise.feedback);bar.statusInCentre=false
        } else {
            bar.status = .turn(side:exercise.scenario.learner,label:exercise.scenario.learner=="w" ? String(localized:"You are White",bundle:.checkmate):String(localized:"You are Black",bundle:.checkmate))
        }
        if !exercise.finished {
            bar.trailing.append(ControlBarItem(action:.trainingHint,symbol:.hint,label:TrainingPanel.hintTitle(exercise),enabled:!TrainingPanel.hintDisabled(exercise,thinking:training.games.thinking)))
            if exercise.scenario.drill != nil || exercise.task == .game{bar.trailing.append(ControlBarItem(action:.trainingTakeBack,symbol:.undo,label:String(localized:"Take back a move",bundle:.checkmate),enabled:canTakeBack(training,exercise)))}
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
    /// The network game whose clocks show when the model asks for them, and its low-time warning.
    var network:NetworkGameController?=nil
    var lowTime:NetworkLowTimeWarning?=nil
    @State private var widths:[Int:CGFloat]=[:]
    static let groupGap:CGFloat=14,itemGap:CGFloat=4,rowHeight:CGFloat=32
    /// The narrowest a leading status may become before the bar takes another row; longer status text is shortened
    /// with an ellipsis instead, so a step with a long lesson name never changes the bar's height.
    static let statusMinimum:CGFloat=72

    /// Whether the bar fits one row in `width`, given its groups' widths. Only controls decide: a leading status
    /// keeps a minimum of room only when nothing else leads, and otherwise takes what is left or hides, so neither a
    /// long status nor a recovery button (Resume, Back) changes the bar's height and resizes the board.
    static func fitsOneRow(_ model:ControlBarModel,leading:CGFloat,centre:CGFloat,trailing:CGFloat,width:CGFloat)->Bool {
        let reserve=(!model.statusInCentre && model.status != nil && !model.hasLeadingControls) ? statusMinimum:0
        return max(leading+reserve,trailing)*2+centre+groupGap*2<=width
    }
    /// The rows the bar needs: one when the sides fit beside the centre; two when the sides fit beside each other
    /// above it; three (leading, trailing, centre) when even they do not.
    static func rows(_ model:ControlBarModel,leading:CGFloat,centre:CGFloat,trailing:CGFloat,width:CGFloat)->Int {
        if fitsOneRow(model,leading:leading,centre:centre,trailing:trailing,width:width){return 1}
        let reserve=(!model.statusInCentre && model.status != nil && !model.hasLeadingControls) ? statusMinimum:0
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
    /// Leading actions at their full size, a group gap between groups, then the status within `room`, shortened when
    /// it does not fit. Their measured width is every leading group's together.
    private func leading(room:CGFloat)->some View {
        HStack(spacing:Self.groupGap) {
            if model.hasLeadingControls {
                HStack(spacing:Self.groupGap) {
                    if !model.leading.isEmpty{HStack(spacing:Self.itemGap){ForEach(model.leading){button($0)}}.modifier(BarGlassGroup())}
                    ForEach(Array(model.leadingGroups.enumerated()),id:\.offset){_,group in HStack(spacing:Self.itemGap){ForEach(group){button($0)}}.modifier(BarGlassGroup())}
                }.fixedSize().background(measure(0))
            }
            let statusRoom=room-(model.hasLeadingControls ? Self.groupGap:0)
            if !model.statusInCentre,let status=model.status,statusRoom>=Self.statusMinimum{StatusPill(status:status).frame(maxWidth:statusRoom,alignment:.leading).background(place("status"))}
        }
    }
    /// The centre group at its natural width: centred statuses are short by construction (turn, thinking, connecting).
    private func centreGroup(room:CGFloat)->some View {
        HStack(spacing:Self.groupGap) {
            if model.statusInCentre,let status=model.status{StatusPill(status:status).background(place("status"))}
            if model.clocks,let network,let lowTime{NetworkBarClocks(game:network,warning:lowTime).background(place("clocks"))}
            if !model.centre.isEmpty{HStack(spacing:Self.itemGap){ForEach(model.centre){button($0)}}.modifier(BarGlassGroup()).accessibilityElement(children:.contain).accessibilityLabel("Playback")}
        }.fixedSize()
    }
    private var trailing:some View {
        HStack(spacing:Self.groupGap) {
            if !model.trailing.isEmpty{HStack(spacing:Self.itemGap){ForEach(model.trailing){button($0)}}.modifier(BarGlassGroup())}
            ForEach(Array(model.trailingGroups.enumerated()),id:\.offset){_,group in HStack(spacing:Self.itemGap){ForEach(group){button($0)}}.modifier(BarGlassGroup())}
        }.fixedSize()
    }
    /// Each control is identified by its action, whatever its label says now, so checks can follow one slot.
    private func button(_ item:ControlBarItem)->some View {control(item).accessibilityIdentifier("bar-\(item.action)").background(place("\(item.action)"))}
    @ViewBuilder private func control(_ item:ControlBarItem)->some View {
        if let symbol=item.symbol {
            if item.menu.isEmpty {
                Button{perform(item.action)}label:{icon(symbol,primary:item.primary)}
                    .modifier(BarButtonStyle()).controlSize(.large).disabled(!item.enabled).help(Self.tooltip(item)).accessibilityLabel(item.label)
            } else if item.action == .more {
                Menu{entries(item)}label:{icon(symbol,primary:false)}
                    .menuStyle(.button).modifier(BarButtonStyle()).controlSize(.large).fixedSize().disabled(!item.enabled).help(Self.tooltip(item)).accessibilityLabel(item.label)
            } else {
                Menu{entries(item)}label:{icon(symbol,primary:false)}primaryAction:{perform(item.action)}
                    .menuStyle(.button).modifier(BarButtonStyle()).controlSize(.large).fixedSize().disabled(!item.enabled).help(Self.tooltip(item)).accessibilityLabel(item.label)
            }
        } else if item.prominent {
            Button(item.label){perform(item.action)}.modifier(BarButtonStyle(prominent:true)).controlSize(.large).disabled(!item.enabled).help(Self.tooltip(item))
        } else {
            Button(item.label){perform(item.action)}.modifier(BarButtonStyle()).controlSize(.large).disabled(!item.enabled).help(Self.tooltip(item))
        }
    }
    private func entries(_ item:ControlBarItem)->some View {ForEach(item.menu){entry in Button(entry.label){perform(entry.action)}.disabled(!entry.enabled).help(Self.tooltip(entry))}}
    /// The tooltip: what the control does, then its menu shortcut when it has one (B-17).
    static func tooltip(_ item:ControlBarItem)->String {let text=item.detail ?? item.label;return shortcut(item.action).map{"\(text) (\($0))"} ?? text}
    /// The shortcut of the menu item that performs the same action.
    static func shortcut(_ action:ControlBarAction)->String? {
        switch action {
        case .takeBack,.attemptUndo,.trainingTakeBack,.miniUndo:return "⌘Z"
        case .hint,.attemptHint,.trainingHint:return "⇧⌘H"
        case .newGame,.miniNewGame:return "⌘N"
        case .flipBoard:return "⇧⌘F"
        case .playPause,.reviewPlayPause,.demoPlayPause:return "⌥⌘P"
        case .previousStep,.previousLesson,.reviewPrevious,.demoPrevious,.previewPrevious:return "⌘["
        case .nextStep,.nextLesson,.reviewNext,.demoNext,.previewNext:return "⌘]"
        case .stepFromStart:return "⌘R"
        default:return nil
        }
    }
    /// Every icon sits in the same square, so swapping play for pause or one chevron for two never resizes a slot.
    private func icon(_ symbol:AppSymbol,primary:Bool)->some View {
        symbol.image.imageScale(primary ? .large:.medium).frame(width:primary ? 26:20,height:20)
    }
}

/// The bar's buttons in Liquid Glass on macOS 26 and later (D-35), and the bordered styles before it. The style draws
/// the button only: its action, label, identifier and hit area are the same in both.
struct BarButtonStyle:ViewModifier {
    var prominent=false
    @ViewBuilder func body(content:Content)->some View {
        if #available(macOS 26,*) {content.buttonStyle(BarGlassButton(prominent:prominent))}
        else if prominent {content.buttonStyle(.borderedProminent)} else {content.buttonStyle(.bordered)}
    }
    /// Whether a prominent button's words are black rather than white on a tint of this colour (linear sRGB): white
    /// stays, as the system draws it, until its contrast with the tint falls under 3:1 (WCAG's least for large text
    /// and controls), as on a yellow, orange or green accent.
    static func darkLabel(onLinearRed red:Double,green:Double,blue:Double)->Bool {
        let luminance=0.2126*red+0.7152*green+0.0722*blue
        return 1.05/(luminance+0.05)<3
    }
}
/// A glass capsule with the bordered button's footprint: 8 points either side of the label, 28 high. The system glass
/// button is 12 points wider, which wraps the practice bar into a second row at 600 points and shrinks the board.
/// Dimming goes on the label: the glass draws in its own layer, which an opacity outside it does not reach. A disabled
/// button keeps a plain capsule, as a disabled bordered button keeps its bezel, and loses the tint; its words take the
/// system's disabled control text colour, the one the Details pane's disabled buttons use, so the two read alike.
@available(macOS 26,*) private struct BarGlassButton:ButtonStyle {
    let prominent:Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.self) private var environment
    func makeBody(configuration:Configuration)->some View {
        configuration.label.padding(.horizontal,8).frame(minHeight:28)
            .foregroundStyle(foreground).opacity(enabled && configuration.isPressed ? 0.8:1)
            .glassEffect(!enabled ? .regular:prominent ? .regular.tint(.accentColor).interactive():.regular.interactive(),in:.capsule)
            .contentShape(.capsule)
    }
    private var foreground:AnyShapeStyle {
        guard enabled else{return AnyShapeStyle(Color(nsColor:.disabledControlTextColor))}
        guard prominent else{return AnyShapeStyle(.primary)}
        let tint=Color.accentColor.resolve(in:environment)
        return AnyShapeStyle(BarButtonStyle.darkLabel(onLinearRed:Double(tint.linearRed),green:Double(tint.linearGreen),blue:Double(tint.linearBlue)) ? Color.black:Color.white)
    }
}
/// One group of bar buttons shares a glass container on macOS 26 and later, so neighbouring glass blends as one
/// surface; before it the group is drawn as it is.
struct BarGlassGroup:ViewModifier {
    @ViewBuilder func body(content:Content)->some View {
        if #available(macOS 26,*) {GlassEffectContainer(spacing:ControlBarView.itemGap){content}} else {content}
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
