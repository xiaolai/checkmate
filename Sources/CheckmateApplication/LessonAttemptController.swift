import CheckmateDomain
import CheckmateRules
import Foundation
/// What agents read about a lesson exercise: the board the learner sees and where the attempt stands.
public struct LessonAttemptProjection:Codable,Equatable {
    public var attemptId:String,fen:String,turn:String,phase:String,goal:String
    public var checkpoints:[Checkpoint],feedback:String?,thinking:Bool,waitingToResume:Bool
    public struct Checkpoint:Codable,Equatable {public var label:String,done:Bool}
}
/// Runs the exercise of the lesson step shown (its invitation step): one attempt at a time, owned by the lesson and
/// saved in `ApplicationState.lessonAttempts`, never in the practice game.
///
/// The learner plays White. The computer answers with the authored reply inside the opening, otherwise with the
/// practice's opponent, and with the beginner opponent when playing on after success. Every reply is bound to the
/// attempt, its generation and its exact moves: an undo, restart, step change or anything newer drops it unplayed.
@MainActor public final class LessonAttemptController {
    public init(session:GameSession) throws {self.session=session;rules=try ChessRules()}
    private let session:GameSession
    /// The live position of the attempt shown; the judge replays into it.
    public let rules:ChessRules
    public private(set) var lessonID:String?
    public private(set) var practice:LessonPractice?
    public private(set) var record:LessonAttemptRecord?
    public private(set) var judgement:LessonAttemptJudgement?
    public private(set) var selected:String?
    /// The computer is choosing its reply.
    public private(set) var thinking=false
    /// The computer is to move in an attempt that was restored or left: it waits for an explicit Resume.
    public private(set) var waitingToResume=false
    /// A move shown by the third hint, as an arrow; never played.
    public private(set) var hintArrow:[String]?
    /// Something to read that is not the attempt's own state: a refused move's reason, a restart notice, a failure to reply.
    public private(set) var notice:String?
    public var onChange:()->Void={}
    /// A move landed on the board (sound, animation, VoiceOver).
    public var onMove:(MoveRecord)->Void={_ in}
    /// The learner committed a move: narration over the instruction stops.
    public var onLearnerMove:()->Void={}
    /// The attempt's moves were taken back or replaced: queued move sounds and animations must not play.
    public var onReset:()->Void={}
    /// How long the computer waits before playing, on top of its search.
    public var replyDelay:()->Duration={MiniGameOpponent.replyDelay}
    private var work:Task<Void,Never>?,generation=0

    public var active:Bool {practice != nil}
    public var phase:LessonAttemptJudgement.Phase? {judgement?.phase}
    /// Visible hints so far, in order. Word hints describe the starting position, so they show only there; once the
    /// game has moved on, the next hint is a move.
    public var hints:[String] {hasMoves ? []:Array((practice?.hints ?? []).prefix(min(2,record?.hints ?? 0)))}
    public var canShowMove:Bool {hasMoves || (record?.hints ?? 0)>=min(2,practice?.hints?.count ?? 0)}
    public var hasMoves:Bool {!(record?.moves.isEmpty ?? true)}
    /// The learner may move now.
    /// A review shown over the lesson owns the board: nothing reaches the attempt behind it.
    public var learnerToMove:Bool {guard let phase,!thinking,!waitingToResume,!session.reviewSuspended,rules.turn=="w" else{return false};return phase == .yourTurn || phase == .playingOn}
    public var destinations:[String] {guard learnerToMove,let selected else{return []};return Array(Set(rules.moves(selected).map(\.to))).sorted()}
    public var board:Position {rules.board}
    /// Identifies the exact position shown, for a promotion choice made in a menu that stays open while it may change.
    /// The generation changes on leaving, returning, undo and restart, so a choice never revives on an equal history.
    public var identity:String {"\(generation):\(record?.id ?? ""):\(record?.moves.joined(separator:",") ?? "")"}
    public var frame:CourseFrame {
        var hl:[Highlight]=[]
        if let last=rules.records.last{hl=[Highlight(sq:last.from,kind:"last"),Highlight(sq:last.to,kind:"last")]}
        if rules.check,let king=rules.board.first(where:{$0.value==rules.turn+"k"})?.key{hl.append(Highlight(sq:king,kind:"check"))}
        if let hintArrow{hl.append(Highlight(sq:hintArrow[0],kind:"hint"))}
        return CourseFrame(board:rules.board,hl:hl,arrows:hintArrow.map{[$0]} ?? [])
    }
    public var projection:LessonAttemptProjection? {
        guard let practice,let record,let judgement else{return nil}
        return LessonAttemptProjection(attemptId:record.id,fen:rules.fen,turn:rules.turn,phase:judgement.phase.rawValue,goal:practice.goal,checkpoints:zip(practice.checkpoints ?? [],judgement.done).map{.init(label:$0.label,done:$1)},feedback:notice ?? judgement.feedback,thinking:thinking,waitingToResume:waitingToResume)
    }

