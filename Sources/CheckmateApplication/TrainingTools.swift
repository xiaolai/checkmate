import CheckmateDomain
import CheckmateSupport
import Foundation
/// The companion's training tools (WI-007): additive and scoped. Every mutation names the attempt and its revision; an
/// agent's submission or hint is recorded help; results carry only what the learner can see, never stored answers.
/// Starting an exercise needs the learner to have chosen Training; the voice coach cannot drive training.
@MainActor public final class TrainingTools {
    public static let methods:Set<String>=["list_training_entries","start_training","submit_training_action","request_training_hint","end_training_attempt"]
    /// Hints an agent may request: the concept and the relevant pieces. The answer itself is the learner's to reveal.
    public static let maximumAgentHintLevel=2
    let session:GameSession,controller:TrainingController
    /// Opens an entry (or the saved exercise when `resume`) through the app's one transition; false when nothing opened.
    public var onStart:((_ entry:String,_ resume:Bool)->Bool)?
    public init(session:GameSession,controller:TrainingController){self.session=session;self.controller=controller}
    /// Increment A always; Increment B only where its preview is enabled, exactly as the library shows it.
    static func offered(_ definition:TrainingEntryDefinition)->Bool {TrainingRolloutPolicy.offered(definition)}
    /// The capabilities the current training view offers; empty outside training.
    public static func capabilities(for projection:TrainingProjection?)->[String] {
        guard let projection else{return []}
        var names=["list_training_entries","start_training"]
        if projection.view=="exercise" {names.append("end_training_attempt");if projection.status=="active"{names+=["submit_training_action","request_training_hint"]}}
        return names
    }
    public func call(_ name:String,args a:[String:Any],lease:String)async throws -> Any {
        if name=="list_training_entries"{return list()}
        // The voice coach holds a separate lease; it may read the session but never drive an exercise.
        guard lease != session.voiceLease else{throw ProtocolFailure("ROLE_FORBIDDEN","The voice coach cannot drive training.")}
        guard session.mode == .training else{throw ProtocolFailure("LEARNER_CONSENT_REQUIRED","Ask the learner to choose Training in Checkmate's sidebar first.")}
        switch name {
        case "start_training":
            let entry=a["entryId"] as! String,resume=a["resume"] as? Bool ?? false
            guard let definition=controller.catalog?.entry(entry),Self.offered(definition) else{throw ProtocolFailure("INVALID_ARGUMENT","Unknown training entry.")}
            guard onStart?(entry,resume)==true else{throw ProtocolFailure("UNAVAILABLE",controller.notice ?? "The exercise could not be opened.")}
            return result()
        case "submit_training_action":
            let exercise=try current(a)
            guard !controller.games.thinking else{throw ProtocolFailure("BUSY","The practice defender is choosing its reply.")}
            // Everything is checked before the help is recorded, so a rejected request never changes progress.
            let kind=a["kind"] as! String,task=exercise.task
            switch kind {
            case "select","submit","none":
                guard task == .select else{throw ProtocolFailure("INVALID_ARGUMENT","This exercise is not answered by selecting squares.")}
                // A missing list is not a request to clear the learner's selection; an explicit empty list is.
                if kind == "select",!(a["squares"] is [String]){throw ProtocolFailure("INVALID_ARGUMENT","A selection needs its squares; send an empty list to clear it.")}
            case "choose":guard task == .choose,let choice=a["choice"] as? String,(exercise.scenario.choices ?? []).contains(choice) else{throw ProtocolFailure("INVALID_ARGUMENT","Choose one of the options this exercise offers.")}
            default:
                guard task == .move || task == .game,a["from"] is String,a["to"] is String else{throw ProtocolFailure("INVALID_ARGUMENT",task == .move || task == .game ? "A move needs from and to squares.":"This exercise is not answered with a move.")}
                try learnerMayAct(exercise)
            }
            // Help that could not be recorded is never applied: graded, it would count as the learner's own work.
            guard controller.recordAgentHelp().helped else{throw ProtocolFailure("UNAVAILABLE",refusal("The help could not be recorded, so nothing was done."))}
            switch kind {
            case "select":controller.replaceSelection(a["squares"] as! [String])
            case "submit":controller.submit()
            case "none":controller.submit(none:true)
            case "choose":controller.choose(a["choice"] as? String ?? "")
            default:controller.attempt(from:a["from"] as! String,to:a["to"] as! String,promotion:a["promotion"] as? String)
            }
            return result()
        case "request_training_hint":
            let exercise=try current(a)
            // The defender's pending reply keeps its revision, so a hint now would be refused while looking delivered.
            guard !controller.games.thinking else{throw ProtocolFailure("BUSY","The practice defender is choosing its reply.")}
            try learnerMayAct(exercise)
            guard (controller.exercise?.hintLevel ?? 0)<Self.maximumAgentHintLevel else{throw ProtocolFailure("HINT_LIMIT","Further help reveals the answer; only the learner can choose that.")}
            // A hint that was not saved as recorded help was not given: the agent is told, never shown a success.
            guard controller.hint() else{throw ProtocolFailure("UNAVAILABLE",refusal("The hint could not be given."))}
            return result()
        default:
            let action=a["action"] as! String,shown=try current(a,finished:action=="leave" ? nil:true)
            switch action {
            case "leave":controller.leave();return result()
            case "retry":controller.retry()
            default:controller.next()
            }
            // Opening another exercise always gives a new attempt; the same one still shown means nothing opened.
            guard controller.exercise?.snapshot.id != shown.snapshot.id else{throw ProtocolFailure("UNAVAILABLE",controller.notice ?? "The exercise could not be opened.")}
            return result()
        }
    }
    /// The exercise this request was made for is still the one shown, at the same revision, and active or finished as
    /// `finished` requires (nil: either). The attempt revision moves with saved progress; a change that is shown but
    /// not saved, such as the learner's selection, changes the projection and so the session revision, which
    /// `CompanionTools` checks before any training call: a submission read before either change is `STALE_STATE`.
    @discardableResult private func current(_ a:[String:Any],finished:Bool?=false)throws -> TrainingController.Exercise {
        guard case .training=session.activity.place,let exercise=controller.exercise,a["attemptId"] as? String==exercise.snapshot.id,a["sessionRevision"] as? Int==exercise.snapshot.revision else{throw ProtocolFailure("STALE_STATE","The exercise or its revision changed. Read get_session again.")}
        if let finished,finished != exercise.finished{throw ProtocolFailure(finished ? "ATTEMPT_ACTIVE":"ATTEMPT_FINISHED")}
        return exercise
    }
    /// A playable game takes the learner's move or hint only on the learner's turn: a game paused after a defender
    /// failure waits for the opponent's reply, and the controller would refuse the action after help was recorded.
    private func learnerMayAct(_ exercise:TrainingController.Exercise)throws {
        guard exercise.task == .game else{return}
        if let paused=exercise.paused{throw ProtocolFailure("UNAVAILABLE",paused)}
        guard (try? exercise.current?.turn())==exercise.scenario.learner else{throw ProtocolFailure("BUSY","It is the practice defender's turn.")}
    }
    /// Why the controller just refused an action: what it told the learner on the exercise, else its notice.
    private func refusal(_ fallback:String)->String {
        if let feedback=controller.exercise?.feedback,!feedback.isEmpty{return feedback}
        return controller.notice ?? fallback
    }
    private func result()->[String:Any] {["revision":session.revision,"training":session.training.map{jsonObject($0)} ?? NSNull()]}
    private func list()->[String:Any] {
        let training=controller.training
        let entries=(controller.catalog?.entries ?? []).filter{Self.offered($0) && controller.provider?.available($0) != false}.map{entry->[String:Any] in
            ["id":entry.id,"title":entry.title,"summary":entry.summary,"objective":entry.objective.rawValue,"ruleMode":entry.ruleMode.rawValue,"origin":entry.origin.rawValue,"rules":entry.rules,"progress":TrainingRecommendation.progress(entry.id,in:training).lines]
        }
        return ["schemaVersion":1,"entries":entries,"resumableEntryId":controller.resumable?.entry as Any? ?? NSNull(),"keptForNewerVersion":["activeAttempt":training.newerActive != nil,"suggestions":training.newerRetryCount]]
    }
}
