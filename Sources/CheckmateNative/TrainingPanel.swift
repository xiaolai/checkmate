import SwiftUI
import CheckmateCore
/// The exercise drawer: the prompt, its rules, the learner's answer controls and honest result labels.
struct TrainingPanel:View {
    @ObservedObject var model:NativeModel
    @ObservedObject var training:TrainingController
    var body:some View {
        if let exercise=training.exercise {
            let definition=exercise.definition,scenario=exercise.scenario
            Text(definition.title).sectionHeading(.title2.bold())
            Text(exercise.prompt).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("training-prompt")
            if let fresh=TrainingRecommendation.freshnessLabel(exercise.snapshot.freshness){Text(fresh).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("training-freshness")}
            if exercise.snapshot.retry{Text("You have tried this board before, so this is practice.").font(.caption).foregroundStyle(.secondary)}
            Text(TrainingLabels.ruleMode(definition.ruleMode)).font(.caption).foregroundStyle(.secondary)
            ForEach(definition.rules,id:\.self){Text($0).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
            if scenario.drill != nil {Text(scenario.budget.map{"Moves: \(exercise.movesUsed) of \($0)"} ?? "Moves: \(exercise.movesUsed)").accessibilityIdentifier("training-moves")}
            answerControls(exercise)
            if exercise.task == .game {gameControls(exercise);if model.voice.training != nil{TrainingVoiceCoach(voice:model.voice,connect:{[weak model] in model?.connectVoiceWithConsent{model?.voice.connectTraining()}})}}
            // A moment retried from a finished guided game leads back to that game's review.
            if training.guidedReview != nil,scenario.check == .moment{Button("Back to Your Game"){training.returnToGuidedGame()}.accessibilityIdentifier("training-back-to-game")}
            // A finished attempt refuses a promotion, so its chooser is not offered.
            if let pending=exercise.pendingPromotion,!exercise.finished {
                HStack{
                    ForEach([("Queen","q"),("Rook","r"),("Bishop","b"),("Knight","n")],id:\.1){title,piece in Button(title){training.attempt(from:pending.from,to:pending.to,promotion:piece)}}
                    Button("Cancel"){training.cancelPromotion()}.accessibilityIdentifier("training-promotion-cancel")
                }
            }
            if let hint=exercise.hintText{Label(hint,symbol:.hint).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("training-hint")}
            if !exercise.feedback.isEmpty{Text(exercise.feedback).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("training-feedback")}
            if exercise.finished {result(exercise)}
            HStack {
                if exercise.finished {
                    if Self.canRetry(exercise){Button("Try Again"){training.retry()}.accessibilityIdentifier("training-retry")}
                    Button("Next Exercise"){training.next()}.accessibilityIdentifier("training-next")
                } else {
                    Button(Self.hintTitle(exercise)){training.hint()}.disabled(Self.hintDisabled(exercise,thinking:training.games.thinking)).accessibilityIdentifier("training-hint-button")
                    if exercise.task != .game{Button("Reveal Answer"){training.reveal()}.accessibilityIdentifier("training-reveal")}
                }
            }
            Button("Back to Training"){model.trainingLibrary()}.accessibilityIdentifier("training-back")
        }
    }
    /// Selecting squares or choosing an answer.
    @ViewBuilder private func answerControls(_ exercise:TrainingController.Exercise)->some View {
        if exercise.task == .select {
            Text(exercise.selection.isEmpty ? "Click squares to select them, then submit.":"Selected: \(Plural.list(exercise.selection.sorted()))")
            HStack {
                Button("Submit"){training.submit()}.disabled(exercise.selection.isEmpty || exercise.finished).keyboardShortcut(.defaultAction).accessibilityIdentifier("training-submit")
                Button("None"){training.submit(none:true)}.disabled(exercise.finished).accessibilityIdentifier("training-none")
                Button("Clear"){training.clearSelection()}.disabled(exercise.selection.isEmpty || exercise.finished)
            }
        }
        if exercise.task == .choose {ForEach(exercise.scenario.choices ?? [],id:\.self){choice in Button(choice){training.choose(choice)}.disabled(exercise.finished)}}
    }
    /// A played game: its status, the break reminder, take back and draw claims, then the moments worth another try.
    @ViewBuilder private func gameControls(_ exercise:TrainingController.Exercise)->some View {
        let scenario=exercise.scenario
        Text(Self.gameStatus(finished:exercise.finished,paused:exercise.paused != nil,thinking:training.games.thinking)).accessibilityIdentifier("training-game-status")
        // The opponent level (mini-game plan D4): only the levels this game offers, and only when there is a choice. The
        // game in progress keeps the level it started with, labelled while it differs, with a new game offered at the other.
        let levels=training.gameLevels(exercise)
        if levels.count>1 {
            Picker("Opponent",selection:Binding(get:{training.preferredGameLevel(exercise)},set:{training.setGameLevel($0)})){ForEach(levels,id:\.self){Text($0.title).tag($0)}}.accessibilityIdentifier("training-level")
        }
        if training.gameNewLevelOffered(exercise) {
            if let level=exercise.snapshot.boundOpponent?.level{Text("This game continues at \(level.title).").foregroundStyle(.secondary)}
            Button("Start a New Game at This Level"){training.startGameAtChosenLevel()}.accessibilityIdentifier("training-new-level")
        }
        Text(TrainingEndgameController.note(for:scenario.check,opponent:exercise.snapshot.boundOpponent)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("training-opponent-note")
        if let habit=exercise.habit,!exercise.finished{Label(habit,symbol:.habit).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("training-habit")}
        // A finished game cannot be kept going, so the reminder belongs only to one still in play.
        if exercise.reminder,!exercise.finished {
            Text("You and the defender have played \(exercise.line.count) moves between you, and the game is saved. Take a break, or keep going.").fixedSize(horizontal:false,vertical:true)
            HStack{Button("Keep Going"){training.dismissReminder()}.accessibilityIdentifier("training-keep-going");Button("Take a Break"){model.trainingLibrary()}}
        }
        // Only a pause waiting on the defender can be retried; one at the saved-action limit cannot.
        if training.canRetryDefender(exercise){Button("Try the Defender Again"){training.retryDefender()}.accessibilityIdentifier("training-defender-retry")}
        if !exercise.finished {
            HStack {
                // A saved attempt refuses actions past its limit, take back included.
                Button("Take Back"){training.undo()}.disabled(!training.canUndo(exercise)).accessibilityIdentifier("training-undo")
                if let reason=exercise.claimable{Button("Claim a Draw (\(reason))"){training.claimDraw()}.disabled(training.games.thinking).accessibilityIdentifier("training-claim")}
                if scenario.check == .guidedGame{Button("End Game"){training.endGuidedGame()}.accessibilityIdentifier("training-end-game")}
            }
        }
        // A finished game opens in Review from its own start and moves, never the practice game; Return to game leads back here.
        if training.canReview(exercise){Button("Review This Game"){model.reviewTraining()}.accessibilityIdentifier("training-review-game")}
        // After the game: up to two exact moments to try again.
        if exercise.finished,!exercise.moments.isEmpty {
            Text("Moments to review").sectionHeading()
            ForEach(Array(exercise.moments.enumerated()),id:\.offset){index,moment in
                Text(moment.label).fixedSize(horizontal:false,vertical:true)
                Button("Try This Moment Again"){training.retryMoment(index)}.accessibilityIdentifier("training-moment-\(index)")
            }
        }
    }
    /// A finished attempt's result, its topic (mixed practice hides it until the learner has answered) and related lessons.
    @ViewBuilder private func result(_ exercise:TrainingController.Exercise)->some View {
        Text(Self.resultLabel(exercise)).font(.headline).accessibilityIdentifier("training-result")
        if let opponent=Self.opponentLine(exercise.snapshot){Text(opponent).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("training-opponent-level")}
        if let skill=exercise.scenario.primarySkill{Text("This one was about \(TrainingLabels.skill(skill)).").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("training-topic")}
        TrainingLessonLinks(model:model,entry:exercise.definition)
    }
    /// A played game's status, a heading like practice's (`DetailContent.practiceHeading`): no closing period.
    static func gameStatus(finished:Bool,paused:Bool,thinking:Bool)->String {finished ? "Game over":paused ? "Game paused":thinking ? "The defender is thinking":"Your move"}
    /// Whether a finished attempt offers Try again, shared by this drawer and the transport: a withdrawn board cannot be retried.
    static func canRetry(_ exercise:TrainingController.Exercise)->Bool {exercise.status != .suspended}
    /// The next hint's title, shared by this drawer and the transport: the third step reveals the answer, or in a game
    /// asks the defender's engine for one good move.
    static func hintTitle(_ exercise:TrainingController.Exercise)->String {exercise.hintLevel<2 ? "Hint":exercise.task == .game ? "Show a good move":"Show answer"}
    /// A game's good move is asked for once, and no game hint is given while the defender is choosing its reply:
    /// saving one would advance the revision that reply belongs to.
    static func hintDisabled(_ exercise:TrainingController.Exercise,thinking:Bool)->Bool {exercise.task == .game && (exercise.hintLevel>=3 || thinking)}
    /// The opponent a finished game names, the one its review names (`boundOpponent`): marked mixed when an older build
    /// continued the game, and none when the saved one belongs to another attempt or cannot be played as frozen.
    static func opponentLine(_ snapshot:TrainingSessionSnapshot)->String? {snapshot.boundOpponent.map{"Opponent: \($0.label)"}}
    /// What a finished attempt shows. Help outside the app cannot be seen, so a clean result says "no recorded help".
    static func resultLabel(_ exercise:TrainingController.Exercise)->String {
        switch exercise.status {
        case .correct:return exercise.snapshot.recordedHelp ? "Solved with recorded help":exercise.snapshot.retry ? "Solved again · practice":"Solved · first try · no recorded help"
        case .incorrect:return "Not solved this time"
        case .revealed:return "Answer shown"
        case .suspended:return "Withdrawn · not counted"
        case .ended:return "Game ended · not counted"
        case .active:return ""
        }
    }
}
/// The training game's voice coach (mini-game plan WI-021, behind its flag), as practice shows it: its status, its
/// controls and the latest of what was said. Connecting records nothing; the attempt is marked helped only once the
/// coach first tells the learner something about the board.
struct TrainingVoiceCoach:View {
    @ObservedObject var voice:VoiceCoach
    /// Connect Voice Coach, which asks for consent first.
    let connect:()->Void
    /// V-25: the coach's help counts as help, said before the learner connects.
    static let helpCaption="Asking the coach for help marks this game as solved with help."
    var body:some View {
        if voice.trainingSession || voice.trainingVoiceAvailable || !voice.history.isEmpty && voice.connection != .disconnected {
            Divider();Text("Voice coach").sectionHeading()
            if voice.connection != .disconnected {Text(voice.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("training-voice-status")}
            VoiceCoachControls(voice:voice,idPrefix:"training-voice",owned:voice.trainingSession,connect:voice.trainingVoiceAvailable ? {connect()}:nil)
            if voice.trainingVoiceAvailable && !voice.connected && !voice.connecting {Text(Self.helpCaption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
            if voice.trainingSession || voice.history.last?.source == .training {ForEach(Array(voice.history.suffix(3).reversed())){entry in Text((entry.role=="learner" ? "You: ":"Coach: ")+entry.text).font(.caption).fixedSize(horizontal:false,vertical:true)}}
        }
    }
}