    // MARK: Opening and leaving
    /// Shows the exercise of `lessonID`: its saved attempt, or a fresh one. A restored computer turn waits for Resume.
    public func open(lessonID:String,practice:LessonPractice){
        if self.lessonID==lessonID,self.practice==practice,record != nil{return}
        cancelReply();self.lessonID=lessonID;self.practice=practice;selected=nil;hintArrow=nil;notice=nil
        let definition=practice.definitionID
        if let saved=session.state.lessonAttempts?[lessonID] {
            if saved.definition != definition {notice="This exercise has changed since you last tried it, so it starts again.";record=LessonAttemptRecord(definition:definition)}
            else {record=saved}
        } else {record=LessonAttemptRecord(definition:definition)}
        if !rejudge(){notice="Your saved attempt could not be replayed, so the exercise starts again.";record=LessonAttemptRecord(definition:definition);_ = rejudge()}
        if session.state.lessonAttempts?[lessonID]==nil,case .object(let kept)?=session.state.unknownFields["lessonAttempts"],kept[lessonID] != nil {notice="Your saved attempt was made by a newer version of Checkmate, so it starts again here. Your first move or hint replaces it."}
        // Opening saves nothing: a replaced or unreadable saved attempt stays on disk until the learner plays this one.
        waitingToResume=computerToMove
        onChange()
    }
    /// Leaves the exercise shown (another step, lesson or activity). Its attempt is already saved; a pending reply is dropped.
    public func close(){suspend();onReset();lessonID=nil;practice=nil;record=nil;judgement=nil;selected=nil;hintArrow=nil;notice=nil;waitingToResume=false}
    /// Stops a pending reply; the computer's turn then waits for Resume.
    public func suspend(){let pending=thinking;cancelReply();if pending || computerToMove && practice != nil{waitingToResume=computerToMove};onChange()}
    public func resume(){guard active else{return};waitingToResume=false;notice=nil;onChange();scheduleReply()}

    // MARK: The learner's moves
    /// A click on the board: choose one of White's pieces, then a destination.
    public func click(_ square:String){
        guard active,ChessRules.validSquare(square) else{return}
        guard learnerToMove else{
            if phase == .offTrack || phase == .failed{notice=judgement?.feedback}
            onChange();return
        }
        if let from=selected,from != square {
            if destinations.contains(square){play(from:from,to:square,promotion:nil);return}
            if !hasMoves,let reason=practice?.mistakes?[from+square]{notice=reason;selected=rules.piece(square)?.color=="w" ? square:nil;onChange();return}
        }
        if selected==square{selected=nil}
        else if rules.piece(square)?.color=="w"{selected=rules.moves(square).isEmpty ? nil:square;notice=selected==nil ? "That piece has no legal move here.":nil}
        else{selected=nil}
        onChange()
    }
    /// A drag dropped on a square the piece cannot reach: a named mistake still explains itself.
    public func refused(from:String,to:String){guard active,!hasMoves,let reason=practice?.mistakes?[from+to] else{return};notice=reason;onChange()}
    public func clearSelection(){guard selected != nil else{return};selected=nil;onChange()}
    public func needsPromotion(from:String,to:String)->Bool {rules.moves(from).contains{$0.to==to && $0.promotion != nil}}
    /// Plays one of White's legal moves. A promotion without a chosen piece is refused: the board asks first.
    public func play(from:String,to:String,promotion:String?){
        guard learnerToMove,var record else{return}
        guard let move=rules.moves(from).first(where:{$0.to==to && ($0.promotion==nil || $0.promotion==promotion)}) else{notice="That move is not legal here.";onChange();return}
        let wasAchieved=judgement?.achieved==true
        record.moves.append(move.uci);self.record=record;selected=nil;hintArrow=nil;notice=nil
        guard rejudge(),let landed=rules.records.last else{self.record?.moves.removeLast();_ = rejudge();onChange();return}
        recordAchievement(was:wasAchieved);save();onLearnerMove();onMove(landed);onChange();scheduleReply()
    }
    /// Back to the learner's previous decision: their last move and any reply after it go.
    public func undo(){
        guard active,var record,!record.moves.isEmpty else{return}
        cancelReply();onReset();let count=record.moves.count;record.moves.removeLast(count%2==0 ? 2:1);self.record=record
        selected=nil;hintArrow=nil;notice=nil;waitingToResume=false
        _ = rejudge();if judgement?.achieved != true{self.record?.playOn=false;_ = rejudge()}
        save();onChange()
    }
    /// A fresh attempt from the practice position; what was achieved before stays achieved.
    public func restart(){guard let practice else{return};cancelReply();onReset();record=LessonAttemptRecord(definition:practice.definitionID);selected=nil;hintArrow=nil;notice=nil;waitingToResume=false;_ = rejudge();save();onChange()}
    /// After success: the game goes on against the beginner opponent.
    public func playOn(){guard phase == .achieved,judgement?.ending==nil,var record else{return};record.playOn=true;self.record=record;_ = rejudge();save();onChange();scheduleReply()}
    /// The next hint stage: two in words, then a move shown as an arrow (from the opening, or the engine's choice).
    public func hint(){
        guard active,var record,learnerToMove || phase == .offTrack else{return}
        let words=min(2,practice?.hints?.count ?? 0)
        if !hasMoves,record.hints<words{record.hints+=1;self.record=record;save();onChange();return}
        record.hints=3;self.record=record;save()
        if phase == .offTrack{notice="Undo your last move first, then ask again.";onChange();return}
        if let node=judgement?.node,let move=practice?.teaching?[node].accepted.first{hintArrow=[String(move.prefix(2)),String(move.dropFirst(2).prefix(2))];onChange();return}
        guard let engine=session.engine,let practice else{notice="A move cannot be shown right now.";onChange();return}
        let token=generation,moves=record.moves
        work=Task{[weak self] in
            let best=try? await engine.analyzeHistory(startFEN:practice.fen,moves:moves,profile:.skill(20),budget:300,multiPv:1).bestMove
            guard let self,!Task.isCancelled,self.generation==token,self.record?.moves==moves else{return}
            self.work=nil
            if let best,best.count>=4{self.hintArrow=[String(best.prefix(2)),String(best.dropFirst(2).prefix(2))]}else{self.notice="A move cannot be shown right now."}
            self.onChange()
        }
        onChange()
    }

    // MARK: The computer's moves
    /// Whether the computer is to play now: inside the opening (or showing a refutation), before success, or when playing on.
    private var computerToMove:Bool {
        guard let judgement,rules.turn=="b",!rules.over else{return false}
        switch judgement.phase {case .computerTurn,.playingOn:return true;case .offTrack:return judgement.authoredReply != nil;default:return false}
    }
    private func scheduleReply(){
        guard active,computerToMove,!waitingToResume,!session.reviewSuspended,let record,let practice,let judgement else{return}
        // A hidden or minimised app holds play, as in Practice: the computer's turn waits for Resume.
        if session.suspended{waitingToResume=true;onChange();return}
        cancelReply();thinking=true;onChange()
        let token=generation,moves=record.moves,id=record.id,authored=judgement.authoredReply,delay=replyDelay()
        let opponent:LessonOpponent=judgement.phase == .playingOn ? .beginner:practice.opponent ?? .beginner
        let engine=session.engine,position=try? rules.copy(),seed=(UInt64(ProgressMigration.digest(id),radix:16) ?? 1) &+ UInt64(moves.count)
        work=Task{[weak self] in
            let started=ContinuousClock.now
            var choice=authored,failed=false
            if choice==nil {
                if let engine,let position {
                    switch opponent {
                    case .beginner:choice=try? await BeginnerOpponent.choose(rules:position,engine:engine,seed:seed).bestMove
                    case .defender:choice=try? await engine.analyzeHistory(startFEN:practice.fen,moves:moves,profile:.skill(20),budget:300,multiPv:1).bestMove
                    }
                }
                failed=choice==nil
            }
            do{try await Task.sleep(for:max(.zero,delay-started.duration(to:.now)))}catch{return}
            guard let self,!Task.isCancelled,self.generation==token,self.record?.id==id,self.record?.moves==moves else{return}
            self.work=nil;self.thinking=false
            if self.session.suspended{self.waitingToResume=true;self.onChange();return}
            if failed{self.waitingToResume=true;self.notice="The computer could not choose a reply. Press Resume to try again.";self.onChange();return}
            self.applyReply(choice!)
        }
    }
    private func applyReply(_ uci:String){
        guard var record,rules.turn=="b",rules.moves().contains(where:{$0.uci==uci}) else{waitingToResume=true;notice="The computer's reply did not fit this position. Press Resume to try again.";onChange();return}
        let wasAchieved=judgement?.achieved==true
        record.moves.append(uci);self.record=record
        guard rejudge(),let landed=rules.records.last else{self.record?.moves.removeLast();_ = rejudge();waitingToResume=true;onChange();return}
        recordAchievement(was:wasAchieved);save();onMove(landed);onChange()
    }
    private func cancelReply(){generation+=1;work?.cancel();work=nil;thinking=false}

    // MARK: Judging and saving
    /// Replays the record into the live position; false when it cannot be replayed.
    @discardableResult private func rejudge()->Bool {
        guard let practice,let record else{judgement=nil;return false}
        do{judgement=try LessonAttemptJudge.judge(practice,moves:record.moves,playOn:record.playOn,rules:rules);return true}catch{judgement=nil;return false}
    }
    private func recordAchievement(was:Bool){
        guard !was,judgement?.achieved==true,let lessonID else{return}
        var practised=session.state.course.practised ?? [];if !practised.contains(lessonID){practised.append(lessonID);session.state.course.practised=practised}
    }
    private func save(){
        guard let lessonID,let record else{return}
        if session.state.lessonAttempts==nil{session.state.lessonAttempts=[:]}
        session.state.lessonAttempts?[lessonID]=record;session.emit(semantic:false,save:true)
    }
}
